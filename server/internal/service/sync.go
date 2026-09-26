package service

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

const (
	MaxPushOps   = 100
	MaxPullLimit = 1000
)

type DeviceInfo struct {
	ID         uuid.UUID `json:"device_id"`
	Name       string    `json:"device_name"`
	Platform   string    `json:"platform"`
	AppVersion string    `json:"app_version"`
}

// RegisterDevice upserts the device for the actor. A device id owned by another
// user or a revoked device is refused.
func (s *Service) RegisterDevice(ctx context.Context, actor Actor, d DeviceInfo) error {
	if d.ID == uuid.Nil {
		return Invalid("device_id", "device_id is required")
	}
	switch d.Platform {
	case "":
		d.Platform = "android"
	case "android", "ios", "web":
	default:
		return Invalid("platform", "platform must be android, ios or web")
	}
	if d.Name == "" {
		d.Name = d.Platform
	}
	var owner uuid.UUID
	var revoked *time.Time
	err := s.Pool.QueryRow(ctx, `
		INSERT INTO devices (id, user_id, name, platform, app_version, last_sync_at)
		VALUES ($1, $2, left($3, 100), $4, left($5, 40), now())
		ON CONFLICT (id) DO UPDATE SET
			name = CASE WHEN devices.user_id = excluded.user_id THEN excluded.name ELSE devices.name END,
			app_version = CASE WHEN devices.user_id = excluded.user_id THEN excluded.app_version ELSE devices.app_version END,
			last_sync_at = CASE WHEN devices.user_id = excluded.user_id THEN now() ELSE devices.last_sync_at END
		RETURNING user_id, revoked_at`, d.ID, actor.UserID, d.Name, d.Platform, d.AppVersion).Scan(&owner, &revoked)
	if err != nil {
		return err
	}
	if owner != actor.UserID {
		return Conflict("device.id_conflict", "device id belongs to another account")
	}
	if revoked != nil {
		return &Problem{Status: http.StatusForbidden, Code: "device.revoked", Title: "this device was signed out – please log in again"}
	}
	return nil
}

type PushResult struct {
	Results   []OpResult `json:"results"`
	ServerSeq int64      `json:"server_seq"`
}

func (s *Service) Push(ctx context.Context, actor Actor, device DeviceInfo, ops []Op) (*PushResult, error) {
	if len(ops) > MaxPushOps {
		return nil, Invalid("ops", "at most %d ops per request", MaxPushOps)
	}
	if err := s.RegisterDevice(ctx, actor, device); err != nil {
		return nil, err
	}
	actor.DeviceID = device.ID
	results, err := s.ApplyOps(ctx, actor, ops)
	if err != nil {
		return nil, err
	}
	var seq int64
	if err := s.Pool.QueryRow(ctx, `SELECT value FROM sync_counter`).Scan(&seq); err != nil {
		return nil, err
	}
	return &PushResult{Results: results, ServerSeq: seq}, nil
}

type Change struct {
	Seq    int64           `json:"seq"`
	Entity string          `json:"entity"`
	Op     string          `json:"op"` // upsert | delete
	ID     uuid.UUID       `json:"id"`
	Data   json.RawMessage `json:"data,omitempty"`
}

type PullResult struct {
	Changes []Change `json:"changes"`
	Next    int64    `json:"next"`
	HasMore bool     `json:"has_more"`
}

var ErrResyncRequired = &Problem{Status: http.StatusGone, Code: "sync.resync_required",
	Title: "cursor is older than the tombstone horizon – run a full snapshot"}

func (s *Service) horizon(ctx context.Context, q db.Querier) (int64, error) {
	var h int64
	err := q.QueryRow(ctx, `SELECT COALESCE((SELECT (value #>> '{}')::bigint FROM instance_settings WHERE key = 'tombstone_horizon_seq'), 0)`).Scan(&h)
	return h, err
}

