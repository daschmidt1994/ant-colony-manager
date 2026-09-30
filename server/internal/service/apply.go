package service

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// Op is a single client change. OpID makes it idempotent.
type Op struct {
	OpID        uuid.UUID       `json:"op_id"`
	Entity      string          `json:"entity"`
	EntityID    uuid.UUID       `json:"entity_id"`
	Op          string          `json:"op"` // create | update | delete
	Payload     json.RawMessage `json:"payload,omitempty"`
	BaseVersion *int64          `json:"base_version,omitempty"`
	ClientTime  *time.Time      `json:"created_at,omitempty"`

	// AutoQR creates an active QR scan link together with a new colony (REST only).
	AutoQR bool `json:"-"`
}

const (
	StatusApplied   = "applied"
	StatusDuplicate = "duplicate"
	StatusMerged    = "merged"
	StatusRejected  = "rejected"
)

type OpResult struct {
	OpID      uuid.UUID      `json:"op_id"`
	EntityID  uuid.UUID      `json:"entity_id"`
	Status    string         `json:"status"`
	Version   int64          `json:"version,omitempty"`
	Conflicts []string       `json:"conflicts,omitempty"`
	Ignored   []string       `json:"ignored_fields,omitempty"`
	Error     *Problem       `json:"error,omitempty"`
	Extra     map[string]any `json:"extra,omitempty"` // e.g. one-time sensor API key (never stored)
}

// write carries the state of one operation through the pipeline and hooks.
type write struct {
	actor     Actor
	op        *Op
	table     string
	e         *entity
	id        uuid.UUID
	create    bool
	delete    bool
	raw       map[string]json.RawMessage // full payload
	data      map[string]json.RawMessage // columns to write
	current   map[string]any             // row before update/delete
	colonyID  uuid.UUID                  // colony of colony-scoped rows
	access    colonyAccess
	dataOwner uuid.UUID // owner of referenced master data (colony owner or actor)
	details   map[string]json.RawMessage
	result    *OpResult
}

// Keys clients commonly echo back; silently ignored.
var quietKeys = map[string]bool{"id": true, "version": true, "created_at": true, "updated_at": true,
	"deleted_at": true, "owner_id": true, "created_by": true, "updated_by": true,
	"server_version": true, "sync_state": true}

// ApplyOps applies a batch in order. Each op commits independently.
func (s *Service) ApplyOps(ctx context.Context, actor Actor, ops []Op) ([]OpResult, error) {
	out := make([]OpResult, 0, len(ops))
	for i := range ops {
		r, err := s.ApplyOp(ctx, actor, ops[i])
		if err != nil {
			return out, err
		}
		out = append(out, r)
	}
	return out, nil
}

// ApplyOp applies one operation exactly once. Problems caused by the client are
// returned as a rejected result (and remembered); internal errors are returned
// as error so the client retries.
func (s *Service) ApplyOp(ctx context.Context, actor Actor, op Op) (OpResult, error) {
	res := OpResult{OpID: op.OpID, EntityID: op.EntityID}
	if p := validateOp(&op); p != nil {
		res.Status, res.Error = StatusRejected, p
		return res, nil // not recorded: malformed ops have no reliable op_id
	}

	if prev, ok, err := s.storedResult(ctx, actor, op.OpID); err != nil {
		return res, err
	} else if ok {
		return prev, nil
	}

	w := &write{actor: actor, op: &op, table: op.Entity, e: entities[op.Entity], id: op.EntityID,
		create: op.Op == "create", delete: op.Op == "delete", result: &res}

	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		if err := s.applyInTx(ctx, tx, w); err != nil {
			return err
		}
		if res.Status == "" {
			res.Status = StatusApplied
		}
		return s.recordResult(ctx, tx, actor, &op, res)
	})
	if err == nil {
		s.mqttKick() // Home Assistant sees a new colony within seconds
		return res, nil
	}
	if db.PgCode(err) == db.CodeUniqueViolation && strings.Contains(err.Error(), "applied_ops") {
		// Same op_id applied concurrently – return the winner's result.
		if prev, ok, err2 := s.storedResult(ctx, actor, op.OpID); err2 == nil && ok {
			return prev, nil
		}
	}
	p, isProblem := AsProblem(problemFromDB(err))
	if !isProblem {
		return res, err
	}
	res = OpResult{OpID: op.OpID, EntityID: op.EntityID, Status: StatusRejected, Error: p}
	if err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error { return s.recordResult(ctx, tx, actor, &op, res) }); err != nil &&
		db.PgCode(err) != db.CodeUniqueViolation {
		return res, err
	}
	return res, nil
}

