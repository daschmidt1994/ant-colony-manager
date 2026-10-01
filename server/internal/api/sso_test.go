package api_test

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

// fakeIdP is a minimal OIDC provider: discovery, JWKS, token endpoint with
// PKCE check and RS256-signed ID tokens.
type fakeIdP struct {
	srv    *httptest.Server
	key    *rsa.PrivateKey
	mu     sync.Mutex
	nonce  string
	claims map[string]any // email, email_verified, name, sub
}

func newFakeIdP(t *testing.T) *fakeIdP {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	p := &fakeIdP{key: key}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"issuer": p.srv.URL, "authorization_endpoint": p.srv.URL + "/authorize", "token_endpoint": p.srv.URL + "/token",
			"jwks_uri": p.srv.URL + "/jwks", "id_token_signing_alg_values_supported": []string{"RS256"},
		})
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &key.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"}}})
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		user, pass, _ := r.BasicAuth()
		if r.Form.Get("code") != "good" || r.Form.Get("code_verifier") == "" || user != "acm" || pass != "geheim" {
			w.WriteHeader(400)
			w.Write([]byte(`{"error":"invalid_grant"}`))
			return
		}
		p.mu.Lock()
		c := map[string]any{"iss": p.srv.URL, "aud": "acm", "exp": time.Now().Add(time.Hour).Unix(),
			"iat": time.Now().Unix(), "nonce": p.nonce}
		for k, v := range p.claims {
			c[k] = v
		}
		p.mu.Unlock()
		sig, _ := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key}, (&jose.SignerOptions{}).WithHeader("kid", "k1"))
		idt, _ := jwt.Signed(sig).Claims(c).Serialize()
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"access_token": "at", "token_type": "Bearer", "id_token": idt, "expires_in": 3600})
	})
	p.srv = httptest.NewServer(mux)
	return p
}

