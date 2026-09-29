package api_test

import (
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestFeedStatusAndCalendar(t *testing.T) {
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
	if !strings.HasPrefix(token, "acm_fk_") || !strings.HasSuffix(created["calendar_url"].(string), token+"/calendar.ics") {
		t.Fatalf("created: %v", created)
	}

	var st struct {
		Overdue, DueToday, Hibernating int
		Colonies                       []struct {
			Name        string
			Hibernating bool
			Overdue     int
			NextDue     *struct{ Task string } `json:"next_due"`
		}
		ByNumber map[string]struct{ Name string } `json:"by_number"`
	}
	env.Anon().Do("GET", "/api/v1/feeds/"+token+"/status.json", nil).Must(t, 200).Decode(t, &st)
	if st.Overdue != 1 || st.Hibernating != 1 || len(st.Colonies) != 2 || len(st.ByNumber) != 2 {
		t.Fatalf("status: %+v", st)
	}
	for _, c := range st.Colonies {
		switch c.Name {
		case "Messor #12":
			if c.Overdue != 1 || c.Hibernating || c.NextDue == nil || c.NextDue.Task != "Proteinfütterung" {
				t.Fatalf("messor: %+v", c)
			}
		case "Lasius":
			if !c.Hibernating || c.Overdue != 0 {
				t.Fatalf("lasius: %+v", c)
			}
		}
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

	// A new address replaces the old one; a wrong secret looks like a missing page.
	token2 := anna.Do("POST", "/api/v1/me/feed", nil).Must(t, 201).JSON()["token"].(string)
	env.Anon().Do("GET", "/api/v1/feeds/"+token+"/status.json", nil).Must(t, 404)
	env.Anon().Do("GET", "/api/v1/feeds/"+token2[:len(token2)-3]+"xyz/status.json", nil).Must(t, 404)
	env.Anon().Do("GET", "/api/v1/feeds/nonsense/calendar.ics", nil).Must(t, 404)
	env.Anon().Do("GET", "/api/v1/feeds/"+token2+"/calendar.ics", nil).Must(t, 200)

	// Another user sees only their own colonies.
	ben := env.User(t, "Ben")
	benToken := ben.Do("POST", "/api/v1/me/feed", nil).Must(t, 201).JSON()["token"].(string)
	env.Anon().Do("GET", "/api/v1/feeds/"+benToken+"/status.json", nil).Must(t, 200).Decode(t, &st)
	if len(st.Colonies) != 0 || st.Overdue != 0 {
		t.Fatalf("ben sees: %+v", st)
	}

	anna.Do("DELETE", "/api/v1/me/feed", nil).Must(t, 204)
	env.Anon().Do("GET", "/api/v1/feeds/"+token2+"/status.json", nil).Must(t, 404)
}
