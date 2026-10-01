package api_test

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// An administrator deletes another account: colonies, photos (also the
// files) go, shared colonies of others stay, members lose access.
func TestAdminDeleteUser(t *testing.T) {
	env := testenv.New(t)
	admin := env.Admin(t)
	bert := env.User(t, "Bert")
	carla := env.User(t, "Carla")

	colony := bert.CreateColony(t, map[string]any{"name": "Lasius"})
	bert.Do("POST", "/api/v1/colonies/"+colony.String()+"/members", map[string]any{"email": carla.Email, "role": "viewer"})
	photo := testenv.NewID()
	bert.Do("POST", "/api/v1/photos", map[string]any{"id": photo, "colony_id": colony}).Must(t, 201)
	img := testJPEG(t, 120, 80, 1)
	sum := sha256.Sum256(img)
	bert.Do("PUT", "/api/v1/photos/"+photo.String()+"/content", img, "Content-SHA256", hex.EncodeToString(sum[:])).Must(t, 200)
	var key string
	if err := env.Svc.Pool.QueryRow(t.Context(), `SELECT storage_key FROM photos WHERE id = $1`, photo).Scan(&key); err != nil || !env.Svc.Blobs.Exists(key) {
		t.Fatalf("photo file: %q %v", key, err)
	}
	carlas := carla.CreateColony(t, map[string]any{"name": "Messor"})

	del := func(c *testenv.Client, id, confirm string) *testenv.Response {
		return c.Do("POST", "/api/v1/admin/users/"+id+"/delete", map[string]any{"confirm_email": confirm})
	}
	del(carla, bert.UserID.String(), bert.Email).Must(t, 403)         // only admins
	del(admin, bert.UserID.String(), carla.Email).Must(t, 422)        // wrong confirmation
	del(admin, admin.UserID.String(), admin.Email).Must(t, 422)       // not yourself
	del(admin, testenv.NewID().String(), "x@ants.test").Must(t, 404)  // unknown
	del(admin, bert.UserID.String(), " "+bert.Email+" ").Must(t, 204) // case/space tolerant

	if n := env.Count(t, `SELECT count(*) FROM users WHERE id = $1`, bert.UserID); n != 0 {
		t.Fatal("user still there")
	}
	if n := env.Count(t, `SELECT count(*) FROM colonies WHERE id = $1`, colony); n != 0 {
		t.Fatal("colony still there")
	}
	if env.Svc.Blobs.Exists(key) {
		t.Fatal("photo file left on disk")
	}
	if n := env.Count(t, `SELECT count(*) FROM colonies WHERE id = $1`, carlas); n != 1 {
		t.Fatal("other user's colony deleted")
	}
	if r := bert.Do("GET", "/api/v1/me", nil); r.Status != 401 {
		t.Fatalf("deleted user still signed in: %d", r.Status)
	}
	if n := env.Count(t, `SELECT count(*) FROM audit_log WHERE action = 'user_deleted'`); n != 1 {
		t.Fatalf("audit entries: %d", n)
	}
	users := admin.Do("GET", "/api/v1/admin/users", nil).Must(t, 200).JSON()["users"].([]any)
	if len(users) != 2 {
		t.Fatalf("users after delete: %d", len(users))
	}
}
