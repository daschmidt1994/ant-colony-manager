package service

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
)

// Feeds: a read-only calendar subscription (iCal) of the user's colonies. It
// authenticates with one secret per user ("acm_fk_<prefix>_<secret>") in the
// address, because calendar apps cannot send headers. The same data feeds the
// colony status that is sent to Home Assistant via MQTT (mqtt.go).

var errBadFeedToken = &Problem{Status: 404, Code: "feed.not_found", Title: "feed not found"}

// FeedInfo tells the app whether a feed address exists (never the token itself).
type FeedInfo struct {
	Active     bool       `json:"active"`
	CreatedAt  *time.Time `json:"created_at,omitempty"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
}

func (s *Service) FeedInfo(ctx context.Context, actor Actor) (*FeedInfo, error) {
	var f FeedInfo
	err := s.Pool.QueryRow(ctx, `SELECT created_at, last_used_at FROM feed_tokens WHERE user_id = $1`, actor.UserID).
		Scan(&f.CreatedAt, &f.LastUsedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return &f, nil
	}
	f.Active = err == nil
	return &f, err
}

// CreateFeedToken issues a new token; an existing one stops working.
func (s *Service) CreateFeedToken(ctx context.Context, actor Actor) (string, error) {
	prefix, secret := newSensorKey()
	_, err := s.Pool.Exec(ctx, `
		INSERT INTO feed_tokens (user_id, prefix, token_hash) VALUES ($1, $2, $3)
		ON CONFLICT (user_id) DO UPDATE SET prefix = $2, token_hash = $3, created_at = now(), last_used_at = NULL`,
		actor.UserID, prefix, auth.HashToken(secret))
	if err != nil {
		return "", err
	}
	return "acm_fk_" + prefix + "_" + secret, nil
}

func (s *Service) DeleteFeedToken(ctx context.Context, actor Actor) error {
	_, err := s.Pool.Exec(ctx, `DELETE FROM feed_tokens WHERE user_id = $1`, actor.UserID)
	return err
}

// FeedUser resolves a token to its user; unknown tokens look like a missing page.
func (s *Service) FeedUser(ctx context.Context, token string) (uuid.UUID, error) {
	parts := strings.SplitN(token, "_", 4)
	if len(parts) != 4 || parts[0] != "acm" || parts[1] != "fk" || parts[2] == "" || parts[3] == "" {
		return uuid.Nil, errBadFeedToken
	}
	var user uuid.UUID
	var hash []byte
	err := s.Pool.QueryRow(ctx, `SELECT user_id, token_hash FROM feed_tokens WHERE prefix = $1`, parts[2]).Scan(&user, &hash)
	if errors.Is(err, pgx.ErrNoRows) {
		auth.HashToken(parts[3]) // keep timing similar
		return uuid.Nil, errBadFeedToken
	}
	if err != nil {
		return uuid.Nil, err
	}
	if subtle.ConstantTimeCompare(auth.HashToken(parts[3]), hash) != 1 {
		return uuid.Nil, errBadFeedToken
	}
	// at most once a minute – polling every few seconds must not write constantly
	_, _ = s.Pool.Exec(ctx, `UPDATE feed_tokens SET last_used_at = now()
		WHERE user_id = $1 AND (last_used_at IS NULL OR last_used_at < now() - interval '1 minute')`, user)
	return user, nil
}

// ---------------------------------------------------------------------------
// Colony status (Home Assistant via MQTT)

type FeedNextDue struct {
	Task  string    `json:"task"`
	At    time.Time `json:"at"`
	Days  int       `json:"days"`
	State string    `json:"state"`
}

type FeedWinter struct {
	PlannedStartOn *string `json:"planned_start_on"`
	StartedOn      *string `json:"started_on"`
	PlannedEndOn   *string `json:"planned_end_on"`
}

type FeedColony struct {
	ID          uuid.UUID    `json:"id"`
	Number      int          `json:"number"`
	Name        string       `json:"name"`
	Species     string       `json:"species"`
	Status      string       `json:"status"`
	Hibernating bool         `json:"hibernating"`
	Overdue     int          `json:"overdue"`
	DueToday    int          `json:"due_today"`
	NextDue     *FeedNextDue `json:"next_due"`
	Winter      *FeedWinter  `json:"winter"`
	Temperature *float64     `json:"temperature"`
	Humidity    *float64     `json:"humidity"`
	MeasuredAt  *time.Time   `json:"measured_at"`
}

type FeedStatus struct {
	GeneratedAt time.Time    `json:"generated_at"`
	Overdue     int          `json:"overdue"`
	DueToday    int          `json:"due_today"`
	Hibernating int          `json:"hibernating"`
	Colonies    []FeedColony `json:"colonies"`
}

type feedData struct {
	lang     string
	prefs    UserPrefs
	colonies []FeedColony
	due      map[uuid.UUID][]DueTask
	tasks    []feedTask
}

type feedTask struct {
	id       uuid.UUID
	colonyID *uuid.UUID
	title    string
	dueAt    time.Time
}

// feedLoad: the colonies the user cares for, with due care, winter rests,
// last measurement and open one-off tasks.
func (s *Service) feedLoad(ctx context.Context, user uuid.UUID) (*feedData, error) {
	d := &feedData{lang: s.userLang(ctx, user), prefs: s.userPrefs(ctx, s.Pool, user)}
	rows, err := s.Pool.Query(ctx, `
		SELECT c.id, c.number, c.name, COALESCE(sp.scientific_name, c.species_text, ''), c.status, c.last_measurement,
		       w.planned_start_on::text, w.started_on::text, w.planned_end_on::text
		FROM colonies c
		JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $1 AND m.deleted_at IS NULL AND m.role <> 'viewer'
		LEFT JOIN species sp ON sp.id = c.species_id
		LEFT JOIN LATERAL (SELECT planned_start_on, started_on, planned_end_on FROM winter_rests
		                   WHERE colony_id = c.id AND deleted_at IS NULL AND ended_on IS NULL
		                   ORDER BY id DESC LIMIT 1) w ON true
		WHERE c.deleted_at IS NULL AND c.archived_at IS NULL AND c.status IN ('founding', 'active', 'hibernating')
		ORDER BY c.number`, user)
	if err != nil {
		return nil, err
	}
	d.colonies, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (FeedColony, error) {
		var c FeedColony
		var measurement []byte
		var w FeedWinter
		if err := r.Scan(&c.ID, &c.Number, &c.Name, &c.Species, &c.Status, &measurement,
			&w.PlannedStartOn, &w.StartedOn, &w.PlannedEndOn); err != nil {
			return c, err
		}
		if w.PlannedStartOn != nil || w.StartedOn != nil {
			c.Winter = &w
		}
		c.Hibernating = c.Status == "hibernating" || w.StartedOn != nil
		if len(measurement) > 0 {
			var m struct {
				Temperature *float64   `json:"temperature"`
				Humidity    *float64   `json:"humidity"`
				At          *time.Time `json:"at"`
			}
			if json.Unmarshal(measurement, &m) == nil {
				c.Temperature, c.Humidity, c.MeasuredAt = m.Temperature, m.Humidity, m.At
			}
		}
		return c, nil
	})
	if err != nil {
		return nil, err
	}
	ids := make([]uuid.UUID, len(d.colonies))
	for i, c := range d.colonies {
		ids[i] = c.ID
	}
	if d.due, err = s.dueFor(ctx, s.Pool, d.prefs, ids); err != nil {
		return nil, err
	}
	rows, err = s.Pool.Query(ctx, `SELECT id, colony_id, title, due_at FROM tasks
		WHERE owner_id = $1 AND deleted_at IS NULL AND done_at IS NULL AND due_at IS NOT NULL
		  AND (colony_id IS NULL OR colony_id = ANY($2))
		ORDER BY due_at LIMIT 500`, user, ids)
	if err != nil {
		return nil, err
	}
	d.tasks, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (feedTask, error) {
		var t feedTask
		err := r.Scan(&t.id, &t.colonyID, &t.title, &t.dueAt)
		return t, err
	})
	return d, err
}

// colonyStatus: per colony hibernating, overdue/due today, next due care and
// last measurement, plus totals.
func (s *Service) colonyStatus(ctx context.Context, user uuid.UUID) (*FeedStatus, error) {
	d, err := s.feedLoad(ctx, user)
	if err != nil {
		return nil, err
	}
	out := &FeedStatus{GeneratedAt: s.Now().UTC(), Colonies: d.colonies}
	if out.Colonies == nil {
		out.Colonies = []FeedColony{}
	}
	for i := range out.Colonies {
		c := &out.Colonies[i]
		for _, t := range d.due[c.ID] {
			if t.Status == DuePaused || t.NextDueAt == nil {
				continue
			}
			switch {
			case t.Days < 0:
				c.Overdue++
			case t.Days == 0:
				c.DueToday++
			}
			if c.NextDue == nil || t.NextDueAt.Before(c.NextDue.At) {
				c.NextDue = &FeedNextDue{Task: taskLabel(d.lang, t), At: *t.NextDueAt, Days: t.Days, State: t.Status}
			}
		}
		out.Overdue += c.Overdue
		out.DueToday += c.DueToday
		if c.Hibernating {
			out.Hibernating++
		}
	}
	return out, nil
}

// ---------------------------------------------------------------------------
// Calendar (iCal, RFC 5545)

// FeedCalendar lists the next due date of every care plan (overdue ones
// today), planned winter rest starts and ends, and open one-off tasks.
func (s *Service) FeedCalendar(ctx context.Context, user uuid.UUID) ([]byte, error) {
	d, err := s.feedLoad(ctx, user)
	if err != nil {
		return nil, err
	}
	now := s.Now()
	today := now.In(d.prefs.Location)
	stamp := now.UTC().Format("20060102T150405Z")
	byID := map[uuid.UUID]FeedColony{}
	for _, c := range d.colonies {
		byID[c.ID] = c
	}
	label := func(c FeedColony) string {
		if c.Species != "" && c.Species != c.Name {
			return fmt.Sprintf("%s (#%d, %s)", c.Name, c.Number, c.Species)
		}
		return fmt.Sprintf("%s (#%d)", c.Name, c.Number)
	}
	link := func(c FeedColony) string { return s.publicURL() + "/colonies/" + c.ID.String() }

	type event struct {
		uid, summary, description, url string
		day                            *time.Time // all-day
		at                             *time.Time // timed (30 min)
	}
	var events []event
	for _, c := range d.colonies {
		for _, t := range d.due[c.ID] {
			if t.Status == DuePaused || t.NextDueAt == nil {
				continue
			}
			day := t.NextDueAt.In(d.prefs.Location)
			desc := ""
			if t.Days < 0 {
				day = today
				desc = dueText(d.lang, t.Days)
			}
			events = append(events, event{uid: "due-" + t.ScheduleID.String(), day: &day, url: link(c),
				summary: "🐜 " + taskLabel(d.lang, t) + " – " + label(c), description: desc})
		}
		if w := c.Winter; w != nil {
			if w.StartedOn == nil && w.PlannedStartOn != nil {
				if day, err := time.ParseInLocation(time.DateOnly, *w.PlannedStartOn, d.prefs.Location); err == nil {
					events = append(events, event{uid: "winter-start-" + c.ID.String(), day: &day, url: link(c),
						summary: "❄ " + tl(d.lang, "Winterruhe beginnen?") + " – " + label(c)})
				}
			}
			if w.PlannedEndOn != nil {
				if day, err := time.ParseInLocation(time.DateOnly, *w.PlannedEndOn, d.prefs.Location); err == nil {
					events = append(events, event{uid: "winter-end-" + c.ID.String(), day: &day, url: link(c),
						summary: "☀ " + tl(d.lang, "Winterruhe beenden?") + " – " + label(c)})
				}
			}
		}
	}
	for _, t := range d.tasks {
		at := t.dueAt
		summary, url := "📋 "+t.title, s.publicURL()+"/"
		if t.colonyID != nil {
			c, ok := byID[*t.colonyID]
			if !ok {
				continue
			}
			summary += " – " + label(c)
			url = link(c)
		}
		events = append(events, event{uid: "task-" + t.id.String(), at: &at, summary: summary, url: url})
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].uid < events[j].uid })

	var b strings.Builder
	line := func(s string) { b.WriteString(icalFold(s) + "\r\n") }
	line("BEGIN:VCALENDAR")
	line("VERSION:2.0")
	line("PRODID:-//Ant Colony Manager//" + d.lang + "//")
	line("CALSCALE:GREGORIAN")
	line("METHOD:PUBLISH")
	line("X-WR-CALNAME:" + icalText(tl(d.lang, "Ameisen")))
	line("X-WR-TIMEZONE:" + d.prefs.Location.String())
	line("REFRESH-INTERVAL;VALUE=DURATION:PT1H")
	line("X-PUBLISHED-TTL:PT1H")
	for _, e := range events {
		line("BEGIN:VEVENT")
		line("UID:" + e.uid + "@ant-colony-manager")
		line("DTSTAMP:" + stamp)
		if e.day != nil {
			line("DTSTART;VALUE=DATE:" + e.day.Format("20060102"))
			line("DTEND;VALUE=DATE:" + e.day.AddDate(0, 0, 1).Format("20060102"))
			line("TRANSP:TRANSPARENT")
		} else {
			line("DTSTART:" + e.at.UTC().Format("20060102T150405Z"))
			line("DTEND:" + e.at.Add(30*time.Minute).UTC().Format("20060102T150405Z"))
		}
		line("SUMMARY:" + icalText(e.summary))
		if e.description != "" {
			line("DESCRIPTION:" + icalText(e.description))
		}
		line("URL:" + e.url)
		line("END:VEVENT")
	}
	line("END:VCALENDAR")
	return []byte(b.String()), nil
}

// icalText escapes a TEXT value (RFC 5545 3.3.11).
func icalText(s string) string {
	return strings.NewReplacer(`\`, `\\`, ";", `\;`, ",", `\,`, "\r\n", `\n`, "\n", `\n`).Replace(s)
}

// icalFold wraps content lines at 75 octets without splitting UTF-8 characters.
func icalFold(s string) string {
	if len(s) <= 75 {
		return s
	}
	var b strings.Builder
	n := 0
	for _, r := range s {
		size := len(string(r))
		if n+size > 75 {
			b.WriteString("\r\n ")
			n = 1
		}
		b.WriteRune(r)
		n += size
	}
	return b.String()
}