// Pull returns everything visible to the actor that changed after since.
func (s *Service) Pull(ctx context.Context, actor Actor, since int64, limit int) (*PullResult, error) {
	if limit <= 0 || limit > MaxPullLimit {
		limit = 500
	}
	res := &PullResult{Changes: []Change{}}
	err := db.InTxOpts(ctx, s.Pool, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		h, err := s.horizon(ctx, tx)
		if err != nil {
			return err
		}
		if h > 0 && since < h { // also since=0: history below the horizon is gone
			return ErrResyncRequired
		}
		var upper int64
		if err := tx.QueryRow(ctx, `SELECT value FROM sync_counter`).Scan(&upper); err != nil {
			return err
		}
		colonies, err := memberColonyIDs(ctx, tx, actor.UserID)
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `
			SELECT seq, entity, entity_id FROM change_log
			WHERE seq > $1 AND seq <= $2
			  AND (colony_id = ANY($3) OR owner_id = $4 OR (owner_id IS NULL AND colony_id IS NULL))
			ORDER BY seq LIMIT $5`, since, upper, colonies, actor.UserID, limit)
		if err != nil {
			return err
		}
		type key struct {
			entity string
			id     uuid.UUID
		}
		latest := map[key]int64{}
		n := 0
		var last int64
		for rows.Next() {
			var seq int64
			var k key
			if err := rows.Scan(&seq, &k.entity, &k.id); err != nil {
				rows.Close()
				return err
			}
			latest[k] = seq
			last = seq
			n++
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return err
		}
		byEntity := map[string][]uuid.UUID{}
		for k := range latest {
			byEntity[k.entity] = append(byEntity[k.entity], k.id)
		}
		rendered := map[key]json.RawMessage{}
		deleted := map[key]bool{}
		for ent, ids := range byEntity {
			if _, ok := entities[ent]; !ok {
				continue
			}
			rs, err := s.renderRows(ctx, tx, ent, "t.id = ANY($1)", ids)
			if err != nil {
				return err
			}
			for _, r := range rs {
				k := key{ent, r.id}
				if r.deleted {
					deleted[k] = true
				} else {
					rendered[k] = r.data
				}
			}
		}
		for k, seq := range latest {
			if _, ok := entities[k.entity]; !ok {
				continue
			}
			c := Change{Seq: seq, Entity: k.entity, ID: k.id, Op: "delete"}
			if data, ok := rendered[k]; ok && !deleted[k] {
				c.Op, c.Data = "upsert", data
			}
			res.Changes = append(res.Changes, c)
		}
		sort.Slice(res.Changes, func(i, j int) bool { return res.Changes[i].Seq < res.Changes[j].Seq })
		if n == limit {
			res.Next, res.HasMore = last, true
		} else {
			res.Next = upper
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if actor.DeviceID != uuid.Nil {
		_, _ = s.Pool.Exec(ctx, `UPDATE devices SET last_pull_seq = $1, last_sync_at = now() WHERE id = $2 AND user_id = $3`,
			res.Next, actor.DeviceID, actor.UserID)
	}
	return res, nil
}

type renderedRow struct {
	id      uuid.UUID
	deleted bool
	data    json.RawMessage
}

// renderRows returns client representations of rows of one entity matching
// where (with $1 as the only argument). Hidden columns are removed.
func (s *Service) renderRows(ctx context.Context, q db.Querier, ent, where string, arg any) ([]renderedRow, error) {
	e := entities[ent]
	ident := pgx.Identifier{ent}.Sanitize()
	expr := "to_jsonb(t)"
	for _, h := range e.Hidden {
		expr += " - '" + h + "'"
	}
	from := ident + " t"
	switch ent {
	case "colony_events":
		expr = "event_json(t.id)"
	case "colony_members":
		expr = "to_jsonb(t) || jsonb_build_object('display_name', u.display_name)"
		from += " JOIN users u ON u.id = t.user_id"
	}
	deleted := "false"
	if s.hasColumn(ent, "deleted_at") {
		deleted = "t.deleted_at IS NOT NULL"
	}
	rows, err := q.Query(ctx, fmt.Sprintf(`SELECT t.id, %s, %s FROM %s WHERE %s`, deleted, expr, from, where), arg)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []renderedRow
	for rows.Next() {
		var r renderedRow
		if err := rows.Scan(&r.id, &r.deleted, &r.data); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Render returns the current client representation of one row, or nil.
func (s *Service) Render(ctx context.Context, ent string, id uuid.UUID) (json.RawMessage, error) {
	rs, err := s.renderRows(ctx, s.Pool, ent, "t.id = $1", id)
	if err != nil || len(rs) == 0 {
		return nil, err
	}
	return rs[0].data, nil
}

type Snapshot struct {
	Cursor   int64                        `json:"cursor"`
	Entities map[string][]json.RawMessage `json:"entities"`
}

// Snapshot returns the complete current state visible to the actor. With
// onlyColonies it is limited to those colonies (e.g. after being invited).
func (s *Service) Snapshot(ctx context.Context, actor Actor, onlyColonies []uuid.UUID) (*Snapshot, error) {
	snap := &Snapshot{Entities: map[string][]json.RawMessage{}}
	err := db.InTxOpts(ctx, s.Pool, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT value FROM sync_counter`).Scan(&snap.Cursor); err != nil {
			return err
		}
		cols, err := memberColonyIDs(ctx, tx, actor.UserID)
		if err != nil {
			return err
		}
		if cols == nil {
			cols = []uuid.UUID{}
		}
		if onlyColonies != nil {
			allowed := map[uuid.UUID]bool{}
			for _, c := range cols {
				allowed[c] = true
			}
			cols = cols[:0]
			for _, c := range onlyColonies {
				if allowed[c] {
					cols = append(cols, c)
				}
			}
		}
		arg := map[string]any{"cols": cols, "user": actor.UserID}
		for _, ent := range sortedKeys(entities) {
			where, ok := s.snapshotWhere(ent, onlyColonies != nil)
			if !ok {
				continue
			}
			rs, err := s.renderRows(ctx, tx, ent, where, arg)
			if err != nil {
				return fmt.Errorf("snapshot %s: %w", ent, err)
			}
			list := make([]json.RawMessage, 0, len(rs))
			for _, r := range rs {
				list = append(list, r.data)
			}
			snap.Entities[ent] = list
		}
		return nil
	})
	return snap, err
}

// snapshotWhere builds a filter using $1 = {"cols": [...], "user": "..."}.
func (s *Service) snapshotWhere(ent string, colonyOnly bool) (string, bool) {
	e := entities[ent]
	cols := `t.%s = ANY(ARRAY(SELECT jsonb_array_elements_text($1::jsonb->'cols'))::uuid[])`
	user := `($1::jsonb->>'user')::uuid`
	alive := " AND t.deleted_at IS NULL"
	switch e.Scope {
	case scopeColonyRoot:
		return fmt.Sprintf(cols, "id") + alive, true
	case scopeColony:
		return fmt.Sprintf(cols, "colony_id") + alive, true
	case scopeSettings:
		if colonyOnly {
			return "", false
		}
		return "t.id = " + user, true
	case scopeOwner:
		var parts []string
		if s.hasColumn(ent, "colony_id") {
			parts = append(parts, fmt.Sprintf(cols, "colony_id"))
		}
		if !colonyOnly {
			parts = append(parts, "t.owner_id = "+user)
			if ent == "species" || ent == "food_items" {
				parts = append(parts, "t.owner_id IS NULL")
			}
		}
		if len(parts) == 0 {
			return "", false
		}
		return "(" + strings.Join(parts, " OR ") + ")" + alive, true
	}
	return "", false
}

// ---------------------------------------------------------------------------
// Conflicts

type SyncConflict struct {
	ID        uuid.UUID       `json:"id"`
	Entity    string          `json:"entity"`
	EntityID  uuid.UUID       `json:"entity_id"`
	Field     string          `json:"field"`
	LostValue json.RawMessage `json:"lost_value"`
	KeptValue json.RawMessage `json:"kept_value"`
	CreatedAt time.Time       `json:"created_at"`
}

func (s *Service) ListConflicts(ctx context.Context, actor Actor) ([]SyncConflict, error) {
	rows, err := s.Pool.Query(ctx, `SELECT id, entity, entity_id, field, COALESCE(lost_value, 'null'), COALESCE(kept_value, 'null'), created_at
		FROM sync_conflicts WHERE user_id = $1 AND dismissed_at IS NULL ORDER BY created_at DESC LIMIT 200`, actor.UserID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (SyncConflict, error) {
		var c SyncConflict
		err := r.Scan(&c.ID, &c.Entity, &c.EntityID, &c.Field, &c.LostValue, &c.KeptValue, &c.CreatedAt)
		return c, err
	})
}

func (s *Service) DismissConflict(ctx context.Context, actor Actor, id uuid.UUID) error {
	tag, err := s.Pool.Exec(ctx, `UPDATE sync_conflicts SET dismissed_at = now() WHERE id = $1 AND user_id = $2 AND dismissed_at IS NULL`, id, actor.UserID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return NotFound("conflict")
	}
	return nil
}
