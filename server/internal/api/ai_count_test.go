package api_test

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// Counting ants with AI: the request to Claude and adding up the photos,
// against a fake Anthropic API.
func TestAICount(t *testing.T) {
	var calls atomic.Int32
	var lastReq map[string]any
	answer := `{"photos":[{"photo":1,"count":120,"min":100,"max":140,"queens":1,"note":""},` +
		`{"photo":2,"count":80,"min":70,"max":95,"queens":0,"note":"Viele Ameisen verdeckt"}],"overlap":false,"note":""}`
	status := http.StatusOK
	errBody := `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`
	rejectFallbacks := false
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/v1/messages" || r.Header.Get("X-Api-Key") != "sk-ant-test" {
			t.Errorf("request %s key %q", r.URL.Path, r.Header.Get("X-Api-Key"))
		}
		b, _ := io.ReadAll(r.Body)
		lastReq = map[string]any{}
		json.Unmarshal(b, &lastReq)
		w.Header().Set("Content-Type", "application/json")
		if rejectFallbacks && lastReq["fallbacks"] != nil {
			w.WriteHeader(400)
			w.Write([]byte(`{"type":"error","error":{"type":"invalid_request_error","message":"fallbacks: not available for this organization"}}`))
			return
		}
		if status != http.StatusOK {
			w.WriteHeader(status)
			w.Write([]byte(errBody))
			return
		}
		msg, _ := json.Marshal(map[string]any{"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
			"content": []any{map[string]any{"type": "text", "text": answer}}, "stop_reason": "end_turn",
			"usage": map[string]any{"input_tokens": 10, "output_tokens": 10}})
		w.Write(msg)
	}))
	defer api.Close()

	env := testenv.New(t)
	env.Svc.AIBaseURL = api.URL
	admin := env.Admin(t)
	anna := env.User(t, "Anna")
	colony := anna.CreateColony(t, nil)
	var photos []uuid.UUID
	for i := 0; i < 2; i++ {
		id := testenv.NewID()
		anna.Do("POST", "/api/v1/photos", map[string]any{"id": id, "colony_id": colony}).Must(t, 201)
		img := testJPEG(t, 300, 200, 1)
		sum := sha256.Sum256(img)
		anna.Do("PUT", "/api/v1/photos/"+id.String()+"/content", img, "Content-SHA256", hex.EncodeToString(sum[:])).Must(t, 200)
		photos = append(photos, id)
	}
	count := func(c *testenv.Client, ids []uuid.UUID, want int) map[string]any {
		t.Helper()
		return c.Do("POST", "/api/v1/colonies/"+colony.String()+"/ai-count", map[string]any{"photo_ids": ids}).Must(t, want).JSON()
	}

	// not set up
	if anna.Do("GET", "/api/v1/ai", nil).Must(t, 200).JSON()["available"] != false {
		t.Fatal("available without setup")
	}
	count(anna, photos, 409)
	anna.Do("PUT", "/api/v1/admin/ai", map[string]any{"enabled": true, "api_key": "x"}).Must(t, 403)
	admin.Do("PUT", "/api/v1/admin/ai", map[string]any{"enabled": true}).Must(t, 422)
	admin.Do("PUT", "/api/v1/admin/ai", map[string]any{"enabled": true, "api_key": "k", "model": "gpt-4"}).Must(t, 422)
	s := admin.Do("PUT", "/api/v1/admin/ai", map[string]any{"enabled": true, "api_key": "sk-ant-test"}).Must(t, 200).JSON()
	if s["api_key_set"] != true || s["api_key"] != nil || s["model"] != "claude-opus-5-5" {
		t.Fatalf("settings: %v", s)
	}
	if anna.Do("GET", "/api/v1/ai", nil).Must(t, 200).JSON()["available"] != true {
		t.Fatal("not available after setup")
	}

	r := count(anna, photos, 200)
	if r["total"] != float64(200) || r["min"] != float64(170) || r["max"] != float64(235) {
		t.Fatalf("sum: %v", r)
	}
	per := r["photos"].([]any)
	if per[1].(map[string]any)["photo_id"] != photos[1].String() || per[0].(map[string]any)["queens"] != float64(1) {
		t.Fatalf("per photo: %v", per)
	}
	// the request: model, both images, JSON schema, fallback
	if lastReq["model"] != "claude-opus-5-5" {
		t.Fatalf("model: %v", lastReq["model"])
	}
	images := 0
	for _, b := range lastReq["messages"].([]any)[0].(map[string]any)["content"].([]any) {
		if b.(map[string]any)["type"] == "image" {
			images++
		}
	}
	oc := lastReq["output_config"].(map[string]any)["format"].(map[string]any)
	if images != 2 || oc["type"] != "json_schema" || lastReq["fallbacks"] != "default" {
		t.Fatalf("request: images %d, format %v, fallbacks %v", images, oc["type"], lastReq["fallbacks"])
	}

	// others may not count this colony; wrong or foreign photos; too many
	env.User(t, "Ben").Do("POST", "/api/v1/colonies/"+colony.String()+"/ai-count", map[string]any{"photo_ids": photos}).Must(t, 404)
	count(anna, []uuid.UUID{testenv.NewID()}, 422)
	count(anna, nil, 422)
	count(anna, make([]uuid.UUID, 7), 422)

	// the AI sends nonsense or refuses the key
	answer = `{"photos":[{"photo":1,"count":5,"min":9,"max":3,"queens":0,"note":""}],"overlap":false,"note":""}`
	if r := count(anna, photos, 502); !strings.Contains(r["title"].(string), "nicht jedes Foto") {
		t.Fatalf("incomplete answer: %v", r)
	}
	status = http.StatusUnauthorized
	if r := count(anna, photos, 502); !strings.Contains(r["title"].(string), "API-Schlüssel") {
		t.Fatalf("bad key: %v", r)
	}
	// no credit – Anthropic answers 400
	status = http.StatusBadRequest
	errBody = `{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}`
	if r := count(anna, photos, 502); !strings.Contains(r["title"].(string), "Guthaben") {
		t.Fatalf("no credit: %v", r)
	}
	// any other reason is shown as Anthropic sent it
	errBody = `{"type":"error","error":{"type":"invalid_request_error","message":"image exceeds 5 MB maximum"}}`
	if r := count(anna, photos, 502); !strings.Contains(r["title"].(string), "image exceeds 5 MB maximum") {
		t.Fatalf("reason: %v", r)
	}
	// fallbacks not available: counted again without them
	status, rejectFallbacks = http.StatusOK, true
	answer = `{"photos":[{"photo":1,"count":3,"min":3,"max":3,"queens":0,"note":""},{"photo":2,"count":4,"min":4,"max":4,"queens":0,"note":""}],"overlap":false,"note":""}`
	if r := count(anna, photos, 200); r["total"] != float64(7) {
		t.Fatalf("retry without fallbacks: %v", r)
	}
	rejectFallbacks = false
	n := calls.Load()
	status = http.StatusOK
	answer = `{"photos":[{"photo":1,"count":5,"min":9,"max":3,"queens":0,"note":""}],"overlap":false,"note":""}`
	r = count(anna, photos[:1], 200)
	if p := r["photos"].([]any)[0].(map[string]any); p["min"] != float64(5) || p["max"] != float64(5) {
		t.Fatalf("range not repaired: %v", p)
	}
	if calls.Load() != n+1 {
		t.Fatal("unexpected retries")
	}
}
