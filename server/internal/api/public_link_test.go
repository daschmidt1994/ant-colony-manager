package api_test

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// Public share page: what the owner chooses, nothing private.
func TestPublicLink(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	ben := env.User(t, "Ben")
	colony := anna.CreateColony(t, map[string]any{"name": "Messor Königsberg", "species_text": "Messor barbarus",
		"founded_on": "2025-05-12", "find_location": "Garten Wien 1010", "seller": "Ameisenshop XY", "notes": "private Notiz zur Kolonie"})
	ev := func(at time.Time, payload map[string]any) {
		payload["colony_id"], payload["occurred_at"] = colony, at
		r := anna.Push(t, testenv.Op{OpID: testenv.NewID(), Entity: "colony_events", EntityID: testenv.NewID(), Op: "create", Payload: testenv.Payload(payload)})
		if r.Results[0].Status != "applied" {
			t.Fatalf("event: %+v", r.Results[0].Error)
		}
	}
	now := time.Now()
	ev(now.AddDate(0, -2, 0), map[string]any{"type": "census", "census": map[string]any{"exact_count": 20}})
	ev(now.AddDate(0, 0, -3), map[string]any{"type": "census", "census": map[string]any{"exact_count": 57}})
	ev(now.AddDate(0, 0, -2), map[string]any{"type": "feeding", "feeding": map[string]any{"items": []any{map[string]any{"food_name": "Heimchen", "category": "protein"}}}})
	ev(now.AddDate(0, 0, -1), map[string]any{"type": "note", "note": "Geheimer Standort im Keller"})
	ev(now.AddDate(0, 0, -1), map[string]any{"type": "custom_task", "payload": map[string]any{"title": "Nest befeuchten"}})
	photo := testenv.NewID()
	anna.Do("POST", "/api/v1/photos", map[string]any{"id": photo, "colony_id": colony}).Must(t, 201)
	img := testJPEG(t, 300, 200, 1)
	sum := sha256.Sum256(img)
	anna.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", img, "Content-SHA256", hex.EncodeToString(sum[:])).Must(t, 200)

	// only the owner shares
	ben.Do("POST", "/api/v1/colonies/"+colony.String()+"/public-links", nil).Must(t, 404)
	link := anna.Do("POST", "/api/v1/colonies/"+colony.String()+"/public-links", nil).Must(t, 201).JSON()
	url := link["url"].(string)
	if !strings.HasPrefix(url, "https://ants.test/p/") || link["options"].(map[string]any)["notes"] != false {
		t.Fatalf("link: %v", link)
	}
	path := url[len("https://ants.test"):]
	page := env.Anon().Do("GET", path, nil).Must(t, 200)
	html := string(page.Body)
	for _, want := range []string{"Messor Königsberg", "Messor barbarus", "57", "Heimchen", "Koloniegröße", "Nest befeuchten", path + "/photos/" + photo.String() + "/thumb.jpg", "<polyline"} {
		if !strings.Contains(html, want) {
			t.Errorf("page lacks %q", want)
		}
	}
	for _, never := range []string{"Garten Wien", "Ameisenshop", "private Notiz", "Geheimer Standort", anna.Email, "Anna", "<script"} {
		if strings.Contains(html, never) {
			t.Errorf("page shows %q", never)
		}
	}
	if csp := page.Header.Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'none'") || page.Header.Get("X-Robots-Tag") == "" {
		t.Fatalf("headers: %v", page.Header)
	}
	env.Anon().Do("GET", path+"/photos/"+photo.String()+"/display.jpg", nil).Must(t, 200)
	env.Anon().Do("GET", path+"/photos/"+photo.String()+"/original.jpg", nil).Must(t, 404)
	env.Anon().Do("GET", path+"/photos/"+testenv.NewID().String()+"/thumb.jpg", nil).Must(t, 404)

	forum := string(env.Anon().Do("GET", path+"/forum.txt", nil).Must(t, 200).Body)
	for _, want := range []string{"[b]Messor Königsberg[/b]", "[i]Messor barbarus[/i]", "[img]" + url + "/photos/", "[url=" + url + "]"} {
		if !strings.Contains(forum, want) {
			t.Errorf("forum text lacks %q:\n%s", want, forum)
		}
	}

	// notes shown on request; photos and timeline can be switched off
	id := link["id"].(string)
	ben.Do("PATCH", "/api/v1/public-links/"+id, map[string]any{"notes": true}).Must(t, 404)
	anna.Do("PATCH", "/api/v1/public-links/"+id, map[string]any{"photos": false, "timeline": true, "notes": true}).Must(t, 204)
	html = string(env.Anon().Do("GET", path, nil).Must(t, 200).Body)
	if !strings.Contains(html, "Geheimer Standort") || strings.Contains(html, "/photos/") || strings.Contains(html, "Garten Wien") {
		t.Fatal("options not applied")
	}
	env.Anon().Do("GET", path+"/photos/"+photo.String()+"/thumb.jpg", nil).Must(t, 404)

	// revoked: gone
	ben.Do("DELETE", "/api/v1/public-links/"+id, nil).Must(t, 404)
	anna.Do("DELETE", "/api/v1/public-links/"+id, nil).Must(t, 204)
	env.Anon().Do("GET", path, nil).Must(t, 404)
	env.Anon().Do("GET", path+"/forum.txt", nil).Must(t, 404)
	env.Anon().Do("GET", "/p/nichtvorhandenertokenxyz", nil).Must(t, 404)
	var list []any
	anna.Do("GET", "/api/v1/colonies/"+colony.String()+"/public-links", nil).Must(t, 200).Decode(t, &list)
	if len(list) != 0 {
		t.Fatalf("revoked link listed: %v", list)
	}
}
