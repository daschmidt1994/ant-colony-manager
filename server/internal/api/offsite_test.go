package api_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"testing"

	"golang.org/x/net/webdav"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// writeBackup creates a complete local backup like the backup container does.
func writeBackup(t *testing.T, dir, name string, photos map[string]string) {
	t.Helper()
	b := filepath.Join(dir, name)
	var sums []string
	for p, content := range photos {
		f := filepath.Join(b, "uploads", p)
		if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
		h := sha256.Sum256([]byte(content))
		sums = append(sums, hex.EncodeToString(h[:])+"  uploads/"+p)
	}
	sort.Strings(sums)
	for f, c := range map[string]string{
		"db.dump": "dump of " + name, "manifest.json": `{"name":"` + name + `"}`,
		"uploads.sha256": strings.Join(sums, "\n") + "\n", "env.redacted": "SECRET=***redacted***",
		"env": "INSTANCE_SECRET=do-not-upload", "OK": "done",
	} {
		if err := os.WriteFile(filepath.Join(b, f), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestOffsiteBackupToWebDAV(t *testing.T) {
	backups := t.TempDir()
	env := testenv.New(t, testenv.Options{Env: map[string]string{"BACKUP_STATUS_DIR": backups}})
	admin := env.Admin(t)
	ctx := context.Background()

	fs := webdav.NewMemFS()
	dav := &webdav.Handler{Prefix: "/dav", FileSystem: fs, LockSystem: webdav.NewMemLS()}
	var puts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if u, p, ok := r.BasicAuth(); !ok || u != "ameisen" || p != "app-passwort" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.Method == http.MethodPut {
			puts.Add(1)
		}
		dav.ServeHTTP(w, r)
	}))
	defer srv.Close()
	exists := func(p string) bool {
		_, err := fs.Stat(ctx, "/"+p)
		return err == nil
	}

	// only administrators
	env.User(t, "Ben").Do("GET", "/api/v1/admin/offsite", nil).Must(t, 403)
	admin.Do("PUT", "/api/v1/admin/offsite", map[string]any{"enabled": true, "url": "ftp://x", "keep": 2}).Must(t, 422)

	admin.Do("PUT", "/api/v1/admin/offsite", map[string]any{
		"enabled": true, "url": srv.URL + "/dav/acm-backups", "user": "ameisen", "password": "falsch", "keep": 2,
	}).Must(t, 200)
	if r := admin.Do("POST", "/api/v1/admin/offsite/test", nil).Must(t, 502); !strings.Contains(string(r.Body), "user and password") {
		t.Fatalf("wrong password: %s", r.Body)
	}
	got := admin.Do("PUT", "/api/v1/admin/offsite", map[string]any{
		"enabled": true, "url": srv.URL + "/dav/acm-backups", "user": "ameisen", "password": "app-passwort", "keep": 2,
	}).Must(t, 200).JSON()
	if got["password_set"] != true || got["password"] != nil || got["type"] != "webdav" {
		t.Fatalf("settings: %v", got)
	}
	admin.Do("POST", "/api/v1/admin/offsite/test", nil).Must(t, 204)

	// nothing local yet → nothing to do
	if did, err := env.Svc.OffsiteSync(ctx, false); err != nil || did {
		t.Fatalf("empty: %v %v", did, err)
	}

	writeBackup(t, backups, "2026-09-27T0300", map[string]string{"c1/a.jpg": "A", "c1/b.jpg": "B"})
	if did, err := env.Svc.OffsiteSync(ctx, false); err != nil || !did {
		t.Fatalf("first: %v %v", did, err)
	}
	for _, p := range []string{"acm-backups/2026-09-27T0300/db.dump", "acm-backups/2026-09-27T0300/OK",
		"acm-backups/2026-09-27T0300/env.redacted", "acm-backups/uploads/c1/a.jpg", "acm-backups/uploads/c1/b.jpg"} {
		if !exists(p) {
			t.Errorf("missing remotely: %s", p)
		}
	}
	if exists("acm-backups/2026-09-27T0300/env") {
		t.Fatal("unredacted env must never be uploaded")
	}
	// already there → no second upload
	before := puts.Load()
	if did, _ := env.Svc.OffsiteSync(ctx, false); did || puts.Load() != before {
		t.Fatal("uploaded the same backup twice")
	}

	// next night: one new photo, the old ones are not sent again
	writeBackup(t, backups, "2026-09-28T0300", map[string]string{"c1/a.jpg": "A", "c1/b.jpg": "B", "c2/c.jpg": "C"})
	before = puts.Load()
	if did, err := env.Svc.OffsiteSync(ctx, false); err != nil || !did {
		t.Fatalf("second: %v %v", did, err)
	}
	// 1 new photo + db.dump, manifest.json, uploads.sha256, env.redacted, OK
	if n := puts.Load() - before; n != 6 {
		t.Fatalf("second run sent %d files", n)
	}

	// third night: keep = 2 → the oldest remote backup goes, photos stay
	writeBackup(t, backups, "2026-09-29T0300", map[string]string{"c1/a.jpg": "A", "c1/b.jpg": "B", "c2/c.jpg": "C"})
	if _, err := env.Svc.OffsiteSync(ctx, false); err != nil {
		t.Fatal(err)
	}
	if exists("acm-backups/2026-09-27T0300") || !exists("acm-backups/2026-09-28T0300/OK") ||
		!exists("acm-backups/2026-09-29T0300/OK") || !exists("acm-backups/uploads/c1/a.jpg") {
		t.Fatal("retention wrong")
	}

	st := admin.Do("GET", "/api/v1/admin/offsite", nil).Must(t, 200).JSON()["status"].(map[string]any)
	if st["last_name"] != "2026-09-29T0300" || st["local_latest"] != "2026-09-29T0300" || st["last_error"] != nil {
		t.Fatalf("status: %v", st)
	}

	// broken target → error in the status, no crash
	admin.Do("PUT", "/api/v1/admin/offsite", map[string]any{
		"enabled": true, "url": srv.URL + "/dav/acm-backups", "user": "ameisen", "password": "geaendert", "keep": 2,
	}).Must(t, 200)
	if _, err := env.Svc.OffsiteSync(ctx, true); err == nil {
		t.Fatal("expected an error")
	}
	st = admin.Do("GET", "/api/v1/admin/offsite", nil).Must(t, 200).JSON()["status"].(map[string]any)
	if !strings.Contains(fmt.Sprint(st["last_error"]), "user and password") {
		t.Fatalf("status after error: %v", st)
	}
}

