package service

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"golang.org/x/oauth2"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// Sign-in with OIDC/SSO (Authentik, Keycloak, Authelia, Google, Microsoft …):
// authorization code flow with PKCE. The provider sends the browser back to
// /api/v1/auth/oidc/callback; the server verifies the ID token, finds or
// creates the account and hands a one-time code (2 minutes) to the web app
// (/sso?code=…) or the Android app (<app id>://acm/sso?code=…), which exchanges
// it for a session – like the device link. Password sign-in keeps working.

const (
	oidcKey      = "oidc"
	oidcStateTTL = 10 * time.Minute
	ssoCodeTTL   = 2 * time.Minute
)

type storedOIDC struct {
	Enabled         bool   `json:"enabled"`
	Issuer          string `json:"issuer"`
	ClientID        string `json:"client_id"`
	ClientSecretEnc string `json:"client_secret_enc,omitempty"`
	Label           string `json:"label,omitempty"` // button text: "Mit <Label> anmelden"
	AllowSignup     bool   `json:"allow_signup"`    // unknown people get an account
}

// OIDCSettings is the admin API shape; the secret is write-only.
type OIDCSettings struct {
	Enabled         bool    `json:"enabled"`
	Issuer          string  `json:"issuer"`
	ClientID        string  `json:"client_id"`
	ClientSecret    *string `json:"client_secret,omitempty"` // input: nil = keep, "" = remove
	ClientSecretSet bool    `json:"client_secret_set"`
	Label           string  `json:"label"`
	AllowSignup     bool    `json:"allow_signup"`
	RedirectURL     string  `json:"redirect_url"` // to register at the provider
}

// oidcState is a sign-in in progress (in memory: a restart only means
// starting the sign-in again).
type oidcState struct {
	verifier, nonce string
	app             string // Android app id, "" = web
	expires         time.Time
}

type oidcRuntime struct {
	mu       sync.Mutex
	states   map[string]oidcState
	provider *oidc.Provider
	issuer   string
	loaded   time.Time
}

func (s *Service) loadOIDC(ctx context.Context) (storedOIDC, error) {
	var st storedOIDC
	_, err := s.loadJSONSetting(ctx, oidcKey, &st)
	if st.Label == "" {
		st.Label = "SSO"
	}
	return st, err
}

func (s *Service) oidcRedirectURL() string { return s.publicURL() + "/api/v1/auth/oidc/callback" }

func (s *Service) GetOIDCSettings(ctx context.Context, actor Actor) (*OIDCSettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	st, err := s.loadOIDC(ctx)
	if err != nil {
		return nil, err
	}
	return &OIDCSettings{Enabled: st.Enabled, Issuer: st.Issuer, ClientID: st.ClientID, ClientSecretSet: st.ClientSecretEnc != "",
		Label: st.Label, AllowSignup: st.AllowSignup, RedirectURL: s.oidcRedirectURL()}, nil
}

func (s *Service) SetOIDCSettings(ctx context.Context, actor Actor, in OIDCSettings, meta ClientMeta) (*OIDCSettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	in.Issuer = strings.TrimRight(strings.TrimSpace(in.Issuer), "/")
	in.ClientID = strings.TrimSpace(in.ClientID)
	in.Label = strings.TrimSpace(in.Label)
	if in.Issuer != "" {
		u, err := url.Parse(in.Issuer)
		if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") || u.RawQuery != "" || len(in.Issuer) > 500 {
			return nil, Invalid("issuer", "enter the issuer URL of the provider, e.g. https://auth.example.com/application/o/acm/")
		}
	}
	if len(in.ClientID) > 300 || len(in.Label) > 40 || strings.ContainsAny(in.Label+in.ClientID, "\r\n") {
		return nil, Invalid("client_id", "client id or button text too long")
	}
	old, err := s.loadOIDC(ctx)
	if err != nil {
		return nil, err
	}
	st := storedOIDC{Enabled: in.Enabled, Issuer: in.Issuer, ClientID: in.ClientID, ClientSecretEnc: old.ClientSecretEnc,
		Label: in.Label, AllowSignup: in.AllowSignup}
	if in.ClientSecret != nil {
		st.ClientSecretEnc = ""
		if v := strings.TrimSpace(*in.ClientSecret); v != "" {
			if len(v) > 1000 {
				return nil, Invalid("client_secret", "client secret too long")
			}
			if st.ClientSecretEnc, err = s.encryptSecret(v); err != nil {
				return nil, err
			}
		}
	}
	if st.Enabled && (st.Issuer == "" || st.ClientID == "") {
		return nil, Invalid("issuer", "enter issuer and client id")
	}
	if err := s.saveJSONSetting(ctx, oidcKey, st); err != nil {
		return nil, err
	}
	s.oidc.mu.Lock()
	s.oidc.provider = nil // discover again with the new settings
	s.oidc.mu.Unlock()
	s.Audit(ctx, &actor.UserID, "oidc_settings_changed", "", map[string]any{"enabled": st.Enabled, "issuer": st.Issuer}, meta.IP)
	return s.GetOIDCSettings(ctx, actor)
}

