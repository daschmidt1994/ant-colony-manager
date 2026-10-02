package api_test

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestSetupRequiresTokenAndRunsOnce(t *testing.T) {
	env := testenv.New(t)
	anon := env.Anon()

	inst := anon.Do("GET", "/api/v1/instance", nil).Must(t, 200).JSON()
	if inst["setup_required"] != true {
		t.Fatalf("fresh instance should require setup: %v", inst)
	}
	if at, err := time.Parse(time.RFC3339Nano, fmt.Sprint(inst["server_time"])); err != nil || at.Sub(env.Clock.Now()).Abs() > time.Second ||
		inst["time_zone"] == "" {
		t.Fatalf("server time: %v %v (%v)", inst["server_time"], inst["time_zone"], err)
	}
	// Registration is impossible before setup.
	r := anon.Do("POST", "/api/v1/auth/register", map[string]any{"email": "x@ants.test", "password": "Messor-barbarus-12"})
	if r.Status != 409 || r.Code() != "setup.required" {
		t.Fatalf("register before setup: %d %s", r.Status, r.Body)
	}
	body := map[string]any{"email": "admin@ants.test", "password": "Formicarium-2026!", "setup_token": "wrong"}
	if r := anon.Do("POST", "/api/v1/setup", body); r.Status != 403 {
		t.Fatalf("wrong setup token must be refused, got %d", r.Status)
	}
	body["setup_token"] = testenv.SetupToken
	r = anon.Do("POST", "/api/v1/setup", body).Must(t, 201)
	if r.JSON()["user"].(map[string]any)["instance_role"] != "admin" {
		t.Fatalf("first user must be admin: %s", r.Body)
	}
	if r := anon.Do("POST", "/api/v1/setup", body); r.Status != 409 {
		t.Fatalf("second setup must fail, got %d", r.Status)
	}
	if anon.Do("GET", "/api/v1/instance", nil).JSON()["setup_required"] != false {
		t.Fatal("setup_required should be false after setup")
	}
}

func TestLoginRefreshRotationAndTheftDetection(t *testing.T) {
	env := testenv.New(t)
	env.Admin(t)
	anon := env.Anon()

	if r := anon.Do("POST", "/api/v1/auth/login", map[string]any{"email": "admin@ants.test", "password": "nope-nope-nope"}); r.Status != 401 {
		t.Fatalf("wrong password: %d", r.Status)
	}
	if r := anon.Do("POST", "/api/v1/auth/login", map[string]any{"email": "unknown@ants.test", "password": "nope-nope-nope"}); r.Status != 401 || r.Code() != "auth.invalid_credentials" {
		t.Fatalf("unknown user must look like wrong password: %d %s", r.Status, r.Body)
	}
	r := anon.Do("POST", "/api/v1/auth/login", map[string]any{"email": "ADMIN@ants.test ", "password": "Formicarium-2026!"}).Must(t, 200)
	s1 := r.JSON()
	rt1 := s1["refresh_token"].(string)
	at1 := s1["access_token"].(string)

	r = anon.Do("POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": rt1}).Must(t, 200)
	rt2 := r.JSON()["refresh_token"].(string)
	if rt2 == rt1 {
		t.Fatal("refresh token must rotate")
	}
	// Parallel refresh with the old token inside the grace period: refused, but no revocation.
	if r := anon.Do("POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": rt1}); r.Code() != "auth.token_rotated" {
		t.Fatalf("expected token_rotated, got %d %s", r.Status, r.Body)
	}
	// Later reuse of the old token = theft → whole family revoked.
	env.Clock.Advance(2 * time.Minute)
	if r := anon.Do("POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": rt1}); r.Code() != "auth.token_reused" {
		t.Fatalf("expected token_reused, got %d %s", r.Status, r.Body)
	}
	if r := anon.Do("POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": rt2}); r.Status != 401 {
		t.Fatalf("newer token of revoked family must be dead, got %d", r.Status)
	}
	c := &testenv.Client{Env: env, Token: at1}
	if r := c.Do("GET", "/api/v1/me", nil); r.Status != 401 {
		t.Fatalf("access token of revoked session must be rejected, got %d", r.Status)
	}
}

