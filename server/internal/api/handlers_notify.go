package api

import (
	"net/http"

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

func (s *Server) testNotify(w http.ResponseWriter, r *http.Request) {
	if err := s.svc.TestNotify(r.Context(), actorOf(r)); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