func validateOp(op *Op) *Problem {
	if op.OpID == uuid.Nil {
		return Invalid("op_id", "op_id is required")
	}
	if op.EntityID == uuid.Nil {
		return Invalid("entity_id", "entity_id is required")
	}
	e, ok := entities[op.Entity]
	if !ok || e.ReadOnly {
		return Invalid("entity", "unknown or read-only entity %q", op.Entity)
	}
	switch op.Op {
	case "create", "update":
		if len(bytes.TrimSpace(op.Payload)) == 0 || bytes.TrimSpace(op.Payload)[0] != '{' {
			return Invalid("payload", "payload must be a JSON object")
		}
	case "delete":
	default:
		return Invalid("op", "op must be create, update or delete")
	}
	return nil
}

func (s *Service) storedResult(ctx context.Context, actor Actor, opID uuid.UUID) (OpResult, bool, error) {
	var user uuid.UUID
	var raw []byte
	err := s.Pool.QueryRow(ctx, `SELECT user_id, result FROM applied_ops WHERE op_id = $1`, opID).Scan(&user, &raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return OpResult{}, false, nil
	}
	if err != nil {
		return OpResult{}, false, err
	}
	var r OpResult
	if user != actor.UserID {
		return OpResult{OpID: opID, Status: StatusRejected, Error: Conflict("op.id_conflict", "op_id already used")}, true, nil
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return OpResult{}, false, err
	}
	if r.Status != StatusRejected {
		r.Status = StatusDuplicate
	}
	r.Extra = nil // one-time secrets are never replayed
	return r, true, nil
}

func (s *Service) recordResult(ctx context.Context, q db.Querier, actor Actor, op *Op, r OpResult) error {
	stored := r
	stored.Extra = nil
	b, err := json.Marshal(stored)
	if err != nil {
		return err
	}
	_, err = q.Exec(ctx, `INSERT INTO applied_ops (op_id, user_id, device_id, entity, entity_id, result)
		VALUES ($1, $2, $3, $4, $5, $6)`, op.OpID, actor.UserID, actor.DeviceID, op.Entity, op.EntityID, b)
	return err
}

// ---------------------------------------------------------------------------

func (s *Service) applyInTx(ctx context.Context, tx pgx.Tx, w *write) error {
	if !w.delete {
		if err := json.Unmarshal(w.op.Payload, &w.raw); err != nil {
			return Invalid("payload", "payload is not valid JSON")
		}
		if err := s.filterPayload(w); err != nil {
			return err
		}
	}
	switch {
	case w.create:
		return s.applyCreate(ctx, tx, w)
	case w.delete:
		return s.applyDelete(ctx, tx, w)
	default:
		return s.applyUpdate(ctx, tx, w)
	}
}

func (s *Service) filterPayload(w *write) error {
	w.data = map[string]json.RawMessage{}
	for k, v := range w.raw {
		switch {
		case slices.Contains(w.e.Fields, k):
			if slices.Contains(w.e.HexBytea, k) {
				conv, err := hexToBytea(k, v)
				if err != nil {
					return err
				}
				v = conv
			}
			w.data[k] = v
		case w.table == "colony_events" && eventDetailKeys[k]:
			// handled by event hooks
		case quietKeys[k]:
		default:
			w.result.Ignored = append(w.result.Ignored, k)
		}
	}
	sort.Strings(w.result.Ignored)
	return nil
}