// A folder mounted into the container (NFS, USB disk) as the target.
func TestOffsiteBackupToFolder(t *testing.T) {
	backups := t.TempDir()
	target := t.TempDir()
	env := testenv.New(t, testenv.Options{Env: map[string]string{"BACKUP_STATUS_DIR": backups}})
	admin := env.Admin(t)
	ctx := context.Background()
	put := func(url string, status int) map[string]any {
		return admin.Do("PUT", "/api/v1/admin/offsite", map[string]any{"enabled": true, "type": "folder", "url": url, "keep": 1}).
			Must(t, status).JSON()
	}

	// never the local backups themselves (retention would delete them), only absolute paths
	put(backups, 422)
	put(filepath.Join(backups, "sub"), 422)
	put(filepath.Dir(backups), 422)
	put("offsite", 422)
	admin.Do("PUT", "/api/v1/admin/offsite", map[string]any{"enabled": true, "type": "ftp", "url": "/x", "keep": 1}).Must(t, 422)

	// a missing mount is reported, not silently created
	put(filepath.Join(target, "fehlt"), 200)
	if r := admin.Do("POST", "/api/v1/admin/offsite/test", nil).Must(t, 502); !strings.Contains(string(r.Body), "mounted") {
		t.Fatalf("missing folder: %s", r.Body)
	}

	if s := put(target, 200); s["type"] != "folder" || s["url"] != target {
		t.Fatalf("settings: %v", s)
	}
	admin.Do("POST", "/api/v1/admin/offsite/test", nil).Must(t, 204)

	exists := func(p string) bool { _, err := os.Stat(filepath.Join(target, p)); return err == nil }
	writeBackup(t, backups, "2026-09-27T0300", map[string]string{"c1/a.jpg": "A"})
	if did, err := env.Svc.OffsiteSync(ctx, false); err != nil || !did {
		t.Fatalf("first: %v %v", did, err)
	}
	if b, _ := os.ReadFile(filepath.Join(target, "uploads/c1/a.jpg")); string(b) != "A" ||
		!exists("2026-09-27T0300/OK") || exists("2026-09-27T0300/env") || exists("2026-09-27T0300/OK.part") ||
		exists(".acm-write-test") {
		t.Fatal("first upload wrong")
	}
	writeBackup(t, backups, "2026-09-28T0300", map[string]string{"c1/a.jpg": "A"})
	if _, err := env.Svc.OffsiteSync(ctx, false); err != nil {
		t.Fatal(err)
	}
	if exists("2026-09-27T0300") || !exists("2026-09-28T0300/db.dump") || !exists("uploads/c1/a.jpg") {
		t.Fatal("retention wrong")
	}
}
