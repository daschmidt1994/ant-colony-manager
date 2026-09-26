package service

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/google/uuid"
)

// ListEntities returns all visible, non-deleted rows of an entity, optionally
// limited to one colony.
func (s *Service) ListEntities(ctx context.Context, actor Actor, table string, colony *uuid.UUID) ([]json.RawMessage, error) {
	e, ok := entities[table]
	if !ok {
		return nil, NotFound("collection")
	}
	if table == "colony_events" {
		return nil, &Problem{Status: http.StatusBadRequest, Code: "events.use_timeline",
			Title: "list events via /api/v1/colonies/{id}/timeline"}
	}
	var where string
	arg := map[string]any{"user": actor.UserID}
	if colony != nil {
		if _, err := requireColony(ctx, s.Pool, actor, *colony, RoleViewer); err != nil {
			return nil, err
		}
		col := "colony_id"
		switch {
		case e.Scope == scopeColonyRoot:
			col = "id"
		case !s.hasColumn(table, "colony_id"):
			return nil, Invalid("colony_id", "this collection cannot be filtered by colony")
		}
		arg["colony"] = *colony
		where = "t." + col + " = ($1::jsonb->>'colony')::uuid AND t.deleted_at IS NULL"
	} else {
		cols, err := memberColonyIDs(ctx, s.Pool, actor.UserID)
		if err != nil {
			return nil, err
		}
		if cols == nil {
			cols = []uuid.UUID{}
		}
		arg["cols"] = cols
		where, _ = s.snapshotWhere(table, false)
	}
	rows, err := s.renderRows(ctx, s.Pool, table, where, arg)
	if err != nil {
		return nil, err
	}
	out := make([]json.RawMessage, 0, len(rows))
	for _, r := range rows {
		out = append(out, r.data)
	}
	return out, nil
}

// GetEntity returns one visible row (deleted rows are 410).
func (s *Service) GetEntity(ctx context.Context, actor Actor, table string, id uuid.UUID) (json.RawMessage, error) {
	e, ok := entities[table]
	if !ok {
		return nil, NotFound("collection")
	}
	row, err := s.loadRow(ctx, s.Pool, table, id, false)
	if err != nil {
		return nil, err
	}
	if row == nil || !s.canSeeRow(ctx, s.Pool, actor, e, row) {
		if !(e.Scope == scopeOwner && row != nil && row["owner_id"] == nil && (table == "species" || table == "food_items")) {
			return nil, NotFound("entity")
		}
	}
	if row["deleted_at"] != nil {
		return nil, ErrGone
	}
	return s.Render(ctx, table, id)
}
