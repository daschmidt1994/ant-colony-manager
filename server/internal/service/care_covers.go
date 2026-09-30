package service

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// Care cover (Pflegevertretung): the owner hands chosen colonies to another
// person for a period – e.g. during a holiday – with care instructions.
// During the period the person is a carer (editor) of those colonies; the
// server adds and removes that membership itself (colony_members.cover_id).
// Memberships that existed before are never touched. Days follow the
// server's date (TZ).

// CareCoverColony is a colony of a cover with its own instructions.
type CareCoverColony struct {
	ColonyID     uuid.UUID `json:"colony_id"`
	Name         string    `json:"name"`
	Number       int       `json:"number"`
	Instructions string    `json:"instructions,omitempty"`
}

// CareCover as the owner and the substitute see it.
type CareCover struct {
	ID           uuid.UUID         `json:"id"`
	OwnerID      uuid.UUID         `json:"owner_id"`
	OwnerName    string            `json:"owner_name"`
	UserID       uuid.UUID         `json:"user_id"`
	UserName     string            `json:"user_name"`
	UserEmail    *string           `json:"user_email,omitempty"` // only for the owner
	StartsOn     string            `json:"starts_on"`
	EndsOn       string            `json:"ends_on"`
	Instructions string            `json:"instructions,omitempty"`
	State        string            `json:"state"` // planned | active | ended
	Mine         bool              `json:"mine"`  // I am the owner
	Colonies     []CareCoverColony `json:"colonies"`
	Done         []CareCoverDone   `json:"done,omitempty"` // detail only
}

// CareCoverDone is care the substitute documented during the cover.
type CareCoverDone struct {
	ColonyID   uuid.UUID `json:"colony_id"`
	Type       string    `json:"type"`
	OccurredAt time.Time `json:"occurred_at"`
	Note       string    `json:"note,omitempty"`
}

// CareCoverInput creates or changes a cover.
type CareCoverInput struct {
	Email        string            `json:"email"`
	StartsOn     string            `json:"starts_on"`
	EndsOn       string            `json:"ends_on"`
	Instructions *string           `json:"instructions"`
	Colonies     []CareCoverColony `json:"colonies"`
}

const coverState = `CASE WHEN c.ended_at IS NOT NULL OR c.ends_on < current_date THEN 'ended'
	WHEN c.starts_on > current_date THEN 'planned' ELSE 'active' END`

func (s *Service) loadCovers(ctx context.Context, q db.Querier, actor Actor, where string, args ...any) ([]CareCover, error) {
	rows, err := q.Query(ctx, `
		SELECT c.id, c.owner_id, o.display_name, c.user_id, u.display_name,
		       CASE WHEN c.owner_id = $1 THEN u.email::text END,
		       c.starts_on::text, c.ends_on::text, COALESCE(c.instructions, ''), `+coverState+`, c.owner_id = $1
		FROM care_covers c JOIN users o ON o.id = c.owner_id JOIN users u ON u.id = c.user_id
		WHERE (c.owner_id = $1 OR c.user_id = $1) AND `+where+`
		ORDER BY c.starts_on DESC, c.id`, append([]any{actor.UserID}, args...)...)
	if err != nil {
		return nil, err
	}
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (CareCover, error) {
		var c CareCover
		err := r.Scan(&c.ID, &c.OwnerID, &c.OwnerName, &c.UserID, &c.UserName, &c.UserEmail,
			&c.StartsOn, &c.EndsOn, &c.Instructions, &c.State, &c.Mine)
		c.Colonies = []CareCoverColony{}
		return c, err
	})
	if err != nil || len(list) == 0 {
		return list, err
	}
	ids := make([]uuid.UUID, len(list))
	for i, c := range list {
		ids[i] = c.ID
	}
	rows, err = q.Query(ctx, `SELECT cc.cover_id, cc.colony_id, col.name, col.number, COALESCE(cc.instructions, '')
		FROM care_cover_colonies cc JOIN colonies col ON col.id = cc.colony_id AND col.deleted_at IS NULL
		WHERE cc.cover_id = ANY($1) ORDER BY col.number`, ids)
	if err != nil {
		return nil, err
	}
	var cover uuid.UUID
	var cc CareCoverColony
	_, err = pgx.ForEachRow(rows, []any{&cover, &cc.ColonyID, &cc.Name, &cc.Number, &cc.Instructions}, func() error {
		for i := range list {
			if list[i].ID == cover {
				list[i].Colonies = append(list[i].Colonies, cc)
			}
		}
		return nil
	})
	return list, err
}

