package api_test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestFeedCalendar(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	messor := anna.CreateColony(t, map[string]any{"name": "Messor #12", "species_text": "Messor barbarus"})
	lasius := anna.CreateColony(t, map[string]any{"name": "Lasius"})
	anna.Push(t,
		testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": messor, "task_type": "protein", "interval_days": 2,
				"starts_at": time.Now().Add(-5 * 24 * time.Hour)})},
		testenv.Op{OpID: testenv.NewID(), Entity: "winter_rests", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": lasius, "started_on": time.Now().AddDate(0, 0, -10).Format(time.DateOnly),
				"planned_end_on": time.Now().AddDate(0, 2, 0).Format(time.DateOnly)})},
		testenv.Op{OpID: testenv.NewID(), Entity: "tasks", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": messor, "title": "Nest umziehen, Arena reinigen",
				"due_at": time.Now().Add(48 * time.Hour)})},
	)

	if anna.Do("GET", "/api/v1/me/feed", nil).Must(t, 200).JSON()["active"].(bool) {
		t.Fatal("feed active before creation")
	}
	created := anna.Do("POST", "/api/v1/me/feed", nil).Must(t, 201).JSON()
	token := created["token"].(string)
	if !strings.HasPrefix(token, "acm_fk_") || !strings.HasSuffix(created["calendar_url"].(string), token+"/calendar.ics") ||
		created["status_url"] != nil {
		t.Fatalf("created: %v", created)
	}

	r := env.Anon().Do("GET", "/api/v1/feeds/"+token+"/calendar.ics", nil).Must(t, 200)
	ics := string(r.Body)
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/calendar") {
		t.Fatalf("content type %q", ct)
	}
	for _, want := range []string{"BEGIN:VCALENDAR\r\n", "X-WR-CALNAME:Ameisen\r\n",
		"SUMMARY:🐜 Proteinfütterung – Messor #12 (#", "Winterruhe beenden?",
		`Nest umziehen\, Arena reinigen`, "DTSTART;VALUE=DATE:" + time.Now().Format("20060102"), "END:VCALENDAR\r\n"} {
		if !strings.Contains(ics, want) {
			t.Errorf("calendar lacks %q:\n%s", want, ics)
		}
	}
	for _, l := range strings.Split(ics, "\r\n") {
		if len(l) > 75 {
			t.Errorf("line longer than 75 octets: %q", l)
		}
	}
	if !anna.Do("GET", "/api/v1/me/feed", nil).Must(t, 200).JSON()["active"].(bool) {
		t.Fatal("feed not active")
	}

	// Only hibernation: care and tasks disappear from the calendar.
	if info := anna.Do("GET", "/api/v1/me/feed", nil).Must(t, 200).JSON(); info["calendar_types"] != nil {
		t.Fatalf("default filter: %v", info)
	}
	anna.Do("PATCH", "/api/v1/me/feed", map[string]any{"calendar_types": []string{"futter"}}).Must(t, 422)
	anna.Do("PATCH", "/api/v1/me/feed", map[string]any{"calendar_types": []string{}}).Must(t, 422)
	info := anna.Do("PATCH", "/api/v1/me/feed", map[string]any{"calendar_types": []string{"winter"}}).Must(t, 200).JSON()
	if fmt.Sprint(info["calendar_types"]) != "[winter]" {
		t.Fatalf("filter: %v", info)
	}
	ics = string(env.Anon().Do("GET", "/api/v1/feeds/"+token+"/calendar.ics", nil).Must(t, 200).Body)
	if !strings.Contains(ics, "Winterruhe beenden?") || strings.Contains(ics, "Proteinfütterung") || strings.Contains(ics, "Nest umziehen") {
		t.Fatalf("only winter:\n%s", ics)
	}
	// Only protein feeding and tasks.
	anna.Do("PATCH", "/api/v1/me/feed", map[string]any{"calendar_types": []string{"tasks", "protein"}}).Must(t, 200)
	ics = string(env.Anon().Do("GET", "/api/v1/feeds/"+token+"/calendar.ics", nil).Must(t, 200).Body)
	if strings.Contains(ics, "Winterruhe") || !strings.Contains(ics, "Proteinfütterung") || !strings.Contains(ics, "Nest umziehen") {
		t.Fatalf("protein and tasks:\n%s", ics)
	}
	// Everything selected is stored as "everything"; a new address keeps the choice.
	all := []string{"protein", "carbohydrate", "feeding", "water", "cleaning", "check", "custom", "winter", "tasks"}
	if info := anna.Do("PATCH", "/api/v1/me/feed", map[string]any{"calendar_types": all}).Must(t, 200).JSON(); info["calendar_types"] != nil {
		t.Fatalf("all: %v", info)
	}
	anna.Do("PATCH", "/api/v1/me/feed", map[string]any{"calendar_types": []string{"winter"}}).Must(t, 200)

	// A new address replaces the old one; a wrong secret looks like a missing page.
	token2 := anna.Do("POST", "/api/v1/me/feed", nil).Must(t, 201).JSON()["token"].(string)
	if info := anna.Do("GET", "/api/v1/me/feed", nil).Must(t, 200).JSON(); fmt.Sprint(info["calendar_types"]) != "[winter]" {
		t.Fatalf("filter lost with a new address: %v", info)
	}
	env.Anon().Do("GET", "/api/v1/feeds/"+token+"/calendar.ics", nil).Must(t, 404)
	env.Anon().Do("GET", "/api/v1/feeds/"+token2[:len(token2)-3]+"xyz/calendar.ics", nil).Must(t, 404)
	env.Anon().Do("GET", "/api/v1/feeds/nonsense/calendar.ics", nil).Must(t, 404)
	env.Anon().Do("GET", "/api/v1/feeds/"+token2+"/calendar.ics", nil).Must(t, 200)

	// Another user sees only their own colonies.
	ben := env.User(t, "Ben")
	ben.Do("PATCH", "/api/v1/me/feed", map[string]any{"calendar_types": []string{"winter"}}).Must(t, 404)
	benToken := ben.Do("POST", "/api/v1/me/feed", nil).Must(t, 201).JSON()["token"].(string)
	if ics := string(env.Anon().Do("GET", "/api/v1/feeds/"+benToken+"/calendar.ics", nil).Must(t, 200).Body); strings.Contains(ics, "Messor") {
		t.Fatalf("ben sees: %s", ics)
	}

	anna.Do("DELETE", "/api/v1/me/feed", nil).Must(t, 204)
	env.Anon().Do("GET", "/api/v1/feeds/"+token2+"/calendar.ics", nil).Must(t, 404)
}

