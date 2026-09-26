package api_test

import (
	"context"
	"encoding/hex"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestColonyLifecycle(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	r := u.Do("POST", "/api/v1/colonies", map[string]any{"name": "Messor #12", "species_text": "Messor barbarus",
		"status": "active", "gyne_type": "monogyne"}).Must(t, 201)
	id := r.JSON()["data"].(map[string]any)["id"].(string)
	etag := r.Header.Get("ETag")
	if r.JSON()["data"].(map[string]any)["number"].(float64) != 1 {
		t.Fatalf("first colony gets number 1: %s", r.Body)
	}

	ov := u.Do("GET", "/api/v1/colonies/"+id, nil).Must(t, 200).JSON()
	links := ov["scan_links"].([]any)
	if len(links) != 1 || links[0].(map[string]any)["kind"] != "qr" {
		t.Fatalf("new colony gets a QR code automatically: %v", links)
	}

	// Optimistic concurrency via If-Match.
	u.Do("PATCH", "/api/v1/colonies/"+id, map[string]any{"name": "Messor Königreich"}, "If-Match", etag).Must(t, 200)
	// Server-managed fields are ignored, not written.
	r = u.Do("PATCH", "/api/v1/colonies/"+id, map[string]any{"owner_id": uuid.NewString(), "queen_count": 99, "notes": "ok"}).Must(t, 200)
	if ign := r.JSON()["ignored_fields"]; ign == nil || !strings.Contains(fmt.Sprint(ign), "queen_count") {
		t.Fatalf("queen_count must be ignored: %s", r.Body)
	}

	u.Do("POST", "/api/v1/colonies/"+id+"/archive", nil).Must(t, 200)
	list := u.Do("GET", "/api/v1/colonies", nil).Must(t, 200).JSON()
	if list["count"].(float64) != 0 {
		t.Fatal("archived colonies are hidden by default")
	}
	list = u.Do("GET", "/api/v1/colonies?archived=true", nil).Must(t, 200).JSON()
	if list["count"].(float64) != 1 {
		t.Fatal("archived filter must show it")
	}
	u.Do("DELETE", "/api/v1/colonies/"+id, nil).Must(t, 204)
	u.Do("GET", "/api/v1/colonies/"+id, nil).Must(t, 410)
}

// Every endpoint must answer 404 for colonies of other users. New endpoints
// belong in this list.
func TestTenantIsolation(t *testing.T) {
	env := testenv.New(t)
	alice := env.User(t, "Alice")
	mallory := env.User(t, "Mallory")
	colony := alice.CreateColony(t, nil)
	ev := testenv.NewID()
	alice.Push(t, feedingOp(colony, ev, time.Now()))
	ov := alice.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 200).JSON()
	link := ov["scan_links"].([]any)[0].(map[string]any)
	token, linkID := link["token"].(string), link["id"].(string)
	photo := testenv.NewID()
	alice.Do("POST", "/api/v1/photos", map[string]any{"id": photo, "colony_id": colony}).Must(t, 201)
	loc := alice.Do("POST", "/api/v1/locations", map[string]any{"name": "Regal A"}).Must(t, 201).JSON()["data"].(map[string]any)["id"].(string)

	c := colony.String()
	cases := []struct{ method, path string }{
		{"GET", "/api/v1/colonies/" + c},
		{"PATCH", "/api/v1/colonies/" + c},
		{"DELETE", "/api/v1/colonies/" + c},
		{"POST", "/api/v1/colonies/" + c + "/archive"},
		{"GET", "/api/v1/colonies/" + c + "/timeline"},
		{"GET", "/api/v1/colonies/" + c + "/due"},
		{"POST", "/api/v1/colonies/" + c + "/feedings/repeat-last"},
		{"GET", "/api/v1/colonies/" + c + "/members"},
		{"POST", "/api/v1/colonies/" + c + "/members"},
		{"POST", "/api/v1/colonies/" + c + "/scan-links/regenerate"},
		{"GET", "/api/v1/scan/" + token},
		{"GET", "/api/v1/scan-links/" + linkID + "/qr.svg"},
		{"GET", "/api/v1/scan-links/" + linkID},
		{"GET", "/api/v1/events/" + ev.String()},
		{"PATCH", "/api/v1/events/" + ev.String()},
		{"DELETE", "/api/v1/events/" + ev.String()},
		{"GET", "/api/v1/photos/" + photo.String()},
		{"GET", "/api/v1/photos/" + photo.String() + "/url"},
		{"PUT", "/api/v1/photos/" + photo.String() + "/content"},
		{"GET", "/api/v1/queens?colony_id=" + c},
		{"GET", "/api/v1/locations/" + loc},
		{"PATCH", "/api/v1/locations/" + loc},
	}
	for _, tc := range cases {
		var body any
		if tc.method == "PATCH" || tc.method == "POST" {
			body = map[string]any{"name": "pwned", "email": "mallory@ants.test", "role": "editor"}
		}
		r := mallory.Do(tc.method, tc.path, body)
		if r.Status != 404 {
			t.Errorf("%s %s: expected 404, got %d %s", tc.method, tc.path, r.Status, r.Body)
		}
	}
	// Sync writes into a foreign colony are rejected; reads contain nothing foreign.
	r := mallory.Push(t, feedingOp(colony, testenv.NewID(), time.Now()))
	if r.Results[0].Status != "rejected" {
		t.Fatalf("foreign sync write: %+v", r.Results[0])
	}
	r = mallory.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colonies", EntityID: testenv.NewID(), Op: "create",
		Payload: testenv.Payload(map[string]any{"name": "X", "species_text": "Y", "location_id": loc})})
	if r.Results[0].Status != "rejected" {
		t.Fatalf("referencing a foreign location must fail: %+v", r.Results[0])
	}
	for _, ch := range mallory.Pull(t, 0).Changes {
		if ch.Entity != "user_settings" && ch.Entity != "food_items" && ch.Entity != "colony_members" && ch.Entity != "colonies" {
			t.Errorf("mallory sees %s", ch.Entity)
		}
		if ch.Entity == "colonies" || ch.Entity == "colony_members" {
			var m map[string]any
			_ = jsonUnmarshal(ch.Data, &m)
			if m["id"] == colony.String() || m["colony_id"] == colony.String() {
				t.Errorf("mallory sees alice's colony")
			}
		}
	}
	if n := mallory.Do("GET", "/api/v1/colonies", nil).JSON()["count"].(float64); n != 0 {
		t.Fatalf("mallory owns no colony (her create was rejected) – got %v", n)
	}
}

