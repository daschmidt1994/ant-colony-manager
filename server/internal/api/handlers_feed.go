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

// setFeedFilter chooses what the calendar shows.
func (s *Server) setFeedFilter(w http.ResponseWriter, r *http.Request) {
	var in struct {
		CalendarTypes []string `json:"calendar_types"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	info, err := s.svc.SetCalendarTypes(r.Context(), actorOf(r), in.CalendarTypes)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, info)
}

func (s *Server) deleteFeed(w http.ResponseWriter, r *http.Request) {
	if err := s.svc.DeleteFeedToken(r.Context(), actorOf(r)); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) feedCalendar(w http.ResponseWriter, r *http.Request) {
	user, feed, ok := s.feedUser(w, r)
	if !ok {
		return
	}
	ics, err := s.svc.FeedCalendar(r.Context(), user, feed)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "text/calendar; charset=utf-8")
	w.Header().Set("Content-Disposition", `inline; filename="ameisen.ics"`)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(ics)
}

func (s *Server) feedUser(w http.ResponseWriter, r *http.Request) (uuid.UUID, uuid.UUID, bool) {
	if ok, retry := s.limAnon.Allow(clientIP(r).String()); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return uuid.Nil, uuid.Nil, false
	}
	u, feed, err := s.svc.FeedUser(r.Context(), chi.URLParam(r, "token"))
	if err != nil {
		s.problem(w, r, err)
		return uuid.Nil, uuid.Nil, false
	}
	return u, feed, true
}

// ---------------------------------------------------------------------------
// Several calendars

func (s *Server) feedURL(tok string) string {
	return s.cfg.PublicURL.String() + "/api/v1/feeds/" + tok + "/calendar.ics"
}

func (s *Server) listFeeds(w http.ResponseWriter, r *http.Request) {
	list, err := s.svc.Feeds(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	if list == nil {
		list = []service.Feed{}
	}
	s.writeJSON(w, http.StatusOK, list)
}

// newFeed creates a calendar; its address is returned only here.
func (s *Server) newFeed(w http.ResponseWriter, r *http.Request) {
	var in service.FeedInput
	if r.ContentLength != 0 {
		if err := decode(r, &in); err != nil {
			s.problem(w, r, err)
			return
		}
	}
	f, tok, err := s.svc.CreateFeed(r.Context(), actorOf(r), in)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusCreated, map[string]any{"feed": f, "calendar_url": s.feedURL(tok)})
}

func (s *Server) updateFeed(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	var in service.FeedInput
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	f, err := s.svc.UpdateFeed(r.Context(), actorOf(r), id, in)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, f)
}

func (s *Server) rotateFeed(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	tok, err := s.svc.RotateFeed(r.Context(), actorOf(r), id)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]string{"calendar_url": s.feedURL(tok)})
}

func (s *Server) removeFeed(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.DeleteFeed(r.Context(), actorOf(r), id); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
