package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/mail"
)

// Notifications per topic (overdue care, sensor alarm, winter rest) via ntfy
// and/or e-mail, with a repeat interval and quiet hours. The daily digest is
// in reminders.go and can go to ntfy as well.

var notifyClient = &http.Client{Timeout: 10 * time.Second}

// NotifyPrefs is the API shape of notification_prefs. The ntfy token is
// write-only: responses only tell whether one is stored.
type NotifyPrefs struct {
	NtfyURL            string  `json:"ntfy_url"`
	NtfyToken          *string `json:"ntfy_token,omitempty"` // input: nil = keep, "" = remove
	NtfyTokenSet       bool    `json:"ntfy_token_set"`
	DigestNtfy         bool    `json:"digest_ntfy"`
	OverdueEmail       bool    `json:"overdue_email"`
	OverdueNtfy        bool    `json:"overdue_ntfy"`
	OverdueRepeatHours int     `json:"overdue_repeat_hours"`
	SensorEmail        bool    `json:"sensor_email"`
	SensorNtfy         bool    `json:"sensor_ntfy"`
	SensorRepeatHours  int     `json:"sensor_repeat_hours"`
	WinterEmail        bool    `json:"winter_email"`
	WinterNtfy         bool    `json:"winter_ntfy"`
	WinterRepeatHours  int     `json:"winter_repeat_hours"`
	QuietStart         string  `json:"quiet_start"` // "HH:MM" or ""
	QuietEnd           string  `json:"quiet_end"`
	QuietExceptSensor  bool    `json:"quiet_except_sensor"`
	EmailAvailable     bool    `json:"email_available"` // server has SMTP (read-only)
}

const prefsCols = `COALESCE(ntfy_url, ''), ntfy_token IS NOT NULL, digest_ntfy, overdue_email, overdue_ntfy, overdue_repeat_hours,
	sensor_email, sensor_ntfy, sensor_repeat_hours, winter_email, winter_ntfy, winter_repeat_hours,
	COALESCE(to_char(quiet_start, 'HH24:MI'), ''), COALESCE(to_char(quiet_end, 'HH24:MI'), ''), quiet_except_sensor`

func (p *NotifyPrefs) scanTargets() []any {
	return []any{&p.NtfyURL, &p.NtfyTokenSet, &p.DigestNtfy, &p.OverdueEmail, &p.OverdueNtfy, &p.OverdueRepeatHours,
		&p.SensorEmail, &p.SensorNtfy, &p.SensorRepeatHours, &p.WinterEmail, &p.WinterNtfy, &p.WinterRepeatHours,
		&p.QuietStart, &p.QuietEnd, &p.QuietExceptSensor}
}

func defaultPrefs() NotifyPrefs {
	return NotifyPrefs{OverdueRepeatHours: 24, SensorRepeatHours: 6, WinterRepeatHours: 24, QuietExceptSensor: true}
}

func (s *Service) NotifyPrefs(ctx context.Context, actor Actor) (*NotifyPrefs, error) {
	p := defaultPrefs()
	err := s.Pool.QueryRow(ctx, `SELECT `+prefsCols+` FROM notification_prefs WHERE user_id = $1`, actor.UserID).Scan(p.scanTargets()...)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	p.EmailAvailable = s.Mail.Enabled()
	return &p, nil
}

