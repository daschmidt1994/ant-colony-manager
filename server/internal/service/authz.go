package service

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// Actor is the authenticated caller.
type Actor struct {
	UserID    uuid.UUID
	SessionID uuid.UUID
	IsAdmin   bool
	DeviceID  uuid.UUID // uuid.Nil for web/REST requests without device
}

type Role string

const (
	RoleNone   Role = ""
	RoleViewer Role = "viewer"
	RoleEditor Role = "editor"
	RoleOwner  Role = "owner"
)

func (r Role) rank() int {
	switch r {
	case RoleOwner:
		return 3
	case RoleEditor:
		return 2
	case RoleViewer:
		return 1
	}
	return 0
}

// AtLeast reports whether r grants at least the rights of min.
func (r Role) AtLeast(min Role) bool { return r.rank() >= min.rank() && r != RoleNone }

// colonyAccess is the result of an access lookup on a colony.
type colonyAccess struct {
	Role    Role
	OwnerID uuid.UUID
	Deleted bool
}

// colonyRole looks up the caller's role on a colony. A missing membership or
// colony yields RoleNone (callers answer 404).
func colonyRole(ctx context.Context, q db.Querier, user, colony uuid.UUID) (colonyAccess, error) {
	var a colonyAccess
	var role *string
	err := q.QueryRow(ctx, `
		SELECT c.owner_id, c.deleted_at IS NOT NULL, m.role
		FROM colonies c
		LEFT JOIN colony_members m ON m.colony_id = c.id AND m.user_id = $2 AND m.deleted_at IS NULL
		WHERE c.id = $1`, colony, user).Scan(&a.OwnerID, &a.Deleted, &role)
	if errors.Is(err, pgx.ErrNoRows) {
		return colonyAccess{}, nil
	}
	if err != nil {
		return colonyAccess{}, err
	}
	if role != nil {
		a.Role = Role(*role)
	}
	return a, nil
}

// requireColony returns the access info or a 404 problem if the caller lacks min.
// Viewers asking for write access get 403 (they already know the colony exists).
func requireColony(ctx context.Context, q db.Querier, actor Actor, colony uuid.UUID, min Role) (colonyAccess, error) {
	a, err := colonyRole(ctx, q, actor.UserID, colony)
	if err != nil {
		return a, err
	}
	if a.Role == RoleNone {
		return a, NotFound("colony")
	}
	if a.Deleted {
		return a, ErrGone
	}
	if !a.Role.AtLeast(min) {
		return a, ErrForbidden
	}
	return a, nil
}

// memberColonyIDs returns all colonies the user can see.
func memberColonyIDs(ctx context.Context, q db.Querier, user uuid.UUID) ([]uuid.UUID, error) {
	rows, err := q.Query(ctx, `SELECT colony_id FROM colony_members WHERE user_id = $1 AND deleted_at IS NULL`, user)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
}
