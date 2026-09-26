package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/config"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/storage"
)

const refreshCookie = "acm_refresh"

// ---------------------------------------------------------------------------
// System

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	_, _ = w.Write([]byte("ok\n"))
}

func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	checks := map[string]string{"database": "ok", "storage": "ok", "migrations": "ok"}
	status := http.StatusOK
	if err := s.svc.Pool.Ping(r.Context()); err != nil {
		checks["database"], status = "unreachable", http.StatusServiceUnavailable
	} else if _, pending, err := db.MigrationStatus(r.Context(), s.svc.Pool); err != nil || len(pending) > 0 {
		checks["migrations"], status = "pending", http.StatusServiceUnavailable
	}
	if fsStore, ok := s.svc.Blobs.(*storage.FS); ok {
		if err := fsStore.Writable(); err != nil {
			checks["storage"], status = "not writable", http.StatusServiceUnavailable
		}
	}
	s.writeJSON(w, status, map[string]any{"status": http.StatusText(status), "checks": checks, "version": s.version})
}

func (s *Server) instance(w http.ResponseWriter, r *http.Request) {
	setup, err := s.svc.SetupRequired(r.Context())
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{
		"name":              s.cfg.InstanceName,
		"version":           s.version,
		"api_version":       1,
		"public_url":        s.cfg.PublicURL.String(),
		"legacy_urls":       urlsToStrings(s.cfg),
		"registration_mode": s.cfg.RegistrationMode,
		"setup_required":    setup,
		"password_reset":    s.svc.Mail.Enabled(),
	})
}

func urlsToStrings(c *config.Config) []string {
	out := make([]string, 0, len(c.LegacyURLs))
	for _, u := range c.LegacyURLs {
		out = append(out, u.String())
	}
	return out
}

func (s *Server) assetLinks(w http.ResponseWriter, r *http.Request) {
	links := []any{}
	if len(s.cfg.AndroidCertSHA256) > 0 {
		links = append(links, map[string]any{
			"relation": []string{"delegate_permission/common.handle_all_urls"},
			"target": map[string]any{
				"namespace":                "android_app",
				"package_name":             s.cfg.AndroidAppID,
				"sha256_cert_fingerprints": s.cfg.AndroidCertSHA256,
			},
		})
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	_ = json.NewEncoder(w).Encode(links)
}

// ---------------------------------------------------------------------------
// Auth

func (s *Server) meta(r *http.Request, device *service.DeviceInfo) service.ClientMeta {
	return service.ClientMeta{IP: clientIP(r), UserAgent: r.UserAgent(), Device: device}
}

func isWebClient(r *http.Request) bool { return r.Header.Get("X-ACM-Client") == "web" }

// respondSession returns tokens. Browsers get the refresh token only as an
// HttpOnly cookie so JavaScript can never read it.
func (s *Server) respondSession(w http.ResponseWriter, r *http.Request, status int, sess *service.Session) {
	if isWebClient(r) {
		http.SetCookie(w, &http.Cookie{
			Name: refreshCookie, Value: sess.RefreshToken, Path: "/api/v1/auth",
			Expires: sess.RefreshExpiresAt, HttpOnly: true, Secure: s.cfg.SecureCookies(), SameSite: http.SameSiteStrictMode,
		})
		sess.RefreshToken = ""
	}
	s.writeJSON(w, status, sess)
}

func (s *Server) sensitiveLimit(w http.ResponseWriter, r *http.Request) bool {
	if ok, retry := s.limSensitive.Allow(clientIP(r).String()); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return false
	}
	return true
}

type registerRequest struct {
	service.RegisterInput
	Device *service.DeviceInfo `json:"device,omitempty"`
}

