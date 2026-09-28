package api_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// fakeNtfy records what the server publishes (JSON to the server root).
type fakeNtfy struct {
	*httptest.Server
	mu     sync.Mutex
	msgs   []map[string]any
	auth   []string
	status int
}

func newFakeNtfy(t *testing.T) *fakeNtfy {
	f := &fakeNtfy{status: 200}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.status != 200 {
			w.WriteHeader(f.status)
			return
		}
		var m map[string]any
		_ = json.NewDecoder(r.Body).Decode(&m)
		m["_path"] = r.URL.Path
		f.msgs = append(f.msgs, m)
		f.auth = append(f.auth, r.Header.Get("Authorization"))
	}))
	t.Cleanup(f.Close)
	return f
}

func (f *fakeNtfy) take() []map[string]any {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.msgs
	f.msgs = nil
	return out
}

func TestNotifySettingsAndTestMessage(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	ntfy := newFakeNtfy(t)

	p := anna.Do("GET", "/api/v1/me/notifications", nil).Must(t, 200).JSON()
	if p["ntfy_url"] != "" || p["sensor_repeat_hours"] != 6.0 || p["quiet_except_sensor"] != true {
		t.Fatalf("defaults: %v", p)
	}
	base := map[string]any{"ntfy_url": ntfy.URL + "/sub/ants", "ntfy_token": "tk_secret", "overdue_repeat_hours": 24,
		"sensor_repeat_hours": 6, "winter_repeat_hours": 24, "sensor_ntfy": true}
	p = anna.Do("PUT", "/api/v1/me/notifications", base).Must(t, 200).JSON()
	if p["ntfy_token_set"] != true || p["ntfy_token"] != nil || p["sensor_ntfy"] != true {
		t.Fatalf("saved: %v", p)
	}
	// Token omitted → kept; the test message uses it, topic from the last path segment.
	delete(base, "ntfy_token")
	anna.Do("PUT", "/api/v1/me/notifications", base).Must(t, 200)
	anna.Do("POST", "/api/v1/me/notifications/test", nil).Must(t, 204)
	msgs := ntfy.take()
	if len(msgs) != 1 || msgs[0]["topic"] != "ants" || msgs[0]["_path"] != "/sub" || ntfy.auth[0] != "Bearer tk_secret" {
		t.Fatalf("test message: %v %v", msgs, ntfy.auth)
	}
	ntfy.status = 403
	if r := anna.Do("POST", "/api/v1/me/notifications/test", nil); r.Status != http.StatusBadGateway || !strings.Contains(string(r.Body), "Token") {
		t.Fatalf("refused ntfy: %d %s", r.Status, r.Body)
	}

	for name, body := range map[string]map[string]any{
		"no topic":     {"ntfy_url": ntfy.URL, "overdue_repeat_hours": 24, "sensor_repeat_hours": 6, "winter_repeat_hours": 24},
		"not http":     {"ntfy_url": "file:///etc/passwd", "overdue_repeat_hours": 24, "sensor_repeat_hours": 6, "winter_repeat_hours": 24},
		"ntfy w/o url": {"overdue_ntfy": true, "overdue_repeat_hours": 24, "sensor_repeat_hours": 6, "winter_repeat_hours": 24},
		"bad repeat":   {"overdue_repeat_hours": 5, "sensor_repeat_hours": 6, "winter_repeat_hours": 24},
		"half quiet":   {"quiet_start": "22:00", "overdue_repeat_hours": 24, "sensor_repeat_hours": 6, "winter_repeat_hours": 24},
	} {
		if r := anna.Do("PUT", "/api/v1/me/notifications", body); r.Status < 400 || r.Status >= 500 {
			t.Errorf("%s: want 4xx, got %d", name, r.Status)
		}
	}
	// Removing the token.
	base["ntfy_token"] = ""
	if p := anna.Do("PUT", "/api/v1/me/notifications", base).Must(t, 200).JSON(); p["ntfy_token_set"] != false {
		t.Fatalf("token not removed: %v", p)
	}
}

