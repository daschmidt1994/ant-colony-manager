package service

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/mail"
)

// digestLateLimit: after a longer downtime a missed digest is skipped rather
// than sent in the middle of the night.
const digestLateLimit = 6 * time.Hour

var taskNames = map[string]string{
	"feeding": "Fütterung", "protein": "Proteinfütterung", "carbohydrate": "Kohlenhydrate",
	"water": "Wasser", "cleaning": "Reinigung", "check": "Kontrolle",
}

// SendDigests e-mails the daily overview („7 Kolonien brauchen heute
// Aufmerksamkeit“) to users who enabled it, once per local day at their
// digest time. Mainly for web-only users – the Android app notifies locally.
// Returns the number of e-mails sent.
func (s *Service) SendDigests(ctx context.Context) (int, error) {
	if !s.Mail.Enabled() {
		return 0, nil
	}
	type candidate struct {
		id              uuid.UUID
		email, name, tz string
		digestAt        string
		soonDays        int
		lastSent        *time.Time
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT u.id, u.email, u.display_name, us.timezone, us.digest_time::text, us.due_soon_days, d.sent_on
		FROM users u JOIN user_settings us ON us.id = u.id
		LEFT JOIN digest_log d ON d.user_id = u.id
		WHERE us.email_digest AND u.disabled_at IS NULL`)
	if err != nil {
		return 0, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (candidate, error) {
		var c candidate
		err := r.Scan(&c.id, &c.email, &c.name, &c.tz, &c.digestAt, &c.soonDays, &c.lastSent)
		return c, err
	})
	if err != nil {
		return 0, err
	}
	sent := 0
	for _, c := range list {
		loc, err := time.LoadLocation(c.tz)
		if err != nil {
			loc = time.UTC
		}
		now := s.Now().In(loc)
		today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
		at, err := time.Parse("15:04:05", c.digestAt)
		if err != nil {
			at = time.Date(0, 1, 1, 18, 0, 0, 0, time.UTC)
		}
		due := time.Date(now.Year(), now.Month(), now.Day(), at.Hour(), at.Minute(), 0, 0, loc)
		if now.Before(due) || now.Sub(due) > digestLateLimit || (c.lastSent != nil && !c.lastSent.Before(today)) {
			continue
		}
		msg, err := s.digestFor(ctx, c.id, UserPrefs{Location: loc, SoonDays: c.soonDays})
		if err != nil {
			return sent, err
		}
		if msg != nil {
			msg.To = c.email
			if err := s.Mail.Send(ctx, *msg); err != nil {
				s.Log.Warn("digest mail failed", "user", c.id, "err", err)
				continue // retried at the next tick
			}
			sent++
		}
		if _, err := s.Pool.Exec(ctx, `INSERT INTO digest_log (user_id, sent_on) VALUES ($1, $2)
			ON CONFLICT (user_id) DO UPDATE SET sent_on = excluded.sent_on`, c.id, today); err != nil {
			return sent, err
		}
	}
	return sent, nil
}

// digestFor builds the overview for one user; nil if nothing needs attention.
func (s *Service) digestFor(ctx context.Context, user uuid.UUID, prefs UserPrefs) (*mail.Message, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT c.id, c.name, COALESCE(sp.scientific_name, c.species_text, '')
		FROM colonies c
		JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $1 AND m.deleted_at IS NULL AND m.role <> 'viewer'
		LEFT JOIN species sp ON sp.id = c.species_id
		WHERE c.deleted_at IS NULL AND c.archived_at IS NULL AND c.status IN ('founding', 'active', 'hibernating')`, user)
	if err != nil {
		return nil, err
	}
	type col struct {
		id            uuid.UUID
		name, species string
	}
	cols, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (col, error) {
		var c col
		err := r.Scan(&c.id, &c.name, &c.species)
		return c, err
	})
	if err != nil || len(cols) == 0 {
		return nil, err
	}
	ids := make([]uuid.UUID, len(cols))
	for i, c := range cols {
		ids[i] = c.id
	}
	due, err := s.dueFor(ctx, s.Pool, prefs, ids)
	if err != nil {
		return nil, err
	}
	type line struct {
		days int
		text string
	}
	var lines []line
	overdue := 0
	for _, c := range cols {
		var parts []string
		worstDays := 1
		for _, t := range due[c.id] {
			if t.Status == DuePaused || t.Days > 0 {
				continue
			}
			name := taskNames[t.TaskType]
			if t.Title != nil && *t.Title != "" {
				name = *t.Title
			}
			parts = append(parts, name+" "+dueText(t.Days))
			worstDays = min(worstDays, t.Days)
		}
		if len(parts) == 0 {
			continue
		}
		if worstDays < 0 {
			overdue++
		}
		label := c.name
		if c.species != "" && c.species != c.name {
			label += " (" + c.species + ")"
		}
		lines = append(lines, line{worstDays, "• " + label + ": " + strings.Join(parts, ", ")})
	}
	if len(lines) == 0 {
		return nil, nil
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].days < lines[j].days })
	head := fmt.Sprintf("%d Kolonien brauchen heute Aufmerksamkeit", len(lines))
	if len(lines) == 1 {
		head = "1 Kolonie braucht heute Aufmerksamkeit"
	}
	if overdue > 0 {
		head += fmt.Sprintf(" (%d überfällig)", overdue)
	}
	var b strings.Builder
	b.WriteString(head + "\n\n")
	for _, l := range lines {
		b.WriteString(l.text + "\n")
	}
	fmt.Fprintf(&b, "\nÖffnen: %s/\n\nDiese E-Mail kommt einmal täglich. Abbestellen: Mehr → Erinnerungen → „Tages-Überblick per E-Mail“.\n",
		strings.TrimRight(s.Cfg.PublicURL.String(), "/"))
	return &mail.Message{Subject: "Ameisen: " + head, Body: b.String()}, nil
}

func dueText(days int) string {
	switch {
	case days == 0:
		return "heute fällig"
	case days == -1:
		return "seit 1 Tag überfällig"
	default:
		return fmt.Sprintf("seit %d Tagen überfällig", -days)
	}
}
