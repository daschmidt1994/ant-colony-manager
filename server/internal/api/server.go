// Package api is the HTTP layer: routing, middleware and thin handlers around
// the service package.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/config"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/ratelimit"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
)

type Server struct {
	svc     *service.Service
	cfg     *config.Config
	log     *slog.Logger
	version string
	web     fs.FS
	broker  *Broker

	limLoginIP    *ratelimit.Limiter
	limLoginEmail *ratelimit.Limiter
	limSensitive  *ratelimit.Limiter // setup, register, password reset, device link
	limScan       *ratelimit.Limiter
	limUser       *ratelimit.Limiter
	limAnon       *ratelimit.Limiter
	limSensor     *ratelimit.Limiter
}

func NewServer(svc *service.Service, cfg *config.Config, log *slog.Logger, version string, web fs.FS, broker *Broker) *Server {
	return &Server{
		svc: svc, cfg: cfg, log: log, version: version, web: web, broker: broker,
		limLoginIP:    ratelimit.New(20*60, 20),
		limLoginEmail: ratelimit.New(5*60, 5),
		limSensitive:  ratelimit.New(20, 10),
		limScan:       ratelimit.New(60*60, 60),
		limUser:       ratelimit.New(300*60, 300),
		limAnon:       ratelimit.New(120*60, 120),
		limSensor:     ratelimit.New(60*60, 60),
	}
}

// GCLimiters drops idle limiter buckets; call periodically.
func (s *Server) GCLimiters() {
	for _, l := range []*ratelimit.Limiter{s.limLoginIP, s.limLoginEmail, s.limSensitive, s.limScan, s.limUser, s.limAnon, s.limSensor} {
		l.GC()
	}
}

type ctxKey int

const (
	ctxActor ctxKey = iota
	ctxRequestID
	ctxClientIP
	ctxLogUser
)