// CareCovers: the covers I set up and those I stand in for (newest first).
func (s *Service) CareCovers(ctx context.Context, actor Actor) ([]CareCover, error) {
	list, err := s.loadCovers(ctx, s.Pool, actor, `true`)
	if list == nil {
		list = []CareCover{}
	}
	return list, err
}

// CareCover: one cover with what the substitute documented during it.
func (s *Service) CareCover(ctx context.Context, actor Actor, id uuid.UUID) (*CareCover, error) {
	list, err := s.loadCovers(ctx, s.Pool, actor, `c.id = $2`, id)
	if err != nil {
		return nil, err
	}
	if len(list) == 0 {
		return nil, NotFound("care_cover")
	}
	c := list[0]
	colonies := make([]uuid.UUID, len(c.Colonies))
	for i, cc := range c.Colonies {
		colonies[i] = cc.ColonyID
	}
	rows, err := s.Pool.Query(ctx, `SELECT e.colony_id, e.type, e.occurred_at, COALESCE(e.note, '')
		FROM colony_events e JOIN care_covers c ON c.id = $1
		WHERE e.colony_id = ANY($2) AND e.created_by = c.user_id AND e.deleted_at IS NULL
		  AND e.occurred_at >= c.starts_on AND e.occurred_at < c.ends_on + 1
		ORDER BY e.occurred_at DESC LIMIT 500`, id, colonies)
	if err != nil {
		return nil, err
	}
	if c.Done, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (CareCoverDone, error) {
		var d CareCoverDone
		err := r.Scan(&d.ColonyID, &d.Type, &d.OccurredAt, &d.Note)
		return d, err
	}); err != nil {
		return nil, err
	}
	return &c, nil
}

func (s *Service) validCoverInput(in *CareCoverInput, create bool) error {
	today := s.Now().Format(time.DateOnly)
	start, err1 := time.Parse(time.DateOnly, in.StartsOn)
	end, err2 := time.Parse(time.DateOnly, in.EndsOn)
	if err1 != nil || err2 != nil {
		return Invalid("starts_on", "enter start and end as dates (YYYY-MM-DD)")
	}
	if end.Before(start) {
		return Invalid("ends_on", "the end must not be before the start")
	}
	if in.EndsOn < today {
		return Invalid("ends_on", "the end lies in the past")
	}
	if end.Sub(start) > 366*24*time.Hour {
		return Invalid("ends_on", "a cover lasts at most a year")
	}
	if create && len(in.Colonies) == 0 {
		return Invalid("colonies", "choose at least one colony")
	}
	if len(in.Colonies) > 200 {
		return Invalid("colonies", "at most 200 colonies")
	}
	if in.Instructions != nil {
		t := strings.TrimSpace(*in.Instructions)
		if len(t) > 5000 {
			return Invalid("instructions", "the instructions are too long (at most 5000 characters)")
		}
		in.Instructions = &t
	}
	for i := range in.Colonies {
		in.Colonies[i].Instructions = strings.TrimSpace(in.Colonies[i].Instructions)
		if len(in.Colonies[i].Instructions) > 2000 {
			return Invalid("colonies", "colony instructions are too long (at most 2000 characters)")
		}
	}
	return nil
}

