package service

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// ---------------------------------------------------------------------------
// Colony list

type ColonyFilter struct {
	Q          string
	Status     []string
	LocationID *uuid.UUID
	SpeciesID  *uuid.UUID
	Genus      string
	Due        string // overdue | today | feeding | water | cleaning
	Archived   bool
	SizeMin    *int
	Sort       string // urgency (default) | name | number | species | location
}

type ColonySummary struct {
	Colony json.RawMessage `json:"colony"`
	Due    []DueTask       `json:"due"`
	Status string          `json:"status"` // worst traffic light
}

const colonySelect = `
	SELECT c.id, to_jsonb(c) || jsonb_build_object(
		'species_name', sp.scientific_name, 'genus', sp.genus, 'german_name', sp.german_name,
		'location_path', l.path, 'role', m.role),
		c.name, c.number, COALESCE(sp.scientific_name, c.species_text, ''), COALESCE(l.path, '')
	FROM colonies c
	JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $1 AND m.deleted_at IS NULL
	LEFT JOIN species sp ON sp.id = c.species_id
	LEFT JOIN locations l ON l.id = c.location_id`

func likeEscape(s string) string {
	return "%" + strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s) + "%"
}

func (s *Service) ListColonies(ctx context.Context, actor Actor, f ColonyFilter) ([]ColonySummary, error) {
	where := []string{"c.deleted_at IS NULL"}
	args := []any{actor.UserID}
	arg := func(v any) string { args = append(args, v); return "$" + strconv.Itoa(len(args)) }

	if f.Archived {
		where = append(where, "c.archived_at IS NOT NULL")
	} else {
		where = append(where, "c.archived_at IS NULL")
	}
	if q := strings.TrimSpace(f.Q); q != "" {
		like := arg(likeEscape(q))
		num := strings.TrimPrefix(q, "#")
		cond := fmt.Sprintf(`(c.name ILIKE %[1]s OR sp.scientific_name ILIKE %[1]s OR sp.genus ILIKE %[1]s
			OR sp.german_name ILIKE %[1]s OR c.species_text ILIKE %[1]s OR c.internal_code ILIKE %[1]s OR l.path ILIKE %[1]s`, like)
		if n, err := strconv.Atoi(num); err == nil {
			cond += " OR c.number = " + arg(n)
		}
		where = append(where, cond+")")
	}
	if len(f.Status) > 0 {
		where = append(where, "c.status = ANY("+arg(f.Status)+")")
	}
	if f.LocationID != nil {
		p := arg(*f.LocationID)
		where = append(where, fmt.Sprintf(`c.location_id IN (
			SELECT x.id FROM locations x, locations root
			WHERE root.id = %s AND root.owner_id = $1 AND x.owner_id = $1 AND x.deleted_at IS NULL
			  AND (x.id = root.id OR x.path LIKE root.path || '/%%'))`, p))
	}
	if f.SpeciesID != nil {
		where = append(where, "c.species_id = "+arg(*f.SpeciesID))
	}
	if f.Genus != "" {
		where = append(where, "lower(sp.genus) = lower("+arg(f.Genus)+")")
	}
	if f.SizeMin != nil {
		where = append(where, "COALESCE(c.worker_estimate_max, c.worker_estimate_min) >= "+arg(*f.SizeMin))
	}

	sql := colonySelect + " WHERE " + strings.Join(where, " AND ") + " LIMIT 5000"
	rows, err := s.Pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	type row struct {
		id                uuid.UUID
		data              json.RawMessage
		name              string
		number            int
		species, location string
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (row, error) {
		var x row
		err := r.Scan(&x.id, &x.data, &x.name, &x.number, &x.species, &x.location)
		return x, err
	})
	if err != nil {
		return nil, err
	}
	ids := make([]uuid.UUID, len(list))
	for i, x := range list {
		ids[i] = x.id
	}
	prefs := s.userPrefs(ctx, s.Pool, actor.UserID)
	due, err := s.dueFor(ctx, s.Pool, prefs, ids)
	if err != nil {
		return nil, err
	}

	out := make([]ColonySummary, 0, len(list))
	meta := map[int]row{}
	for _, x := range list {
		tasks := due[x.id]
		if !matchesDueFilter(tasks, f.Due) {
			continue
		}
		st := DueOK
		if w := worst(tasks); w != nil {
			st = w.Status
		} else if len(tasks) > 0 {
			st = DuePaused
		}
		if tasks == nil {
			tasks = []DueTask{}
		}
		meta[len(out)] = x
		out = append(out, ColonySummary{Colony: x.data, Due: tasks, Status: st})
	}
	idx := make([]int, len(out))
	for i := range idx {
		idx[i] = i
	}
	urgency := func(i int) int {
		if w := worst(out[i].Due); w != nil {
			return w.Days
		}
		return 1 << 20
	}
	sort.SliceStable(idx, func(a, b int) bool {
		ma, mb := meta[idx[a]], meta[idx[b]]
		switch f.Sort {
		case "name":
			return strings.ToLower(ma.name) < strings.ToLower(mb.name)
		case "number":
			return ma.number < mb.number
		case "species":
			return ma.species < mb.species
		case "location":
			return ma.location < mb.location
		default:
			ua, ub := urgency(idx[a]), urgency(idx[b])
			if ua != ub {
				return ua < ub
			}
			return ma.number < mb.number
		}
	})
	sorted := make([]ColonySummary, len(out))
	for i, j := range idx {
		sorted[i] = out[j]
	}
	return sorted, nil
}