func TestLoginRateLimit(t *testing.T) {
	env := testenv.New(t)
	env.Admin(t)
	anon := env.Anon()
	var last *testenv.Response
	for i := 0; i < 7; i++ {
		last = anon.Do("POST", "/api/v1/auth/login", map[string]any{"email": "admin@ants.test", "password": "wrong-password-x"})
	}
	if last.Status != 429 || last.Header.Get("Retry-After") == "" {
		t.Fatalf("expected 429 with Retry-After, got %d", last.Status)
	}
}

func TestWebClientGetsHttpOnlyRefreshCookie(t *testing.T) {
	env := testenv.New(t)
	env.Admin(t)
	web := env.Anon()
	web.Headers["X-ACM-Client"] = "web"
	r := web.Do("POST", "/api/v1/auth/login", map[string]any{"email": "admin@ants.test", "password": "Formicarium-2026!"}).Must(t, 200)
	if _, ok := r.JSON()["refresh_token"]; ok {
		t.Fatal("web clients must not receive the refresh token in the body")
	}
	cookie := r.Header.Get("Set-Cookie")
	for _, want := range []string{"acm_refresh=", "HttpOnly", "Secure", "SameSite=Strict", "Path=/api/v1/auth"} {
		if !strings.Contains(cookie, want) {
			t.Fatalf("cookie %q misses %q", cookie, want)
		}
	}
	val := strings.SplitN(strings.SplitN(cookie, ";", 2)[0], "=", 2)[1]
	// Cookie alone (no custom header) is not accepted → no CSRF.
	plain := env.Anon()
	if r := plain.Do("POST", "/api/v1/auth/refresh", nil, "Cookie", "acm_refresh="+val); r.Status != 401 {
		t.Fatalf("cookie refresh without X-ACM-Client must fail, got %d", r.Status)
	}
	web.Do("POST", "/api/v1/auth/refresh", nil, "Cookie", "acm_refresh="+val).Must(t, 200)
}

func TestRegistrationModes(t *testing.T) {
	env := testenv.New(t, testenv.Options{RegistrationMode: "invite"})
	admin := env.Admin(t)
	anon := env.Anon()
	body := map[string]any{"email": "helper@ants.test", "password": "Lasius-niger-2026"}
	if r := anon.Do("POST", "/api/v1/auth/register", body); r.Code() != "registration.closed" {
		t.Fatalf("invite mode must refuse open registration: %s", r.Body)
	}
	inv := admin.Do("POST", "/api/v1/invitations", map[string]any{"email": "helper@ants.test"}).Must(t, 201).JSON()
	link := inv["link"].(string)
	token := link[strings.Index(link, "invite=")+7:]
	body["invite_token"] = token
	anon.Do("POST", "/api/v1/auth/register", body).Must(t, 201)
	// Invitation is single-use.
	body["email"] = "other@ants.test"
	if r := anon.Do("POST", "/api/v1/auth/register", body); r.Status != 422 {
		t.Fatalf("reused invitation must fail, got %d %s", r.Status, r.Body)
	}
}

func TestPasswordRules(t *testing.T) {
	env := testenv.New(t)
	env.Admin(t)
	for _, pw := range []string{"short", "1234567890", "passwort123"} {
		r := env.Anon().Do("POST", "/api/v1/auth/register", map[string]any{"email": "a@ants.test", "password": pw})
		if r.Status != 422 || r.JSON()["field"] != "password" {
			t.Fatalf("password %q should be rejected: %d %s", pw, r.Status, r.Body)
		}
	}
}