func TestDueDashboardAndRepeatFeeding(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, map[string]any{"name": "Messor #12"})
	for _, s := range []map[string]any{
		{"colony_id": colony, "task_type": "protein", "interval_days": 3, "starts_at": time.Now().Add(-30 * 24 * time.Hour)},
		{"colony_id": colony, "task_type": "water", "interval_days": 2, "starts_at": time.Now()},
	} {
		u.Do("POST", "/api/v1/schedules", s).Must(t, 201)
	}
	u.Push(t, feedingOp(colony, testenv.NewID(), time.Now().Add(-5*24*time.Hour)))

	due := u.Do("GET", "/api/v1/colonies/"+colony.String()+"/due", nil).Must(t, 200).JSON()["due"].([]any)
	protein := due[0].(map[string]any)
	if protein["task_type"] != "protein" || protein["status"] != "overdue" || protein["days"].(float64) != -2 {
		t.Fatalf("protein should be 2 days overdue: %v", protein)
	}
	dash := u.Do("GET", "/api/v1/dashboard", nil).Must(t, 200).JSON()
	if n := len(dash["groups"].(map[string]any)["overdue"].([]any)); n != 1 {
		t.Fatalf("dashboard overdue group: %v", dash["groups"])
	}
	if dash["needs_attention"].(float64) != 1 {
		t.Fatalf("needs_attention: %v", dash["needs_attention"])
	}

	// One tap: repeat the last feeding.
	r := u.Do("POST", "/api/v1/colonies/"+colony.String()+"/feedings/repeat-last", nil).Must(t, 201)
	items := r.JSON()["data"].(map[string]any)["feeding"].(map[string]any)["items"].([]any)
	if len(items) != 2 {
		t.Fatalf("repeated feeding must copy items: %s", r.Body)
	}
	due = u.Do("GET", "/api/v1/colonies/"+colony.String()+"/due", nil).Must(t, 200).JSON()["due"].([]any)
	for _, d := range due {
		if d.(map[string]any)["task_type"] == "protein" && d.(map[string]any)["status"] == "overdue" {
			t.Fatal("protein must no longer be overdue after feeding")
		}
	}
	// Filter: colonies with water due.
	list := u.Do("GET", "/api/v1/colonies?due=water", nil).Must(t, 200).JSON()
	if list["count"].(float64) != 0 {
		t.Fatal("water is not due yet (interval starts today + 2 days)")
	}
}

