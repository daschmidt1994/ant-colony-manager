package api_test

import (
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// „Noch ausreichend Wasser“: the deferral is documented as an event with a
// reason, the care plan is not due before the chosen day.
func TestCareDeferredWithReason(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	colony := anna.CreateColony(t, nil)
	water := testenv.NewID()
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: water, Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony, "task_type": "water", "interval_days": 3,
			"starts_at": time.Now().Add(-5 * 24 * time.Hour)})})
	if n := env.Count(t, `SELECT count(*) FROM care_due WHERE schedule_id = $1 AND next_due_at < now()`, water); n != 1 {
		t.Fatal("water should be overdue")
	}

	until := time.Now().Add(48 * time.Hour).UTC().Truncate(time.Second)
	r := anna.Push(t,
		testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": colony, "type": "care_deferred", "schedule_id": water,
				"note": "Reagenzglas noch halb voll", "payload": map[string]any{"reason": "water_enough", "days": 2, "task_type": "water"}})},
		testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: water, Op: "update",
			Payload: testenv.Payload(map[string]any{"snoozed_until": until})},
	)
	for _, res := range r.Results {
		if res.Status != "applied" {
			t.Fatalf("deferral: %+v", res.Error)
		}
	}
	if n := env.Count(t, `SELECT count(*) FROM care_due WHERE schedule_id = $1 AND next_due_at >= $2`, water, until); n != 1 {
		t.Fatal("still due before the deferral ends")
	}
	if n := env.Count(t, `SELECT count(*) FROM colony_events WHERE colony_id = $1 AND type = 'care_deferred'
		AND payload->>'reason' = 'water_enough' AND note = 'Reagenzglas noch halb voll'`, colony); n != 1 {
		t.Fatal("deferral not documented")
	}

	// without care plan or reason: refused
	for _, p := range []map[string]any{
		{"colony_id": colony, "type": "care_deferred", "payload": map[string]any{"reason": "x", "days": 1}},
		{"colony_id": colony, "type": "care_deferred", "schedule_id": water},
		{"colony_id": colony, "type": "care_deferred", "schedule_id": water, "payload": map[string]any{"reason": "x", "days": 0}},
	} {
		r := anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(p)})
		if r.Results[0].Status != "rejected" {
			t.Fatalf("accepted: %v", p)
		}
	}
	// a care plan of another colony cannot be deferred here
	other := anna.CreateColony(t, map[string]any{"name": "Lasius"})
	r = anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": other, "type": "care_deferred", "schedule_id": water,
			"payload": map[string]any{"reason": "x", "days": 1}})})
	if r.Results[0].Status != "rejected" {
		t.Fatal("foreign care plan accepted")
	}
}
