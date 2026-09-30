package api

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
)

// ---------------------------------------------------------------------------
// Feeds: calendar subscription (iCal)

func (s *Server) getFeed(w http.ResponseWriter, r *http.Request) {
	info, err := s.svc.FeedInfo(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, info)
}

// createFeed issues a new address (the old one stops working); the token is
// shown exactly once.
func (s *Server) createFeed(w http.ResponseWriter, r *http.Request) {
	tok, err := s.svc.CreateFeedToken(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	base := s.cfg.PublicURL.String() + "/api/v1/feeds/" + tok
	s.writeJSON(w, http.StatusCreated, map[string]string{
		"token":        tok,
		"calendar_url": base + "/calendar.ics",
	})
}

func (s *Server) deleteFeed(w http.ResponseWriter, r *http.Request) {
	if err := s.svc.DeleteFeedToken(r.Context(), actorOf(r)); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) feedCalendar(w http.ResponseWriter, r *http.Request) {
	user, ok := s.feedUser(w, r)
	if !ok {
		return
	}
	ics, err := s.svc.FeedCalendar(r.Context(), user)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "text/calendar; charset=utf-8")
	w.Header().Set("Content-Disposition", `inline; filename="ameisen.ics"`)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(ics)
}

func (s *Server) feedUser(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	if ok, retry := s.limAnon.Allow(clientIP(r).String()); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return uuid.Nil, false
	}
	u, err := s.svc.FeedUser(r.Context(), chi.URLParam(r, "token"))
	if err != nil {
		s.problem(w, r, err)
		return uuid.Nil, false
	}
	return u, true
}
