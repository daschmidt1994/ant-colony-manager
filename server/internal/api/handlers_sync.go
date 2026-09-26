package api

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
)

func (s *Server) syncPush(w http.ResponseWriter, r *http.Request) {
	var in struct {
		service.DeviceInfo
		Ops []service.Op `json:"ops"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	res, err := s.svc.Push(r.Context(), actorOf(r), in.DeviceInfo, in.Ops)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, res)
}

func (s *Server) syncPull(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	since, err := strconv.ParseInt(q.Get("since"), 10, 64)
	if err != nil && q.Get("since") != "" {
		s.problem(w, r, service.Invalid("since", "since must be a number"))
		return
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	actor := actorOf(r)
	if d := r.Header.Get("X-Device-ID"); d != "" {
		if id, err := uuid.Parse(d); err == nil {
			actor.DeviceID = id
		}
	}
	res, err := s.svc.Pull(r.Context(), actor, since, limit)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, res)
}

func (s *Server) syncSnapshot(w http.ResponseWriter, r *http.Request) {
	var only []uuid.UUID
	if v := r.URL.Query().Get("colony_ids"); v != "" {
		for _, part := range strings.Split(v, ",") {
			id, err := uuid.Parse(strings.TrimSpace(part))
			if err != nil {
				s.problem(w, r, service.Invalid("colony_ids", "colony_ids must be UUIDs"))
				return
			}
			only = append(only, id)
		}
	}
	snap, err := s.svc.Snapshot(r.Context(), actorOf(r), only)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, snap)
}

func (s *Server) listConflicts(w http.ResponseWriter, r *http.Request) {
	list, err := s.svc.ListConflicts(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"conflicts": list})
}

func (s *Server) dismissConflict(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err == nil {
		err = s.svc.DismissConflict(r.Context(), actorOf(r), id)
	}
	if err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// syncEvents is a Server-Sent Events stream that only says "something changed
// up to seq N"; clients then pull. No data leaves through this channel.
func (s *Server) syncEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		s.problem(w, r, fmt.Errorf("streaming unsupported"))
		return
	}
	if s.broker == nil {
		s.problem(w, r, &service.Problem{Status: http.StatusServiceUnavailable, Code: "realtime.disabled", Title: "realtime not available"})
		return
	}
	// Long-lived stream: lift the server's write timeout for this response.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Time{})
	actor := actorOf(r)
	ch, cancel := s.broker.Subscribe(actor.UserID)
	defer cancel()

	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Accel-Buffering", "no") // nginx: do not buffer
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "retry: 5000\n\n")
	flusher.Flush()

	ping := time.NewTicker(25 * time.Second)
	defer ping.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case seq := <-ch:
			fmt.Fprintf(w, "event: change\ndata: {\"seq\":%d}\n\n", seq)
			flusher.Flush()
		case <-ping.C:
			fmt.Fprint(w, ": ping\n\n")
			flusher.Flush()
		}
	}
}

// ---------------------------------------------------------------------------
// Broker: LISTEN acm_changes → per-user channels.

type Broker struct {
	pool    *pgxpool.Pool
	svc     *service.Service
	log     *slog.Logger
	mu      sync.Mutex
	subs    map[uuid.UUID]map[chan int64]struct{}
	members map[uuid.UUID]cachedMembers
}

type cachedMembers struct {
	users []uuid.UUID
	at    time.Time
}

func NewBroker(pool *pgxpool.Pool, svc *service.Service, log *slog.Logger) *Broker {
	return &Broker{pool: pool, svc: svc, log: log, subs: map[uuid.UUID]map[chan int64]struct{}{},
		members: map[uuid.UUID]cachedMembers{}}
}

func (b *Broker) Subscribe(user uuid.UUID) (<-chan int64, func()) {
	ch := make(chan int64, 1)
	b.mu.Lock()
	if b.subs[user] == nil {
		b.subs[user] = map[chan int64]struct{}{}
	}
	b.subs[user][ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		delete(b.subs[user], ch)
		if len(b.subs[user]) == 0 {
			delete(b.subs, user)
		}
		b.mu.Unlock()
	}
}

func (b *Broker) hasSubscribers() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.subs) > 0
}

func (b *Broker) notify(user uuid.UUID, seq int64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subs[user] {
		select {
		case ch <- seq:
		default: // a pending signal is enough; the client pulls everything anyway
			select {
			case <-ch:
			default:
			}
			ch <- seq
		}
	}
}

// Run listens for database notifications until ctx ends, reconnecting on error.
func (b *Broker) Run(ctx context.Context) {
	backoff := time.Second
	for ctx.Err() == nil {
		err := b.listen(ctx)
		if ctx.Err() != nil {
			return
		}
		b.log.Warn("realtime listener stopped, reconnecting", "err", err, "in", backoff)
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, time.Minute)
	}
}

func (b *Broker) listen(ctx context.Context) error {
	conn, err := b.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, "LISTEN acm_changes"); err != nil {
		return err
	}
	for {
		n, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return err
		}
		if !b.hasSubscribers() {
			continue
		}
		parts := strings.Split(n.Payload, "|")
		if len(parts) != 3 {
			continue
		}
		seq, _ := strconv.ParseInt(parts[2], 10, 64)
		if owner, err := uuid.Parse(parts[1]); err == nil {
			b.notify(owner, seq)
		}
		if colony, err := uuid.Parse(parts[0]); err == nil {
			for _, u := range b.colonyMembers(ctx, colony) {
				b.notify(u, seq)
			}
		}
	}
}

// colonyMembers caches membership for a few seconds (bursts during a care round).
func (b *Broker) colonyMembers(ctx context.Context, colony uuid.UUID) []uuid.UUID {
	b.mu.Lock()
	c, ok := b.members[colony]
	b.mu.Unlock()
	if ok && time.Since(c.at) < 5*time.Second {
		return c.users
	}
	users, err := b.svc.MembersOf(ctx, colony)
	if err != nil {
		b.log.Warn("realtime member lookup failed", "err", err)
		return nil
	}
	b.mu.Lock()
	if len(b.members) > 10_000 {
		b.members = map[uuid.UUID]cachedMembers{}
	}
	b.members[colony] = cachedMembers{users: users, at: time.Now()}
	b.mu.Unlock()
	return users
}