func TestWinterRestPausesTasks(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	u.Do("POST", "/api/v1/schedules", map[string]any{"colony_id": colony, "task_type": "water", "interval_days": 2,
		"starts_at": time.Now().Add(-10 * 24 * time.Hour)}).Must(t, 201)
	wr := u.Do("POST", "/api/v1/winter-rests", map[string]any{"colony_id": colony, "started_on": time.Now().Format("2006-01-02"),
		"reminder_mode": "pause", "target_temp_c": 8}).Must(t, 201).JSON()["data"].(map[string]any)
	ov := u.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 200).JSON()
	if ov["colony"].(map[string]any)["status"] != "hibernating" {
		t.Fatalf("colony should hibernate: %v", ov["colony"].(map[string]any)["status"])
	}
	if ov["due"].([]any)[0].(map[string]any)["status"] != "paused" {
		t.Fatalf("water must be paused: %v", ov["due"])
	}
	dash := u.Do("GET", "/api/v1/dashboard", nil).Must(t, 200).JSON()
	if len(dash["hibernating"].([]any)) != 1 {
		t.Fatal("dashboard must list hibernating colony")
	}
	u.Do("PATCH", "/api/v1/winter-rests/"+wr["id"].(string), map[string]any{"ended_on": time.Now().Format("2006-01-02")}).Must(t, 200)
	ov = u.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 200).JSON()
	if ov["colony"].(map[string]any)["status"] != "active" {
		t.Fatal("colony should be active after winter rest")
	}
}

func TestEventValidationAndSideEffects(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	push := func(payload map[string]any) testenv.PushResult {
		payload["colony_id"] = colony
		return u.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(payload)})
	}
	bad := []map[string]any{
		{"type": "feeding"}, // no items
		{"type": "feeding", "feeding": map[string]any{"items": []any{}}},
		{"type": "water", "water": map[string]any{"kinds": []string{"champagne"}}},
		{"type": "note", "feeding": map[string]any{"items": []any{map[string]any{"food_name": "x", "category": "protein"}}}},
		{"type": "measurement", "measurements": []any{map[string]any{"metric": "humidity", "value": 140}}},
		{"type": "teleport"},
	}
	for i, p := range bad {
		if r := push(p); r.Results[0].Status != "rejected" {
			t.Errorf("case %d must be rejected: %+v", i, r.Results[0])
		}
	}
	// Future timestamps from wrong device clocks are clamped.
	ev := testenv.NewID()
	u.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: ev, Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony, "type": "note", "note": "Hallo",
			"occurred_at": time.Now().Add(48 * time.Hour)})})
	var at time.Time
	env.Pool.QueryRow(context.Background(), `SELECT occurred_at FROM colony_events WHERE id = $1`, ev).Scan(&at)
	if at.After(time.Now().Add(time.Minute)) {
		t.Fatalf("future timestamp must be clamped, got %v", at)
	}

	// Census, measurement and queen events update the colony header fields.
	queen := testenv.NewID()
	u.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "queens", EntityID: queen, Op: "create",
		Payload: testenv.Payload(map[string]any{"colony_id": colony, "label": "Königin A"})})
	push(map[string]any{"type": "census", "census": map[string]any{"estimate_min": 500, "estimate_max": 1000}})
	push(map[string]any{"type": "water", "water": map[string]any{"kinds": []string{"nest_moistened"}},
		"measurements": []any{map[string]any{"metric": "temperature", "value": 25.4}, map[string]any{"metric": "humidity", "value": 61}}})
	c := u.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 200).JSON()["colony"].(map[string]any)
	if c["queen_count"].(float64) != 1 || c["worker_estimate_min"].(float64) != 500 || c["worker_estimate_max"].(float64) != 1000 {
		t.Fatalf("header fields: %v", c)
	}
	if c["last_measurement"].(map[string]any)["temperature"].(map[string]any)["value"].(float64) != 25.4 {
		t.Fatalf("last measurement: %v", c["last_measurement"])
	}
	push(map[string]any{"type": "queen", "queen": map[string]any{"queen_id": queen, "action": "died"}})
	c = u.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 200).JSON()["colony"].(map[string]any)
	if c["queen_count"].(float64) != 0 {
		t.Fatalf("queen died → 0 queens, got %v", c["queen_count"])
	}

	tl := u.Do("GET", "/api/v1/colonies/"+colony.String()+"/timeline?types=water,census", nil).Must(t, 200).JSON()
	if n := len(tl["events"].([]any)); n != 2 {
		t.Fatalf("timeline filter: %d events", n)
	}
}