func TestNotifyOverdueSensorQuietHoursAndDigest(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	ntfy := newFakeNtfy(t)
	ctx := context.Background()
	colony := anna.CreateColony(t, map[string]any{"name": "Messor #12", "species_text": "Messor barbarus"})
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony, "task_type": "protein", "interval_days": 2,
			"starts_at": time.Now().Add(-5 * 24 * time.Hour)})})
	anna.Do("PATCH", "/api/v1/me/settings", map[string]any{"timezone": middayZone()}).Must(t, 200)
	prefs := map[string]any{"ntfy_url": ntfy.URL + "/ants", "overdue_ntfy": true, "overdue_repeat_hours": 0,
		"sensor_ntfy": true, "sensor_repeat_hours": 6, "winter_repeat_hours": 24, "quiet_except_sensor": true}
	anna.Do("PUT", "/api/v1/me/notifications", prefs).Must(t, 200)
	run := func() []map[string]any {
		t.Helper()
		if _, err := env.Svc.SendNotifications(ctx); err != nil {
			t.Fatal(err)
		}
		return ntfy.take()
	}

	// Overdue: one message per colony with a link to it; "only once" means once.
	msgs := run()
	if len(msgs) != 1 || msgs[0]["title"] != "Messor #12 (Messor barbarus): Pflege überfällig" ||
		msgs[0]["message"] != "Proteinfütterung seit 3 Tagen überfällig" ||
		!strings.HasSuffix(msgs[0]["click"].(string), "/colonies/"+colony.String()) {
		t.Fatalf("overdue: %v", msgs)
	}
	if msgs := run(); len(msgs) != 0 {
		t.Fatalf("repeated although once: %v", msgs)
	}
	// Every 6 hours → again after 6 h.
	prefs["overdue_repeat_hours"] = 6
	anna.Do("PUT", "/api/v1/me/notifications", prefs).Must(t, 200)
	env.Clock.Advance(6 * time.Hour)
	if msgs := run(); len(msgs) != 1 {
		t.Fatalf("no repeat after 6 h: %v", msgs)
	}

	// Quiet hours all day: overdue waits, the sensor alarm gets through.
	prefs["quiet_start"], prefs["quiet_end"] = "00:00", "23:59"
	anna.Do("PUT", "/api/v1/me/notifications", prefs).Must(t, 200)
	res := anna.Do("POST", "/api/v1/sensors", map[string]any{"name": "Regal A", "colony_id": colony,
		"temp_min": 18, "temp_max": 28}).Must(t, http.StatusCreated).JSON()
	sensor := res["data"].(map[string]any)["id"].(string)
	key := res["extra"].(map[string]any)["api_key"].(string)
	env.Anon().Do("POST", "/api/v1/sensors/"+sensor+"/measurements", map[string]any{
		"readings": []map[string]any{{"metric": "temperature", "value": 31.5, "measured_at": env.Svc.Now()}},
	}, "Authorization", "Bearer "+key).Must(t, http.StatusAccepted)
	env.Clock.Advance(6 * time.Hour)
	env.Anon().Do("POST", "/api/v1/sensors/"+sensor+"/measurements", map[string]any{
		"readings": []map[string]any{{"metric": "temperature", "value": 31.5, "measured_at": env.Svc.Now()}},
	}, "Authorization", "Bearer "+key).Must(t, http.StatusAccepted)
	msgs = run()
	if len(msgs) != 1 || !strings.Contains(msgs[0]["title"].(string), "Sensor-Alarm") || msgs[0]["priority"] != 4.0 ||
		msgs[0]["message"] != "Sensor „Regal A“: Temperatur 31,5 °C – über dem Grenzwert 28,0 °C" {
		t.Fatalf("sensor during quiet hours: %v", msgs)
	}
	if msgs := run(); len(msgs) != 0 {
		t.Fatalf("sensor repeated within 6 h: %v", msgs)
	}
	// Back within limits → the occasion is over; a new alarm is reported at once.
	env.Anon().Do("POST", "/api/v1/sensors/"+sensor+"/measurements", map[string]any{
		"readings": []map[string]any{{"metric": "temperature", "value": 25, "measured_at": env.Svc.Now().Add(time.Minute)}},
	}, "Authorization", "Bearer "+key).Must(t, http.StatusAccepted)
	run()
	env.Anon().Do("POST", "/api/v1/sensors/"+sensor+"/measurements", map[string]any{
		"readings": []map[string]any{{"metric": "temperature", "value": 30, "measured_at": env.Svc.Now().Add(2 * time.Minute)}},
	}, "Authorization", "Bearer "+key).Must(t, http.StatusAccepted)
	if msgs := run(); len(msgs) != 1 {
		t.Fatalf("new alarm after recovery: %v", msgs)
	}

	// Daily digest via ntfy, without e-mail.
	prefs["digest_ntfy"] = true
	delete(prefs, "quiet_start")
	delete(prefs, "quiet_end")
	anna.Do("PUT", "/api/v1/me/notifications", prefs).Must(t, 200)
	loc, _ := time.LoadLocation(middayZone())
	anna.Do("PATCH", "/api/v1/me/settings", map[string]any{"digest_time": env.Svc.Now().In(loc).Format("15:04")}).Must(t, 200)
	before := len(env.Mail.Messages())
	if n, err := env.Svc.SendDigests(ctx); err != nil || n != 1 {
		t.Fatalf("digest: n=%d err=%v", n, err)
	}
	msgs = ntfy.take()
	if len(msgs) != 1 || msgs[0]["title"] != "1 Kolonie braucht heute Aufmerksamkeit (1 überfällig)" ||
		!strings.Contains(msgs[0]["message"].(string), "Messor #12 (Messor barbarus): Proteinfütterung") {
		t.Fatalf("digest via ntfy: %v", msgs)
	}
	if len(env.Mail.Messages()) != before {
		t.Fatal("digest mail although e-mail is off")
	}
}