// OIDCInfo for the sign-in screen (public).
func (s *Service) OIDCInfo(ctx context.Context) map[string]any {
	st, err := s.loadOIDC(ctx)
	if err != nil || !st.Enabled || st.Issuer == "" || st.ClientID == "" {
		return map[string]any{"enabled": false}
	}
	return map[string]any{"enabled": true, "label": st.Label}
}

// oidcProvider discovers the provider (cached for an hour).
func (s *Service) oidcProvider(ctx context.Context, st storedOIDC) (*oidc.Provider, *oauth2.Config, error) {
	s.oidc.mu.Lock()
	p := s.oidc.provider
	if p != nil && (s.oidc.issuer != st.Issuer || time.Since(s.oidc.loaded) > time.Hour) {
		p = nil
	}
	s.oidc.mu.Unlock()
	if p == nil {
		dctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		var err error
		if p, err = oidc.NewProvider(oidc.ClientContext(dctx, s.oidcHTTP()), st.Issuer); err != nil {
			return nil, nil, &Problem{Status: http.StatusBadGateway, Code: "oidc.discovery",
				Title: "the SSO provider cannot be reached or the issuer URL is wrong: " + err.Error()}
		}
		s.oidc.mu.Lock()
		s.oidc.provider, s.oidc.issuer, s.oidc.loaded = p, st.Issuer, time.Now()
		s.oidc.mu.Unlock()
	}
	secret, err := s.decryptSecret(st.ClientSecretEnc)
	if err != nil {
		return nil, nil, fmt.Errorf("stored client secret cannot be decrypted (INSTANCE_SECRET changed?): %w", err)
	}
	return p, &oauth2.Config{ClientID: st.ClientID, ClientSecret: secret, Endpoint: p.Endpoint(),
		RedirectURL: s.oidcRedirectURL(), Scopes: []string{oidc.ScopeOpenID, "email", "profile"}}, nil
}

func (s *Service) oidcHTTP() *http.Client {
	if s.OIDCClient != nil {
		return s.OIDCClient
	}
	return &http.Client{Timeout: 20 * time.Second}
}

// TestOIDC checks discovery with the saved settings.
func (s *Service) TestOIDC(ctx context.Context, actor Actor) error {
	if err := requireAdmin(actor); err != nil {
		return err
	}
	st, err := s.loadOIDC(ctx)
	if err != nil {
		return err
	}
	if st.Issuer == "" || st.ClientID == "" {
		return Invalid("issuer", "enter and save issuer and client id first")
	}
	s.oidc.mu.Lock()
	s.oidc.provider = nil
	s.oidc.mu.Unlock()
	_, _, err = s.oidcProvider(ctx, st)
	return err
}