var dueFilterTypes = map[string][]string{
	"feeding":  {"feeding", "protein", "carbohydrate"},
	"water":    {"water"},
	"cleaning": {"cleaning"},
}

func matchesDueFilter(tasks []DueTask, filter string) bool {
	if filter == "" {
		return true
	}
	for _, t := range tasks {
		switch filter {
		case "overdue":
			if t.Status == DueOverdue {
				return true
			}
		case "today":
			if t.Status != DuePaused && t.Days <= 0 {
				return true
			}
		default:
			if contains(dueFilterTypes[filter], t.TaskType) && (t.Status == DueOverdue || t.Status == DueSoon) {
				return true
			}
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Colony overview (the colony start page)

type ColonyOverview struct {
	Colony      json.RawMessage   `json:"colony"`
	Due         []DueTask         `json:"due"`
	LastFeeding json.RawMessage   `json:"last_feeding"`
	ScanLinks   []json.RawMessage `json:"scan_links"`
	Timeline    []json.RawMessage `json:"timeline"`
	WinterRest  json.RawMessage   `json:"winter_rest"`
}

func (s *Service) ColonyOverview(ctx context.Context, actor Actor, id uuid.UUID) (*ColonyOverview, error) {
	if _, err := requireColony(ctx, s.Pool, actor, id, RoleViewer); err != nil {
		return nil, err
	}
	ov := &ColonyOverview{}
	var name, species, loc string
	var number int
	var cid uuid.UUID
	if err := s.Pool.QueryRow(ctx, colonySelect+" WHERE c.id = $2", actor.UserID, id).
		Scan(&cid, &ov.Colony, &name, &number, &species, &loc); err != nil {
		return nil, err
	}
	due, err := s.dueFor(ctx, s.Pool, s.userPrefs(ctx, s.Pool, actor.UserID), []uuid.UUID{id})
	if err != nil {
		return nil, err
	}
	ov.Due = due[id]
	if ov.Due == nil {
		ov.Due = []DueTask{}
	}
	err = s.Pool.QueryRow(ctx, `SELECT event_json(id) FROM colony_events WHERE colony_id = $1 AND type = 'feeding'
		AND deleted_at IS NULL ORDER BY occurred_at DESC, id DESC LIMIT 1`, id).Scan(&ov.LastFeeding)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	err = s.Pool.QueryRow(ctx, `SELECT to_jsonb(w) FROM winter_rests w WHERE colony_id = $1 AND ended_on IS NULL
		AND deleted_at IS NULL ORDER BY started_on DESC LIMIT 1`, id).Scan(&ov.WinterRest)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	if ov.ScanLinks, err = s.jsonList(ctx, `SELECT to_jsonb(t) FROM scan_links t WHERE colony_id = $1 AND deleted_at IS NULL
		ORDER BY active DESC, created_at DESC`, id); err != nil {
		return nil, err
	}
	page, err := s.Timeline(ctx, actor, id, nil, "", 10)
	if err != nil {
		return nil, err
	}
	ov.Timeline = page.Events
	return ov, nil
}

func (s *Service) jsonList(ctx context.Context, sql string, args ...any) ([]json.RawMessage, error) {
	rows, err := s.Pool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, pgx.RowTo[json.RawMessage])
	if list == nil {
		list = []json.RawMessage{}
	}
	return list, err
}

// ---------------------------------------------------------------------------
// Timeline

type TimelinePage struct {
	Events []json.RawMessage `json:"events"`
	Next   string            `json:"next,omitempty"`
}

func encodeCursor(t time.Time, id uuid.UUID) string {
	return base64.RawURLEncoding.EncodeToString([]byte(t.UTC().Format(time.RFC3339Nano) + "|" + id.String()))
}

func decodeCursor(c string) (time.Time, uuid.UUID, error) {
	b, err := base64.RawURLEncoding.DecodeString(c)
	if err != nil {
		return time.Time{}, uuid.Nil, err
	}
	ts, idStr, ok := strings.Cut(string(b), "|")
	if !ok {
		return time.Time{}, uuid.Nil, errors.New("bad cursor")
	}
	t, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		return time.Time{}, uuid.Nil, err
	}
	id, err := uuid.Parse(idStr)
	return t, id, err
}

func (s *Service) Timeline(ctx context.Context, actor Actor, colony uuid.UUID, types []string, cursor string, limit int) (*TimelinePage, error) {
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleViewer); err != nil {
		return nil, err
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	args := []any{colony, limit + 1}
	where := "colony_id = $1 AND deleted_at IS NULL"
	if len(types) > 0 {
		args = append(args, types)
		where += " AND type = ANY($3)"
	}
	if cursor != "" {
		t, id, err := decodeCursor(cursor)
		if err != nil {
			return nil, Invalid("cursor", "invalid cursor")
		}
		args = append(args, t, id)
		where += fmt.Sprintf(" AND (occurred_at, id) < ($%d, $%d)", len(args)-1, len(args))
	}
	rows, err := s.Pool.Query(ctx, `SELECT event_json(id), occurred_at, id FROM colony_events WHERE `+where+
		` ORDER BY occurred_at DESC, id DESC LIMIT $2`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	page := &TimelinePage{Events: []json.RawMessage{}}
	var lastT time.Time
	var lastID uuid.UUID
	for rows.Next() {
		var ev json.RawMessage
		if err := rows.Scan(&ev, &lastT, &lastID); err != nil {
			return nil, err
		}
		if len(page.Events) == limit {
			// one extra row fetched → there is a next page
			page.Next = encodeCursorFromLast(page)
			break
		}
		page.Events = append(page.Events, ev)
	}
	return page, rows.Err()
}

func encodeCursorFromLast(p *TimelinePage) string {
	var last struct {
		ID         uuid.UUID `json:"id"`
		OccurredAt time.Time `json:"occurred_at"`
	}
	_ = json.Unmarshal(p.Events[len(p.Events)-1], &last)
	return encodeCursor(last.OccurredAt, last.ID)
}

// ---------------------------------------------------------------------------
// Dashboard

type DashboardColony struct {
	ID       uuid.UUID `json:"id"`
	Name     string    `json:"name"`
	Number   int       `json:"number"`
	Species  string    `json:"species"`
	Location *string   `json:"location_path"`
	Status   string    `json:"status"`
	Tasks    []DueTask `json:"tasks"`
}

type Dashboard struct {
	Counts         map[string]int               `json:"counts"`
	NeedsAttention int                          `json:"needs_attention"`
	Groups         map[string][]DashboardColony `json:"groups"`
	Hibernating    []HibernatingColony          `json:"hibernating"`
	Problems       []json.RawMessage            `json:"problems"`
	OpenConflicts  int                          `json:"open_conflicts"`
	Recent         []json.RawMessage            `json:"recent"`
}

type HibernatingColony struct {
	ID        uuid.UUID `json:"id"`
	Name      string    `json:"name"`
	Species   string    `json:"species"`
	Since     *string   `json:"since"`
	Days      *int      `json:"days"`
	PlannedTo *string   `json:"planned_end_on"`
}

func (s *Service) Dashboard(ctx context.Context, actor Actor) (*Dashboard, error) {
	d := &Dashboard{Counts: map[string]int{}, Groups: map[string][]DashboardColony{}}
	for _, g := range []string{GroupOverdue, GroupToday, GroupTomorrow, GroupWeek, GroupLater} {
		d.Groups[g] = []DashboardColony{}
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT c.id, c.name, c.number, COALESCE(sp.scientific_name, c.species_text, ''), l.path, c.status
		FROM colonies c
		JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $1 AND m.deleted_at IS NULL
		LEFT JOIN species sp ON sp.id = c.species_id
		LEFT JOIN locations l ON l.id = c.location_id
		WHERE c.deleted_at IS NULL AND c.archived_at IS NULL`, actor.UserID)
	if err != nil {
		return nil, err
	}
	cols, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (DashboardColony, error) {
		var c DashboardColony
		err := r.Scan(&c.ID, &c.Name, &c.Number, &c.Species, &c.Location, &c.Status)
		return c, err
	})
	if err != nil {
		return nil, err
	}
	ids := make([]uuid.UUID, len(cols))
	for i, c := range cols {
		ids[i] = c.ID
		d.Counts[c.Status]++
	}
	d.Counts["total"] = len(cols)
	due, err := s.dueFor(ctx, s.Pool, s.userPrefs(ctx, s.Pool, actor.UserID), ids)
	if err != nil {
		return nil, err
	}
	for _, c := range cols {
		c.Tasks = due[c.ID]
		w := worst(c.Tasks)
		if w == nil {
			continue
		}
		if w.Days <= 0 {
			d.NeedsAttention++
		}
		d.Groups[w.Group] = append(d.Groups[w.Group], c)
	}
	for g := range d.Groups {
		sort.SliceStable(d.Groups[g], func(i, j int) bool {
			return d.Groups[g][i].Tasks[0].Days < d.Groups[g][j].Tasks[0].Days
		})
	}

	hrows, err := s.Pool.Query(ctx, `
		SELECT c.id, c.name, COALESCE(sp.scientific_name, c.species_text, ''),
		       w.started_on::text, (current_date - w.started_on), w.planned_end_on::text
		FROM colonies c
		JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $1 AND m.deleted_at IS NULL
		LEFT JOIN species sp ON sp.id = c.species_id
		LEFT JOIN winter_rests w ON w.colony_id = c.id AND w.ended_on IS NULL AND w.deleted_at IS NULL
		WHERE c.deleted_at IS NULL AND c.archived_at IS NULL AND c.status = 'hibernating'
		ORDER BY w.started_on NULLS LAST, c.name`, actor.UserID)
	if err != nil {
		return nil, err
	}
	d.Hibernating, err = pgx.CollectRows(hrows, func(r pgx.CollectableRow) (HibernatingColony, error) {
		var h HibernatingColony
		err := r.Scan(&h.ID, &h.Name, &h.Species, &h.Since, &h.Days, &h.PlannedTo)
		return h, err
	})
	if err != nil {
		return nil, err
	}
	if d.Hibernating == nil {
		d.Hibernating = []HibernatingColony{}
	}

	if d.Problems, err = s.jsonList(ctx, `
		SELECT event_json(e.id) || jsonb_build_object('colony_name', c.name)
		FROM colony_events e
		JOIN colonies c ON c.id = e.colony_id AND c.deleted_at IS NULL
		JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $1 AND m.deleted_at IS NULL
		WHERE e.type = 'problem' AND e.deleted_at IS NULL AND e.occurred_at > now() - interval '30 days'
		  AND COALESCE(e.payload->>'resolved', 'false') <> 'true'
		ORDER BY e.occurred_at DESC LIMIT 10`, actor.UserID); err != nil {
		return nil, err
	}
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM sync_conflicts WHERE user_id = $1 AND dismissed_at IS NULL`,
		actor.UserID).Scan(&d.OpenConflicts); err != nil {
		return nil, err
	}
	if d.Recent, err = s.jsonList(ctx, `
		SELECT event_json(e.id) || jsonb_build_object('colony_name', c.name, 'colony_number', c.number)
		FROM colony_events e
		JOIN colonies c ON c.id = e.colony_id AND c.deleted_at IS NULL
		JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $1 AND m.deleted_at IS NULL
		WHERE e.deleted_at IS NULL
		ORDER BY e.occurred_at DESC, e.id DESC LIMIT 15`, actor.UserID); err != nil {
		return nil, err
	}
	return d, nil
}

// ---------------------------------------------------------------------------
// Repeat last feeding

func (s *Service) RepeatLastFeeding(ctx context.Context, actor Actor, colony uuid.UUID, opID, eventID uuid.UUID, at *time.Time) (OpResult, error) {
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleEditor); err != nil {
		return OpResult{}, err
	}
	var last json.RawMessage
	err := s.Pool.QueryRow(ctx, `SELECT event_json(id) FROM colony_events WHERE colony_id = $1 AND type = 'feeding'
		AND deleted_at IS NULL ORDER BY occurred_at DESC, id DESC LIMIT 1`, colony).Scan(&last)
	if errors.Is(err, pgx.ErrNoRows) {
		return OpResult{}, &Problem{Status: http.StatusConflict, Code: "feeding.none", Title: "no previous feeding to repeat"}
	}
	if err != nil {
		return OpResult{}, err
	}
	var ev struct {
		Feeding struct {
			Items []map[string]any `json:"items"`
		} `json:"feeding"`
	}
	if err := json.Unmarshal(last, &ev); err != nil {
		return OpResult{}, err
	}
	items := make([]map[string]any, 0, len(ev.Feeding.Items))
	for _, it := range ev.Feeding.Items {
		n := map[string]any{}
		for _, k := range []string{"food_item_id", "food_name", "category", "quantity", "unit", "size", "position"} {
			if v, ok := it[k]; ok && v != nil {
				n[k] = v
			}
		}
		items = append(items, n)
	}
	payload := map[string]any{
		"colony_id": colony,
		"type":      "feeding",
		"feeding":   map[string]any{"acceptance": "unknown", "items": items},
	}
	if at != nil {
		payload["occurred_at"] = at
	}
	if eventID == uuid.Nil {
		eventID = uuid.Must(uuid.NewV7())
	}
	if opID == uuid.Nil {
		opID = uuid.Must(uuid.NewV7())
	}
	return s.ApplyOp(ctx, actor, Op{OpID: opID, Entity: "colony_events", EntityID: eventID, Op: "create", Payload: mustJSON(payload)})
}

// ---------------------------------------------------------------------------
// Scan resolution

type ScanResult struct {
	ColonyID   uuid.UUID `json:"colony_id"`
	ScanLinkID uuid.UUID `json:"scan_link_id"`
	Kind       string    `json:"kind"`
}

var ErrScanRevoked = &Problem{Status: http.StatusGone, Code: "scan.revoked", Title: "this code was deactivated"}

// ResolveScan maps a token to a colony. It never grants rights: unknown tokens
// and colonies without membership look identical (404).
func (s *Service) ResolveScan(ctx context.Context, actor Actor, token string) (*ScanResult, error) {
	if !auth.ValidScanToken(token) {
		return nil, NotFound("scan")
	}
	var r ScanResult
	var active bool
	err := s.Pool.QueryRow(ctx, `SELECT id, colony_id, kind, active FROM scan_links WHERE token = $1 AND deleted_at IS NULL`,
		token).Scan(&r.ScanLinkID, &r.ColonyID, &r.Kind, &active)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, NotFound("scan")
	}
	if err != nil {
		return nil, err
	}
	acc, err := colonyRole(ctx, s.Pool, actor.UserID, r.ColonyID)
	if err != nil {
		return nil, err
	}
	if acc.Role == RoleNone || acc.Deleted {
		return nil, NotFound("scan")
	}
	if !active {
		return nil, ErrScanRevoked
	}
	return &r, nil
}