// setCoverColonies replaces the colonies of a cover – all must be the actor's own.
func setCoverColonies(ctx context.Context, tx pgx.Tx, actor Actor, cover uuid.UUID, colonies []CareCoverColony) error {
	seen := map[uuid.UUID]bool{}
	if _, err := tx.Exec(ctx, `DELETE FROM care_cover_colonies WHERE cover_id = $1`, cover); err != nil {
		return err
	}
	for _, c := range colonies {
		if seen[c.ColonyID] {
			continue
		}
		seen[c.ColonyID] = true
		if _, err := requireColony(ctx, tx, actor, c.ColonyID, RoleOwner); err != nil {
			return Invalid("colonies", "only your own colonies can be handed over")
		}
		if _, err := tx.Exec(ctx, `INSERT INTO care_cover_colonies (cover_id, colony_id, instructions) VALUES ($1, $2, NULLIF($3, ''))`,
			cover, c.ColonyID, c.Instructions); err != nil {
			return err
		}
	}
	return nil
}

// CreateCareCover hands colonies to a person for a period.
func (s *Service) CreateCareCover(ctx context.Context, actor Actor, in CareCoverInput, meta ClientMeta) (*CareCover, error) {
	if err := s.validCoverInput(&in, true); err != nil {
		return nil, err
	}
	var id uuid.UUID
	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		var user uuid.UUID
		err := tx.QueryRow(ctx, `SELECT id FROM users WHERE email = $1 AND disabled_at IS NULL`, strings.TrimSpace(in.Email)).Scan(&user)
		if errors.Is(err, pgx.ErrNoRows) {
			return Invalid("email", "no account with this e-mail address on this server – invite the person first")
		}
		if err != nil {
			return err
		}
		if user == actor.UserID {
			return Invalid("email", "you cannot stand in for yourself")
		}
		instr := ""
		if in.Instructions != nil {
			instr = *in.Instructions
		}
		if err := tx.QueryRow(ctx, `INSERT INTO care_covers (owner_id, user_id, starts_on, ends_on, instructions)
			VALUES ($1, $2, $3, $4, NULLIF($5, '')) RETURNING id`, actor.UserID, user, in.StartsOn, in.EndsOn, instr).Scan(&id); err != nil {
			return err
		}
		return setCoverColonies(ctx, tx, actor, id, in.Colonies)
	})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, &actor.UserID, "care_cover_created", id.String(), map[string]any{"from": in.StartsOn, "to": in.EndsOn, "colonies": len(in.Colonies)}, meta.IP)
	if err := s.ApplyCareCovers(ctx); err != nil {
		return nil, err
	}
	return s.CareCover(ctx, actor, id)
}

// UpdateCareCover changes period, instructions or colonies (owner only).
func (s *Service) UpdateCareCover(ctx context.Context, actor Actor, id uuid.UUID, in CareCoverInput) (*CareCover, error) {
	list, err := s.loadCovers(ctx, s.Pool, actor, `c.id = $2`, id)
	if err != nil {
		return nil, err
	}
	if len(list) == 0 || !list[0].Mine {
		return nil, NotFound("care_cover")
	}
	cur := list[0]
	if cur.State == "ended" {
		return nil, Invalid("ends_on", "the cover has ended – set up a new one")
	}
	if in.StartsOn == "" {
		in.StartsOn = cur.StartsOn
	}
	if in.EndsOn == "" {
		in.EndsOn = cur.EndsOn
	}
	if err := s.validCoverInput(&in, false); err != nil {
		return nil, err
	}
	err = db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE care_covers SET starts_on = $2, ends_on = $3,
			instructions = CASE WHEN $4::text IS NULL THEN instructions ELSE NULLIF($4, '') END WHERE id = $1`,
			id, in.StartsOn, in.EndsOn, in.Instructions); err != nil {
			return err
		}
		if in.Colonies != nil {
			if len(in.Colonies) == 0 {
				return Invalid("colonies", "choose at least one colony")
			}
			return setCoverColonies(ctx, tx, actor, id, in.Colonies)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if err := s.ApplyCareCovers(ctx); err != nil {
		return nil, err
	}
	return s.CareCover(ctx, actor, id)
}

// EndCareCover ends a cover now – the owner or the substitute. A cover that
// has not started yet is removed.
func (s *Service) EndCareCover(ctx context.Context, actor Actor, id uuid.UUID, meta ClientMeta) error {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM care_covers WHERE id = $1 AND (owner_id = $2 OR user_id = $2)
		AND starts_on > current_date AND ended_at IS NULL`, id, actor.UserID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		tag, err = s.Pool.Exec(ctx, `UPDATE care_covers SET ended_at = now(), ends_on = LEAST(ends_on, current_date)
			WHERE id = $1 AND (owner_id = $2 OR user_id = $2) AND ended_at IS NULL`, id, actor.UserID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return NotFound("care_cover")
		}
	}
	s.Audit(ctx, &actor.UserID, "care_cover_ended", id.String(), nil, meta.IP)
	return s.ApplyCareCovers(ctx)
}

