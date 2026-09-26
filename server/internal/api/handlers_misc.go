package api

import (
	"errors"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
)

// ---------------------------------------------------------------------------
// Photos

func (s *Server) uploadPhoto(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	data, err := s.svc.UploadPhoto(r.Context(), actorOf(r), id, r.Body, r.Header.Get("Content-SHA256"))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, data)
}

func (s *Server) photoURL(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	u, err := s.svc.PhotoURL(r.Context(), actorOf(r), id, r.URL.Query().Get("variant"))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, u)
}

// serveFile delivers uploads only with a valid, unexpired signature.
func (s *Server) serveFile(w http.ResponseWriter, r *http.Request) {
	key := chi.URLParam(r, "*")
	q := r.URL.Query()
	if !s.svc.VerifyFileSignature(key, q.Get("exp"), q.Get("sig")) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	f, size, err := s.svc.Blobs.Open(key)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			http.NotFound(w, r)
			return
		}
		s.problem(w, r, err)
		return
	}
	defer f.Close()
	ctype := "image/jpeg"
	if strings.HasSuffix(key, ".orig") {
		ctype = "application/octet-stream"
		w.Header().Set("Content-Disposition", "attachment")
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("Cache-Control", "private, max-age=86400, immutable")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	http.ServeContent(w, r, "", time.Time{}, f)
}

// ---------------------------------------------------------------------------
// Sensors

func (s *Server) ingestSensor(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	if ok, retry := s.limSensor.Allow(id.String()); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return
	}
	key, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	var in struct {
		Readings []service.SensorReading `json:"readings"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	n, err := s.svc.IngestSensor(r.Context(), key, id, in.Readings)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusAccepted, map[string]any{"stored": n, "received": len(in.Readings)})
}

func (s *Server) sensorReadings(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	q := r.URL.Query()
	to := time.Now()
	from := to.Add(-7 * 24 * time.Hour)
	if v := q.Get("from"); v != "" {
		if from, err = time.Parse(time.RFC3339, v); err != nil {
			s.problem(w, r, service.Invalid("from", "from must be RFC 3339"))
			return
		}
	}
	if v := q.Get("to"); v != "" {
		if to, err = time.Parse(time.RFC3339, v); err != nil {
			s.problem(w, r, service.Invalid("to", "to must be RFC 3339"))
			return
		}
	}
	bucket := time.Hour
	if v := q.Get("bucket"); v != "" {
		if bucket, err = time.ParseDuration(v); err != nil {
			s.problem(w, r, service.Invalid("bucket", "bucket must be a duration like 15m or 1h"))
			return
		}
	}
	list, err := s.svc.SensorReadings(r.Context(), actorOf(r), id, from, to, bucket)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"buckets": list})
}

func (s *Server) rotateSensorKey(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	key, err := s.svc.RotateSensorKey(r.Context(), actorOf(r), id)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"api_key": key})
}

// ---------------------------------------------------------------------------
// Invitations & admin

func (s *Server) listInvitations(w http.ResponseWriter, r *http.Request) {
	list, err := s.svc.ListInvitations(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"invitations": list})
}

func (s *Server) createInvitation(w http.ResponseWriter, r *http.Request) {
	var in service.InvitationInput
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	inv, err := s.svc.CreateInvitation(r.Context(), actorOf(r), in)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusCreated, inv)
}

func (s *Server) deleteInvitation(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err == nil {
		err = s.svc.DeleteInvitation(r.Context(), actorOf(r), id)
	}
	if err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminUsers(w http.ResponseWriter, r *http.Request) {
	list, err := s.svc.ListUsers(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"users": list})
}

func (s *Server) adminUpdateUser(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	var in service.AdminUserPatch
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.UpdateUser(r.Context(), actorOf(r), id, in); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) adminResetLink(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	a := actorOf(r)
	if !a.IsAdmin {
		s.problem(w, r, service.ErrForbidden)
		return
	}
	var email string
	if err := s.svc.Pool.QueryRow(r.Context(), `SELECT email FROM users WHERE id = $1`, id).Scan(&email); err != nil {
		s.problem(w, r, service.NotFound("user"))
		return
	}
	link, err := s.svc.AdminResetLink(r.Context(), email)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.svc.Audit(r.Context(), &a.UserID, "admin_reset_link", id.String(), nil, clientIP(r))
	s.writeJSON(w, http.StatusCreated, map[string]any{"link": link, "valid_minutes": 30})
}

func (s *Server) adminSystem(w http.ResponseWriter, r *http.Request) {
	info, err := s.svc.SystemInfo(r.Context(), actorOf(r), s.version, s.cfg.BackupDir)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, info)
}

// ---------------------------------------------------------------------------
// Web app (embedded Flutter build; placeholder until Phase 5)

func (s *Server) hasWebIndex() bool {
	if s.web == nil {
		return false
	}
	_, err := fs.Stat(s.web, "index.html")
	return err == nil
}

func (s *Server) webApp(w http.ResponseWriter, r *http.Request) {
	if s.web == nil || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
		http.NotFound(w, r)
		return
	}
	p := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
	if p != "" && p != "index.html" {
		if st, err := fs.Stat(s.web, p); err == nil && !st.IsDir() {
			f, err := s.web.Open(p)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			defer f.Close()
			if ct := mime.TypeByExtension(path.Ext(p)); ct != "" {
				w.Header().Set("Content-Type", ct)
			}
			if strings.HasPrefix(p, "assets/") || strings.HasPrefix(p, "canvaskit/") {
				w.Header().Set("Cache-Control", "public, max-age=604800")
			} else {
				w.Header().Set("Cache-Control", "no-cache")
			}
			_, _ = io.Copy(w, f)
			return
		}
		// Unknown file-like paths are 404; app routes fall back to index.html.
		if path.Ext(p) != "" {
			http.NotFound(w, r)
			return
		}
	}
	s.serveIndex(w, r, nil)
}

func (s *Server) serveIndex(w http.ResponseWriter, r *http.Request, replace map[string]string) {
	b, err := fs.ReadFile(s.web, "index.html")
	if err != nil {
		http.NotFound(w, r)
		return
	}
	page := string(b)
	if replace == nil {
		replace = map[string]string{}
	}
	if _, ok := replace["{{APP_INTENT}}"]; !ok {
		replace["{{APP_INTENT}}"] = ""
	}
	for k, v := range replace {
		page = strings.ReplaceAll(page, k, v)
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache")
	_, _ = io.WriteString(w, page)
}
