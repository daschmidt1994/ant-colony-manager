package api_test

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// The update button only drops a request file for the updater service.
func TestUpdateButton(t *testing.T) {
	dir := t.TempDir()
	env := testenv.New(t, testenv.Options{Env: map[string]string{"UPDATE_DIR": dir}})
	admin := env.Admin(t)
	env.User(t, "Ben").Do("GET", "/api/v1/admin/update", nil).Must(t, 403)

	// no updater running
	if st := admin.Do("GET", "/api/v1/admin/update", nil).Must(t, 200).JSON(); st["available"] != false || st["state"] != "idle" {
		t.Fatalf("without updater: %v", st)
	}
	admin.Do("POST", "/api/v1/admin/update", nil).Must(t, 409)

	beat := func() {
		os.WriteFile(filepath.Join(dir, "heartbeat"), []byte(strconv.FormatInt(env.Clock.Now().Unix(), 10)+"\n"), 0o644)
	}
	beat()
	if st := admin.Do("POST", "/api/v1/admin/update", nil).Must(t, 202).JSON(); st["state"] != "requested" {
		t.Fatalf("requested: %v", st)
	}
	if _, err := os.Stat(filepath.Join(dir, "request")); err != nil {
		t.Fatal("no request file")
	}
	admin.Do("POST", "/api/v1/admin/update", nil).Must(t, 409) // already requested

	// the updater took it and failed
	os.Remove(filepath.Join(dir, "request"))
	os.WriteFile(filepath.Join(dir, "status.json"), []byte(`{"state":"failed","message":"Update fehlgeschlagen","at":"2026-09-30T10:00:00Z"}`), 0o644)
	os.WriteFile(filepath.Join(dir, "update.log"), []byte(strings.Repeat("x", 5000)+"pull access denied"), 0o644)
	st := admin.Do("GET", "/api/v1/admin/update", nil).Must(t, 200).JSON()
	if st["state"] != "failed" || !strings.HasSuffix(st["log"].(string), "pull access denied") || len(st["log"].(string)) > 4000 {
		t.Fatalf("failed: %v", st["state"])
	}
	// a stale heartbeat: the updater is gone
	env.Clock.Advance(2 * 60e9)
	if st := admin.Do("GET", "/api/v1/admin/update", nil).Must(t, 200).JSON(); st["available"] != false {
		t.Fatalf("stale heartbeat: %v", st)
	}
}
