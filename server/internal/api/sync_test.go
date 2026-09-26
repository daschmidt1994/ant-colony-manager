package api_test

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func feedingOp(colony, event uuid.UUID, at time.Time) testenv.Op {
	return testenv.Op{
		OpID: testenv.NewID(), Entity: "colony_events", EntityID: event, Op: "create",
		Payload: testenv.Payload(map[string]any{
			"colony_id": colony, "type": "feeding", "occurred_at": at,
			"feeding": map[string]any{"items": []map[string]any{
				{"food_name": "Schabe", "category": "protein", "quantity": 2, "unit": "piece", "size": "small"},
				{"food_name": "Zuckerwasser", "category": "carbohydrate"},
			}},
		}),
	}
}

// The core requirement: offline feeding → retries with lost responses →
// exactly one feeding on the server.
func TestOfflineFeedingIsStoredExactlyOnce(t *testing.T) {
	env := testenv.New(t)
	phone := env.User(t, "Anna")
	colony := phone.CreateColony(t, nil)

	event := testenv.NewID()
	op := feedingOp(colony, event, time.Now().Add(-3*time.Hour)) // recorded offline 3 h ago

	first := phone.Push(t, op)
	if first.Results[0].Status != "applied" {
		t.Fatalf("first push: %+v", first.Results[0])
	}
	// Response "lost" → the app retries the same op three times.
	for i := 0; i < 3; i++ {
		r := phone.Push(t, op)
		if r.Results[0].Status != "duplicate" || r.Results[0].Version != first.Results[0].Version {
			t.Fatalf("retry %d: %+v", i, r.Results[0])
		}
	}
	// Reinstalled app re-sends the event with a new op id.
	op2 := op
	op2.OpID = testenv.NewID()
	if r := phone.Push(t, op2); r.Results[0].Status != "duplicate" {
		t.Fatalf("same event, new op id: %+v", r.Results[0])
	}
	if n := env.Count(t, `SELECT count(*) FROM colony_events WHERE type = 'feeding'`); n != 1 {
		t.Fatalf("expected exactly 1 feeding, got %d", n)
	}
	if n := env.Count(t, `SELECT count(*) FROM feeding_items`); n != 2 {
		t.Fatalf("expected 2 feeding items, got %d", n)
	}

	// The web app (other client of the same user) sees it via pull.
	web := &testenv.Client{Env: env, Token: phone.Token, DeviceID: testenv.NewID(), Headers: map[string]string{}}
	pull := web.Pull(t, 0)
	var found bool
	for _, c := range pull.Changes {
		if c.Entity == "colony_events" && c.ID == event {
			found = true
			var ev map[string]any
			_ = json.Unmarshal(c.Data, &ev)
			items := ev["feeding"].(map[string]any)["items"].([]any)
			if len(items) != 2 || items[0].(map[string]any)["food_name"] != "Schabe" {
				t.Fatalf("aggregate incomplete: %s", c.Data)
			}
		}
	}
	if !found {
		t.Fatal("feeding not in pull")
	}
}

func TestConcurrentDuplicatePushes(t *testing.T) {
	env := testenv.New(t)
	phone := env.User(t, "Anna")
	colony := phone.CreateColony(t, nil)
	op := feedingOp(colony, testenv.NewID(), time.Now())
	done := make(chan string, 5)
	for i := 0; i < 5; i++ {
		go func() {
			res, err := env.Svc.ApplyOp(context.Background(), actorFor(phone), op)
			if err != nil {
				done <- "error: " + err.Error()
				return
			}
			done <- res.Status
		}()
	}
	applied := 0
	for i := 0; i < 5; i++ {
		switch s := <-done; s {
		case "applied":
			applied++
		case "duplicate":
		default:
			t.Fatalf("unexpected result %s", s)
		}
	}
	if applied != 1 || env.Count(t, `SELECT count(*) FROM colony_events`) != 1 {
		t.Fatalf("applied=%d rows=%d", applied, env.Count(t, `SELECT count(*) FROM colony_events`))
	}
}

func TestPullCursorAndPaging(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	p := u.Pull(t, 0)
	cursor := p.Next
	for i := 0; i < 7; i++ {
		u.Push(t, feedingOp(colony, testenv.NewID(), time.Now()))
	}
	var got int
	for {
		r := u.Do("GET", fmt.Sprintf("/api/v1/sync/pull?since=%d&limit=3", cursor), nil).Must(t, 200)
		var pr testenv.PullResult
		r.Decode(t, &pr)
		for _, c := range pr.Changes {
			if c.Entity == "colony_events" {
				got++
			}
		}
		cursor = pr.Next
		if !pr.HasMore {
			break
		}
	}
	if got != 7 {
		t.Fatalf("expected 7 events over pages, got %d", got)
	}
	if again := u.Pull(t, cursor); len(again.Changes) != 0 {
		t.Fatalf("nothing new expected, got %d", len(again.Changes))
	}
}