func hexToBytea(field string, v json.RawMessage) (json.RawMessage, error) {
	if string(v) == "null" {
		return v, nil
	}
	var s string
	if err := json.Unmarshal(v, &s); err != nil {
		return nil, Invalid(field, "%s must be a hex string", field)
	}
	s = strings.TrimPrefix(strings.ToLower(s), "\\x")
	if _, err := hex.DecodeString(s); err != nil {
		return nil, Invalid(field, "%s must be a hex string", field)
	}
	return json.Marshal(`\x` + s)
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

func (w *write) set(col string, v any) { w.data[col] = mustJSON(v) }

// uuidField reads a UUID from data (or current row as fallback).
func (w *write) uuidField(col string) (uuid.UUID, bool, error) {
	if v, ok := w.data[col]; ok {
		if string(v) == "null" {
			return uuid.Nil, false, nil
		}
		var id uuid.UUID
		if err := json.Unmarshal(v, &id); err != nil {
			return uuid.Nil, false, Invalid(col, "%s must be a UUID", col)
		}
		return id, true, nil
	}
	if w.current != nil {
		if s, ok := w.current[col].(string); ok {
			id, err := uuid.Parse(s)
			return id, err == nil, nil
		}
	}
	return uuid.Nil, false, nil
}

func (s *Service) applyCreate(ctx context.Context, tx pgx.Tx, w *write) error {
	a := w.actor
	switch w.e.Scope {
	case scopeColonyRoot:
		w.dataOwner = a.UserID
		w.colonyID = w.id
		w.set("owner_id", a.UserID)
	case scopeColony:
		cid, ok, err := w.uuidField("colony_id")
		if err != nil {
			return err
		}
		if !ok {
			return Invalid("colony_id", "colony_id is required")
		}
		acc, err := requireColony(ctx, tx, a, cid, RoleEditor)
		if err != nil {
			return err
		}
		w.colonyID, w.access, w.dataOwner = cid, acc, acc.OwnerID
		if s.hasColumn(w.table, "owner_id") {
			w.set("owner_id", acc.OwnerID)
		}
	case scopeOwner:
		w.dataOwner = a.UserID
		w.set("owner_id", a.UserID)
	case scopeSettings:
		return Invalid("op", "settings can only be updated")
	}
	w.set("id", w.id)
	if s.hasColumn(w.table, "created_by") {
		w.set("created_by", a.UserID)
	}
	if s.hasColumn(w.table, "updated_by") {
		w.set("updated_by", a.UserID)
	}
	if w.e.beforeWrite != nil {
		if err := w.e.beforeWrite(ctx, s, tx, w); err != nil {
			return err
		}
	}
	if err := s.checkRefs(ctx, tx, w); err != nil {
		return err
	}

	cols := sortedKeys(w.data)
	ident := pgx.Identifier{w.table}.Sanitize()
	colList, selList := columnLists(cols, "r")
	sql := fmt.Sprintf(`INSERT INTO %s (%s) SELECT %s FROM jsonb_populate_record(NULL::%s, $1::jsonb) r
		ON CONFLICT (id) DO NOTHING RETURNING version`, ident, colList, selList, ident)
	var version int64
	err := tx.QueryRow(ctx, sql, dataJSON(w.data)).Scan(&version)
	if errors.Is(err, pgx.ErrNoRows) {
		// ID exists already: a retry with a new op_id (e.g. after reinstall) or a real clash.
		return s.existingOnCreate(ctx, tx, w)
	}
	if err != nil {
		return err
	}
	if w.e.afterWrite != nil {
		if err := w.e.afterWrite(ctx, s, tx, w); err != nil {
			return err
		}
	}
	return s.finishVersion(ctx, tx, w)
}

func (s *Service) existingOnCreate(ctx context.Context, tx pgx.Tx, w *write) error {
	cur, err := s.loadRow(ctx, tx, w.table, w.id, false)
	if err != nil {
		return err
	}
	if cur == nil || !s.canSeeRow(ctx, tx, w.actor, w.e, cur) {
		return Conflict("entity.id_conflict", "id already in use")
	}
	w.result.Status = StatusDuplicate
	w.result.Version = int64(cur["version"].(float64))
	return nil
}

func (s *Service) canSeeRow(ctx context.Context, q db.Querier, actor Actor, e *entity, row map[string]any) bool {
	switch e.Scope {
	case scopeOwner, scopeSettings:
		return row["owner_id"] == actor.UserID.String()
	case scopeColonyRoot, scopeColony:
		col := "colony_id"
		if e.Scope == scopeColonyRoot {
			col = "id"
		}
		cid, err := uuid.Parse(fmt.Sprint(row[col]))
		if err != nil {
			return false
		}
		acc, err := colonyRole(ctx, q, actor.UserID, cid)
		return err == nil && acc.Role != RoleNone
	}
	return false
}

// authorizeExisting checks access to an existing row for update/delete.
func (s *Service) authorizeExisting(ctx context.Context, q db.Querier, w *write, min Role) error {
	switch w.e.Scope {
	case scopeColonyRoot, scopeColony:
		col := "colony_id"
		if w.e.Scope == scopeColonyRoot {
			col = "id"
		}
		cid, err := uuid.Parse(fmt.Sprint(w.current[col]))
		if err != nil {
			return NotFound("entity")
		}
		acc, err := colonyRole(ctx, q, w.actor.UserID, cid)
		if err != nil {
			return err
		}
		if acc.Role == RoleNone {
			return NotFound("entity")
		}
		if !acc.Role.AtLeast(min) {
			return ErrForbidden
		}
		w.colonyID, w.access, w.dataOwner = cid, acc, acc.OwnerID
	case scopeOwner, scopeSettings:
		if w.current["owner_id"] != w.actor.UserID.String() {
			return NotFound("entity")
		}
		w.dataOwner = w.actor.UserID
	}
	return nil
}

func (s *Service) applyUpdate(ctx context.Context, tx pgx.Tx, w *write) error {
	cur, err := s.loadRow(ctx, tx, w.table, w.id, true)
	if err != nil {
		return err
	}
	if cur == nil {
		return NotFound("entity")
	}
	w.current = cur
	if err := s.authorizeExisting(ctx, tx, w, RoleEditor); err != nil {
		return err
	}
	curVersion := int64(cur["version"].(float64))
	if cur["deleted_at"] != nil {
		s.recordConflicts(ctx, tx, w, fieldsOf(w.data), "client")
		return ErrGone
	}
	for _, f := range w.e.Immutable {
		if _, ok := w.data[f]; ok {
			delete(w.data, f)
			w.result.Ignored = append(w.result.Ignored, f)
		}
	}
	if w.access.Role != RoleOwner && w.e.Scope != scopeOwner {
		for _, f := range w.e.OwnerOnly {
			if _, ok := w.data[f]; ok {
				return ErrForbidden
			}
		}
	}
	if w.e.beforeWrite != nil {
		if err := w.e.beforeWrite(ctx, s, tx, w); err != nil {
			return err
		}
	}
	if w.op.BaseVersion != nil && *w.op.BaseVersion < curVersion {
		if err := s.resolveConflicts(ctx, tx, w, *w.op.BaseVersion); err != nil {
			return err
		}
	}
	if err := s.checkRefs(ctx, tx, w); err != nil {
		return err
	}
	if len(w.data) > 0 {
		if s.hasColumn(w.table, "updated_by") {
			w.set("updated_by", w.actor.UserID)
		}
		cols := sortedKeys(w.data)
		sets := make([]string, len(cols))
		for i, c := range cols {
			q := pgx.Identifier{c}.Sanitize()
			sets[i] = q + " = r." + q
		}
		ident := pgx.Identifier{w.table}.Sanitize()
		sql := fmt.Sprintf(`UPDATE %s t SET %s FROM jsonb_populate_record(NULL::%s, $1::jsonb) r WHERE t.id = $2`,
			ident, strings.Join(sets, ", "), ident)
		if _, err := tx.Exec(ctx, sql, dataJSON(w.data), w.id); err != nil {
			return err
		}
	}
	if w.e.afterWrite != nil {
		if err := w.e.afterWrite(ctx, s, tx, w); err != nil {
			return err
		}
	}
	return s.finishVersion(ctx, tx, w)
}

func (s *Service) applyDelete(ctx context.Context, tx pgx.Tx, w *write) error {
	cur, err := s.loadRow(ctx, tx, w.table, w.id, true)
	if err != nil {
		return err
	}
	if cur == nil {
		return NotFound("entity")
	}
	w.current = cur
	min := w.e.DeleteRole
	if min == RoleNone {
		min = RoleEditor
	}
	if err := s.authorizeExisting(ctx, tx, w, min); err != nil {
		return err
	}
	// Editors may only delete their own events.
	if w.table == "colony_events" && w.access.Role == RoleEditor && cur["created_by"] != w.actor.UserID.String() {
		return ErrForbidden
	}
	if cur["deleted_at"] != nil {
		w.result.Status = StatusDuplicate
		w.result.Version = int64(cur["version"].(float64))
		return nil
	}
	ident := pgx.Identifier{w.table}.Sanitize()
	var err2 error
	if s.hasColumn(w.table, "updated_by") {
		_, err2 = tx.Exec(ctx, fmt.Sprintf(`UPDATE %s SET deleted_at = now(), updated_by = $2 WHERE id = $1`, ident), w.id, w.actor.UserID)
	} else {
		_, err2 = tx.Exec(ctx, fmt.Sprintf(`UPDATE %s SET deleted_at = now() WHERE id = $1`, ident), w.id)
	}
	if err2 != nil {
		return err2
	}
	if w.e.afterWrite != nil {
		if err := w.e.afterWrite(ctx, s, tx, w); err != nil {
			return err
		}
	}
	return s.finishVersion(ctx, tx, w)
}

func (s *Service) finishVersion(ctx context.Context, q db.Querier, w *write) error {
	return q.QueryRow(ctx, fmt.Sprintf(`SELECT version FROM %s WHERE id = $1`, pgx.Identifier{w.table}.Sanitize()), w.id).
		Scan(&w.result.Version)
}

// loadRow returns the row as a JSON map (numbers as float64) or nil.
func (s *Service) loadRow(ctx context.Context, q db.Querier, table string, id uuid.UUID, forUpdate bool) (map[string]any, error) {
	ident := pgx.Identifier{table}.Sanitize()
	sql := fmt.Sprintf(`SELECT to_jsonb(t) FROM %s t WHERE id = $1`, ident)
	if forUpdate {
		sql += " FOR UPDATE"
	}
	var raw []byte
	err := q.QueryRow(ctx, sql, id).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var m map[string]any
	return m, json.Unmarshal(raw, &m)
}

// ---------------------------------------------------------------------------
// Conflicts

// resolveConflicts compares the patch with fields changed on the server since
// base. Non-overlapping changes merge; overlapping fields use last-writer-wins
// by edit time, and the losing value is kept in sync_conflicts.
func (s *Service) resolveConflicts(ctx context.Context, tx pgx.Tx, w *write, base int64) error {
	rows, err := tx.Query(ctx, `SELECT changed_fields, changed_at FROM change_log
		WHERE entity = $1 AND entity_id = $2 AND seq > $3 ORDER BY seq`, w.table, w.id, base)
	if err != nil {
		return err
	}
	serverChanged := map[string]time.Time{}
	for rows.Next() {
		var fields []string
		var at time.Time
		if err := rows.Scan(&fields, &at); err != nil {
			rows.Close()
			return err
		}
		for _, f := range fields {
			serverChanged[f] = at
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	w.result.Status = StatusMerged
	var serverWins, clientWins []string
	for _, f := range sortedKeys(w.data) {
		at, clash := serverChanged[f]
		if !clash || f == "updated_by" {
			continue
		}
		w.result.Conflicts = append(w.result.Conflicts, f)
		if w.op.ClientTime != nil && w.op.ClientTime.Before(at) {
			serverWins = append(serverWins, f)
		} else {
			clientWins = append(clientWins, f)
		}
	}
	s.recordConflicts(ctx, tx, w, clientWins, "server")
	s.recordConflicts(ctx, tx, w, serverWins, "client")
	for _, f := range serverWins {
		delete(w.data, f)
		if f == "details_rev" {
			w.details = nil
		}
	}
	return nil
}

// recordConflicts stores the losing values. loser is "server" (current row value
// overwritten) or "client" (patch value discarded).
func (s *Service) recordConflicts(ctx context.Context, q db.Querier, w *write, fields []string, loser string) {
	for _, f := range fields {
		clientVal := w.data[f]
		serverVal := mustJSON(w.current[f])
		lost, kept := serverVal, clientVal
		var lostDevice any
		if loser == "client" {
			lost, kept = clientVal, serverVal
			if w.actor.DeviceID != uuid.Nil {
				lostDevice = w.actor.DeviceID
			}
		}
		if _, err := q.Exec(ctx, `INSERT INTO sync_conflicts (user_id, entity, entity_id, field, lost_value, kept_value, lost_device)
			VALUES ($1, $2, $3, $4, $5, $6, $7)`, w.actor.UserID, w.table, w.id, f, []byte(lost), []byte(kept), lostDevice); err != nil {
			s.Log.Warn("record conflict failed", "err", err)
		}
	}
}

func fieldsOf(m map[string]json.RawMessage) []string { return sortedKeys(m) }

// ---------------------------------------------------------------------------
// References

func (s *Service) checkRefs(ctx context.Context, q db.Querier, w *write) error {
	for _, r := range w.e.Refs {
		if _, present := w.data[r.Field]; !present {
			continue
		}
		id, ok, err := w.uuidField(r.Field)
		if err != nil {
			return err
		}
		if !ok {
			continue
		}
		if err := s.checkRef(ctx, q, w, r, id); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) checkRef(ctx context.Context, q db.Querier, w *write, r ref, id uuid.UUID) error {
	var sql string
	var args []any
	switch r.Kind {
	case refLocation:
		sql, args = `SELECT EXISTS (SELECT 1 FROM locations WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL)`, []any{id, w.dataOwner}
	case refSpecies:
		sql, args = `SELECT EXISTS (SELECT 1 FROM species WHERE id = $1 AND (owner_id IS NULL OR owner_id = $2) AND deleted_at IS NULL)`, []any{id, w.dataOwner}
	case refFoodItem:
		sql, args = `SELECT EXISTS (SELECT 1 FROM food_items WHERE id = $1 AND (owner_id IS NULL OR owner_id = $2) AND deleted_at IS NULL)`, []any{id, w.dataOwner}
	case refHabitat:
		sql, args = `SELECT EXISTS (SELECT 1 FROM habitats WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL)`, []any{id, w.dataOwner}
	case refCareRound:
		sql, args = `SELECT EXISTS (SELECT 1 FROM care_rounds WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL)`, []any{id, w.actor.UserID}
	case refColonyEditor, refColonyOwned:
		min := RoleEditor
		if r.Kind == refColonyOwned {
			min = RoleOwner
		}
		acc, err := colonyRole(ctx, q, w.actor.UserID, id)
		if err != nil {
			return err
		}
		if !acc.Role.AtLeast(min) || acc.Deleted {
			return Invalid(r.Field, "referenced colony not found")
		}
		return nil
	case refSameColonyQueen, refSameColonyEvent, refSameColonySchedule, refSameColonyWinter, refSameColonyScanLink:
		table := map[refKind]string{refSameColonyQueen: "queens", refSameColonyEvent: "colony_events",
			refSameColonySchedule: "care_schedules", refSameColonyWinter: "winter_rests",
			refSameColonyScanLink: "scan_links"}[r.Kind]
		sql = fmt.Sprintf(`SELECT EXISTS (SELECT 1 FROM %s WHERE id = $1 AND colony_id = $2 AND deleted_at IS NULL)`, table)
		args = []any{id, w.colonyID}
	}
	var ok bool
	if err := q.QueryRow(ctx, sql, args...).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return Invalid(r.Field, "referenced record not found")
	}
	return nil
}

// ---------------------------------------------------------------------------

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func columnLists(cols []string, alias string) (string, string) {
	a := make([]string, len(cols))
	b := make([]string, len(cols))
	for i, c := range cols {
		q := pgx.Identifier{c}.Sanitize()
		a[i] = q
		b[i] = alias + "." + q
	}
	return strings.Join(a, ", "), strings.Join(b, ", ")
}

func dataJSON(m map[string]json.RawMessage) []byte {
	b, _ := json.Marshal(m)
	return b
}