func (s *Service) SetNotifyPrefs(ctx context.Context, actor Actor, in NotifyPrefs) (*NotifyPrefs, error) {
	in.NtfyURL = strings.TrimSpace(in.NtfyURL)
	if in.NtfyURL != "" {
		if err := validNtfyURL(in.NtfyURL); err != nil {
			return nil, err
		}
	} else if in.DigestNtfy || in.OverdueNtfy || in.SensorNtfy || in.WinterNtfy {
		return nil, Invalid("ntfy_url", "enter the ntfy topic address first")
	}
	if in.NtfyToken != nil && (len(*in.NtfyToken) > 500 || strings.ContainsAny(*in.NtfyToken, "\r\n")) {
		return nil, Invalid("ntfy_token", "invalid token")
	}
	for field, v := range map[string]struct {
		got     int
		allowed []int
	}{
		"overdue_repeat_hours": {in.OverdueRepeatHours, []int{0, 6, 12, 24}},
		"sensor_repeat_hours":  {in.SensorRepeatHours, []int{0, 1, 6, 12, 24}},
		"winter_repeat_hours":  {in.WinterRepeatHours, []int{0, 24}},
	} {
		if !slices.Contains(v.allowed, v.got) {
			return nil, Invalid(field, "%s must be one of %v", field, v.allowed)
		}
	}
	if (in.QuietStart == "") != (in.QuietEnd == "") {
		return nil, Invalid("quiet_start", "quiet hours need start and end")
	}
	for field, v := range map[string]string{"quiet_start": in.QuietStart, "quiet_end": in.QuietEnd} {
		if _, err := time.Parse("15:04", v); v != "" && err != nil {
			return nil, Invalid(field, "%s must be HH:MM", field)
		}
	}
	keep := in.NtfyToken == nil
	var token *string
	if !keep && *in.NtfyToken != "" {
		t := strings.TrimSpace(*in.NtfyToken)
		token = &t
	}
	_, err := s.Pool.Exec(ctx, `
		INSERT INTO notification_prefs (user_id, ntfy_url, ntfy_token, digest_ntfy, overdue_email, overdue_ntfy, overdue_repeat_hours,
			sensor_email, sensor_ntfy, sensor_repeat_hours, winter_email, winter_ntfy, winter_repeat_hours,
			quiet_start, quiet_end, quiet_except_sensor, updated_at)
		VALUES ($1, NULLIF($2, ''), $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, NULLIF($14, '')::time, NULLIF($15, '')::time, $16, now())
		ON CONFLICT (user_id) DO UPDATE SET
			ntfy_url = excluded.ntfy_url,
			ntfy_token = CASE WHEN $17 THEN notification_prefs.ntfy_token ELSE excluded.ntfy_token END,
			digest_ntfy = excluded.digest_ntfy, overdue_email = excluded.overdue_email, overdue_ntfy = excluded.overdue_ntfy,
			overdue_repeat_hours = excluded.overdue_repeat_hours, sensor_email = excluded.sensor_email,
			sensor_ntfy = excluded.sensor_ntfy, sensor_repeat_hours = excluded.sensor_repeat_hours,
			winter_email = excluded.winter_email, winter_ntfy = excluded.winter_ntfy,
			winter_repeat_hours = excluded.winter_repeat_hours, quiet_start = excluded.quiet_start,
			quiet_end = excluded.quiet_end, quiet_except_sensor = excluded.quiet_except_sensor, updated_at = now()`,
		actor.UserID, in.NtfyURL, token, in.DigestNtfy, in.OverdueEmail, in.OverdueNtfy, in.OverdueRepeatHours,
		in.SensorEmail, in.SensorNtfy, in.SensorRepeatHours, in.WinterEmail, in.WinterNtfy, in.WinterRepeatHours,
		in.QuietStart, in.QuietEnd, in.QuietExceptSensor, keep)
	if err != nil {
		return nil, problemFromDB(err)
	}
	return s.NotifyPrefs(ctx, actor)
}

func validNtfyURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil ||
		u.RawQuery != "" || u.Fragment != "" || len(raw) > 500 {
		return Invalid("ntfy_url", "ntfy address must look like https://ntfy.sh/my-topic")
	}
	if topic := strings.Trim(u.Path, "/"); topic == "" {
		return Invalid("ntfy_url", "the address needs a topic, e.g. https://ntfy.sh/my-topic")
	}
	return nil
}