func (s *Server) Handler() *chi.Mux {
	r := chi.NewRouter()
	r.Use(s.requestID, s.clientIP, s.accessLog, s.recoverer, s.securityHeaders)

	r.Get("/healthz", s.healthz)
	r.Get("/readyz", s.readyz)
	r.Get("/.well-known/assetlinks.json", s.assetLinks)
	r.Get("/files/*", s.serveFile)

	r.Route("/api/v1", func(r chi.Router) {
		r.Use(s.bodyLimit)
		r.Get("/instance", s.instance)
		r.Post("/setup", s.setup)

		r.Route("/auth", func(r chi.Router) {
			r.Post("/register", s.register)
			r.Post("/login", s.login)
			r.Post("/refresh", s.refresh)
			r.Post("/password/forgot", s.forgotPassword)
			r.Post("/password/reset", s.resetPassword)
			r.Post("/device-link/redeem", s.redeemDeviceLink)
			r.Get("/oidc/start", s.oidcStart)
			r.Get("/oidc/callback", s.oidcCallback)
			r.Post("/oidc/redeem", s.oidcRedeem)
			r.Group(func(r chi.Router) {
				r.Use(s.authenticated)
				r.Post("/logout", s.logout)
				r.Post("/device-link", s.createDeviceLink)
				r.Get("/sessions", s.listSessions)
				r.Delete("/sessions/{id}", s.revokeSession)
			})
		})

		// Signed, short-lived export link (opened in the browser from the app).
		r.Get("/export/download", s.exportDownload)
		// „Morgen“ button in ntfy notifications (signed link).
		r.Post("/snooze", s.snooze)

		// Sensor ingest authenticates with the sensor key, not a user session.
		r.Post("/sensors/{id}/measurements", s.ingestSensor)
		// Calendar subscription and Home Assistant status: secret in the address.
		r.Get("/feeds/{token}/calendar.ics", s.feedCalendar)

		r.Group(func(r chi.Router) {
			r.Use(s.authenticated)

			r.Get("/me", s.me)
			r.Patch("/me", s.updateMe)
			r.Get("/me/settings", s.getSettings)
			r.Patch("/me/settings", s.updateSettings)
			r.Get("/updates", s.updates)
			r.Get("/me/notifications", s.getNotifyPrefs)
			r.Put("/me/notifications", s.setNotifyPrefs)
			r.With(s.rateLimitUser(s.limScan)).Post("/me/notifications/test", s.testNotify)
			r.Get("/me/feed", s.getFeed)
			r.With(s.rateLimitUser(s.limSensitive)).Post("/me/feed", s.createFeed)
			r.Patch("/me/feed", s.setFeedFilter)
			r.Get("/me/home-assistant", s.getHomeAssistantMe)
			r.Put("/me/home-assistant", s.setHomeAssistantMe)
			r.Delete("/me/feed", s.deleteFeed)
			r.Get("/me/feeds", s.listFeeds)
			r.With(s.rateLimitUser(s.limSensitive)).Post("/me/feeds", s.newFeed)
			r.Patch("/me/feeds/{id}", s.updateFeed)
			r.With(s.rateLimitUser(s.limSensitive)).Post("/me/feeds/{id}/rotate", s.rotateFeed)
			r.Delete("/me/feeds/{id}", s.removeFeed)
			r.Put("/me/password", s.changePassword)
			r.Delete("/me", s.deleteMe)

			r.Route("/sync", func(r chi.Router) {
				r.Post("/push", s.syncPush)
				r.Get("/pull", s.syncPull)
				r.Get("/snapshot", s.syncSnapshot)
				r.Get("/events", s.syncEvents)
				r.Get("/conflicts", s.listConflicts)
				r.Delete("/conflicts/{id}", s.dismissConflict)
			})

			r.Get("/dashboard", s.dashboard)
			r.Get("/export.json", s.export)
			r.Get("/export.zip", s.exportZip)
			r.Post("/export/link", s.exportLink)

			r.Get("/colonies", s.listColonies)
			r.Post("/colonies", s.createEntity("colonies"))
			r.Get("/colonies/{id}", s.colonyOverview)
			r.Patch("/colonies/{id}", s.updateEntity("colonies"))
			r.Delete("/colonies/{id}", s.deleteEntity("colonies"))
			r.Post("/colonies/{id}/archive", s.archiveColony(true))
			r.Post("/colonies/{id}/unarchive", s.archiveColony(false))
			r.Get("/colonies/{id}/timeline", s.timeline)
			r.Get("/colonies/{id}/due", s.colonyDue)
			r.Post("/colonies/{id}/feedings/repeat-last", s.repeatLastFeeding)
			r.With(s.rateLimitUser(s.limScan)).Post("/colonies/{id}/ai-count", s.aiCount)
			r.Get("/ai", s.aiInfo)
			r.Get("/colonies/{id}/public-links", s.listPublicLinks)
			r.Post("/colonies/{id}/public-links", s.createPublicLink)
			r.Patch("/public-links/{id}", s.updatePublicLink)
			r.Delete("/public-links/{id}", s.revokePublicLink)
			r.Get("/care-covers", s.listCareCovers)
			r.Post("/care-covers", s.createCareCover)
			r.Get("/care-covers/{id}", s.getCareCover)
			r.Patch("/care-covers/{id}", s.updateCareCover)
			r.Post("/care-covers/{id}/end", s.endCareCover)
			r.Get("/colonies/{id}/care-instructions", s.careInstructions)
			r.Get("/ai-count/{job}", s.aiCountJob)
			r.Get("/colonies/{id}/members", s.listMembers)
			r.Post("/colonies/{id}/members", s.setMember)
			r.Delete("/colonies/{id}/members/{userId}", s.removeMember)
			r.Post("/colonies/{id}/scan-links/regenerate", s.regenerateQR)

			r.With(s.rateLimitUser(s.limScan)).Get("/scan/{token}", s.resolveScan)
			r.With(s.rateLimitUser(s.limScan)).Post("/scan/nfc-uid", s.resolveNFC)
			r.Get("/scan-links/{id}/qr.svg", s.qrCode("svg"))
			r.Get("/scan-links/{id}/qr.png", s.qrCode("png"))

			r.Put("/photos/{id}/content", s.uploadPhoto)
			r.Get("/photos/{id}/url", s.photoURL)

			r.Get("/sensors/{id}/measurements", s.sensorReadings)
			r.Post("/sensors/{id}/rotate-key", s.rotateSensorKey)

			r.Get("/invitations", s.listInvitations)
			r.Post("/invitations", s.createInvitation)
			r.Delete("/invitations/{id}", s.deleteInvitation)

			r.Route("/admin", func(r chi.Router) {
				r.Get("/users", s.adminUsers)
				r.Patch("/users/{id}", s.adminUpdateUser)
				r.Post("/users/{id}/password-reset-link", s.adminResetLink)
				r.Get("/system", s.adminSystem)
				r.Get("/smtp", s.getSMTP)
				r.Put("/smtp", s.setSMTP)
				r.With(s.rateLimitUser(s.limScan)).Post("/smtp/test", s.testSMTP)
				r.Get("/offsite", s.getOffsite)
				r.Put("/offsite", s.setOffsite)
				r.With(s.rateLimitUser(s.limScan)).Post("/offsite/test", s.testOffsite)
				r.With(s.rateLimitUser(s.limScan)).Post("/offsite/run", s.runOffsite)
				r.Get("/mqtt", s.getMQTT)
				r.Put("/mqtt", s.setMQTT)
				r.With(s.rateLimitUser(s.limScan)).Post("/mqtt/test", s.testMQTT)
				r.With(s.rateLimitUser(s.limScan)).Post("/home-assistant/test", s.testHomeAssistant)
				r.Get("/ai", s.getAI)
				r.Get("/oidc", s.getOIDC)
				r.Put("/oidc", s.setOIDC)
				r.With(s.rateLimitUser(s.limScan)).Post("/oidc/test", s.testOIDC)
				r.Put("/ai", s.setAI)
			})

			// Generic collections (locations, food-items, species, habitats, …)
			r.Get("/{collection}", s.listGeneric)
			r.Post("/{collection}", s.createGeneric)
			r.Get("/{collection}/{id}", s.getGeneric)
			r.Patch("/{collection}/{id}", s.updateGeneric)
			r.Delete("/{collection}/{id}", s.deleteGeneric)
		})

		r.NotFound(func(w http.ResponseWriter, r *http.Request) {
			s.problem(w, r, service.NotFound("route"))
		})
	})

	r.Get("/c/{token}", s.scanLanding)
	r.Get("/p/{token}", s.publicPage)
	r.Get("/p/{token}/forum.txt", s.publicForum)
	r.Get("/p/{token}/photos/{id}/{variant}", s.publicPhoto)
	r.NotFound(s.webApp)
	return r
}

