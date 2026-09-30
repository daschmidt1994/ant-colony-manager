package api_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// Pflegevertretung: Ben cares for one of Anna's colonies during her holiday.
func TestCareCover(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	ben := env.User(t, "Ben")
	carl := env.User(t, "Carl")
	dora := env.User(t, "Dora")
	messor := anna.CreateColony(t, map[string]any{"name": "Messor"})
	lasius := anna.CreateColony(t, map[string]any{"name": "Lasius"})
	today := time.Now().Format(time.DateOnly)
	week := time.Now().AddDate(0, 0, 7).Format(time.DateOnly)
	member := func(c fmt.Stringer, u *testenv.Client) int {
		return env.Count(t, `SELECT count(*) FROM colony_members WHERE colony_id = $1 AND user_id = $2 AND deleted_at IS NULL`, c, u.UserID)
	}
	water := func(u *testenv.Client, c fmt.Stringer) string {
		r := u.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": c, "type": "water", "water": map[string]any{"kinds": []string{"drinker_refilled"}}})})
		return r.Results[0].Status
	}

	// mistakes
	for _, bad := range []map[string]any{
		{"email": "niemand@ants.test", "starts_on": today, "ends_on": week, "colonies": []any{map[string]any{"colony_id": messor}}},
		{"email": anna.Email, "starts_on": today, "ends_on": week, "colonies": []any{map[string]any{"colony_id": messor}}},
		{"email": ben.Email, "starts_on": week, "ends_on": today, "colonies": []any{map[string]any{"colony_id": messor}}},
		{"email": ben.Email, "starts_on": today, "ends_on": week, "colonies": []any{}},
		{"email": ben.Email, "starts_on": today, "ends_on": week, "colonies": []any{map[string]any{"colony_id": dora.CreateColony(t, nil)}}},
	} {
		anna.Do("POST", "/api/v1/care-covers", bad).Must(t, 422)
	}

	// Carl already views Lasius – the cover must not touch that
	anna.Do("POST", "/api/v1/colonies/"+lasius.String()+"/members", map[string]any{"email": carl.Email, "role": "viewer"}).Must(t, 200)

	cover := anna.Do("POST", "/api/v1/care-covers", map[string]any{
		"email": ben.Email, "starts_on": today, "ends_on": week,
		"instructions": "Proteinfutter nur jeden zweiten Tag.",
		"colonies":     []any{map[string]any{"colony_id": messor, "instructions": "Wasser im Reagenzglas prüfen"}},
	}).Must(t, 201).JSON()
	id := cover["id"].(string)
	if cover["state"] != "active" || cover["user_name"] != "Ben" || cover["user_email"] != ben.Email {
		t.Fatalf("cover: %v", cover)
	}
	if member(messor, ben) != 1 || member(lasius, ben) != 0 {
		t.Fatal("ben should care for messor only")
	}
	if water(ben, messor) != "applied" || water(ben, lasius) == "applied" {
		t.Fatal("ben's rights are wrong")
	}

	// Ben sees the instructions on the colony, Dora nothing
	instr := ben.Do("GET", "/api/v1/colonies/"+messor.String()+"/care-instructions", nil).Must(t, 200).Body
	if !strings.Contains(string(instr), "jeden zweiten Tag") || !strings.Contains(string(instr), "Reagenzglas") ||
		strings.Contains(string(instr), ben.Email) {
		t.Fatalf("instructions: %s", instr)
	}
	dora.Do("GET", "/api/v1/colonies/"+messor.String()+"/care-instructions", nil).Must(t, 404)
	dora.Do("GET", "/api/v1/care-covers/"+id, nil).Must(t, 404)
	var benList []map[string]any
	ben.Do("GET", "/api/v1/care-covers", nil).Must(t, 200).Decode(t, &benList)
	if len(benList) != 1 || benList[0]["mine"] != false {
		t.Fatalf("ben's list: %v", benList)
	}

	// Anna sees what Ben did
	detail := anna.Do("GET", "/api/v1/care-covers/"+id, nil).Must(t, 200).JSON()
	done := detail["done"].([]any)
	if len(done) != 1 || done[0].(map[string]any)["type"] != "water" {
		t.Fatalf("done: %v", detail["done"])
	}
	// only Anna changes it; add Lasius
	ben.Do("PATCH", "/api/v1/care-covers/"+id, map[string]any{"ends_on": week}).Must(t, 404)
	anna.Do("PATCH", "/api/v1/care-covers/"+id, map[string]any{"colonies": []any{
		map[string]any{"colony_id": messor}, map[string]any{"colony_id": lasius}}}).Must(t, 200)
	if member(lasius, ben) != 1 {
		t.Fatal("lasius not handed over")
	}
	// Carl is on Lasius too – a second cover for him does not change his viewer role
	anna.Do("POST", "/api/v1/care-covers", map[string]any{"email": carl.Email, "starts_on": today, "ends_on": week,
		"colonies": []any{map[string]any{"colony_id": lasius}}}).Must(t, 201)
	if env.Count(t, `SELECT count(*) FROM colony_members WHERE colony_id = $1 AND user_id = $2 AND deleted_at IS NULL AND role = 'viewer'`, lasius, carl.UserID) != 1 {
		t.Fatal("carl's viewer membership changed")
	}

	// removed by hand from Lasius: not handed over again
	anna.Do("DELETE", "/api/v1/colonies/"+lasius.String()+"/members/"+ben.UserID.String(), nil).Must(t, 204)
	if err := env.Svc.ApplyCareCovers(t.Context()); err != nil {
		t.Fatal(err)
	}
	if member(lasius, ben) != 0 {
		t.Fatal("ben added again after removal")
	}

	// Ben ends it early: access gone, the documented care stays visible to Anna
	ben.Do("POST", "/api/v1/care-covers/"+id+"/end", nil).Must(t, 204)
	if member(messor, ben) != 0 {
		t.Fatal("ben still cares for messor")
	}
	if water(ben, messor) == "applied" {
		t.Fatal("ben can still write after the end")
	}
	if d := anna.Do("GET", "/api/v1/care-covers/"+id, nil).Must(t, 200).JSON(); d["state"] != "ended" || len(d["done"].([]any)) != 1 {
		t.Fatalf("after end: %v", d)
	}
	if member(lasius, carl) != 1 {
		t.Fatal("carl lost his viewer membership")
	}

	// a planned cover does not give access yet; ending it removes it
	tomorrow := time.Now().AddDate(0, 0, 1).Format(time.DateOnly)
	planned := anna.Do("POST", "/api/v1/care-covers", map[string]any{"email": ben.Email, "starts_on": tomorrow, "ends_on": week,
		"colonies": []any{map[string]any{"colony_id": messor}}}).Must(t, 201).JSON()
	if planned["state"] != "planned" || member(messor, ben) != 0 {
		t.Fatalf("planned: %v", planned)
	}
	anna.Do("POST", "/api/v1/care-covers/"+planned["id"].(string)+"/end", nil).Must(t, 204)
	anna.Do("GET", "/api/v1/care-covers/"+planned["id"].(string), nil).Must(t, 404)
}
