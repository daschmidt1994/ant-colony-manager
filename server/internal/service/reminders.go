package service

import (
	"context"
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

// SendDigests sends the daily overview („7 Kolonien brauchen heute
// Aufmerksamkeit“) by e-mail and/or ntfy to users who enabled it, once per
// local day at their digest time. Returns the number of users reached.
func (s *Service) SendDigests(ctx context.Context) (int, error) {
	type candidate struct {
		id              uuid.UUID
		email, name, tz string
		digestAt        string
		soonDays        int
		lastSent        *time.Time
		byMail          bool
		ntfyURL, token  string
		locale, hint    *string
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT u.id, u.email, u.display_name, us.timezone, us.digest_time::text, us.due_soon_days, d.sent_on,
			us.email_digest AND $1, CASE WHEN np.digest_ntfy THEN COALESCE(np.ntfy_url, '') ELSE '' END,
			COALESCE(np.ntfy_token, ''), us.locale, u.lang_hint
		FROM users u JOIN user_settings us ON us.id = u.id
		LEFT JOIN digest_log d ON d.user_id = u.id
		LEFT JOIN notification_prefs np ON np.user_id = u.id
		WHERE u.disabled_at IS NULL AND ((us.email_digest AND $1) OR (np.digest_ntfy AND np.ntfy_url IS NOT NULL))`,
		s.Mail.Enabled())
	if err != nil {
		return 0, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (candidate, error) {
		var c candidate
		err := r.Scan(&c.id, &c.email, &c.name, &c.tz, &c.digestAt, &c.soonDays, &c.lastSent, &c.byMail, &c.ntfyURL, &c.token,
			&c.locale, &c.hint)
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
		lang := resolveLang(c.locale, c.hint)
		d, err := s.digestFor(ctx, c.id, UserPrefs{Location: loc, SoonDays: c.soonDays}, lang)
		if err != nil {
			return sent, err
		}
		if d != nil {
			ok := false
			if c.ntfyURL != "" {
				n := notice{Title: d.head, Body: strings.Join(d.lines, "\n"), Click: s.publicURL() + "/", Priority: 2, Tags: []string{"ant"}}
				if err := s.sendNtfy(ctx, lang, c.ntfyURL, c.token, n); err != nil {
					s.Log.Warn("digest ntfy failed", "user", c.id, "err", err)
				} else {
					ok = true
				}
			}
			if c.byMail {
				if err := s.Mail.Send(ctx, d.mail(c.email, s.publicURL(), lang)); err != nil {
					s.Log.Warn("digest mail failed", "user", c.id, "err", err)
				} else {
					ok = true
				}
			}
			if !ok {
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

type digest struct {
	head  string
	lines []string
}

func (d *digest) mail(to, publicURL, lang string) mail.Message {
	var b strings.Builder
	b.WriteString(d.head + "\n\n")
	for _, l := range d.lines {
		b.WriteString(l + "\n")
	}
	b.WriteString("\n" + tl(lang, "Öffnen: %s", publicURL+"/") + "\n\n" +
		tl(lang, "Diese E-Mail kommt einmal täglich. Abbestellen: Mehr → Benachrichtigungen → Tages-Überblick.") + "\n")
	return mail.Message{To: to, Subject: tl(lang, "Ameisen: %s", d.head), Body: b.String()}
}

// digestFor builds the overview for one user; nil if nothing needs attention.
func (s *Service) digestFor(ctx context.Context, user uuid.UUID, prefs UserPrefs, lang string) (*digest, error) {
	cols, err := s.careColonies(ctx, user)
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
	winter, err := s.winterDueFor(ctx, ids, s.Now().In(prefs.Location).Format(time.DateOnly))
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
			parts = append(parts, taskLabel(lang, t)+" "+dueText(lang, t.Days))
			worstDays = min(worstDays, t.Days)
		}
		if w := winter[c.id]; w != "" {
			parts = append(parts, winterText(lang, w))
			worstDays = min(worstDays, 0)
		}
		if len(parts) == 0 {
			continue
		}
		if worstDays < 0 {
			overdue++
		}
		lines = append(lines, line{worstDays, "• " + c.label() + ": " + strings.Join(parts, ", ")})
	}
	if len(lines) == 0 {
		return nil, nil
	}
	sort.SliceStable(lines, func(i, j int) bool { return lines[i].days < lines[j].days })
	head := tl(lang, "%d Kolonien brauchen heute Aufmerksamkeit", len(lines))
	if len(lines) == 1 {
		head = tl(lang, "1 Kolonie braucht heute Aufmerksamkeit")
	}
	if overdue > 0 {
		head += tl(lang, " (%d überfällig)", overdue)
	}
	d := &digest{head: head}
	for _, l := range lines {
		d.lines = append(d.lines, l.text)
	}
	return d, nil
}

// winterDueFor: colonies whose planned winter rest should start or end by
// today (the user's local date) – the switch in the app is still pending.
// Values are "start" or "end" (text: winterText).
func (s *Service) winterDueFor(ctx context.Context, ids []uuid.UUID, today string) (map[uuid.UUID]string, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT colony_id, started_on IS NULL FROM winter_rests
		WHERE colony_id = ANY($1) AND deleted_at IS NULL AND ended_on IS NULL
		  AND ((started_on IS NULL AND planned_start_on <= $2::date)
		    OR (started_on IS NOT NULL AND planned_end_on <= $2::date))`, ids, today)
	if err != nil {
		return nil, err
	}
	out := map[uuid.UUID]string{}
	var id uuid.UUID
	var planned bool
	_, err = pgx.ForEachRow(rows, []any{&id, &planned}, func() error {
		out[id] = "end"
		if planned {
			out[id] = "start"
		}
		return nil
	})
	return out, err
}

func winterText(lang, code string) string {
	if code == "start" {
		return tl(lang, "Winterruhe beginnen?")
	}
	return tl(lang, "Winterruhe beenden?")
}

func dueText(lang string, days int) string {
	switch {
	case days == 0:
		return tl(lang, "heute fällig")
	case days == -1:
		return tl(lang, "seit 1 Tag überfällig")
	default:
		return tl(lang, "seit %d Tagen überfällig", -days)
	}
}
