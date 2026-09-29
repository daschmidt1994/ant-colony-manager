package service

import (
	"context"
	"crypto/hmac"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
)

// „Morgen“ in a notification: care that is due today or overdue counts as
// not due before tomorrow; a planned winter rest start/end moves by one day.
// ntfy calls a signed link (no login on the phone needed), the app writes
// the same fields itself through sync.

const snoozeLinkMaxAge = 7 * 24 * time.Hour

func (s *Service) snoozeSig(q url.Values) string {
	msg := fmt.Sprintf("snooze:%s:%s:%s:%s", q.Get("u"), q.Get("k"), q.Get("id"), q.Get("exp"))
	return base64.RawURLEncoding.EncodeToString(auth.HMAC(s.Cfg.InstanceSecret, msg))
}

// snoozeURL: absolute link for an ntfy http action. kind is "care" (all care
// of the colony due by today) or "winter" (the colony's winter plan).
func (s *Service) snoozeURL(user uuid.UUID, kind string, colony uuid.UUID) string {
	q := url.Values{"u": {user.String()}, "k": {kind}, "id": {colony.String()},
		"exp": {strconv.FormatInt(s.Now().Add(snoozeLinkMaxAge).Unix(), 10)}}
	q.Set("sig", s.snoozeSig(q))
	return s.publicURL() + "/api/v1/snooze?" + q.Encode()
}

// SnoozeByLink executes a link from snoozeURL. Returns a short confirmation.
func (s *Service) SnoozeByLink(ctx context.Context, q url.Values) (string, error) {
	exp, err := strconv.ParseInt(q.Get("exp"), 10, 64)
	if err != nil || s.Now().Unix() > exp || !hmac.Equal([]byte(s.snoozeSig(q)), []byte(q.Get("sig"))) {
		return "", ErrUnauthorized
	}
	user, err1 := uuid.Parse(q.Get("u"))
	colony, err2 := uuid.Parse(q.Get("id"))
	if err1 != nil || err2 != nil {
		return "", ErrUnauthorized
	}
	var active bool
	if err := s.Pool.QueryRow(ctx, `SELECT disabled_at IS NULL FROM users WHERE id = $1`, user).Scan(&active); err != nil || !active {
		return "", ErrUnauthorized
	}
	actor := Actor{UserID: user}
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleEditor); err != nil {
		return "", err
	}
	prefs := s.userPrefs(ctx, s.Pool, user)
	lang := s.userLang(ctx, user)
	switch q.Get("k") {
	case "care":
		n, err := s.snoozeCare(ctx, colony, prefs.Location)
		if err != nil {
			return "", err
		}
		if n == 0 {
			return tl(lang, "Nichts mehr fällig"), nil
		}
		return tl(lang, "Auf morgen verschoben"), nil
	case "winter":
		if err := s.snoozeWinter(ctx, colony, prefs.Location); err != nil {
			return "", err
		}
		return tl(lang, "Winterruhe um einen Tag verschoben"), nil
	}
	return "", Invalid("k", "unknown kind")
}

// startOfTomorrow in loc, as an instant.
func startOfTomorrow(now time.Time, loc *time.Location) time.Time {
	l := now.In(loc)
	return time.Date(l.Year(), l.Month(), l.Day()+1, 0, 0, 0, 0, loc)
}

// snoozeCare: every care task of the colony that is due today or overdue.
func (s *Service) snoozeCare(ctx context.Context, colony uuid.UUID, loc *time.Location) (int64, error) {
	tomorrow := startOfTomorrow(s.Now(), loc)
	tag, err := s.Pool.Exec(ctx, `UPDATE care_schedules SET snoozed_until = $2
		WHERE id IN (SELECT schedule_id FROM care_due WHERE colony_id = $1 AND next_due_at < $2)`, colony, tomorrow)
	return tag.RowsAffected(), err
}

// snoozeWinter moves the pending step of the open winter plan by one day.
func (s *Service) snoozeWinter(ctx context.Context, colony uuid.UUID, loc *time.Location) error {
	today := s.Now().In(loc).Format(time.DateOnly)
	var id uuid.UUID
	var started bool
	err := s.Pool.QueryRow(ctx, `SELECT id, started_on IS NOT NULL FROM winter_rests
		WHERE colony_id = $1 AND ended_on IS NULL AND deleted_at IS NULL`, colony).Scan(&id, &started)
	if errors.Is(err, pgx.ErrNoRows) {
		return NotFound("winter rest")
	}
	if err != nil {
		return err
	}
	if started {
		_, err = s.Pool.Exec(ctx, `UPDATE winter_rests SET planned_end_on = GREATEST(planned_end_on, $2::date) + 1 WHERE id = $1`, id, today)
		return err
	}
	// the planned end must stay after the start
	_, err = s.Pool.Exec(ctx, `UPDATE winter_rests SET
			planned_start_on = GREATEST(planned_start_on, $2::date) + 1,
			planned_end_on = GREATEST(planned_end_on, GREATEST(planned_start_on, $2::date) + 2)
		WHERE id = $1`, id, today)
	return err
}