func TestNotifyWinterPlanFromDigestTime(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	ntfy := newFakeNtfy(t)
	ctx := context.Background()
	zone := middayZone()
	loc, _ := time.LoadLocation(zone)
	colony := anna.CreateColony(t, map[string]any{"name": "Lasius", "species_text": "Lasius niger"})
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "winter_rests", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony,
			"planned_start_on": time.Now().In(loc).Format(time.DateOnly)})})
	later := env.Svc.Now().In(loc).Add(time.Hour).Format("15:04")
	anna.Do("PATCH", "/api/v1/me/settings", map[string]any{"timezone": zone, "digest_time": later}).Must(t, 200)
	anna.Do("PUT", "/api/v1/me/notifications", map[string]any{"ntfy_url": ntfy.URL + "/ants", "winter_ntfy": true,
		"winter_repeat_hours": 0, "overdue_repeat_hours": 24, "sensor_repeat_hours": 6}).Must(t, 200)
	run := func() []map[string]any {
		t.Helper()
		if _, err := env.Svc.SendNotifications(ctx); err != nil {
			t.Fatal(err)
		}
		return ntfy.take()
	}
	if msgs := run(); len(msgs) != 0 {
		t.Fatalf("winter reminder before the digest time: %v", msgs)
	}
	env.Clock.Advance(90 * time.Minute)
	msgs := run()
	if len(msgs) != 1 || msgs[0]["title"] != "Lasius (Lasius niger): Winterruhe" || msgs[0]["message"] != "Winterruhe beginnen?" {
		t.Fatalf("winter reminder: %v", msgs)
	}
	if msgs := run(); len(msgs) != 0 {
		t.Fatalf("repeated although once: %v", msgs)
	}
}