// ApplyCareCovers brings the memberships in line with the covers: the
// substitute becomes a carer while a cover runs and loses that afterwards.
// Runs hourly and after every change.
func (s *Service) ApplyCareCovers(ctx context.Context) error {
	return db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		// end: cover over, colony taken out of the cover, cover deleted
		if _, err := tx.Exec(ctx, `
			UPDATE colony_members m SET deleted_at = now()
			WHERE m.cover_id IS NOT NULL AND m.deleted_at IS NULL AND NOT EXISTS (
				SELECT 1 FROM care_covers c JOIN care_cover_colonies cc ON cc.cover_id = c.id
				WHERE c.id = m.cover_id AND cc.colony_id = m.colony_id AND c.user_id = m.user_id
				  AND c.ended_at IS NULL AND c.starts_on <= current_date AND c.ends_on >= current_date)`); err != nil {
			return err
		}
		// start: only where the person has no membership yet
		_, err := tx.Exec(ctx, `
			INSERT INTO colony_members (colony_id, user_id, role, cover_id)
			SELECT DISTINCT ON (cc.colony_id, c.user_id) cc.colony_id, c.user_id, 'editor', c.id
			FROM care_covers c JOIN care_cover_colonies cc ON cc.cover_id = c.id
			JOIN colonies col ON col.id = cc.colony_id AND col.deleted_at IS NULL
			WHERE c.ended_at IS NULL AND c.starts_on <= current_date AND c.ends_on >= current_date
			  AND NOT EXISTS (SELECT 1 FROM colony_members m WHERE m.colony_id = cc.colony_id
			                  AND m.user_id = c.user_id AND m.deleted_at IS NULL)
			ORDER BY cc.colony_id, c.user_id, c.ends_on DESC`)
		return err
	})
}

// CareInstructions: running and planned covers of a colony that concern the
// actor (as owner or substitute) – shown on top of the colony.
func (s *Service) CareInstructions(ctx context.Context, actor Actor, colony uuid.UUID) ([]CareCover, error) {
	if _, err := requireColony(ctx, s.Pool, actor, colony, RoleViewer); err != nil {
		return nil, err
	}
	list, err := s.loadCovers(ctx, s.Pool, actor, `c.ended_at IS NULL AND c.ends_on >= current_date
		AND EXISTS (SELECT 1 FROM care_cover_colonies x WHERE x.cover_id = c.id AND x.colony_id = $2)`, colony)
	if err != nil {
		return nil, err
	}
	for i := range list {
		// only this colony's instructions
		list[i].Colonies = slices.DeleteFunc(list[i].Colonies, func(cc CareCoverColony) bool { return cc.ColonyID != colony })
	}
	if list == nil {
		list = []CareCover{}
	}
	return list, nil
}
