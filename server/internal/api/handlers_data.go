package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
)

// ---------------------------------------------------------------------------
// Generic entity writes: REST calls become the same ops the sync uses.

type writeResponse struct {
	Data      json.RawMessage `json:"data"`
	Status    string          `json:"status"`
	Conflicts []string        `json:"conflicts,omitempty"`
	Ignored   []string        `json:"ignored_fields,omitempty"`
	Extra     map[string]any  `json:"extra,omitempty"`
}

func opIDFromHeader(r *http.Request) (uuid.UUID, error) {
	if k := r.Header.Get("Idempotency-Key"); k != "" {
		id, err := uuid.Parse(k)
		if err != nil {
			return uuid.Nil, service.Invalid("Idempotency-Key", "Idempotency-Key must be a UUID")
		}
		return id, nil
	}
	return uuid.Must(uuid.NewV7()), nil
}

// baseVersion reads If-Match: "123" (optimistic concurrency, optional).
func baseVersion(r *http.Request) (*int64, error) {
	v := strings.Trim(strings.TrimPrefix(r.Header.Get("If-Match"), "W/"), `"`)
	if v == "" {
		return nil, nil
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return nil, service.Invalid("If-Match", "If-Match must be a version number")
	}
	return &n, nil
}

func (s *Server) writeOp(w http.ResponseWriter, r *http.Request, table, kind string, id uuid.UUID) {
	opID, err := opIDFromHeader(r)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	op := service.Op{OpID: opID, Entity: table, EntityID: id, Op: kind}
	if kind != "delete" {
		var raw json.RawMessage
		if err := decode(r, &raw); err != nil {
			s.problem(w, r, err)
			return
		}
		op.Payload = raw
	}
	if kind == "update" {
		if op.BaseVersion, err = baseVersion(r); err != nil {
			s.problem(w, r, err)
			return
		}
		now := time.Now()
		op.ClientTime = &now
	}
	if kind == "create" && table == "colonies" {
		op.AutoQR = r.URL.Query().Get("qr") != "false"
	}
	s.respondOp(w, r, op, func() (service.OpResult, error) { return s.svc.ApplyOp(r.Context(), actorOf(r), op) })
}

func (s *Server) respondOp(w http.ResponseWriter, r *http.Request, op service.Op, apply func() (service.OpResult, error)) {
	res, err := apply()
	if err != nil {
		s.problem(w, r, err)
		return
	}
	if res.Status == service.StatusRejected {
		s.problem(w, r, res.Error)
		return
	}
	status := http.StatusOK
	if op.Op == "create" && res.Status != service.StatusDuplicate {
		status = http.StatusCreated
	}
	if op.Op == "delete" {
		w.Header().Set("ETag", strconv.Quote(strconv.FormatInt(res.Version, 10)))
		w.WriteHeader(http.StatusNoContent)
		return
	}
	data, err := s.svc.Render(r.Context(), op.Entity, res.EntityID)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	w.Header().Set("ETag", strconv.Quote(strconv.FormatInt(res.Version, 10)))
	s.writeJSON(w, status, writeResponse{Data: data, Status: res.Status, Conflicts: res.Conflicts, Ignored: res.Ignored, Extra: res.Extra})
}

// idFromBody takes "id" from a create payload (client-generated) or makes one.
func idFromBody(r *http.Request) (uuid.UUID, *http.Request, error) {
	var raw json.RawMessage
	if err := decode(r, &raw); err != nil {
		return uuid.Nil, r, err
	}
	var probe struct {
		ID *uuid.UUID `json:"id"`
	}
	_ = json.Unmarshal(raw, &probe)
	id := uuid.Must(uuid.NewV7())
	if probe.ID != nil && *probe.ID != uuid.Nil {
		id = *probe.ID
	}
	r2 := r.Clone(r.Context())
	r2.Body = io.NopCloser(bytes.NewReader(raw))
	return id, r2, nil
}

func (s *Server) createEntity(table string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, r2, err := idFromBody(r)
		if err != nil {
			s.problem(w, r, err)
			return
		}
		s.writeOp(w, r2, table, "create", id)
	}
}

