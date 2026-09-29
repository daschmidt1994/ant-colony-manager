package api_test

import (
	"testing"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestSpeciesCatalog(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")

	// The shipped catalog is visible to everyone and carries the care sheet.
	var catalog struct {
		Items []map[string]any `json:"items"`
	}
	u.Do("GET", "/api/v1/species", nil).Must(t, 200).Decode(t, &catalog)
	var nico map[string]any
	for _, s := range catalog.Items {
		if s["scientific_name"] == "Camponotus nicobarensis" {
			nico = s
		}
	}
	if len(catalog.Items) < 20 || nico == nil {
		t.Fatalf("catalog missing: %d species", len(catalog.Items))
	}
	if nico["hibernation"] != "none" || nico["temp_nest_min"] != 24.0 || nico["owner_id"] != nil {
		t.Fatalf("care sheet incomplete: %v", nico)
	}
	if src, _ := nico["sources"].([]any); len(src) == 0 {
		t.Fatalf("catalog species need a source: %v", nico["sources"])
	}

	// System species are read-only.
	u.Do("PATCH", "/api/v1/species/"+nico["id"].(string), map[string]any{"notes": "x"}).Must(t, 404)

	// Own species with care data; genus derives from the name.
	r := u.Do("POST", "/api/v1/species", map[string]any{
		"scientific_name": "Camponotus  sp. \"Rot\"", "temp_nest_min": 24, "temp_nest_max": 28,
		"hibernation": "optional", "difficulty": 2,
		"sources": []map[string]string{{"title": "Händler-Steckbrief", "url": "https://example.org/art"}, {"title": "Buch"}},
	}).Must(t, 201)
	own := r.JSON()["data"].(map[string]any)
	if own["genus"] != "Camponotus" || own["scientific_name"] != "Camponotus sp. \"Rot\"" || own["difficulty"] != 2.0 {
		t.Fatalf("own species: %v", own)
	}

	// Colonies link to catalog species.
	colony := u.Do("POST", "/api/v1/colonies", map[string]any{"name": "Nico #1", "species_id": nico["id"]}).Must(t, 201)
	if colony.JSON()["data"].(map[string]any)["species_id"] != nico["id"] {
		t.Fatalf("species link lost: %s", colony.Body)
	}

	for name, body := range map[string]map[string]any{
		"script url":   {"scientific_name": "X y", "sources": []map[string]string{{"title": "a", "url": "javascript:alert(1)"}}},
		"no title":     {"scientific_name": "X y", "sources": []map[string]string{{"url": "https://example.org"}}},
		"not a list":   {"scientific_name": "X y", "sources": map[string]string{"title": "a"}},
		"bad range":    {"scientific_name": "X y", "temp_nest_min": 30, "temp_nest_max": 20},
		"bad enum":     {"scientific_name": "X y", "hibernation": "sometimes"},
		"bad humidity": {"scientific_name": "X y", "humidity_nest_max": 120},
	} {
		if r := u.Do("POST", "/api/v1/species", body); r.Status < 400 || r.Status >= 500 {
			t.Errorf("%s: want 4xx, got %d %s", name, r.Status, r.Body)
		}
	}
}

func TestSpeciesCatalogTranslationsInvasiveAndFlightWatch(t *testing.T) {
	env := testenv.New(t)
	u := env.User(t, "Anna")
	var catalog struct {
		Items []map[string]any `json:"items"`
	}
	u.Do("GET", "/api/v1/species", nil).Must(t, 200).Decode(t, &catalog)
	invasive := map[string]bool{}
	for _, s := range catalog.Items {
		if s["owner_id"] != nil {
			continue
		}
		en, _ := s["translations"].(map[string]any)["en"].(map[string]any)
		if en["german_name"] == nil || en["distribution"] == nil {
			t.Errorf("%s: no English care sheet: %v", s["scientific_name"], s["translations"])
		}
		if s["eu_invasive"] == true {
			invasive[s["scientific_name"].(string)] = true
			if s["legal_note"] == nil || len(s["sources"].([]any)) < 2 {
				t.Errorf("%s: invasive without legal note or sources", s["scientific_name"])
			}
		}
	}
	for _, n := range []string{"Solenopsis invicta", "Solenopsis richteri", "Solenopsis geminata", "Wasmannia auropunctata"} {
		if !invasive[n] {
			t.Errorf("%s not marked as EU invasive", n)
		}
	}
	if len(invasive) != 4 {
		t.Errorf("invasive: %v", invasive)
	}

	id := catalog.Items[0]["id"].(string)
	u.Do("PATCH", "/api/v1/me/settings", map[string]any{"flight_watch": []string{id}}).Must(t, 200)
	if got := u.Do("GET", "/api/v1/me/settings", nil).Must(t, 200).JSON()["flight_watch"].([]any); len(got) != 1 || got[0] != id {
		t.Fatalf("flight_watch: %v", got)
	}
	u.Do("PATCH", "/api/v1/me/settings", map[string]any{"flight_watch": "Lasius"}).Must(t, 422)
}
