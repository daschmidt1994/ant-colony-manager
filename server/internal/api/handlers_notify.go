package api

import (
	"net/http"
	"strings"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
)

// Notification settings (ntfy, e-mail per topic). Not synced: the ntfy token
// stays on the server, responses only say whether one is stored.

func (s *Server) getNotifyPrefs(w http.ResponseWriter, r *http.Request) {
	p, err := s.svc.NotifyPrefs(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, p)
}

func (s *Server) setNotifyPrefs(w http.ResponseWriter, r *http.Request) {
	var in service.NotifyPrefs
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	p, err := s.svc.SetNotifyPrefs(r.Context(), actorOf(r), in)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, p)
}

// snooze: „Morgen“ button of an ntfy notification (signed link, no login).
func (s *Server) snooze(w http.ResponseWriter, r *http.Request) {
	if ok, retry := s.limAnon.Allow(clientIP(r).String()); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return
	}
	msg, err := s.svc.SnoozeByLink(r.Context(), r.URL.Query())
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"message": msg})
}

func (s *Server) testNotify(w http.ResponseWriter, r *http.Request) {
	if err := s.svc.TestNotify(r.Context(), actorOf(r)); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---------------------------------------------------------------------------
// E-mail server (SMTP) – administrators, in the app instead of SMTP_* env.

func (s *Server) getSMTP(w http.ResponseWriter, r *http.Request) {
	st, err := s.svc.GetSMTPSettings(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, st)
}

func (s *Server) setSMTP(w http.ResponseWriter, r *http.Request) {
	var in service.SMTPSettings
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	st, err := s.svc.SetSMTPSettings(r.Context(), actorOf(r), in, service.ClientMeta{IP: clientIP(r)})
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, st)
}

func (s *Server) testSMTP(w http.ResponseWriter, r *http.Request) {
	if err := s.svc.SendTestMail(r.Context(), actorOf(r)); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) getOffsite(w http.ResponseWriter, r *http.Request) {
	st, err := s.svc.GetOffsiteSettings(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, st)
}

func (s *Server) setOffsite(w http.ResponseWriter, r *http.Request) {
	var in service.OffsiteSettings
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	st, err := s.svc.SetOffsiteSettings(r.Context(), actorOf(r), in, service.ClientMeta{IP: clientIP(r)})
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, st)
}

func (s *Server) testOffsite(w http.ResponseWriter, r *http.Request) {
	if err := s.svc.TestOffsite(r.Context(), actorOf(r)); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) runOffsite(w http.ResponseWriter, r *http.Request) {
	if err := s.svc.StartOffsite(r.Context(), actorOf(r)); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

// updates: newer releases of the server/app, with breaking-change warnings.
func (s *Server) updates(w http.ResponseWriter, r *http.Request) {
	lang := "de"
	if strings.HasPrefix(strings.ToLower(r.Header.Get("Accept-Language")), "en") {
		lang = "en"
	}
	s.writeJSON(w, http.StatusOK, s.svc.Updates(r.Context(), s.version, lang))
}