func (s *Server) updateEntity(table string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathUUID(r, "id")
		if err != nil {
			s.problem(w, r, err)
			return
		}
		s.writeOp(w, r, table, "update", id)
	}
}

func (s *Server) deleteEntity(table string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathUUID(r, "id")
		if err != nil {
			s.problem(w, r, err)
			return
		}
		s.writeOp(w, r, table, "delete", id)
	}
}

func collectionTable(r *http.Request) (string, error) {
	t, ok := service.EntityByCollection(chi.URLParam(r, "collection"))
	if !ok || t == "colony_members" || t == "user_settings" {
		return "", service.NotFound("route")
	}
	return t, nil
}

func (s *Server) listGeneric(w http.ResponseWriter, r *http.Request) {
	t, err := collectionTable(r)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	colony, err := queryUUID(r, "colony_id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	list, err := s.svc.ListEntities(r.Context(), actorOf(r), t, colony)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"items": list})
}

func (s *Server) getGeneric(w http.ResponseWriter, r *http.Request) {
	t, err := collectionTable(r)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	data, err := s.svc.GetEntity(r.Context(), actorOf(r), t, id)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, data)
}

func (s *Server) createGeneric(w http.ResponseWriter, r *http.Request) {
	t, err := collectionTable(r)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.createEntity(t)(w, r)
}

func (s *Server) updateGeneric(w http.ResponseWriter, r *http.Request) {
	t, err := collectionTable(r)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.updateEntity(t)(w, r)
}

func (s *Server) deleteGeneric(w http.ResponseWriter, r *http.Request) {
	t, err := collectionTable(r)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.deleteEntity(t)(w, r)
}

// ---------------------------------------------------------------------------
// Colonies

func (s *Server) listColonies(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	f := service.ColonyFilter{Q: q.Get("q"), Genus: q.Get("genus"), Due: q.Get("due"), Sort: q.Get("sort"),
		Archived: q.Get("archived") == "true"}
	if st := q.Get("status"); st != "" {
		f.Status = strings.Split(st, ",")
	}
	var err error
	if f.LocationID, err = queryUUID(r, "location_id"); err == nil {
		f.SpeciesID, err = queryUUID(r, "species_id")
	}
	if err != nil {
		s.problem(w, r, err)
		return
	}
	if v := q.Get("size_min"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			s.problem(w, r, service.Invalid("size_min", "size_min must be a number"))
			return
		}
		f.SizeMin = &n
	}
	list, err := s.svc.ListColonies(r.Context(), actorOf(r), f)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"items": list, "count": len(list)})
}

func (s *Server) colonyOverview(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	ov, err := s.svc.ColonyOverview(r.Context(), actorOf(r), id)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, ov)
}

func (s *Server) archiveColony(archive bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, err := pathUUID(r, "id")
		if err != nil {
			s.problem(w, r, err)
			return
		}
		var v any
		if archive {
			v = time.Now().UTC()
		}
		op := service.Op{OpID: uuid.Must(uuid.NewV7()), Entity: "colonies", EntityID: id, Op: "update",
			Payload: mustJSON(map[string]any{"archived_at": v})}
		s.respondOp(w, r, op, func() (service.OpResult, error) { return s.svc.ApplyOp(r.Context(), actorOf(r), op) })
	}
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

func (s *Server) timeline(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	q := r.URL.Query()
	var types []string
	if t := q.Get("types"); t != "" {
		types = strings.Split(t, ",")
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	page, err := s.svc.Timeline(r.Context(), actorOf(r), id, types, q.Get("cursor"), limit)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, page)
}

func (s *Server) colonyDue(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	ov, err := s.svc.ColonyOverview(r.Context(), actorOf(r), id)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"due": ov.Due})
}