func TestSnoozeFromNtfyAndApp(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	ntfy := newFakeNtfy(t)
	ctx := context.Background()
	zone := middayZone()
	loc, _ := time.LoadLocation(zone)
	colony := anna.CreateColony(t, map[string]any{"name": "Messor #12"})
	schedule := testenv.NewID()
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: schedule, Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony, "task_type": "water", "interval_days": 2,
			"starts_at": time.Now().Add(-5 * 24 * time.Hour)})})
	anna.Do("PATCH", "/api/v1/me/settings", map[string]any{"timezone": zone,
		"notify_winter_app": false, "notify_sensor_app": false, "notify_digest_app": false}).Must(t, 200)
	anna.Do("PUT", "/api/v1/me/notifications", map[string]any{"ntfy_url": ntfy.URL + "/ants", "overdue_ntfy": true,
		"overdue_repeat_hours": 0, "sensor_repeat_hours": 6, "winter_repeat_hours": 24}).Must(t, 200)
	nextDue := func() time.Time {
		var at time.Time
		if err := env.Pool.QueryRow(ctx, `SELECT next_due_at FROM care_due WHERE schedule_id = $1`, schedule).Scan(&at); err != nil {
			t.Fatal(err)
		}
		return at
	}
	if _, err := env.Svc.SendNotifications(ctx); err != nil {
		t.Fatal(err)
	}
	msgs := ntfy.take()
	if len(msgs) != 1 {
		t.Fatalf("overdue: %v", msgs)
	}
	actions, _ := msgs[0]["actions"].([]any)
	if len(actions) != 1 || actions[0].(map[string]any)["label"] != "Morgen" || actions[0].(map[string]any)["method"] != "POST" {
		t.Fatalf("snooze action: %v", msgs[0]["actions"])
	}
	link := actions[0].(map[string]any)["url"].(string)
	path := strings.TrimPrefix(link, strings.TrimRight(env.Cfg.PublicURL.String(), "/"))

	// Tampered or GET → refused; the real link (no login) moves it to tomorrow.
	env.Anon().Do("POST", strings.Replace(path, "k=care", "k=winter", 1), nil).Must(t, http.StatusUnauthorized)
	env.Anon().Do("POST", strings.Replace(path, "sig=", "sig=x", 1), nil).Must(t, http.StatusUnauthorized)
	if r := env.Anon().Do("GET", path, nil); r.Status == 200 {
		t.Fatal("snooze via GET")
	}
	r := env.Anon().Do("POST", path, nil).Must(t, 200).JSON()
	if r["message"] != "Auf morgen verschoben" {
		t.Fatalf("snooze: %v", r)
	}
	tomorrow := time.Date(time.Now().In(loc).Year(), time.Now().In(loc).Month(), time.Now().In(loc).Day()+1, 0, 0, 0, 0, loc)
	if got := nextDue(); !got.Equal(tomorrow) {
		t.Fatalf("next due %v, want start of tomorrow %v", got, tomorrow)
	}
	// Not overdue any more → no message; the day after tomorrow it is overdue again.
	if _, err := env.Svc.SendNotifications(ctx); err != nil {
		t.Fatal(err)
	}
	if msgs := ntfy.take(); len(msgs) != 0 {
		t.Fatalf("still reported after snooze: %v", msgs)
	}
	env.Clock.Advance(48 * time.Hour)
	if _, err := env.Svc.SendNotifications(ctx); err != nil {
		t.Fatal(err)
	}
	if msgs := ntfy.take(); len(msgs) != 1 {
		t.Fatalf("not reported again after the snooze day: %v", msgs)
	}

	// The app writes snoozed_until through sync like any other field.
	var base int64
	if err := env.Pool.QueryRow(ctx, `SELECT version FROM care_schedules WHERE id = $1`, schedule).Scan(&base); err != nil {
		t.Fatal(err)
	}
	until := env.Svc.Now().Add(72 * time.Hour).UTC().Truncate(time.Second)
	res := anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: schedule, Op: "update",
		BaseVersion: &base, Payload: testenv.Payload(map[string]any{"snoozed_until": until})})
	if res.Results[0].Error != nil {
		t.Fatalf("app snooze: %+v", res.Results[0].Error)
	}
	if got := nextDue(); !got.Equal(until) {
		t.Fatalf("app snooze: next due %v, want %v", got, until)
	}
}

func TestSnoozeWinterPlanByLink(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	ntfy := newFakeNtfy(t)
	ctx := context.Background()
	zone := middayZone()
	loc, _ := time.LoadLocation(zone)
	today := time.Now().In(loc)
	day := func(offset int) string { return today.AddDate(0, 0, offset).Format(time.DateOnly) }
	colony := anna.CreateColony(t, map[string]any{"name": "Lasius"})
	rest := testenv.NewID()
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "winter_rests", EntityID: rest, Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony, "planned_start_on": day(-2), "planned_end_on": day(0)})})
	anna.Do("PATCH", "/api/v1/me/settings", map[string]any{"timezone": zone, "digest_time": "00:00"}).Must(t, 200)
	anna.Do("PUT", "/api/v1/me/notifications", map[string]any{"ntfy_url": ntfy.URL + "/ants", "winter_ntfy": true,
		"overdue_repeat_hours": 24, "sensor_repeat_hours": 6, "winter_repeat_hours": 24}).Must(t, 200)
	if _, err := env.Svc.SendNotifications(ctx); err != nil {
		t.Fatal(err)
	}
	msgs := ntfy.take()
	if len(msgs) != 1 {
		t.Fatalf("winter: %v", msgs)
	}
	link := msgs[0]["actions"].([]any)[0].(map[string]any)["url"].(string)
	path := strings.TrimPrefix(link, strings.TrimRight(env.Cfg.PublicURL.String(), "/"))
	env.Anon().Do("POST", path, nil).Must(t, 200)
	var start, end string
	if err := env.Pool.QueryRow(ctx, `SELECT planned_start_on::text, planned_end_on::text FROM winter_rests WHERE id = $1`, rest).
		Scan(&start, &end); err != nil {
		t.Fatal(err)
	}
	// start was overdue → tomorrow; the end stays after the start
	if start != day(1) || end != day(2) {
		t.Fatalf("plan after snooze: %s – %s", start, end)
	}
}
