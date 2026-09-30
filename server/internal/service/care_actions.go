package service

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Actions from outside the app (Home Assistant buttons and switches). They
// behave like the buttons in the app: "done" logs the same event the app
// would log, winter rest on/off starts or ends it today.

// MarkCareDone logs the event that completes a care schedule: water and
// cleaning with the kinds used last time, feedings repeat the last matching
// feeding, custom plans get a custom_task event.
func (s *Service) MarkCareDone(ctx context.Context, actor Actor, schedule uuid.UUID) (OpResult, error) {
	var colony uuid.UUID
	var taskType string
	err := s.Pool.QueryRow(ctx, `SELECT colony_id, task_type FROM care_schedules WHERE id = $1 AND deleted_at IS NULL`, schedule).
		Scan(&colony, &taskType)
	if errors.Is(err, pgx.ErrNoRows) {
		return OpResult{}, NotFound("care_schedule")
	}
	if err != nil {
		return OpResult{}, err
	}
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleEditor); err != nil {
		return OpResult{}, err
	}
	lastKinds := func(table string, fallback string) ([]string, error) {
		var kinds []string
		err := s.Pool.QueryRow(ctx, `SELECT d.kinds FROM colony_events e JOIN `+table+` d ON d.event_id = e.id
			WHERE e.colony_id = $1 AND e.deleted_at IS NULL ORDER BY e.occurred_at DESC, e.id DESC LIMIT 1`, colony).Scan(&kinds)
		if errors.Is(err, pgx.ErrNoRows) {
			return []string{fallback}, nil
		}
		return kinds, err
	}
	payload := map[string]any{"colony_id": colony}
	switch taskType {
	case "feeding", "protein", "carbohydrate":
		category := taskType
		if category == "feeding" {
			category = ""
		}
		return rejectedAsError(s.repeatFeeding(ctx, actor, colony, category, uuid.Nil, uuid.Nil, nil))
	case "water":
		kinds, err := lastKinds("waterings", "drinker_refilled")
		if err != nil {
			return OpResult{}, err
		}
		payload["type"], payload["water"] = "water", map[string]any{"kinds": kinds}
	case "cleaning":
		kinds, err := lastKinds("cleanings", "other")
		if err != nil {
			return OpResult{}, err
		}
		payload["type"], payload["cleaning"] = "cleaning", map[string]any{"kinds": kinds}
	case "check":
		payload["type"] = "check"
	default:
		payload["type"], payload["schedule_id"] = "custom_task", schedule
	}
	return rejectedAsError(s.ApplyOp(ctx, actor, Op{OpID: uuid.Must(uuid.NewV7()), Entity: "colony_events",
		EntityID: uuid.Must(uuid.NewV7()), Op: "create", Payload: mustJSON(payload)}))
}

// rejectedAsError: for callers without a sync client a rejected op is an error.
func rejectedAsError(res OpResult, err error) (OpResult, error) {
	if err == nil && res.Status == StatusRejected && res.Error != nil {
		return res, res.Error
	}
	return res, err
}

// SetHibernation starts the winter rest today (a planned one, otherwise a
// new one) or ends the running one today.
func (s *Service) SetHibernation(ctx context.Context, actor Actor, colony uuid.UUID, on bool) (OpResult, error) {
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleEditor); err != nil {
		return OpResult{}, err
	}
	today := s.Now().In(s.userPrefs(ctx, s.Pool, actor.UserID).Location).Format(time.DateOnly)
	var id uuid.UUID
	var started *string
	err := s.Pool.QueryRow(ctx, `SELECT id, started_on::text FROM winter_rests
		WHERE colony_id = $1 AND ended_on IS NULL AND deleted_at IS NULL`, colony).Scan(&id, &started)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return OpResult{}, err
	}
	op := Op{OpID: uuid.Must(uuid.NewV7()), Entity: "winter_rests", EntityID: id, Op: "update"}
	switch {
	case on && id == uuid.Nil:
		op.EntityID, op.Op = uuid.Must(uuid.NewV7()), "create"
		op.Payload = mustJSON(map[string]any{"colony_id": colony, "started_on": today})
	case on && (started == nil || *started > today):
		op.Payload = mustJSON(map[string]any{"started_on": today})
	case !on && started != nil && *started <= today:
		op.Payload = mustJSON(map[string]any{"ended_on": today})
	default:
		return OpResult{Status: StatusApplied, EntityID: id}, nil // already so
	}
	return rejectedAsError(s.ApplyOp(ctx, actor, op))
}