func TestConflictsMergeAndLastWriterWins(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, map[string]any{"name": "Messor #12"})
	var base int64
	if err := env.Pool.QueryRow(context.Background(), `SELECT version FROM colonies WHERE id = $1`, colony).Scan(&base); err != nil {
		t.Fatal(err)
	}
	upd := func(fields map[string]any, at time.Time) testenv.PushResult {
		return u.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colonies", EntityID: colony, Op: "update",
			BaseVersion: &base, ClientTime: &at, Payload: testenv.Payload(fields)})
	}
	t0 := time.Now()
	// Web changes notes, phone (same base) changes status → both survive.
	upd(map[string]any{"notes": "vom Web"}, t0)
	r := upd(map[string]any{"status": "founding"}, t0.Add(time.Second))
	if r.Results[0].Status != "merged" || len(r.Results[0].Conflicts) != 0 {
		t.Fatalf("non-overlapping edit should merge cleanly: %+v", r.Results[0])
	}
	var notes, status, name string
	env.Pool.QueryRow(context.Background(), `SELECT notes, status FROM colonies WHERE id = $1`, colony).Scan(&notes, &status)
	if notes != "vom Web" || status != "founding" {
		t.Fatalf("merge lost data: notes=%q status=%q", notes, status)
	}

	// Both rename: an edit made earlier (offline) than the server change loses.
	upd(map[string]any{"name": "Neu vom Web"}, time.Now())
	r = upd(map[string]any{"name": "Alt vom Handy"}, t0.Add(-time.Hour))
	if r.Results[0].Status != "merged" || len(r.Results[0].Conflicts) != 1 {
		t.Fatalf("expected conflict on name: %+v", r.Results[0])
	}
	env.Pool.QueryRow(context.Background(), `SELECT name FROM colonies WHERE id = $1`, colony).Scan(&name)
	if name != "Neu vom Web" {
		t.Fatalf("newer edit must win, got %q", name)
	}
	conflicts := u.Do("GET", "/api/v1/sync/conflicts", nil).Must(t, 200).JSON()["conflicts"].([]any)
	if len(conflicts) != 1 || conflicts[0].(map[string]any)["lost_value"] != "Alt vom Handy" {
		t.Fatalf("losing value must be kept: %v", conflicts)
	}
}

func TestColonyNumberCollisionFromTwoOfflineDevices(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	mk := func() testenv.PushResult {
		return u.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colonies", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(map[string]any{"name": "Neu", "number": 5, "species_text": "Lasius niger"})})
	}
	mk()
	r := mk()
	if r.Results[0].Status != "merged" {
		t.Fatalf("second #5 should be renumbered: %+v", r.Results[0])
	}
	if n := env.Count(t, `SELECT count(DISTINCT number) FROM colonies`); n != 2 {
		t.Fatalf("numbers must stay unique, got %d distinct", n)
	}
}

func TestDeleteTombstoneAndHorizon(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	ev := testenv.NewID()
	u.Push(t, feedingOp(colony, ev, time.Now()))
	cursor := u.Pull(t, 0).Next

	del := u.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: ev, Op: "delete"})
	if del.Results[0].Status != "applied" {
		t.Fatalf("delete: %+v", del.Results[0])
	}
	p := u.Pull(t, cursor)
	if len(p.Changes) == 0 || p.Changes[len(p.Changes)-1].Op != "delete" || p.Changes[len(p.Changes)-1].ID != ev {
		t.Fatalf("tombstone expected in pull: %+v", p.Changes)
	}
	// Updating a deleted record: delete wins.
	upd := u.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: ev, Op: "update",
		Payload: testenv.Payload(map[string]any{"note": "zu spät"})})
	if upd.Results[0].Status != "rejected" || upd.Results[0].Error.Code != "entity.deleted" {
		t.Fatalf("update after delete: %+v", upd.Results[0])
	}

	// 181 days later the garbage collector removes tombstones and raises the horizon.
	env.Clock.Advance(181 * 24 * time.Hour)
	if _, err := env.Pool.Exec(context.Background(), `UPDATE change_log SET changed_at = changed_at - interval '181 days'`); err != nil {
		t.Fatal(err)
	}
	if err := env.Svc.Maintenance(context.Background()); err != nil {
		t.Fatal(err)
	}
	if env.Count(t, `SELECT count(*) FROM colony_events WHERE id = $1`, ev) != 0 {
		t.Fatal("tombstone should be collected")
	}
	if r := u.Do("GET", fmt.Sprintf("/api/v1/sync/pull?since=%d", cursor), nil); r.Status != 410 || r.Code() != "sync.resync_required" {
		t.Fatalf("old cursor must require resync: %d %s", r.Status, r.Body)
	}
	snap := u.Do("GET", "/api/v1/sync/snapshot", nil).Must(t, 200).JSON()
	cols := snap["entities"].(map[string]any)["colonies"].([]any)
	if len(cols) != 1 {
		t.Fatalf("snapshot must contain the colony, got %d", len(cols))
	}
}