// NFCUIDKey is the per-instance key clients use to hash tag UIDs
// (HMAC-SHA256(key, uid)) before storing or looking them up.
func (s *Service) NFCUIDKey() string {
	return base64.StdEncoding.EncodeToString(auth.HMAC(s.Cfg.InstanceSecret, "nfc-uid-v1"))
}

func (s *Service) ResolveNFCUID(ctx context.Context, actor Actor, uidHashHex string) (*ScanResult, error) {
	b, err := hex.DecodeString(strings.ToLower(uidHashHex))
	if err != nil || len(b) != 32 {
		return nil, Invalid("uid_hash", "uid_hash must be 64 hex characters")
	}
	var r ScanResult
	err = s.Pool.QueryRow(ctx, `
		SELECT t.colony_id, COALESCE(t.scan_link_id, '00000000-0000-0000-0000-000000000000'::uuid)
		FROM nfc_tags t
		JOIN colony_members m ON m.colony_id = t.colony_id AND m.user_id = $2 AND m.deleted_at IS NULL
		JOIN colonies c ON c.id = t.colony_id AND c.deleted_at IS NULL
		WHERE t.uid_hash = $1 AND t.deleted_at IS NULL
		ORDER BY (t.owner_id = $2) DESC LIMIT 1`, b, actor.UserID).Scan(&r.ColonyID, &r.ScanLinkID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, NotFound("scan")
	}
	r.Kind = "nfc"
	return &r, err
}