// Several calendars: one only for the winter rest, one only for the protein
// feeding of one colony – with their own names.
func TestSeveralCalendars(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	messor := anna.CreateColony(t, map[string]any{"name": "Messor"})
	lasius := anna.CreateColony(t, map[string]any{"name": "Lasius"})
	for _, c := range []any{messor, lasius} {
		anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "care_schedules", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": c, "task_type": "protein", "interval_days": 2,
				"starts_at": time.Now().Add(-5 * 24 * time.Hour)})})
	}
	anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "winter_rests", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": lasius, "started_on": time.Now().AddDate(0, 0, -3).Format(time.DateOnly),
			"planned_end_on": time.Now().AddDate(0, 3, 0).Format(time.DateOnly)})})

	winter := anna.Do("POST", "/api/v1/me/feeds", map[string]any{"name": "Winterruhe", "calendar_types": []string{"winter"}}).Must(t, 201).JSON()
	feeding := anna.Do("POST", "/api/v1/me/feeds", map[string]any{"name": "Messor füttern",
		"calendar_types": []string{"protein"}, "colony_ids": []any{messor}}).Must(t, 201).JSON()
	anna.Do("POST", "/api/v1/me/feeds", map[string]any{"calendar_types": []string{}}).Must(t, 422)
	anna.Do("POST", "/api/v1/me/feeds", map[string]any{"name": ""}).Must(t, 422)

	get := func(created map[string]any) string {
		u := created["calendar_url"].(string)
		return string(env.Anon().Do("GET", u[strings.Index(u, "/api/"):], nil).Must(t, 200).Body)
	}
	w := get(winter)
	if !strings.Contains(w, "X-WR-CALNAME:Winterruhe") || !strings.Contains(w, "Winterruhe beenden?") || strings.Contains(w, "Protein") {
		t.Fatalf("winter calendar:\n%s", w)
	}
	f := get(feeding)
	if !strings.Contains(f, "X-WR-CALNAME:Messor füttern") || !strings.Contains(f, "Proteinfütterung – Messor") ||
		strings.Contains(f, "Lasius") || strings.Contains(f, "Winterruhe") {
		t.Fatalf("feeding calendar:\n%s", f)
	}

	var list []struct {
		ID            string   `json:"id"`
		Name          string   `json:"name"`
		CalendarTypes []string `json:"calendar_types"`
		ColonyIDs     []string `json:"colony_ids"`
	}
	anna.Do("GET", "/api/v1/me/feeds", nil).Must(t, 200).Decode(t, &list)
	if len(list) != 2 || list[0].Name != "Winterruhe" || fmt.Sprint(list[1].ColonyIDs) != "["+messor.String()+"]" {
		t.Fatalf("list: %+v", list)
	}
	// all colonies again, renamed; applies at once
	id := list[1].ID
	anna.Do("PATCH", "/api/v1/me/feeds/"+id, map[string]any{"name": "Protein", "colony_ids": []any{}}).Must(t, 200)
	if f := get(feeding); !strings.Contains(f, "X-WR-CALNAME:Protein") || !strings.Contains(f, "Lasius") {
		t.Fatalf("after change:\n%s", f)
	}
	// new address: the old one is gone
	rot := anna.Do("POST", "/api/v1/me/feeds/"+id+"/rotate", nil).Must(t, 200).JSON()
	old := feeding["calendar_url"].(string)
	env.Anon().Do("GET", old[strings.Index(old, "/api/"):], nil).Must(t, 404)
	get(rot)

	// others cannot see or change them
	ben := env.User(t, "Ben")
	ben.Do("PATCH", "/api/v1/me/feeds/"+id, map[string]any{"name": "x"}).Must(t, 404)
	ben.Do("DELETE", "/api/v1/me/feeds/"+id, nil).Must(t, 404)
	ben.Do("POST", "/api/v1/me/feeds/"+id+"/rotate", nil).Must(t, 404)
	var benList []any
	ben.Do("GET", "/api/v1/me/feeds", nil).Must(t, 200).Decode(t, &benList)
	if len(benList) != 0 {
		t.Fatalf("ben sees: %v", benList)
	}

	// the old single-calendar API acts on the first calendar
	if info := anna.Do("GET", "/api/v1/me/feed", nil).Must(t, 200).JSON(); info["active"] != true || fmt.Sprint(info["calendar_types"]) != "[winter]" {
		t.Fatalf("old api: %v", info)
	}
	// at most 10 (the rest directly – creating is rate limited)
	if _, err := env.Pool.Exec(context.Background(), `INSERT INTO feed_tokens (user_id, prefix, token_hash)
		SELECT user_id, 'x' || g, token_hash FROM feed_tokens, generate_series(1, 8) g WHERE id = $1`, list[0].ID); err != nil {
		t.Fatal(err)
	}
	env.Clock.Advance(time.Hour)
	anna.Do("POST", "/api/v1/me/feeds", nil).Must(t, 422)
	anna.Do("DELETE", "/api/v1/me/feeds/"+id, nil).Must(t, 204)
	env.Anon().Do("GET", rot["calendar_url"].(string)[strings.Index(rot["calendar_url"].(string), "/api/"):], nil).Must(t, 404)
}