func TestEventUpdateReplacesDetails(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	ev := testenv.NewID()
	u.Push(t, feedingOp(colony, ev, time.Now()))
	// Acceptance is often only known hours later.
	r := u.Do("PATCH", "/api/v1/events/"+ev.String(), map[string]any{"feeding": map[string]any{"acceptance": "accepted",
		"items": []any{map[string]any{"food_name": "Heimchen", "category": "protein", "quantity": 1}}}}).Must(t, 200)
	f := r.JSON()["data"].(map[string]any)["feeding"].(map[string]any)
	if f["acceptance"] != "accepted" || len(f["items"].([]any)) != 1 {
		t.Fatalf("details not replaced: %v", f)
	}
	if n := env.Count(t, `SELECT count(*) FROM feeding_items`); n != 1 {
		t.Fatalf("old items must be removed, %d left", n)
	}
}

func TestScanLinksAndNFC(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	ov := u.Do("GET", "/api/v1/colonies/"+colony.String(), nil).Must(t, 200).JSON()
	token := ov["scan_links"].([]any)[0].(map[string]any)["token"].(string)
	if !auth.ValidScanToken(token) {
		t.Fatalf("bad token format %q", token)
	}
	res := u.Do("GET", "/api/v1/scan/"+token, nil).Must(t, 200).JSON()
	if res["colony_id"] != colony.String() {
		t.Fatalf("QR → wrong colony: %v", res)
	}
	u.Do("GET", "/api/v1/scan/not-a-token", nil).Must(t, 404)
	u.Do("GET", "/api/v1/scan/0000000000000000", nil).Must(t, 404)

	svg := u.Do("GET", "/api/v1/scan-links/"+ov["scan_links"].([]any)[0].(map[string]any)["id"].(string)+"/qr.svg", nil).Must(t, 200)
	if !strings.HasPrefix(string(svg.Body), "<svg") || svg.Header.Get("Content-Type") != "image/svg+xml" {
		t.Fatalf("qr svg: %s", svg.Body[:40])
	}

	// Regenerate: old labels stop working, the new one works.
	newLink := u.Do("POST", "/api/v1/colonies/"+colony.String()+"/scan-links/regenerate", nil).Must(t, 201).JSON()
	if r := u.Do("GET", "/api/v1/scan/"+token, nil); r.Status != 410 || r.Code() != "scan.revoked" {
		t.Fatalf("old token must be revoked: %d %s", r.Status, r.Body)
	}
	u.Do("GET", "/api/v1/scan/"+newLink["token"].(string), nil).Must(t, 200)

	// NFC created offline by the app: link token generated on the device.
	nfcToken := auth.NewScanToken()
	link := testenv.NewID()
	uidKey := u.Do("GET", "/api/v1/me", nil).Must(t, 200).JSON()["nfc_uid_key"].(string)
	if uidKey == "" {
		t.Fatal("nfc_uid_key missing")
	}
	uidHash := hex.EncodeToString(auth.HMAC([]byte(uidKey), "04A2B3C4D5E680"))
	r := u.Push(t,
		testenv.Op{OpID: testenv.NewID(), Entity: "scan_links", EntityID: link, Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": colony, "token": nfcToken, "kind": "nfc"})},
		testenv.Op{OpID: testenv.NewID(), Entity: "nfc_tags", EntityID: testenv.NewID(), Op: "create",
			Payload: testenv.Payload(map[string]any{"colony_id": colony, "scan_link_id": link, "uid_hash": uidHash, "tag_type": "NTAG213"})},
	)
	for _, res := range r.Results {
		if res.Status != "applied" {
			t.Fatalf("nfc push: %+v", res)
		}
	}
	res = u.Do("GET", "/api/v1/scan/"+nfcToken, nil).Must(t, 200).JSON()
	if res["colony_id"] != colony.String() || res["kind"] != "nfc" {
		t.Fatalf("NFC → wrong colony: %v", res)
	}
	res = u.Do("POST", "/api/v1/scan/nfc-uid", map[string]any{"uid_hash": uidHash}).Must(t, 200).JSON()
	if res["colony_id"] != colony.String() {
		t.Fatalf("NFC UID → wrong colony: %v", res)
	}

	// Browser without app: landing page, no colony data, app link on Android.
	page := env.Anon().Do("GET", "/c/"+nfcToken, nil, "User-Agent", "Mozilla/5.0 (Linux; Android 15)").Must(t, 200)
	if !strings.Contains(string(page.Body), "intent://ants.test/c/"+nfcToken) {
		t.Fatalf("android landing page must offer the app: %s", page.Body)
	}
	if strings.Contains(string(page.Body), "Messor") {
		t.Fatal("landing page must not leak colony data")
	}
}

func TestLocationTreeFilter(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	room := u.Do("POST", "/api/v1/locations", map[string]any{"name": "Ameisenraum"}).Must(t, 201).JSON()["data"].(map[string]any)["id"].(string)
	shelf := u.Do("POST", "/api/v1/locations", map[string]any{"name": "Regal A", "parent_id": room}).Must(t, 201).JSON()["data"].(map[string]any)
	if shelf["path"] != "Ameisenraum/Regal A" {
		t.Fatalf("path: %v", shelf["path"])
	}
	level := u.Do("POST", "/api/v1/locations", map[string]any{"name": "Ebene 3", "parent_id": shelf["id"]}).Must(t, 201).JSON()["data"].(map[string]any)["id"].(string)
	u.CreateColony(t, map[string]any{"name": "Im Regal", "location_id": level})
	u.CreateColony(t, map[string]any{"name": "Woanders"})
	list := u.Do("GET", "/api/v1/colonies?location_id="+room, nil).Must(t, 200).JSON()
	if list["count"].(float64) != 1 {
		t.Fatalf("filter by parent location must include descendants: %v", list["count"])
	}
	// Renaming a parent updates the paths below.
	u.Do("PATCH", "/api/v1/locations/"+room, map[string]any{"name": "Keller"}).Must(t, 200)
	l := u.Do("GET", "/api/v1/locations/"+level, nil).Must(t, 200).JSON()
	if l["path"] != "Keller/Regal A/Ebene 3" {
		t.Fatalf("child path not updated: %v", l["path"])
	}
	// Cycles are impossible.
	if r := u.Do("PATCH", "/api/v1/locations/"+room, map[string]any{"parent_id": level}); r.Status != 422 {
		t.Fatalf("cycle must be rejected, got %d %s", r.Status, r.Body)
	}
	// Search finds colonies by location path and number.
	if n := u.Do("GET", "/api/v1/colonies?q=Regal", nil).JSON()["count"].(float64); n != 1 {
		t.Fatalf("search by location: %v", n)
	}
	if n := u.Do("GET", "/api/v1/colonies?q=%232", nil).JSON()["count"].(float64); n != 1 {
		t.Fatalf("search by #number: %v", n)
	}
}

func TestSensorIngest(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, nil)
	r := u.Do("POST", "/api/v1/sensors", map[string]any{"name": "ESP32 Regal A", "kind": "esp32", "colony_id": colony}).Must(t, 201).JSON()
	key := r["extra"].(map[string]any)["api_key"].(string)
	id := r["data"].(map[string]any)["id"].(string)
	if _, ok := r["data"].(map[string]any)["api_key_hash"]; ok {
		t.Fatal("key hash must never be sent to clients")
	}
	now := time.Now().UTC().Truncate(time.Second)
	body := map[string]any{"readings": []any{
		map[string]any{"metric": "temperature", "value": 24.8, "measured_at": now},
		map[string]any{"metric": "humidity", "value": 58, "measured_at": now},
	}}
	sensor := env.Anon()
	res := sensor.Do("POST", "/api/v1/sensors/"+id+"/measurements", body, "Authorization", "Bearer "+key).Must(t, 202).JSON()
	if res["stored"].(float64) != 2 {
		t.Fatalf("stored: %v", res)
	}
	res = sensor.Do("POST", "/api/v1/sensors/"+id+"/measurements", body, "Authorization", "Bearer "+key).Must(t, 202).JSON()
	if res["stored"].(float64) != 0 {
		t.Fatal("duplicates must be ignored")
	}
	sensor.Do("POST", "/api/v1/sensors/"+id+"/measurements", body, "Authorization", "Bearer "+key+"x").Must(t, 401)
	sensor.Do("POST", "/api/v1/sensors/"+uuid.NewString()+"/measurements", body, "Authorization", "Bearer "+key).Must(t, 401)
	// A sensor key is not a user session.
	sensor.Do("GET", "/api/v1/colonies", nil, "Authorization", "Bearer "+key).Must(t, 401)

	b := u.Do("GET", "/api/v1/sensors/"+id+"/measurements?bucket=1h", nil).Must(t, 200).JSON()["buckets"].([]any)
	if len(b) != 2 {
		t.Fatalf("buckets: %v", b)
	}
	newKey := u.Do("POST", "/api/v1/sensors/"+id+"/rotate-key", nil).Must(t, 200).JSON()["api_key"].(string)
	sensor.Do("POST", "/api/v1/sensors/"+id+"/measurements", body, "Authorization", "Bearer "+key).Must(t, 401)
	sensor.Do("POST", "/api/v1/sensors/"+id+"/measurements", body, "Authorization", "Bearer "+newKey).Must(t, 202)
}

