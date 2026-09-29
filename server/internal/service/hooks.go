package service

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// ---------------------------------------------------------------------------
// Colonies

func colonyBeforeWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	if !w.create {
		return nil
	}
	// Serialize number assignment per owner.
	if _, err := q.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1::text, 42))`, w.actor.UserID); err != nil {
		return err
	}
	var requested *int
	if v, ok := w.data["number"]; ok && string(v) != "null" {
		var n int
		if err := json.Unmarshal(v, &n); err != nil || n <= 0 {
			return Invalid("number", "number must be a positive integer")
		}
		requested = &n
	}
	if requested != nil {
		var taken bool
		if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM colonies WHERE owner_id = $1 AND number = $2 AND deleted_at IS NULL)`,
			w.actor.UserID, *requested).Scan(&taken); err != nil {
			return err
		}
		if !taken {
			return nil
		}
		// Offline clients may pick the same number on two devices: assign the next free one.
		w.result.Status = StatusMerged
		w.result.Conflicts = append(w.result.Conflicts, "number")
	}
	var next int
	if err := q.QueryRow(ctx, `SELECT COALESCE(max(number), 0) + 1 FROM colonies WHERE owner_id = $1 AND deleted_at IS NULL`,
		w.actor.UserID).Scan(&next); err != nil {
		return err
	}
	w.set("number", next)
	return nil
}

func colonyAfterWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	if !w.create {
		return nil
	}
	if _, err := q.Exec(ctx, `INSERT INTO colony_members (colony_id, user_id, role) VALUES ($1, $2, 'owner')`,
		w.id, w.actor.UserID); err != nil {
		return err
	}
	if w.op.AutoQR {
		if _, err := q.Exec(ctx, `INSERT INTO scan_links (id, colony_id, token, kind, created_by) VALUES (uuidv7(), $1, $2, 'qr', $3)`,
			w.id, auth.NewScanToken(), w.actor.UserID); err != nil {
			return err
		}
	}
	return nil
}

// refreshColonyStats recomputes denormalised display fields. It only writes when
// something changed, so it does not produce needless sync traffic.
func refreshColonyStats(ctx context.Context, q db.Querier, colony uuid.UUID) error {
	_, err := q.Exec(ctx, `
		WITH q AS (
			SELECT CASE WHEN count(*) = 0 THEN NULL
			            ELSE count(*) FILTER (WHERE status = 'alive') END::int AS n
			FROM queens WHERE colony_id = $1 AND deleted_at IS NULL
		), census AS (
			SELECT COALESCE(cc.exact_count, cc.estimate_min) AS mn,
			       CASE WHEN cc.exact_count IS NOT NULL THEN cc.exact_count ELSE cc.estimate_max END AS mx
			FROM colony_events e JOIN colony_counts cc ON cc.event_id = e.id
			WHERE e.colony_id = $1 AND e.deleted_at IS NULL
			ORDER BY e.occurred_at DESC, e.id DESC LIMIT 1
		), meas AS (
			SELECT jsonb_object_agg(metric, jsonb_build_object('value', value, 'at', occurred_at)) AS j
			FROM (
				SELECT DISTINCT ON (m.metric) m.metric, m.value, e.occurred_at
				FROM colony_events e JOIN measurements m ON m.event_id = e.id
				WHERE e.colony_id = $1 AND e.deleted_at IS NULL
				ORDER BY m.metric, e.occurred_at DESC
			) x
		)
		UPDATE colonies c SET
			queen_count = (SELECT n FROM q),
			worker_estimate_min = (SELECT mn FROM census),
			worker_estimate_max = (SELECT mx FROM census),
			last_measurement = (SELECT j FROM meas)
		WHERE c.id = $1 AND (c.queen_count, c.worker_estimate_min, c.worker_estimate_max, c.last_measurement)
			IS DISTINCT FROM ((SELECT n FROM q), (SELECT mn FROM census), (SELECT mx FROM census), (SELECT j FROM meas))`, colony)
	return err
}

func refreshStatsAfterWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	return refreshColonyStats(ctx, q, w.colonyID)
}