func TestPasswordResetFlow(t *testing.T) {
	env := testenv.New(t)
	user := env.User(t, "Anna")
	anon := env.Anon()
	anon.Do("POST", "/api/v1/auth/password/forgot", map[string]any{"email": "nobody@ants.test"}).Must(t, 202)
	anon.Do("POST", "/api/v1/auth/password/forgot", map[string]any{"email": "anna@ants.test"}).Must(t, 202)
	var body string
	for i := 0; i < 50 && body == ""; i++ {
		for _, m := range env.Mail.Messages() {
			if m.To == "anna@ants.test" {
				body = m.Body
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(env.Mail.Messages()) != 1 {
		t.Fatalf("exactly one mail expected (none for unknown address), got %d", len(env.Mail.Messages()))
	}
	i := strings.Index(body, "token=")
	if i < 0 {
		t.Fatalf("no reset link in mail: %s", body)
	}
	token := strings.Fields(body[i+6:])[0]
	anon.Do("POST", "/api/v1/auth/password/reset", map[string]any{"token": token, "password": "Neues-Passwort-2026"}).Must(t, 204)
	if r := anon.Do("POST", "/api/v1/auth/password/reset", map[string]any{"token": token, "password": "Noch-eins-2026-x"}); r.Status != 422 {
		t.Fatalf("reset token must be single-use, got %d", r.Status)
	}
	if r := user.Do("GET", "/api/v1/me", nil); r.Status != 401 {
		t.Fatalf("old sessions must be revoked after reset, got %d", r.Status)
	}
	anon.Do("POST", "/api/v1/auth/login", map[string]any{"email": "anna@ants.test", "password": "Neues-Passwort-2026"}).Must(t, 200)
}

func TestDeviceLinkConnectsAppWithoutPassword(t *testing.T) {
	env := testenv.New(t)
	web := env.User(t, "Web")
	link := web.Do("POST", "/api/v1/auth/device-link", nil).Must(t, 201).JSON()
	if !strings.HasPrefix(link["qr_payload"].(string), "https://ants.test/link#code=") {
		t.Fatalf("unexpected payload %v", link["qr_payload"])
	}
	device := map[string]any{"device_id": testenv.NewID().String(), "device_name": "Pixel", "platform": "android"}
	r := env.Anon().Do("POST", "/api/v1/auth/device-link/redeem", map[string]any{"code": link["code"], "device": device}).Must(t, 200)
	if r.JSON()["user"].(map[string]any)["email"] != "web@ants.test" {
		t.Fatalf("wrong user: %s", r.Body)
	}
	if r := env.Anon().Do("POST", "/api/v1/auth/device-link/redeem", map[string]any{"code": link["code"]}); r.Status != 422 {
		t.Fatalf("code must be single-use, got %d", r.Status)
	}
	sessions := web.Do("GET", "/api/v1/auth/sessions", nil).Must(t, 200).JSON()["sessions"].([]any)
	if len(sessions) != 2 {
		t.Fatalf("expected web + app session, got %d", len(sessions))
	}
}

func TestSecurityHeadersAndHealth(t *testing.T) {
	env := testenv.New(t)
	r := env.Anon().Do("GET", "/readyz", nil).Must(t, 200)
	for _, h := range []string{"Content-Security-Policy", "X-Content-Type-Options", "Strict-Transport-Security", "X-Request-ID"} {
		if r.Header.Get(h) == "" {
			t.Errorf("missing header %s", h)
		}
	}
	env.Anon().Do("GET", "/healthz", nil).Must(t, 200)
	if r := env.Anon().Do("GET", "/api/v1/colonies", nil); r.Status != 401 || !strings.Contains(r.Header.Get("Content-Type"), "problem+json") {
		t.Fatalf("unauthenticated API access: %d %s", r.Status, r.Header.Get("Content-Type"))
	}
	if r := env.Anon().Do("GET", "/api/v1/does-not-exist", nil); r.Status != http.StatusUnauthorized && r.Status != 404 {
		t.Fatalf("unknown route: %d", r.Status)
	}
}

func TestAdminEndpointsRequireAdmin(t *testing.T) {
	env := testenv.New(t)
	admin := env.Admin(t)
	user := env.User(t, "Bert")
	if r := user.Do("GET", "/api/v1/admin/users", nil); r.Status != 403 {
		t.Fatalf("non-admin must get 403, got %d", r.Status)
	}
	users := admin.Do("GET", "/api/v1/admin/users", nil).Must(t, 200).JSON()["users"].([]any)
	if len(users) != 2 {
		t.Fatalf("expected 2 users, got %d", len(users))
	}
	link := admin.Do("POST", "/api/v1/admin/users/"+user.UserID.String()+"/password-reset-link", nil).Must(t, 201).JSON()
	if !strings.Contains(link["link"].(string), "/reset-password?token=") {
		t.Fatalf("bad link %v", link)
	}
	admin.Do("PATCH", "/api/v1/admin/users/"+user.UserID.String(), map[string]any{"disabled": true}).Must(t, 204)
	if r := user.Do("GET", "/api/v1/me", nil); r.Status != 401 {
		t.Fatalf("disabled user must be logged out, got %d", r.Status)
	}
	sys := admin.Do("GET", "/api/v1/admin/system", nil).Must(t, 200).JSON()
	if sys["users"].(float64) != 2 || sys["schema_version"] == "" {
		t.Fatalf("system info: %v", sys)
	}
}

func TestWebAssetsRevalidateWithETag(t *testing.T) {
	env := testenv.New(t)
	r := env.Anon().Do("GET", "/placeholder.css", nil).Must(t, 200)
	etag := r.Header.Get("ETag")
	if etag == "" || r.Header.Get("Cache-Control") != "no-cache" {
		t.Fatalf("missing validators: %v", r.Header)
	}
	env.Anon().Do("GET", "/placeholder.css", nil, "If-None-Match", etag).Must(t, http.StatusNotModified)
	// App routes fall back to index.html, unknown files are 404.
	env.Anon().Do("GET", "/colonies/abc", nil).Must(t, 200)
	env.Anon().Do("GET", "/missing.js", nil).Must(t, 404)
}

func TestSignedOutDeviceIsToldToWipeAndCanSignInAgain(t *testing.T) {
	env := testenv.New(t)
	web := env.User(t, "Anna")
	device := map[string]any{"device_id": testenv.NewID().String(), "device_name": "Pixel", "platform": "android"}
	login := map[string]any{"email": "anna@ants.test", "password": "Messor-barbarus-12", "device": device}
	phone := env.Anon().Do("POST", "/api/v1/auth/login", login).Must(t, 200).JSON()

	// Web: sign the phone out.
	var phoneSession string
	for _, s := range web.Do("GET", "/api/v1/auth/sessions", nil).Must(t, 200).JSON()["sessions"].([]any) {
		if m := s.(map[string]any); m["device_id"] == device["device_id"] {
			phoneSession = m["id"].(string)
		}
	}
	if phoneSession == "" {
		t.Fatal("phone session not listed")
	}
	web.Do("DELETE", "/api/v1/auth/sessions/"+phoneSession, nil).Must(t, 204)

	r := env.Anon().Do("POST", "/api/v1/auth/refresh", map[string]any{"refresh_token": phone["refresh_token"]})
	if r.Status != 401 || r.Code() != "device.revoked" {
		t.Fatalf("expected device.revoked, got %d %s", r.Status, r.Body)
	}

	// Signing in again on the same device works, including sync.
	again := env.Anon().Do("POST", "/api/v1/auth/login", login).Must(t, 200).JSON()
	c := &testenv.Client{Env: env, Token: again["access_token"].(string), Headers: map[string]string{}}
	c.Do("POST", "/api/v1/sync/push", map[string]any{"device_id": device["device_id"], "platform": "android", "ops": []any{}}).Must(t, 200)
}

func TestAPICompressesJSON(t *testing.T) {
	env := testenv.New(t)
	r := env.Anon().Do("GET", "/api/v1/instance", nil, "Accept-Encoding", "gzip")
	if r.Status != 200 || r.Header.Get("Content-Encoding") != "gzip" {
		t.Fatalf("instance: %d %v", r.Status, r.Header)
	}
}