// ---------------------------------------------------------------------------
// Middleware

func (s *Server) requestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := auth.NewToken(9)
		w.Header().Set("X-Request-ID", id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxRequestID, id)))
	})
}

// clientIP resolves the real client address. X-Forwarded-For is only trusted
// when the direct peer is a configured proxy.
func (s *Server) clientIP(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := peerAddr(r.RemoteAddr)
		if s.trusted(ip) {
			if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
				parts := strings.Split(xff, ",")
				for i := len(parts) - 1; i >= 0; i-- {
					a, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
					if err != nil {
						break
					}
					ip = a.Unmap()
					if !s.trusted(ip) {
						break
					}
				}
			}
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxClientIP, ip)))
	})
}

func (s *Server) trusted(ip netip.Addr) bool {
	for _, p := range s.cfg.TrustedProxies {
		if p.Contains(ip) {
			return true
		}
	}
	return false
}

func peerAddr(remote string) netip.Addr {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		host = remote
	}
	a, _ := netip.ParseAddr(host)
	return a.Unmap()
}

func clientIP(r *http.Request) netip.Addr {
	ip, _ := r.Context().Value(ctxClientIP).(netip.Addr)
	return ip
}

type statusWriter struct {
	http.ResponseWriter
	status int
	bytes  int
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(b)
	w.bytes += n
	return n, err
}

func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// logPath removes secrets from paths: scan tokens, file keys; query strings are never logged.
func logPath(p string) string {
	switch {
	case strings.HasPrefix(p, "/c/"):
		return "/c/…"
	case strings.HasPrefix(p, "/files/"):
		return "/files/…"
	case strings.HasPrefix(p, "/api/v1/feeds/"):
		return "/api/v1/feeds/…"
	case strings.HasPrefix(p, "/api/v1/scan/") && !strings.HasPrefix(p, "/api/v1/scan/nfc-uid"):
		return "/api/v1/scan/…"
	}
	return p
}

func (s *Server) accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w}
		holder := &uuid.UUID{}
		r = r.WithContext(context.WithValue(r.Context(), ctxLogUser, holder))
		next.ServeHTTP(sw, r)
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			return
		}
		attrs := []any{"method", r.Method, "path", logPath(r.URL.Path), "status", sw.status,
			"bytes", sw.bytes, "ms", time.Since(start).Milliseconds(), "ip", clientIP(r).String(),
			"request_id", r.Context().Value(ctxRequestID)}
		if *holder != uuid.Nil {
			attrs = append(attrs, "user", holder.String())
		}
		level := slog.LevelInfo
		if sw.status >= 500 {
			level = slog.LevelError
		}
		s.log.Log(r.Context(), level, "request", attrs...)
	})
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if v == http.ErrAbortHandler {
					panic(v)
				}
				s.log.Error("panic", "value", fmt.Sprint(v), "stack", string(debug.Stack()),
					"request_id", r.Context().Value(ctxRequestID))
				s.problem(w, r, errors.New("panic"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Permissions-Policy", "camera=(self), microphone=(), geolocation=()")
		h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "+
			"style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; "+
			"worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'")
		if s.cfg.SecureCookies() {
			h.Set("Strict-Transport-Security", "max-age=31536000")
		}
		next.ServeHTTP(w, r)
	})
}