// winterRestAfterWrite keeps the colony status in line with open winter rests.
func winterRestAfterWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	_, err := q.Exec(ctx, `
		UPDATE colonies SET status = CASE
			WHEN EXISTS (SELECT 1 FROM winter_rests WHERE colony_id = $1 AND ended_on IS NULL
			             AND deleted_at IS NULL AND started_on <= current_date) THEN 'hibernating'
			ELSE 'active' END
		WHERE id = $1 AND (
			(status IN ('active', 'founding', 'paused') AND EXISTS (SELECT 1 FROM winter_rests WHERE colony_id = $1
				AND ended_on IS NULL AND deleted_at IS NULL AND started_on <= current_date))
			OR (status = 'hibernating' AND NOT EXISTS (SELECT 1 FROM winter_rests WHERE colony_id = $1
				AND ended_on IS NULL AND deleted_at IS NULL AND started_on <= current_date)))`, w.colonyID)
	return err
}

// ---------------------------------------------------------------------------
// Events

var eventDetailKeys = map[string]bool{"feeding": true, "water": true, "cleaning": true, "measurements": true,
	"census": true, "brood": true, "habitat_move": true, "queen": true}

// required detail per event type, and optional extra details.
var eventDetailRules = map[string]struct {
	required string
	optional []string
}{
	"feeding":      {required: "feeding"},
	"water":        {required: "water", optional: []string{"measurements"}},
	"cleaning":     {required: "cleaning"},
	"measurement":  {required: "measurements"},
	"census":       {required: "census"},
	"brood":        {required: "brood"},
	"habitat_move": {required: "habitat_move"},
	"queen":        {required: "queen"},
	"check":        {optional: []string{"measurements", "census", "brood"}},
}

const maxFutureSkew = 5 * time.Minute

func eventBeforeWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	if w.delete {
		return nil
	}
	evType := ""
	if w.create {
		if err := json.Unmarshal(w.data["type"], &evType); err != nil || evType == "" {
			return Invalid("type", "type is required")
		}
	} else {
		evType, _ = w.current["type"].(string)
	}

	// occurred_at: default now, clamp device clocks that run ahead.
	now := s.Now()
	if v, ok := w.data["occurred_at"]; ok || w.create {
		var t time.Time
		if !ok || string(v) == "null" {
			if !w.create {
				return Invalid("occurred_at", "occurred_at cannot be empty")
			}
			t = now
		} else if err := json.Unmarshal(v, &t); err != nil {
			return Invalid("occurred_at", "occurred_at must be an RFC 3339 timestamp")
		}
		if t.After(now.Add(maxFutureSkew)) {
			t = now
		}
		w.set("occurred_at", t)
	}

	w.details = map[string]json.RawMessage{}
	for k := range eventDetailKeys {
		if v, ok := w.raw[k]; ok && string(v) != "null" {
			w.details[k] = v
		}
	}
	rule := eventDetailRules[evType]
	for k := range w.details {
		if k != rule.required && !contains(rule.optional, k) {
			return Invalid(k, "%s is not allowed for %s events", k, evType)
		}
	}
	if w.create && rule.required != "" {
		if _, ok := w.details[rule.required]; !ok {
			return Invalid(rule.required, "%s is required for %s events", rule.required, evType)
		}
	}
	if !w.create {
		if len(w.details) > 0 {
			if rule.required != "" {
				if _, ok := w.details[rule.required]; !ok {
					return Invalid(rule.required, "details must be sent completely (%s missing)", rule.required)
				}
			}
			rev, _ := w.current["details_rev"].(float64)
			w.set("details_rev", int(rev)+1)
		}
	}
	return validateEventDetails(w.details)
}

func validateEventDetails(d map[string]json.RawMessage) error {
	if v, ok := d["feeding"]; ok {
		var f struct {
			Items []json.RawMessage `json:"items"`
		}
		if err := json.Unmarshal(v, &f); err != nil {
			return Invalid("feeding", "feeding must be an object")
		}
		if len(f.Items) == 0 || len(f.Items) > 20 {
			return Invalid("feeding.items", "a feeding needs 1–20 items")
		}
	}
	for _, k := range []string{"measurements", "brood"} {
		if v, ok := d[k]; ok {
			var arr []json.RawMessage
			if err := json.Unmarshal(v, &arr); err != nil || len(arr) == 0 || len(arr) > 10 {
				return Invalid(k, "%s must be a list with 1–10 entries", k)
			}
		}
	}
	for _, k := range []string{"water", "cleaning", "census", "habitat_move", "queen"} {
		if v, ok := d[k]; ok {
			var m map[string]any
			if err := json.Unmarshal(v, &m); err != nil {
				return Invalid(k, "%s must be an object", k)
			}
		}
	}
	return nil
}

func eventAfterWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	if !w.delete && len(w.details) > 0 {
		if err := replaceEventDetails(ctx, q, w); err != nil {
			return err
		}
		if err := eventSideEffects(ctx, q, w); err != nil {
			return err
		}
	}
	return refreshColonyStats(ctx, q, w.colonyID)
}

func replaceEventDetails(ctx context.Context, q db.Querier, w *write) error {
	id := w.id
	if !w.create {
		for _, t := range []string{"feeding_items", "feedings", "waterings", "cleanings", "measurements",
			"colony_counts", "brood_counts", "habitat_moves", "queen_events"} {
			col := "event_id"
			if t == "feeding_items" {
				col = "feeding_id"
			}
			if _, err := q.Exec(ctx, fmt.Sprintf(`DELETE FROM %s WHERE %s = $1`, t, col), id); err != nil {
				return err
			}
		}
	}
	d := w.details
	if v, ok := d["feeding"]; ok {
		var f struct {
			Acceptance *string         `json:"acceptance"`
			Items      json.RawMessage `json:"items"`
		}
		_ = json.Unmarshal(v, &f)
		acc := "unknown"
		if f.Acceptance != nil {
			acc = *f.Acceptance
		}
		if _, err := q.Exec(ctx, `INSERT INTO feedings (event_id, acceptance) VALUES ($1, $2)`, id, acc); err != nil {
			return err
		}
		// Referenced food must be system catalog or belong to the colony owner.
		var bad int
		if err := q.QueryRow(ctx, `
			SELECT count(*) FROM jsonb_populate_recordset(NULL::feeding_items, $1::jsonb) r
			WHERE r.food_item_id IS NOT NULL AND NOT EXISTS (
				SELECT 1 FROM food_items f WHERE f.id = r.food_item_id AND (f.owner_id IS NULL OR f.owner_id = $2))`,
			[]byte(f.Items), w.dataOwner).Scan(&bad); err != nil {
			return err
		}
		if bad > 0 {
			return Invalid("feeding.items.food_item_id", "food item not found")
		}
		if _, err := q.Exec(ctx, `
			INSERT INTO feeding_items (id, feeding_id, food_item_id, food_name, category, quantity, unit, size, acceptance, position)
			SELECT COALESCE(r.id, uuidv7()), $2, r.food_item_id,
			       COALESCE(NULLIF(r.food_name, ''), f.name), COALESCE(r.category, f.category),
			       r.quantity, COALESCE(r.unit, CASE WHEN r.quantity IS NOT NULL THEN f.default_unit END),
			       r.size, r.acceptance, COALESCE(r.position, (r.ordinality - 1)::smallint)
			FROM jsonb_populate_recordset(NULL::feeding_items, $1::jsonb) WITH ORDINALITY AS r
			LEFT JOIN food_items f ON f.id = r.food_item_id`, []byte(f.Items), id); err != nil {
			return err
		}
	}
	if v, ok := d["water"]; ok {
		if _, err := q.Exec(ctx, `INSERT INTO waterings (event_id, kinds)
			SELECT $2, r.kinds FROM jsonb_populate_record(NULL::waterings, $1::jsonb) r`, []byte(v), id); err != nil {
			return err
		}
	}
	if v, ok := d["cleaning"]; ok {
		if _, err := q.Exec(ctx, `INSERT INTO cleanings (event_id, kinds)
			SELECT $2, r.kinds FROM jsonb_populate_record(NULL::cleanings, $1::jsonb) r`, []byte(v), id); err != nil {
			return err
		}
	}
	if v, ok := d["measurements"]; ok {
		if _, err := q.Exec(ctx, `INSERT INTO measurements (id, event_id, metric, value, unit, place)
			SELECT COALESCE(r.id, uuidv7()), $2, r.metric, r.value,
			       COALESCE(r.unit, CASE r.metric WHEN 'temperature' THEN 'celsius' WHEN 'humidity' THEN 'percent' END), r.place
			FROM jsonb_populate_recordset(NULL::measurements, $1::jsonb) r`, []byte(v), id); err != nil {
			return err
		}
	}
	if v, ok := d["census"]; ok {
		if _, err := q.Exec(ctx, `INSERT INTO colony_counts (event_id, exact_count, estimate_min, estimate_max)
			SELECT $2, r.exact_count, r.estimate_min, r.estimate_max
			FROM jsonb_populate_record(NULL::colony_counts, $1::jsonb) r`, []byte(v), id); err != nil {
			return err
		}
	}
	if v, ok := d["brood"]; ok {
		if _, err := q.Exec(ctx, `INSERT INTO brood_counts (id, event_id, stage, exact_count, level)
			SELECT COALESCE(r.id, uuidv7()), $2, r.stage, r.exact_count, r.level
			FROM jsonb_populate_recordset(NULL::brood_counts, $1::jsonb) r`, []byte(v), id); err != nil {
			return err
		}
	}
	if v, ok := d["habitat_move"]; ok {
		var hm struct {
			From *uuid.UUID `json:"from_habitat_id"`
			To   *uuid.UUID `json:"to_habitat_id"`
		}
		if err := json.Unmarshal(v, &hm); err != nil {
			return Invalid("habitat_move", "invalid habitat ids")
		}
		for field, hid := range map[string]*uuid.UUID{"habitat_move.from_habitat_id": hm.From, "habitat_move.to_habitat_id": hm.To} {
			if hid == nil {
				continue
			}
			if err := checkOwned(ctx, q, "habitats", *hid, w.dataOwner, field); err != nil {
				return err
			}
		}
		if _, err := q.Exec(ctx, `INSERT INTO habitat_moves (event_id, from_habitat_id, to_habitat_id, reason)
			SELECT $2, r.from_habitat_id, r.to_habitat_id, r.reason
			FROM jsonb_populate_record(NULL::habitat_moves, $1::jsonb) r`, []byte(v), id); err != nil {
			return err
		}
	}
	if v, ok := d["queen"]; ok {
		var qe struct {
			QueenID *uuid.UUID `json:"queen_id"`
		}
		if err := json.Unmarshal(v, &qe); err != nil {
			return Invalid("queen", "invalid queen id")
		}
		if qe.QueenID != nil {
			var ok bool
			if err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM queens WHERE id = $1 AND colony_id = $2 AND deleted_at IS NULL)`,
				*qe.QueenID, w.colonyID).Scan(&ok); err != nil {
				return err
			}
			if !ok {
				return Invalid("queen.queen_id", "queen not found")
			}
		}
		if _, err := q.Exec(ctx, `INSERT INTO queen_events (event_id, queen_id, action)
			SELECT $2, r.queen_id, r.action FROM jsonb_populate_record(NULL::queen_events, $1::jsonb) r`, []byte(v), id); err != nil {
			return err
		}
	}
	return nil
}

func checkOwned(ctx context.Context, q db.Querier, table string, id, owner uuid.UUID, field string) error {
	var ok bool
	if err := q.QueryRow(ctx, fmt.Sprintf(`SELECT EXISTS (SELECT 1 FROM %s WHERE id = $1 AND owner_id = $2 AND deleted_at IS NULL)`, table),
		id, owner).Scan(&ok); err != nil {
		return err
	}
	if !ok {
		return Invalid(field, "referenced record not found")
	}
	return nil
}

// eventSideEffects applies consequences of events to other records.
func eventSideEffects(ctx context.Context, q db.Querier, w *write) error {
	if _, ok := w.details["queen"]; ok {
		if _, err := q.Exec(ctx, `
			UPDATE queens qn SET status = CASE qe.action WHEN 'died' THEN 'dead' ELSE 'removed' END,
			                     ended_on = e.occurred_at::date
			FROM queen_events qe JOIN colony_events e ON e.id = qe.event_id
			WHERE qe.event_id = $1 AND qn.id = qe.queen_id AND qe.action IN ('died', 'removed') AND qn.status = 'alive'`, w.id); err != nil {
			return err
		}
	}
	if _, ok := w.details["habitat_move"]; ok {
		if _, err := q.Exec(ctx, `
			UPDATE habitats h SET colony_id = NULL, status = 'stored'
			FROM habitat_moves m WHERE m.event_id = $1 AND h.id = m.from_habitat_id AND h.colony_id = $2`, w.id, w.colonyID); err != nil {
			return err
		}
		if _, err := q.Exec(ctx, `
			UPDATE habitats h SET colony_id = $2, status = 'in_use'
			FROM habitat_moves m WHERE m.event_id = $1 AND h.id = m.to_habitat_id
			AND (h.colony_id IS DISTINCT FROM $2 OR h.status <> 'in_use')`, w.id, w.colonyID); err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Other entities

func scanLinkBeforeWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	if w.create {
		var tok string
		if v, ok := w.data["token"]; ok {
			_ = json.Unmarshal(v, &tok)
		}
		if tok == "" {
			tok = auth.NewScanToken()
		}
		if !auth.ValidScanToken(tok) {
			return Invalid("token", "token must be 16 base62 characters")
		}
		w.set("token", tok)
	}
	if v, ok := w.data["active"]; ok {
		var active bool
		if err := json.Unmarshal(v, &active); err != nil {
			return Invalid("active", "active must be boolean")
		}
		if active {
			w.set("revoked_at", nil)
		} else {
			w.set("revoked_at", s.Now())
		}
	}
	return nil
}

func speciesBeforeWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	var name string
	if v, ok := w.data["scientific_name"]; ok {
		if err := json.Unmarshal(v, &name); err != nil {
			return Invalid("scientific_name", "scientific_name must be text")
		}
		name = strings.Join(strings.Fields(name), " ")
		if name == "" {
			return Invalid("scientific_name", "scientific_name is required")
		}
		w.set("scientific_name", name)
	}
	if _, ok := w.data["genus"]; !ok && name != "" {
		w.set("genus", strings.Fields(name)[0])
	}
	if v, ok := w.data["sources"]; ok {
		if err := validateSources(v); err != nil {
			return err
		}
	}
	return nil
}

// validateSources accepts up to 20 entries {"title": "…", "url": "https://…"};
// url is optional (books), but only http(s) links are allowed since clients open them.
func validateSources(raw json.RawMessage) error {
	var list []struct {
		Title string `json:"title"`
		URL   string `json:"url"`
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return Invalid("sources", "sources must be a list of {title, url}")
	}
	if len(list) > 20 {
		return Invalid("sources", "at most 20 sources")
	}
	for _, src := range list {
		if strings.TrimSpace(src.Title) == "" || len(src.Title) > 300 {
			return Invalid("sources", "every source needs a title (max. 300 characters)")
		}
		if src.URL == "" {
			continue
		}
		u, err := url.Parse(src.URL)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || len(src.URL) > 2000 {
			return Invalid("sources", "source url must be an http(s) link")
		}
	}
	return nil
}

func settingsBeforeWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	if v, ok := w.data["timezone"]; ok {
		var tz string
		if err := json.Unmarshal(v, &tz); err != nil {
			return Invalid("timezone", "timezone must be text")
		}
		if _, err := time.LoadLocation(tz); err != nil || tz == "" || tz == "Local" {
			return Invalid("timezone", "unknown time zone %q", tz)
		}
	}
	if v, ok := w.data["locale"]; ok {
		var l string
		if err := json.Unmarshal(v, &l); err != nil || (l != "system" && !languages[l]) {
			return Invalid("locale", "locale must be system or one of the supported languages")
		}
	}
	return nil
}

// sensorBeforeWrite creates the API key on sensor creation. The plain key is
// returned exactly once via OpResult.Extra.
func sensorBeforeWrite(ctx context.Context, s *Service, q db.Querier, w *write) error {
	if !w.create {
		return nil
	}
	prefix, secret := newSensorKey()
	w.set("api_key_prefix", prefix)
	w.set("api_key_hash", `\x`+hex.EncodeToString(auth.HashToken(secret)))
	w.result.Extra = map[string]any{"api_key": "acm_sk_" + prefix + "_" + secret}
	return nil
}

func newSensorKey() (prefix, secret string) {
	return strings.ToLower(auth.NewScanToken()[:10]), auth.NewToken(32)
}

func contains(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}