// TestNotify sends a test message through the saved ntfy settings.
func (s *Service) TestNotify(ctx context.Context, actor Actor) error {
	var u, tok *string
	err := s.Pool.QueryRow(ctx, `SELECT ntfy_url, ntfy_token FROM notification_prefs WHERE user_id = $1`, actor.UserID).Scan(&u, &tok)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && u == nil) {
		return Invalid("ntfy_url", "save an ntfy address first")
	}
	if err != nil {
		return err
	}
	err = s.sendNtfy(ctx, *u, deref(tok), notice{
		Title: "Ant Colony Manager", Body: "Testnachricht – ntfy ist eingerichtet. 🐜",
		Click: s.publicURL() + "/", Priority: 3, Tags: []string{"ant"},
	})
	if err != nil {
		return &Problem{Status: http.StatusBadGateway, Code: "notify.ntfy_failed", Title: err.Error()}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Delivery

type notice struct {
	Title, Body, Click string
	Priority           int // ntfy: 1 min … 5 max
	Tags               []string
}

// sendNtfy publishes as JSON to the server root, so titles may contain
// umlauts. The token may be an access token (tk_…) or "user:password".
func (s *Service) sendNtfy(ctx context.Context, topicURL, token string, n notice) error {
	u, err := url.Parse(topicURL)
	if err != nil {
		return err
	}
	path := strings.Trim(u.Path, "/")
	base, topic := "", path
	if i := strings.LastIndex(path, "/"); i >= 0 {
		base, topic = path[:i], path[i+1:]
	}
	u.Path = "/" + base
	body, _ := json.Marshal(map[string]any{
		"topic": topic, "title": n.Title, "message": n.Body, "priority": n.Priority, "tags": n.Tags, "click": n.Click,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		if user, pass, ok := strings.Cut(token, ":"); ok {
			req.SetBasicAuth(user, pass)
		} else {
			req.Header.Set("Authorization", "Bearer "+token)
		}
	}
	resp, err := notifyClient.Do(req)
	if err != nil {
		return fmt.Errorf("ntfy nicht erreichbar: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
		switch resp.StatusCode {
		case http.StatusUnauthorized, http.StatusForbidden:
			return fmt.Errorf("ntfy lehnt ab (%d) – Token oder Berechtigung für das Topic prüfen", resp.StatusCode)
		}
		return fmt.Errorf("ntfy antwortet %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
	}
	return nil
}

type recipient struct {
	id               uuid.UUID
	email            string
	ntfyURL, token   string
	loc              *time.Location
	soonDays         int
	digestAt         time.Time // time of day
	quietFrom, quiet *time.Time
	quietSensor      bool
	prefs            NotifyPrefs
}

// deliver sends over the chosen channels; true if at least one worked.
func (s *Service) deliver(ctx context.Context, r recipient, emailOn, ntfyOn bool, n notice) bool {
	ok := false
	if ntfyOn && r.ntfyURL != "" {
		if err := s.sendNtfy(ctx, r.ntfyURL, r.token, n); err != nil {
			s.Log.Warn("ntfy notification failed", "user", r.id, "err", err)
		} else {
			ok = true
		}
	}
	if emailOn && s.Mail.Enabled() {
		body := n.Body + "\n\nÖffnen: " + n.Click + "\n\nEinstellen: Mehr → Benachrichtigungen\n"
		if err := s.Mail.Send(ctx, mail.Message{To: r.email, Subject: "Ameisen: " + n.Title, Body: body}); err != nil {
			s.Log.Warn("notification mail failed", "user", r.id, "err", err)
		} else {
			ok = true
		}
	}
	return ok
}

func (s *Service) publicURL() string { return strings.TrimRight(s.Cfg.PublicURL.String(), "/") }

// ---------------------------------------------------------------------------
// Scheduler: runs every minute.

// SendNotifications checks overdue care, sensor limits and planned winter
// rests for every user with an active topic and sends what is due. Returns
// the number of notifications sent.
func (s *Service) SendNotifications(ctx context.Context) (int, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT u.id, u.email, COALESCE(np.ntfy_token, ''), us.timezone, us.digest_time::text, us.due_soon_days,
			np.quiet_start::text, np.quiet_end::text, `+prefsCols+`
		FROM notification_prefs np
		JOIN users u ON u.id = np.user_id AND u.disabled_at IS NULL
		JOIN user_settings us ON us.id = u.id
		WHERE np.overdue_email OR np.overdue_ntfy OR np.sensor_email OR np.sensor_ntfy OR np.winter_email OR np.winter_ntfy`)
	if err != nil {
		return 0, err
	}
	list, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (recipient, error) {
		var r recipient
		var tz, digest string
		var qs, qe *string
		r.prefs = defaultPrefs()
		err := row.Scan(append([]any{&r.id, &r.email, &r.token, &tz, &digest, &r.soonDays, &qs, &qe}, r.prefs.scanTargets()...)...)
		if err != nil {
			return r, err
		}
		r.ntfyURL = r.prefs.NtfyURL
		if r.loc, err = time.LoadLocation(tz); err != nil {
			r.loc = time.UTC
		}
		if r.digestAt, err = time.Parse("15:04:05", digest); err != nil {
			r.digestAt = time.Date(0, 1, 1, 18, 0, 0, 0, time.UTC)
		}
		if qs != nil && qe != nil {
			a, errA := time.Parse("15:04:05", *qs)
			b, errB := time.Parse("15:04:05", *qe)
			if errA == nil && errB == nil {
				r.quietFrom, r.quiet = &a, &b
			}
		}
		r.quietSensor = r.prefs.QuietExceptSensor
		return r, nil
	})
	if err != nil {
		return 0, err
	}
	sent := 0
	for _, r := range list {
		n, err := s.notifyUser(ctx, r)
		sent += n
		if err != nil {
			return sent, err
		}
	}
	return sent, nil
}

// inQuiet: local time of day within [from, to); the window may span midnight.
func inQuiet(now time.Time, from, to *time.Time) bool {
	if from == nil || to == nil {
		return false
	}
	m := now.Hour()*60 + now.Minute()
	a, b := from.Hour()*60+from.Minute(), to.Hour()*60+to.Minute()
	if a == b {
		return false
	}
	if a < b {
		return m >= a && m < b
	}
	return m >= a || m < b
}

type pending struct {
	colony uuid.UUID
	keys   []string
	lines  []string
}

func (s *Service) notifyUser(ctx context.Context, r recipient) (int, error) {
	now := s.Now()
	local := now.In(r.loc)
	quiet := inQuiet(local, r.quietFrom, r.quiet)
	cols, err := s.careColonies(ctx, r.id)
	if err != nil || len(cols) == 0 {
		return 0, err
	}
	ids := make([]uuid.UUID, len(cols))
	byID := map[uuid.UUID]careColony{}
	for i, c := range cols {
		ids[i] = c.id
		byID[c.id] = c
	}
	rows, err := s.Pool.Query(ctx, `SELECT key, sent_at FROM notification_log WHERE user_id = $1`, r.id)
	if err != nil {
		return 0, err
	}
	logged := map[string]time.Time{}
	var k string
	var at time.Time
	if _, err := pgx.ForEachRow(rows, []any{&k, &at}, func() error { logged[k] = at; return nil }); err != nil {
		return 0, err
	}
	active := []string{}
	due := func(key string, repeatHours int) bool {
		active = append(active, key)
		last, ok := logged[key]
		if !ok {
			return true
		}
		return repeatHours > 0 && now.Sub(last) >= time.Duration(repeatHours)*time.Hour-time.Minute
	}
	collect := func(m map[uuid.UUID]*pending, colony uuid.UUID, key, line string) {
		p := m[colony]
		if p == nil {
			p = &pending{colony: colony}
			m[colony] = p
		}
		p.keys = append(p.keys, key)
		p.lines = append(p.lines, line)
	}
	sent := 0
	send := func(m map[uuid.UUID]*pending, emailOn, ntfyOn bool, title string, prio int, tags []string) error {
		for _, p := range m {
			c := byID[p.colony]
			n := notice{Title: c.label() + ": " + title, Body: strings.Join(p.lines, "\n"),
				Click: s.publicURL() + "/colonies/" + c.id.String(), Priority: prio, Tags: tags}
			if !s.deliver(ctx, r, emailOn, ntfyOn, n) {
				continue // retried next minute
			}
			sent++
			for _, key := range p.keys {
				if _, err := s.Pool.Exec(ctx, `INSERT INTO notification_log (user_id, key, sent_at) VALUES ($1, $2, $3)
					ON CONFLICT (user_id, key) DO UPDATE SET sent_at = excluded.sent_at`, r.id, key, now); err != nil {
					return err
				}
			}
		}
		return nil
	}
	p := r.prefs

	// Overdue care, one message per colony.
	if p.OverdueEmail || p.OverdueNtfy {
		tasks, err := s.dueFor(ctx, s.Pool, UserPrefs{Location: r.loc, SoonDays: r.soonDays}, ids)
		if err != nil {
			return sent, err
		}
		out := map[uuid.UUID]*pending{}
		for colony, ts := range tasks {
			for _, t := range ts {
				if t.Status != DueOverdue || t.NextDueAt == nil {
					continue
				}
				key := fmt.Sprintf("overdue:%s:%d", t.ScheduleID, t.NextDueAt.Unix())
				if due(key, p.OverdueRepeatHours) && !quiet {
					collect(out, colony, key, taskLabel(t)+" "+dueText(t.Days))
				}
			}
		}
		if err := send(out, p.OverdueEmail, p.OverdueNtfy, "Pflege überfällig", 3, []string{"ant"}); err != nil {
			return sent, err
		}
	}

	// Sensor limits: newest reading of the last 2 hours per sensor and metric.
	if p.SensorEmail || p.SensorNtfy {
		rows, err := s.Pool.Query(ctx, `
			SELECT s.id, s.name, s.colony_id, r.metric, r.value::float8,
				s.temp_min::float8, s.temp_max::float8, s.humidity_min::float8, s.humidity_max::float8
			FROM sensors s
			JOIN LATERAL (SELECT DISTINCT ON (metric) metric, value FROM sensor_readings
				WHERE sensor_id = s.id AND measured_at > $2 ORDER BY metric, measured_at DESC) r ON true
			WHERE s.colony_id = ANY($1) AND s.deleted_at IS NULL AND s.active`, ids, now.Add(-2*time.Hour))
		if err != nil {
			return sent, err
		}
		out := map[uuid.UUID]*pending{}
		var id, colony uuid.UUID
		var name, metric string
		var value float64
		var tMin, tMax, hMin, hMax *float64
		_, err = pgx.ForEachRow(rows, []any{&id, &name, &colony, &metric, &value, &tMin, &tMax, &hMin, &hMax}, func() error {
			if line := limitText(name, metric, value, tMin, tMax, hMin, hMax); line != "" {
				key := "sensor:" + id.String() + ":" + metric
				if due(key, p.SensorRepeatHours) && (!quiet || r.quietSensor) {
					collect(out, colony, key, line)
				}
			}
			return nil
		})
		if err != nil {
			return sent, err
		}
		if err := send(out, p.SensorEmail, p.SensorNtfy, "Sensor-Alarm", 4, []string{"warning"}); err != nil {
			return sent, err
		}
	}

	// Winter rest start/end on the planned day, from the digest time on.
	if p.WinterEmail || p.WinterNtfy {
		at := time.Date(local.Year(), local.Month(), local.Day(), r.digestAt.Hour(), r.digestAt.Minute(), 0, 0, r.loc)
		if !local.Before(at) {
			winter, err := s.winterDueFor(ctx, ids, local.Format(time.DateOnly))
			if err != nil {
				return sent, err
			}
			out := map[uuid.UUID]*pending{}
			for colony, text := range winter {
				key := "winter:" + colony.String() + ":" + text
				if due(key, p.WinterRepeatHours) && !quiet {
					collect(out, colony, key, text)
				}
			}
			if err := send(out, p.WinterEmail, p.WinterNtfy, "Winterruhe", 3, []string{"snowflake"}); err != nil {
				return sent, err
			}
		} else {
			// before the digest time: keep today's winter keys (no reset)
			for key := range logged {
				if strings.HasPrefix(key, "winter:") {
					active = append(active, key)
				}
			}
		}
	}

	// Occasions that are over start from scratch next time.
	_, err = s.Pool.Exec(ctx, `DELETE FROM notification_log WHERE user_id = $1 AND NOT (key = ANY($2))`, r.id, active)
	return sent, err
}

func taskLabel(t DueTask) string {
	if t.Title != nil && *t.Title != "" {
		return *t.Title
	}
	return taskNames[t.TaskType]
}

// limitText describes a reading outside the sensor's limits, "" if fine.
func limitText(sensor, metric string, v float64, tMin, tMax, hMin, hMax *float64) string {
	lo, hi, label, unit := tMin, tMax, "Temperatur", "°C"
	if metric == "humidity" {
		lo, hi, label, unit = hMin, hMax, "Luftfeuchtigkeit", "%"
	}
	switch {
	case hi != nil && v > *hi:
		return fmt.Sprintf("Sensor „%s“: %s %s %s – über dem Grenzwert %s %s", sensor, label, num(v), unit, num(*hi), unit)
	case lo != nil && v < *lo:
		return fmt.Sprintf("Sensor „%s“: %s %s %s – unter dem Grenzwert %s %s", sensor, label, num(v), unit, num(*lo), unit)
	}
	return ""
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// ---------------------------------------------------------------------------

type careColony struct {
	id            uuid.UUID
	name, species string
}

func (c careColony) label() string {
	if c.species != "" && c.species != c.name {
		return c.name + " (" + c.species + ")"
	}
	return c.name
}

// careColonies: colonies the user cares for (not only viewing) that are in care.
func (s *Service) careColonies(ctx context.Context, user uuid.UUID) ([]careColony, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT c.id, c.name, COALESCE(sp.scientific_name, c.species_text, '')
		FROM colonies c
		JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $1 AND m.deleted_at IS NULL AND m.role <> 'viewer'
		LEFT JOIN species sp ON sp.id = c.species_id
		WHERE c.deleted_at IS NULL AND c.archived_at IS NULL AND c.status IN ('founding', 'active', 'hibernating')`, user)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (careColony, error) {
		var c careColony
		err := r.Scan(&c.id, &c.name, &c.species)
		return c, err
	})
}