// bodyLimit caps request bodies: 1 MB by default, more for sync pushes and
// photo uploads.
func (s *Server) bodyLimit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limit := int64(1 << 20)
		switch p := r.URL.Path; {
		case p == "/api/v1/sync/push":
			limit = 5 << 20
		case strings.HasPrefix(p, "/api/v1/photos/") && strings.HasSuffix(p, "/content"):
			limit = s.cfg.UploadMaxBytes + 64<<10
		case strings.HasPrefix(p, "/api/v1/sensors/"):
			limit = 256 << 10
		}
		r.Body = http.MaxBytesReader(w, r.Body, limit)
		next.ServeHTTP(w, r)
	})
}

func (s *Server) authenticated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || tok == "" {
			if ok, retry := s.limAnon.Allow(clientIP(r).String()); !ok {
				s.problem(w, r, service.RateLimited(retry))
				return
			}
			s.problem(w, r, service.ErrUnauthorized)
			return
		}
		actor, err := s.svc.Authenticate(r.Context(), tok)
		if err != nil {
			s.problem(w, r, err)
			return
		}
		if h, ok := r.Context().Value(ctxLogUser).(*uuid.UUID); ok {
			*h = actor.UserID
		}
		if ok, retry := s.limUser.Allow(actor.UserID.String()); !ok {
			s.problem(w, r, service.RateLimited(retry))
			return
		}
		// language of the app (for e-mail/ntfy when „device language“ is set)
		if al := r.Header.Get("Accept-Language"); al != "" {
			s.svc.NoteLanguage(r.Context(), actor.UserID, al)
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxActor, actor)))
	})
}

func (s *Server) rateLimitUser(l interface {
	Allow(string) (bool, time.Duration)
}) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if ok, retry := l.Allow(actorOf(r).UserID.String()); !ok {
				s.problem(w, r, service.RateLimited(retry))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func actorOf(r *http.Request) service.Actor {
	a, _ := r.Context().Value(ctxActor).(service.Actor)
	return a
}

// ---------------------------------------------------------------------------
// Helpers

func (s *Server) writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		s.log.Debug("write response failed", "err", err)
	}
}

type problemBody struct {
	Type      string `json:"type"`
	Title     string `json:"title"`
	Status    int    `json:"status"`
	Code      string `json:"code"`
	Field     string `json:"field,omitempty"`
	RequestID any    `json:"request_id,omitempty"`
}

func (s *Server) problem(w http.ResponseWriter, r *http.Request, err error) {
	p, ok := service.AsProblem(err)
	if !ok {
		var mbe *http.MaxBytesError
		switch {
		case errors.As(err, &mbe):
			p = &service.Problem{Status: http.StatusRequestEntityTooLarge, Code: "request.too_large", Title: "request body too large"}
		case errors.Is(err, context.Canceled):
			return
		case db.IsDataError(err):
			p = service.Invalid("", "invalid value")
			s.log.Info("data error", "err", err, "request_id", r.Context().Value(ctxRequestID))
		default:
			s.log.Error("internal error", "err", err, "request_id", r.Context().Value(ctxRequestID))
			p = &service.Problem{Status: http.StatusInternalServerError, Code: "internal", Title: "internal server error"}
		}
	}
	if p.RetryAfter > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(int(p.RetryAfter.Seconds())+1))
	}
	w.Header().Set("Content-Type", "application/problem+json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(p.Status)
	_ = json.NewEncoder(w).Encode(problemBody{Type: "about:blank", Title: p.Title, Status: p.Status, Code: p.Code,
		Field: p.Field, RequestID: r.Context().Value(ctxRequestID)})
}

func decode(r *http.Request, v any) error {
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			return err
		}
		return &service.Problem{Status: http.StatusBadRequest, Code: "request.invalid_json", Title: "request body is not valid JSON"}
	}
	return nil
}

func pathUUID(r *http.Request, name string) (uuid.UUID, error) {
	id, err := uuid.Parse(chi.URLParam(r, name))
	if err != nil {
		return uuid.Nil, service.NotFound("entity")
	}
	return id, nil
}

func queryUUID(r *http.Request, name string) (*uuid.UUID, error) {
	v := r.URL.Query().Get(name)
	if v == "" {
		return nil, nil
	}
	id, err := uuid.Parse(v)
	if err != nil {
		return nil, service.Invalid(name, "%s must be a UUID", name)
	}
	return &id, nil
}