func TestSSO(t *testing.T) {
	idp := newFakeIdP(t)
	defer idp.srv.Close()
	env := testenv.New(t)
	env.Svc.OIDCClient = idp.srv.Client()
	admin := env.Admin(t)
	anna := env.User(t, "Anna")
	noFollow := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	get := func(path string) *url.URL {
		t.Helper()
		resp, err := noFollow.Get(env.HTTP.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusFound {
			t.Fatalf("%s: status %d", path, resp.StatusCode)
		}
		u, _ := url.Parse(resp.Header.Get("Location"))
		return u
	}
	// one sign-in: start → (provider) → callback → where the browser goes
	signIn := func(app string, claims map[string]any) *url.URL {
		t.Helper()
		start := get("/api/v1/auth/oidc/start?app=" + url.QueryEscape(app))
		if !strings.HasPrefix(start.String(), idp.srv.URL+"/authorize") {
			return start // an error page of the app
		}
		q := start.Query()
		if q.Get("code_challenge_method") != "S256" || q.Get("redirect_uri") != "https://ants.test/api/v1/auth/oidc/callback" {
			t.Fatalf("authorize request: %v", q)
		}
		idp.mu.Lock()
		idp.nonce, idp.claims = q.Get("nonce"), claims
		idp.mu.Unlock()
		return get("/api/v1/auth/oidc/callback?state=" + url.QueryEscape(q.Get("state")) + "&code=good")
	}

	// not set up: no button, start leads to an error
	if inst := env.Anon().Do("GET", "/api/v1/instance", nil).Must(t, 200).JSON(); inst["sso"].(map[string]any)["enabled"] != false {
		t.Fatalf("sso before setup: %v", inst["sso"])
	}
	anna.Do("PUT", "/api/v1/admin/oidc", map[string]any{"enabled": true, "issuer": idp.srv.URL, "client_id": "acm"}).Must(t, 403)
	admin.Do("PUT", "/api/v1/admin/oidc", map[string]any{"enabled": true, "issuer": "kein-url"}).Must(t, 422)
	s := admin.Do("PUT", "/api/v1/admin/oidc", map[string]any{"enabled": true, "issuer": idp.srv.URL, "client_id": "acm",
		"client_secret": "geheim", "label": "Authentik"}).Must(t, 200).JSON()
	if s["client_secret_set"] != true || s["client_secret"] != nil || s["redirect_url"] != "https://ants.test/api/v1/auth/oidc/callback" {
		t.Fatalf("settings: %v", s)
	}
	admin.Do("POST", "/api/v1/admin/oidc/test", nil).Must(t, 204)
	if inst := env.Anon().Do("GET", "/api/v1/instance", nil).Must(t, 200).JSON(); inst["sso"].(map[string]any)["label"] != "Authentik" {
		t.Fatalf("sso info: %v", inst["sso"])
	}

	// existing account with the same verified e-mail: linked, signed in (web)
	back := signIn("", map[string]any{"sub": "u-anna", "email": anna.Email, "email_verified": true, "name": "Anna"})
	if back.Host != "ants.test" || back.Path != "/sso" || back.Query().Get("code") == "" {
		t.Fatalf("back to the web app: %v", back)
	}
	sess := env.Anon().Do("POST", "/api/v1/auth/oidc/redeem", map[string]any{"code": back.Query().Get("code")}).Must(t, 200).JSON()
	if sess["user"].(map[string]any)["email"] != anna.Email || sess["access_token"] == "" {
		t.Fatalf("session: %v", sess)
	}
	// the code works once
	env.Anon().Do("POST", "/api/v1/auth/oidc/redeem", map[string]any{"code": back.Query().Get("code")}).Must(t, 401)

	// later the identity counts, even if the provider sends another address now
	back = signIn("", map[string]any{"sub": "u-anna", "email": "anna-neu@ants.test", "email_verified": true})
	sess = env.Anon().Do("POST", "/api/v1/auth/oidc/redeem", map[string]any{"code": back.Query().Get("code")}).Must(t, 200).JSON()
	if sess["user"].(map[string]any)["email"] != anna.Email {
		t.Fatal("identity not used")
	}

	// unknown person: no account unless allowed
	back = signIn("", map[string]any{"sub": "u-ben", "email": "ben@ants.test", "email_verified": true, "name": "Ben"})
	if back.Query().Get("code") != "" || !strings.Contains(back.Query().Get("error"), "no account") {
		t.Fatalf("unknown person: %v", back)
	}
	// unverified e-mail is never matched
	back = signIn("", map[string]any{"sub": "u-x", "email": anna.Email, "email_verified": false})
	if back.Query().Get("code") != "" {
		t.Fatal("unverified e-mail signed in")
	}
	admin.Do("PUT", "/api/v1/admin/oidc", map[string]any{"enabled": true, "issuer": idp.srv.URL, "client_id": "acm",
		"label": "Authentik", "allow_signup": true}).Must(t, 200)

	// Android app: back via the app's own scheme; only this server's app
	back = signIn("at.antcolony.manager", map[string]any{"sub": "u-ben", "email": "ben@ants.test", "email_verified": true, "name": "Ben"})
	if back.Scheme != "at.antcolony.manager" || back.Host != "acm" || back.Path != "/sso" || back.Query().Get("code") == "" {
		t.Fatalf("back to the app: %v", back)
	}
	sess = env.Anon().Do("POST", "/api/v1/auth/oidc/redeem", map[string]any{"code": back.Query().Get("code")}).Must(t, 200).JSON()
	if sess["user"].(map[string]any)["display_name"] != "Ben" {
		t.Fatalf("new account: %v", sess["user"])
	}
	if back := signIn("com.evil.app", nil); back.Path != "/sso" || back.Query().Get("error") == "" {
		t.Fatalf("foreign app accepted: %v", back)
	}

	// a state that was not started here, or a provider error: no code
	if back := get("/api/v1/auth/oidc/callback?state=erfunden&code=good"); back.Query().Get("code") != "" {
		t.Fatal("unknown state accepted")
	}
	start := get("/api/v1/auth/oidc/start")
	if back := get("/api/v1/auth/oidc/callback?state=" + url.QueryEscape(start.Query().Get("state")) + "&error=access_denied"); !strings.Contains(back.Query().Get("error"), "access_denied") {
		t.Fatalf("provider error: %v", back)
	}
	// password sign-in still works
	env.Anon().Do("POST", "/api/v1/auth/login", map[string]any{"email": anna.Email, "password": "Messor-barbarus-12"}).Must(t, 200)
}