// RegenerateQR deactivates the active QR code of a colony and creates a new one.
func (s *Service) RegenerateQR(ctx context.Context, actor Actor, colony uuid.UUID) (json.RawMessage, error) {
	var out json.RawMessage
	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := requireColony(ctx, tx, actor, colony, RoleEditor); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE scan_links SET active = false, revoked_at = now()
			WHERE colony_id = $1 AND kind = 'qr' AND active AND deleted_at IS NULL`, colony); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `INSERT INTO scan_links (id, colony_id, token, kind, created_by)
			VALUES (uuidv7(), $1, $2, 'qr', $3) RETURNING to_jsonb(scan_links.*)`,
			colony, auth.NewScanToken(), actor.UserID).Scan(&out)
	})
	return out, err
}

// ScanLinkToken returns the token of a scan link the actor can see.
func (s *Service) ScanLinkToken(ctx context.Context, actor Actor, id uuid.UUID) (string, error) {
	var token string
	var colony uuid.UUID
	err := s.Pool.QueryRow(ctx, `SELECT token, colony_id FROM scan_links WHERE id = $1 AND deleted_at IS NULL`, id).Scan(&token, &colony)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", NotFound("scan_link")
	}
	if err != nil {
		return "", err
	}
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleViewer); err != nil {
		return "", NotFound("scan_link")
	}
	return token, nil
}

// ---------------------------------------------------------------------------
// Members (sharing)

type Member struct {
	UserID      uuid.UUID `json:"user_id"`
	DisplayName string    `json:"display_name"`
	Email       *string   `json:"email,omitempty"` // only visible to the owner
	Role        string    `json:"role"`
	Since       time.Time `json:"since"`
}

func (s *Service) ListMembers(ctx context.Context, actor Actor, colony uuid.UUID) ([]Member, error) {
	acc, err := requireColony(ctx, s.Pool, actor, colony, RoleViewer)
	if err != nil {
		return nil, err
	}
	rows, err := s.Pool.Query(ctx, `SELECT u.id, u.display_name, CASE WHEN $2 THEN u.email::text END, m.role, m.created_at
		FROM colony_members m JOIN users u ON u.id = m.user_id
		WHERE m.colony_id = $1 AND m.deleted_at IS NULL
		ORDER BY (m.role = 'owner') DESC, u.display_name`, colony, acc.Role == RoleOwner)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Member, error) {
		var m Member
		err := r.Scan(&m.UserID, &m.DisplayName, &m.Email, &m.Role, &m.Since)
		return m, err
	})
}

func (s *Service) SetMember(ctx context.Context, actor Actor, colony uuid.UUID, email string, role Role) error {
	if role != RoleEditor && role != RoleViewer {
		return Invalid("role", "role must be editor or viewer")
	}
	return db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := requireColony(ctx, tx, actor, colony, RoleOwner); err != nil {
			return err
		}
		var user uuid.UUID
		err := tx.QueryRow(ctx, `SELECT id FROM users WHERE email = $1 AND disabled_at IS NULL`, strings.TrimSpace(email)).Scan(&user)
		if errors.Is(err, pgx.ErrNoRows) {
			return Invalid("email", "no account with this e-mail address on this server – send an invitation instead")
		}
		if err != nil {
			return err
		}
		if user == actor.UserID {
			return Invalid("email", "you already own this colony")
		}
		tag, err := tx.Exec(ctx, `UPDATE colony_members SET role = $3 WHERE colony_id = $1 AND user_id = $2 AND deleted_at IS NULL
			AND role <> 'owner'`, colony, user, string(role))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			_, err = tx.Exec(ctx, `INSERT INTO colony_members (colony_id, user_id, role) VALUES ($1, $2, $3)`, colony, user, string(role))
		}
		return err
	})
}

func (s *Service) RemoveMember(ctx context.Context, actor Actor, colony, user uuid.UUID) error {
	return db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		acc, err := requireColony(ctx, tx, actor, colony, RoleViewer)
		if err != nil {
			return err
		}
		// Owners remove anyone except themselves; members may leave.
		if acc.Role != RoleOwner && user != actor.UserID {
			return ErrForbidden
		}
		tag, err := tx.Exec(ctx, `UPDATE colony_members SET deleted_at = now()
			WHERE colony_id = $1 AND user_id = $2 AND deleted_at IS NULL AND role <> 'owner'`, colony, user)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return NotFound("member")
		}
		return nil
	})
}
