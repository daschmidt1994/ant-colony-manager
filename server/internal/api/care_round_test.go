package api_test

import (
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// A care round is recorded completely offline and pushed in one batch: the
// round, its stops and the events that point at it. Nobody else may attach
// events to it.
func TestCareRoundPushedOfflineInOneBatch(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	c1 := anna.CreateColony(t, nil)
	c2 := anna.CreateColony(t, nil)

	round, stop1, stop2, ev := testenv.NewID(), testenv.NewID(), testenv.NewID(), testenv.NewID()
	start := time.Now().Add(-20 * time.Minute)
	ops := []testenv.Op{
		{OpID: testenv.NewID(), Entity: "care_rounds", EntityID: round, Op: "create", Payload: testenv.Payload(map[string]any{"started_at": start})},
		{OpID: testenv.NewID(), Entity: "care_round_colonies", EntityID: stop1, Op: "create", Payload: testenv.Payload(map[string]any{
			"care_round_id": round, "colony_id": c1, "planned": true, "visited_at": start.Add(time.Minute),
		})},
		{OpID: testenv.NewID(), Entity: "care_round_colonies", EntityID: stop2, Op: "create", Payload: testenv.Payload(map[string]any{
			"care_round_id": round, "colony_id": c2, "planned": true,
		})},
		{OpID: testenv.NewID(), Entity: "colony_events", EntityID: ev, Op: "create", Payload: testenv.Payload(map[string]any{
			"colony_id": c1, "type": "water", "occurred_at": start.Add(2 * time.Minute), "care_round_id": round,
			"water": map[string]any{"kinds": []string{"drinker_refilled"}},
		})},
		{OpID: testenv.NewID(), Entity: "care_round_colonies", EntityID: stop2, Op: "update", Payload: testenv.Payload(map[string]any{"skipped": true})},
		{OpID: testenv.NewID(), Entity: "care_rounds", EntityID: round, Op: "update", Payload: testenv.Payload(map[string]any{"ended_at": time.Now()})},
	}
	for i, r := range anna.Push(t, ops...).Results {
		if r.Status != "applied" && r.Status != "merged" {
			t.Fatalf("op %d: %+v", i, r)
		}
	}
	if n := env.Count(t, `SELECT count(*) FROM colony_events WHERE care_round_id = $1`, round); n != 1 {
		t.Fatalf("events in round: %d", n)
	}
	if n := env.Count(t, `SELECT count(*) FROM care_round_colonies WHERE care_round_id = $1 AND skipped`, round); n != 1 {
		t.Fatalf("skipped stops: %d", n)
	}
	if n := env.Count(t, `SELECT count(*) FROM care_rounds WHERE id = $1 AND ended_at IS NOT NULL`, round); n != 1 {
		t.Fatal("round not ended")
	}

	// The round and its stops reach Anna's other devices.
	snap := anna.Do("GET", "/api/v1/sync/snapshot", nil).Must(t, 200).JSON()["entities"].(map[string]any)
	if len(snap["care_rounds"].([]any)) != 1 || len(snap["care_round_colonies"].([]any)) != 2 {
		t.Fatalf("snapshot: rounds %v, stops %v", snap["care_rounds"], snap["care_round_colonies"])
	}

	// Somebody else cannot see the round or attach an event to it.
	ben := env.User(t, "Ben")
	own := ben.CreateColony(t, nil)
	r := ben.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": own, "type": "check", "occurred_at": time.Now(), "care_round_id": round})})
	if r.Results[0].Status == "applied" {
		t.Fatal("event attached to a foreign care round")
	}
	if s := ben.Do("GET", "/api/v1/sync/snapshot", nil).Must(t, 200).JSON()["entities"].(map[string]any); len(s["care_rounds"].([]any)) != 0 {
		t.Fatal("foreign care round visible")
	}
}