func (s *Server) repeatLastFeeding(w http.ResponseWriter, r *http.Request) {
	colony, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	var in struct {
		ID         uuid.UUID  `json:"id"`
		OccurredAt *time.Time `json:"occurred_at"`
	}
	if r.ContentLength != 0 {
		if err := decode(r, &in); err != nil {
			s.problem(w, r, err)
			return
		}
	}
	opID, err := opIDFromHeader(r)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	op := service.Op{Op: "create", Entity: "colony_events"}
	s.respondOp(w, r, op, func() (service.OpResult, error) {
		return s.svc.RepeatLastFeeding(r.Context(), actorOf(r), colony, opID, in.ID, in.OccurredAt)
	})
}

func (s *Server) dashboard(w http.ResponseWriter, r *http.Request) {
	d, err := s.svc.Dashboard(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, d)
}

func (s *Server) export(w http.ResponseWriter, r *http.Request) {
	ex, err := s.svc.Export(r.Context(), actorOf(r))
	if err != nil {
		s.problem(w, r, err)
		return
	}
	w.Header().Set("Content-Disposition", `attachment; filename="ant-colony-manager-export-`+time.Now().Format("2006-01-02")+`.json"`)
	s.writeJSON(w, http.StatusOK, ex)
}

// exportZip streams JSON + CSV tables (+ photos unless ?photos=0) as one ZIP.
func (s *Server) exportZip(w http.ResponseWriter, r *http.Request) {
	s.writeExportZip(w, r, actorOf(r), r.URL.Query().Get("photos") != "0")
}

func (s *Server) exportLink(w http.ResponseWriter, r *http.Request) {
	s.writeJSON(w, http.StatusOK, s.svc.ExportLink(actorOf(r), r.URL.Query().Get("photos") != "0"))
}

func (s *Server) exportDownload(w http.ResponseWriter, r *http.Request) {
	if ok, retry := s.limAnon.Allow(clientIP(r).String()); !ok {
		s.problem(w, r, service.RateLimited(retry))
		return
	}
	actor, photos, err := s.svc.ExportLinkActor(r.Context(), r.URL.Query())
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeExportZip(w, r, actor, photos)
}

func (s *Server) writeExportZip(w http.ResponseWriter, r *http.Request, actor service.Actor, photos bool) {
	// Many photos take longer than the server's normal write timeout.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(30 * time.Minute))
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", `attachment; filename="ant-colony-manager-export-`+time.Now().Format("2006-01-02")+`.zip"`)
	if err := s.svc.ExportZip(r.Context(), actor, w, photos); err != nil {
		// Headers are gone already; the truncated ZIP is detected by any unzip tool.
		s.log.Error("zip export failed", "err", err)
	}
}

// ---------------------------------------------------------------------------
// Members

func (s *Server) listMembers(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	list, err := s.svc.ListMembers(r.Context(), actorOf(r), id)
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"members": list})
}

func (s *Server) setMember(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	var in struct {
		Email string `json:"email"`
		Role  string `json:"role"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.SetMember(r.Context(), actorOf(r), id, in.Email, service.Role(in.Role)); err != nil {
		s.problem(w, r, err)
		return
	}
	s.listMembers(w, r)
}

func (s *Server) removeMember(w http.ResponseWriter, r *http.Request) {
	id, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	user, err := pathUUID(r, "userId")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	if err := s.svc.RemoveMember(r.Context(), actorOf(r), id, user); err != nil {
		s.problem(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// aiCount counts the ants on photos of a colony with the AI set up by the admin.
func (s *Server) aiCount(w http.ResponseWriter, r *http.Request) {
	colony, err := pathUUID(r, "id")
	if err != nil {
		s.problem(w, r, err)
		return
	}
	var in struct {
		PhotoIDs []uuid.UUID `json:"photo_ids"`
	}
	if err := decode(r, &in); err != nil {
		s.problem(w, r, err)
		return
	}
	res, err := s.svc.AICount(r.Context(), actorOf(r), colony, in.PhotoIDs, service.ClientMeta{IP: clientIP(r)})
	if err != nil {
		s.problem(w, r, err)
		return
	}
	s.writeJSON(w, http.StatusOK, res)
}

func (s *Server) aiInfo(w http.ResponseWriter, r *http.Request) {
	s.writeJSON(w, http.StatusOK, map[string]bool{"available": s.svc.AIAvailable(r.Context())})
}
