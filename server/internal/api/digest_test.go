package api_test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// middayZone returns a fixed-offset zone in which it is around noon right now,
// so the test never runs across a local midnight.
func middayZone() string {
	x := time.Now().UTC().Hour() - 12 // Etc/GMT+X is UTC−X
	if x >= 0 {
		return fmt.Sprintf("Etc/GMT+%d", x)
	}
	return fmt.Sprintf("Etc/GMT-%d", -x)
}

func TestEmailDigestOncePerDayWithWhatIsDue(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	overdue := anna.CreateColony(t, map[string]any{"name": "Messor #12", "species_text": "Messor barbarus"})
	anna.CreateColony(t, map[string]any{"name": "Ruhig"})
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": overdue, "task_type": "protein", "interval_days": 2,
			"starts_at": time.Now().Add(-5 * 24 * time.Hour)})})

	ctx := context.Background()
	// Not enabled → nothing.
	if n, err := env.Svc.SendDigests(ctx); err != nil || n != 0 {
		t.Fatalf("disabled: n=%d err=%v", n, err)
	}
	anna.Do("PATCH", "/api/v1/me/settings", map[string]any{
		"email_digest": true, "digest_time": "11:00", "timezone": middayZone(),
	}).Must(t, 200)

	if n, err := env.Svc.SendDigests(ctx); err != nil || n != 1 {
		t.Fatalf("first run: n=%d err=%v", n, err)
	}
	msgs := env.Mail.Messages()
	m := msgs[len(msgs)-1]
	if m.To != "anna@ants.test" || !strings.Contains(m.Subject, "1 Kolonie braucht heute Aufmerksamkeit (1 überfällig)") {
		t.Fatalf("mail: %+v", m)
	}
	if !strings.Contains(m.Body, "Messor #12 (Messor barbarus): Proteinfütterung seit 3 Tagen überfällig") ||
		strings.Contains(m.Body, "Ruhig") {
		t.Fatalf("body:\n%s", m.Body)
	}
	// Same day again → nothing.
	if n, _ := env.Svc.SendDigests(ctx); n != 0 {
		t.Fatal("digest sent twice on the same day")
	}
	// Next day → again.
	env.Clock.Advance(24 * time.Hour)
	if n, _ := env.Svc.SendDigests(ctx); n != 1 {
		t.Fatal("no digest on the next day")
	}
}

func TestWinterPlanRemindsStartAndEnd(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	colony := anna.CreateColony(t, map[string]any{"name": "Lasius", "species_text": "Lasius niger"})
	zone := middayZone()
	loc, _ := time.LoadLocation(zone)
	day := func(offset int) string { return time.Now().In(loc).AddDate(0, 0, offset).Format(time.DateOnly) }
	ctx := context.Background()
	status := func() string {
		var s string
		if err := env.Pool.QueryRow(ctx, `SELECT status FROM colonies WHERE id = $1`, colony).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	rest := testenv.NewID()
	update := func(fields map[string]any) {
		var base int64
		if err := env.Pool.QueryRow(ctx, `SELECT version FROM winter_rests WHERE id = $1`, rest).Scan(&base); err != nil {
			t.Fatal(err)
		}
		r := anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "winter_rests", EntityID: rest, Op: "update",
			BaseVersion: &base, Payload: testenv.Payload(fields)})
		if r.Results[0].Error != nil {
			t.Fatalf("update %v: %+v", fields, r.Results[0].Error)
		}
	}

	// Neither started nor planned → rejected by the schema.
	if r := anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "winter_rests", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony})}); r.Results[0].Error == nil {
		t.Fatalf("winter rest without start or plan accepted: %+v", r.Results[0])
	}

	// A plan alone keeps the colony active, but the digest asks to start it.
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "winter_rests", EntityID: rest, Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony, "planned_start_on": day(-1), "planned_end_on": day(90)})})
	if s := status(); s != "active" {
		t.Fatalf("planned winter rest changed the status to %q", s)
	}
	anna.Do("PATCH", "/api/v1/me/settings", map[string]any{
		"email_digest": true, "digest_time": "11:00", "timezone": zone,
	}).Must(t, 200)
	if n, err := env.Svc.SendDigests(ctx); err != nil || n != 1 {
		t.Fatalf("start reminder: n=%d err=%v", n, err)
	}
	msgs := env.Mail.Messages()
	if m := msgs[len(msgs)-1]; !strings.Contains(m.Body, "Lasius (Lasius niger): Winterruhe beginnen?") ||
		strings.Contains(m.Subject, "überfällig") {
		t.Fatalf("start mail: %+v", m)
	}

	// The switch in the app sets started_on → hibernating, no reminder until the planned end.
	update(map[string]any{"started_on": day(-1)})
	if s := status(); s != "hibernating" {
		t.Fatalf("started winter rest: status %q", s)
	}
	env.Clock.Advance(24 * time.Hour)
	if n, _ := env.Svc.SendDigests(ctx); n != 0 {
		t.Fatalf("digest during a running winter rest: %+v", env.Mail.Messages()[len(env.Mail.Messages())-1])
	}

	// Planned end reached → „beenden?“; switching off ends it.
	update(map[string]any{"planned_end_on": day(0)})
	env.Clock.Advance(24 * time.Hour)
	if n, _ := env.Svc.SendDigests(ctx); n != 1 {
		t.Fatal("no end reminder")
	}
	msgs = env.Mail.Messages()
	if m := msgs[len(msgs)-1]; !strings.Contains(m.Body, "Lasius (Lasius niger): Winterruhe beenden?") {
		t.Fatalf("end mail: %+v", m)
	}
	update(map[string]any{"ended_on": day(0)})
	if s := status(); s != "active" {
		t.Fatalf("ended winter rest: status %q", s)
	}
}