func (s *Server) setup(w http.ResponseWriter, r *http.Request) {
	if !s.sensitiveLimit(w, r) {
		return
	}
	var in registerRequest
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	sess, err := s.svc.Setup(r.Context(), in.RegisterInput, s.meta(r, in.Device))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.log.Info("setup completed – administrator account created")
	s.respondSession(w, r, http.StatusCreated, sess)
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) {
	if !s.sensitiveLimit(w, r) {
		return
	}
	var in registerRequest
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	sess, err := s.svc.Register(r.Context(), in.RegisterInput, s.meta(r, in.Device))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.respondSession(w, r, http.StatusCreated, sess)
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Email    string              `json:"email"`
		Password string              `json:"password"`
		Device   *service.DeviceInfo `json:"device,omitempty"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	ip := clientIP(r).String()
	emailKey := strings.ToLower(strings.TrimSpace(in.Email)) + "|" + ip
	if ok, retry := s.limLoginIP.Allow(ip); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return
	}
	if ok, retry := s.limLoginEmail.Allow(emailKey); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return
	}
	sess, err := s.svc.Login(r.Context(), in.Email, in.Password, s.meta(r, in.Device))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.limLoginEmail.Reset(emailKey)
	s.respondSession(w, r, http.StatusOK, sess)
}

func (s *Server) refresh(w http.ResponseWriter, r *http.Request) {
	var in struct {
		RefreshToken string `json:"refresh_token"`
	}
	if r.ContentLength != 0 {
		if err := decode(r, &in); err != nil {
			s.problem(w, r, err)
			return
		}
	}
	tok := in.RefreshToken
	if tok == "" && isWebClient(r) { // custom header required → no CSRF via cookie
		if c, err := r.Cookie(refreshCookie); err == nil {
			tok = c.Value
		}
	}
	if ok, retry := s.limLoginIP.Allow("refresh|" + clientIP(r).String()); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return
	}
	sess, err := s.svc.Refresh(r.Context(), tok, s.meta(r, nil))
	if err != nil {
		if isWebClient(r) {
			s.clearRefreshCookie(w)
		}
		s.problem(w, r, err)
		return
	}
	s.respondSession(w, r, http.StatusOK, sess)
}

func (s *Server) clearRefreshCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: refreshCookie, Value: "", Path: "/api/v1/auth", MaxAge: -1,
		HttpOnly: true, Secure: s.cfg.SecureCookies(), SameSite: http.SameSiteStrictMode})
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	all := r.URL.Query().Get("all") == "true"
	if err := s.svc.Logout(r.Context(), actorOf(r), all); err != nil {
		s.problem(w, r, err)
		return
	}
	s.clearRefreshCookie(w)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) forgotPassword(w http.ResponseWriter, r *http.Request) {
	if !s.sensitiveLimit(w, r) {
		return
	}
	var in struct {
		Email string `json:"email"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.ForgotPassword(r.Context(), in.Email, s.meta(r, nil)); err != nil {
		s.log.Error("forgot password failed", "err", err)
	}
	// Always the same answer: no account enumeration.
	s.writeJSON(w, http.StatusAccepted, map[string]any{"status": "accepted", "email_enabled": s.svc.Mail.Enabled()})
}

func (s *Server) resetPassword(w http.ResponseWriter, r *http.Request) {
	if !s.sensitiveLimit(w, r) {
		return
	}
	var in struct {
		Token    string `json:"token"`
		Password string `json:"password"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.ResetPassword(r.Context(), in.Token, in.Password, s.meta(r, nil)); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) createDeviceLink(w http.ResponseWriter, r *http.Request) {
	link, err := s.svc.CreateDeviceLink(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusCreated, link)
}

func (s *Server) redeemDeviceLink(w http.ResponseWriter, r *http.Request) {
	if !s.sensitiveLimit(w, r) {
		return
	}
	var in struct {
		Code   string              `json:"code"`
		Device *service.DeviceInfo `json:"device,omitempty"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	sess, err := s.svc.RedeemDeviceLink(r.Context(), in.Code, s.meta(r, in.Device))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.respondSession(w, r, http.StatusOK, sess)
}

func (s *Server) listSessions(w http.ResponseWriter, r *http.Request) {
	list, err := s.svc.ListSessions(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"sessions": list})
}

func (s *Server) revokeSession(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err == nil {
		err = s.svc.RevokeSession(r.Context(), actorOf(r), id)
	}
	if err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------------------
// Me

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	u, err := s.svc.Me(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"user": u, "nfc_uid_key": s.svc.NFCUIDKey(),
		"server_time": time.Now().UTC()})
}

func (s *Server) updateMe(w http.ResponseWriter, r *http.Request) {
	var in struct {
		DisplayName string `json:"display_name"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	name := strings.TrimSpace(in.DisplayName)
	if name == "" || len([]rune(name)) > 100 {
		s.problem(w, r, service.Invalid("display_name", "name must have 1–100 characters"))
		return
	}
	if _, err := s.svc.Pool.Exec(r.Context(), `UPDATE users SET display_name = $2, updated_at = now() WHERE id = $1`,
		actorOf(r).UserID, name); err != nil {
		s.problem(w, r, err)
		return
	}
	s.me(w, r)
}

func (s *Server) getSettings(w http.ResponseWriter, r *http.Request) {
	a := actorOf(r)
	data, err := s.svc.GetEntity(r.Context(), a, "user_settings", a.UserID)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, json.RawMessage(data))
}

func (s *Server) updateSettings(w http.ResponseWriter, r *http.Request) {
	s.writeOp(w, r, "user_settings", "update", actorOf(r).UserID)
}

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request) {
	var in struct {
		OldPassword string `json:"old_password"`
		Password    string `json:"password"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.ChangePassword(r.Context(), actorOf(r), in.OldPassword, in.Password); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) deleteMe(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Password string `json:"password"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.DeleteAccount(r.Context(), actorOf(r), in.Password); err != nil {
		s.problem(w, r, err)
		return
	}
	s.clearRefreshCookie(w)
	w.WriteHeader(http.StatusNoContent)
}
