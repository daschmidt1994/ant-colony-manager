package api_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestUpdateCheckWarnsAboutBreakingChanges(t *testing.T) {
	env := testenv.New(t)
	anna := env.User(t, "Anna")
	var calls atomic.Int32
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		_ = json.NewEncoder(w).Encode([]map[string]any{
			{"tag_name": "v2.0.0", "html_url": "https://github.com/x/r/releases/v2.0.0", "published_at": "2026-10-10T10:00:00Z",
				"body": "## ⚠ Breaking Changes\n\nDatenbank neu, alte Apps gehen nicht mehr.\nVorher Backup!\n\n**Android-App:** …"},
			{"tag_name": "v1.3.0", "html_url": "u", "published_at": "2026-10-01T10:00:00Z", "body": "Neu: Englisch"},
			{"tag_name": "v1.2.3", "html_url": "u", "published_at": "2026-09-29T10:00:00Z", "body": "Fix"},
			{"tag_name": "v1.2.2", "html_url": "u", "published_at": "2026-09-28T10:00:00Z", "body": ""},
			{"tag_name": "v9.9.9", "draft": true},
			{"tag_name": "v3.0.0-rc1", "prerelease": true},
		})
	}))
	t.Cleanup(gh.Close)
	env.Cfg.UpdateURL = gh.URL
	ctx := context.Background()

	u := env.Svc.Updates(ctx, "1.2.2-dev.abc1234", "de")
	if !u.UpdateAvailable || u.Latest != "2.0.0" || !u.Breaking || len(u.Newer) != 3 {
		t.Fatalf("updates: %+v", u)
	}
	if u.Newer[0].BreakingText != "Datenbank neu, alte Apps gehen nicht mehr.\nVorher Backup!" || u.Newer[1].Breaking {
		t.Fatalf("breaking text: %+v", u.Newer)
	}
	// From 1.2.3: 1.3.0 is harmless, but 2.0.0 ahead still warns.
	if u := env.Svc.Updates(ctx, "1.2.3", "de"); !u.Breaking || u.Latest != "2.0.0" || len(u.Newer) != 2 {
		t.Fatalf("from 1.2.3: %+v", u)
	}
	if u := env.Svc.Updates(ctx, "2.0.0", "de"); u.UpdateAvailable || u.Breaking {
		t.Fatalf("up to date: %+v", u)
	}
	if calls.Load() != 1 {
		t.Fatalf("release list fetched %d times – must be cached", calls.Load())
	}
	env.Clock.Advance(7 * time.Hour)
	env.Svc.Updates(ctx, "2.0.0", "de")
	if calls.Load() != 2 {
		t.Fatal("cache not refreshed after 6 hours")
	}

	// Switched off → no request at all; the endpoint answers for every user.
	env.Cfg.UpdateCheck = false
	if u := env.Svc.Updates(ctx, "1.0.0", "de"); u.Enabled || u.UpdateAvailable {
		t.Fatalf("disabled: %+v", u)
	}
	if calls.Load() != 2 {
		t.Fatal("request although disabled")
	}
	r := anna.Do("GET", "/api/v1/updates", nil).Must(t, 200).JSON()
	if r["enabled"] != false || r["newer"] == nil {
		t.Fatalf("endpoint: %v", r)
	}
}

func TestMajorVersionIsBreakingWithoutNotes(t *testing.T) {
	env := testenv.New(t)
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode([]map[string]any{{"tag_name": "v2.0.0", "html_url": "u", "body": "ohne Abschnitt"}})
	}))
	t.Cleanup(gh.Close)
	env.Cfg.UpdateURL = gh.URL + "/major"
	if u := env.Svc.Updates(context.Background(), "1.9.0", "de"); !u.Breaking || !u.Newer[0].Breaking {
		t.Fatalf("major bump must warn: %+v", u)
	}
}
