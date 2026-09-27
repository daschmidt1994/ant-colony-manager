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