var appIDRe = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$`)

// OIDCStart begins a sign-in and returns the provider's address. app is the
// Android app id for the way back ("" = web); only this server's app is
// accepted, so the code cannot be sent to another app.
func (s *Service) OIDCStart(ctx context.Context, app string) (string, error) {
	st, err := s.loadOIDC(ctx)
	if err != nil {
		return "", err
	}
	if !st.Enabled || st.Issuer == "" {
		return "", &Problem{Status: http.StatusNotFound, Code: "oidc.disabled", Title: "sign-in with SSO is not set up"}
	}
	if app != "" && (!appIDRe.MatchString(app) || (app != s.Cfg.AndroidAppID && app != s.Cfg.AndroidAppID+".dev")) {
		return "", Invalid("app", "unknown app")
	}
	_, cfg, err := s.oidcProvider(ctx, st)
	if err != nil {
		return "", err
	}
	state, nonce, verifier := auth.NewToken(24), auth.NewToken(24), oauth2.GenerateVerifier()
	s.oidc.mu.Lock()
	if s.oidc.states == nil {
		s.oidc.states = map[string]oidcState{}
	}
	now := time.Now()
	for k, v := range s.oidc.states {
		if now.After(v.expires) {
			delete(s.oidc.states, k)
		}
	}
	if len(s.oidc.states) > 10000 {
		s.oidc.mu.Unlock()
		return "", RateLimited(time.Minute)
	}
	s.oidc.states[state] = oidcState{verifier: verifier, nonce: nonce, app: app, expires: now.Add(oidcStateTTL)}
	s.oidc.mu.Unlock()
	return cfg.AuthCodeURL(state, oidc.Nonce(nonce), oauth2.S256ChallengeOption(verifier)), nil
}

// OIDCCallback finishes the sign-in: returns where to send the browser – the
// web app or the Android app, with a one-time code or an error.
func (s *Service) OIDCCallback(ctx context.Context, state, code, providerError string, meta ClientMeta) string {
	s.oidc.mu.Lock()
	st, ok := s.oidc.states[state]
	delete(s.oidc.states, state)
	s.oidc.mu.Unlock()
	back := func(q url.Values) string {
		if ok && st.app != "" {
			return st.app + "://acm/sso?" + q.Encode() // path /sso, as in the web app
		}
		return s.publicURL() + "/sso?" + q.Encode()
	}
	fail := func(msg string, err error) string {
		if err != nil {
			s.Log.Warn("sso sign-in failed", "reason", msg, "err", err)
		}
		return back(url.Values{"error": {msg}})
	}
	if !ok || time.Now().After(st.expires) {
		return fail("the sign-in took too long or was started elsewhere – please try again", nil)
	}
	if providerError != "" {
		return fail("the SSO provider refused the sign-in: "+providerError, nil)
	}
	conf, err := s.loadOIDC(ctx)
	if err != nil || !conf.Enabled {
		return fail("sign-in with SSO is not set up", err)
	}
	p, cfg, err := s.oidcProvider(ctx, conf)
	if err != nil {
		return fail("the SSO provider cannot be reached", err)
	}
	hctx := oidc.ClientContext(ctx, s.oidcHTTP())
	tok, err := cfg.Exchange(hctx, code, oauth2.VerifierOption(st.verifier))
	if err != nil {
		return fail("the SSO provider did not confirm the sign-in (client secret?)", err)
	}
	raw, _ := tok.Extra("id_token").(string)
	idt, err := p.Verifier(&oidc.Config{ClientID: conf.ClientID}).Verify(hctx, raw)
	if err != nil || idt.Nonce != st.nonce {
		return fail("the answer of the SSO provider is not valid", err)
	}
	var claims struct {
		Email         string `json:"email"`
		EmailVerified *bool  `json:"email_verified"`
		Name          string `json:"name"`
		Username      string `json:"preferred_username"`
	}
	if err := idt.Claims(&claims); err != nil {
		return fail("the answer of the SSO provider is not readable", err)
	}
	verified := claims.EmailVerified == nil || *claims.EmailVerified
	if claims.Email == "" { // some providers send it only from the userinfo endpoint
		if ui, err := p.UserInfo(hctx, oauth2.StaticTokenSource(tok)); err == nil && ui.Email != "" {
			claims.Email, verified = ui.Email, ui.EmailVerified
		}
	}
	user, err := s.ssoUser(ctx, conf, idt.Issuer, idt.Subject, claims.Email, verified,
		firstNonEmpty(claims.Name, claims.Username), meta)
	if err != nil {
		var p *Problem
		if errors.As(err, &p) {
			return fail(p.Title, nil)
		}
		return fail("sign-in failed", err)
	}
	one := auth.NewToken(32)
	if _, err := s.Pool.Exec(ctx, `INSERT INTO sso_codes (code_hash, user_id, expires_at) VALUES ($1, $2, $3)`,
		auth.HashToken(one), user, s.Now().Add(ssoCodeTTL)); err != nil {
		return fail("sign-in failed", err)
	}
	return back(url.Values{"code": {one}})
}

func firstNonEmpty(v ...string) string {
	for _, s := range v {
		if strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return ""
}

// ssoUser finds the account of an identity: linked before, or the account
// with the same (verified) e-mail address, or – if allowed – a new one.
func (s *Service) ssoUser(ctx context.Context, conf storedOIDC, issuer, subject, email string, verified bool, name string, meta ClientMeta) (uuid.UUID, error) {
	var user uuid.UUID
	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT user_id FROM user_identities WHERE issuer = $1 AND subject = $2`, issuer, subject).Scan(&user)
		if err == nil {
			return nil
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		email = strings.ToLower(strings.TrimSpace(email))
		if email == "" {
			return Invalid("email", "the SSO provider sends no e-mail address – allow the scope \"email\" for this client there")
		}
		if !verified {
			return Invalid("email", "the SSO provider marks the e-mail address %s as not verified – mark it as verified there "+
				"(Pocket ID: Application Configuration → Emails Verified)", email)
		}
		err = tx.QueryRow(ctx, `SELECT id FROM users WHERE email = $1`, email).Scan(&user)
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			if setup, err := s.SetupRequired(ctx); err != nil || setup {
				return Invalid("email", "set up the server first (create the administrator account)")
			}
			if !conf.AllowSignup {
				return Invalid("email", "there is no account for %s on this server – ask the administrator", email)
			}
			if name == "" {
				name = strings.Split(email, "@")[0]
			}
			if len([]rune(name)) > 80 {
				name = string([]rune(name)[:80])
			}
			// no password is known – sign-in only via SSO (or after a password reset)
			if user, err = s.createUser(ctx, tx, RegisterInput{Email: email, Password: auth.NewToken(32), DisplayName: name}, "user"); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE users SET email_verified_at = now() WHERE id = $1`, user); err != nil {
				return err
			}
			s.Audit(ctx, &user, "user_registered", email, map[string]any{"via": "sso"}, meta.IP)
		case err != nil:
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO user_identities (issuer, subject, user_id) VALUES ($1, $2, $3)
			ON CONFLICT DO NOTHING`, issuer, subject, user)
		return err
	})
	if err != nil {
		return uuid.Nil, err
	}
	var disabled *time.Time
	if err := s.Pool.QueryRow(ctx, `SELECT disabled_at FROM users WHERE id = $1`, user).Scan(&disabled); err != nil {
		return uuid.Nil, err
	}
	if disabled != nil {
		return uuid.Nil, &Problem{Status: http.StatusForbidden, Code: "user.disabled", Title: "this account is disabled"}
	}
	return user, nil
}

// RedeemSSOCode exchanges the one-time code for a session.
func (s *Service) RedeemSSOCode(ctx context.Context, code string, meta ClientMeta) (*Session, error) {
	var user uuid.UUID
	err := s.Pool.QueryRow(ctx, `DELETE FROM sso_codes WHERE code_hash = $1 AND expires_at > now() RETURNING user_id`,
		auth.HashToken(strings.TrimSpace(code))).Scan(&user)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &Problem{Status: http.StatusUnauthorized, Code: "sso.code", Title: "the sign-in code is invalid or expired – please sign in again"}
	}
	if err != nil {
		return nil, err
	}
	_, _ = s.Pool.Exec(ctx, `UPDATE users SET last_login_at = now() WHERE id = $1`, user)
	s.Audit(ctx, &user, "login", "", map[string]any{"via": "sso"}, meta.IP)
	return s.newSession(ctx, user, meta)
}