func TestSharingAndRevocation(t *testing.T) {
	env := testenv.New(t)
	owner := env.User(t, "Owner")
	helper := env.User(t, "Helper")
	colony := owner.CreateColony(t, nil)
	ownerEvent := testenv.NewID()
	owner.Push(t, feedingOp(colony, ownerEvent, time.Now()))

	// Helper cannot see it yet.
	helper.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 404)

	owner.Do("POST", "/api/v1/colonies/"+colony.String()+"/members", map[string]any{"email": "helper@ants.test", "role": "editor"}).Must(t, 200)
	helper.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 200)
	snap := helper.Do("GET", "/api/v1/sync/snapshot?colony_ids="+colony.String(), nil).Must(t, 200).JSON()
	if n := len(snap["entities"].(map[string]any)["colony_events"].([]any)); n != 1 {
		t.Fatalf("helper snapshot should contain 1 event, got %d", n)
	}
	cursor := helper.Pull(t, 0).Next

	// Editor may document …
	own := testenv.NewID()
	if r := helper.Push(t, feedingOp(colony, own, time.Now())); r.Results[0].Status != "applied" {
		t.Fatalf("editor feeding: %+v", r.Results[0])
	}
	// … delete own events, but not the owner's, and not archive the colony.
	if r := helper.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: ownerEvent, Op: "delete"}); r.Results[0].Error == nil || r.Results[0].Error.Code != "auth.forbidden" {
		t.Fatalf("editor deleting owner's event: %+v", r.Results[0])
	}
	if r := helper.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: own, Op: "delete"}); r.Results[0].Status != "applied" {
		t.Fatalf("editor deleting own event: %+v", r.Results[0])
	}
	helper.Do("POST", "/api/v1/colonies/"+colony.String()+"/archive", nil).Must(t, 403)
	helper.Do("DELETE", "/api/v1/colonies/"+colony.String(), nil).Must(t, 403)

	// Owner revokes → helper's device learns about it and loses access.
	owner.Do("DELETE", fmt.Sprintf("/api/v1/colonies/%s/members/%s", colony, helper.UserID), nil).Must(t, 204)
	p := helper.Pull(t, cursor)
	var revoked bool
	for _, c := range p.Changes {
		if c.Entity == "colony_members" && c.Op == "delete" {
			revoked = true
		}
	}
	if !revoked {
		t.Fatalf("helper must receive membership deletion: %+v", p.Changes)
	}
	helper.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 404)
}

func TestViewerIsReadOnly(t *testing.T) {
	env := testenv.New(t)
	owner := env.User(t, "Owner")
	viewer := env.User(t, "Viewer")
	colony := owner.CreateColony(t, nil)
	owner.Do("POST", "/api/v1/colonies/"+colony.String()+"/members", map[string]any{"email": "viewer@ants.test", "role": "viewer"}).Must(t, 200)
	viewer.Do("GET", "/api/v1/colonies/"+colony.String()+"/timeline", nil).Must(t, 200)
	r := viewer.Push(t, feedingOp(colony, testenv.NewID(), time.Now()))
	if r.Results[0].Status != "rejected" || r.Results[0].Error.Code != "auth.forbidden" {
		t.Fatalf("viewer must not write: %+v", r.Results[0])
	}
	members := viewer.Do("GET", "/api/v1/colonies/"+colony.String()+"/members", nil).Must(t, 200).JSON()["members"].([]any)
	for _, m := range members {
		if _, ok := m.(map[string]any)["email"]; ok {
			t.Fatal("viewers must not see e-mail addresses of members")
		}
	}
}

func TestRealtimeSignal(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)

	req, _ := newSSERequest(env, u)
	events := make(chan string, 10)
	go readSSE(t, req, events)
	time.Sleep(300 * time.Millisecond) // subscription established
	u.Push(t, feedingOp(colony, testenv.NewID(), time.Now()))
	select {
	case line := <-events:
		if line == "" {
			t.Fatal("empty event")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no realtime signal received")
	}
}