func TestExportContainsUserData(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	colony := u.CreateColony(t, map[string]any{"name": "Export-Kolonie"})
	u.Push(t, feedingOp(colony, testenv.NewID(), time.Now()))
	r := u.Do("GET", "/api/v1/export.json", nil).Must(t, 200)
	if !strings.Contains(r.Header.Get("Content-Disposition"), "attachment") {
		t.Fatal("export must download as file")
	}
	ex := r.JSON()
	if ex["format"] != "ant-colony-manager/v1" {
		t.Fatalf("format: %v", ex["format"])
	}
	ents := ex["entities"].(map[string]any)
	if len(ents["colonies"].([]any)) != 1 || len(ents["colony_events"].([]any)) != 1 || len(ents["food_items"].([]any)) < 10 {
		t.Fatalf("export incomplete: colonies=%d events=%d", len(ents["colonies"].([]any)), len(ents["colony_events"].([]any)))
	}
}

func TestIdempotencyKeyOnREST(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	key := uuid.NewString()
	id := testenv.NewID()
	body := map[string]any{"id": id, "name": "Regal B"}
	u.Do("POST", "/api/v1/locations", body, "Idempotency-Key", key).Must(t, http.StatusCreated)
	r := u.Do("POST", "/api/v1/locations", body, "Idempotency-Key", key).Must(t, http.StatusOK)
	if r.JSON()["status"] != "duplicate" {
		t.Fatalf("retry must be a duplicate: %s", r.Body)
	}
	if n := env.Count(t, `SELECT count(*) FROM locations`); n != 1 {
		t.Fatalf("expected 1 location, got %d", n)
	}
}
