package service

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

func requireAdmin(a Actor) error {
	if !a.IsAdmin {
		return ErrForbidden
	}
	return nil
}

type AdminUser struct {
	UserInfo
	Disabled    bool       `json:"disabled"`
	LastLoginAt *time.Time `json:"last_login_at"`
	Colonies    int        `json:"colonies"`
	Photos      int        `json:"photos"`
	PhotoBytes  int64      `json:"photo_bytes"`
}

// ListUsers shows accounts with usage metadata – never colony contents.
func (s *Service) ListUsers(ctx context.Context, actor Actor) ([]AdminUser, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	rows, err := s.Pool.Query(ctx, `
		SELECT u.id, u.email, u.display_name, u.instance_role, u.created_at, u.disabled_at IS NOT NULL, u.last_login_at,
		       (SELECT count(*) FROM colonies c WHERE c.owner_id = u.id AND c.deleted_at IS NULL),
		       (SELECT count(*) FROM photos p WHERE p.owner_id = u.id AND p.deleted_at IS NULL),
		       (SELECT COALESCE(sum(bytes), 0) FROM photos p WHERE p.owner_id = u.id AND p.deleted_at IS NULL)
		FROM users u ORDER BY u.created_at`)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (AdminUser, error) {
		var u AdminUser
		err := r.Scan(&u.ID, &u.Email, &u.DisplayName, &u.InstanceRole, &u.CreatedAt, &u.Disabled, &u.LastLoginAt,
			&u.Colonies, &u.Photos, &u.PhotoBytes)
		return u, err
	})
}

type AdminUserPatch struct {
	Disabled     *bool   `json:"disabled"`
	InstanceRole *string `json:"instance_role"`
}

func (s *Service) UpdateUser(ctx context.Context, actor Actor, id uuid.UUID, p AdminUserPatch) error {
	if err := requireAdmin(actor); err != nil {
		return err
	}
	if id == actor.UserID && ((p.Disabled != nil && *p.Disabled) || (p.InstanceRole != nil && *p.InstanceRole != "admin")) {
		return Invalid("id", "you cannot disable or demote yourself")
	}
	if p.InstanceRole != nil && *p.InstanceRole != "admin" && *p.InstanceRole != "user" {
		return Invalid("instance_role", "role must be admin or user")
	}
	return db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE users SET
			disabled_at = CASE WHEN $2::boolean IS NULL THEN disabled_at WHEN $2 THEN COALESCE(disabled_at, now()) ELSE NULL END,
			instance_role = COALESCE($3, instance_role), updated_at = now()
			WHERE id = $1`, id, p.Disabled, p.InstanceRole)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return NotFound("user")
		}
		if p.Disabled != nil && *p.Disabled {
			_, err = tx.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`, id)
		}
		return err
	})
}

type Invitation struct {
	ID         uuid.UUID  `json:"id"`
	Email      *string    `json:"email"`
	ColonyID   *uuid.UUID `json:"colony_id,omitempty"`
	ColonyRole *string    `json:"colony_role,omitempty"`
	ExpiresAt  time.Time  `json:"expires_at"`
	AcceptedAt *time.Time `json:"accepted_at"`
	CreatedAt  time.Time  `json:"created_at"`
	Link       string     `json:"link,omitempty"` // only returned on creation
}

type InvitationInput struct {
	Email      string     `json:"email"`
	ColonyID   *uuid.UUID `json:"colony_id"`
	ColonyRole string     `json:"colony_role"`
	ValidDays  int        `json:"valid_days"`
}

// CreateInvitation is allowed for admins (instance invitations) and for colony
// owners (invitation that also shares a colony).
func (s *Service) CreateInvitation(ctx context.Context, actor Actor, in InvitationInput) (*Invitation, error) {
	if in.ColonyID != nil {
		if _, err := requireColony(ctx, s.Pool, actor, *in.ColonyID, RoleOwner); err != nil {
			return nil, err
		}
		if in.ColonyRole != "editor" && in.ColonyRole != "viewer" {
			return nil, Invalid("colony_role", "colony_role must be editor or viewer")
		}
		if s.Cfg.RegistrationMode == "closed" && !actor.IsAdmin {
			return nil, ErrForbidden
		}
	} else if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	if in.ValidDays <= 0 || in.ValidDays > 30 {
		in.ValidDays = 7
	}
	tok := auth.NewToken(24)
	inv := &Invitation{}
	var email, role *string
	if e := strings.TrimSpace(strings.ToLower(in.Email)); e != "" {
		email = &e
	}
	if in.ColonyID != nil {
		role = &in.ColonyRole
	}
	err := s.Pool.QueryRow(ctx, `INSERT INTO invitations (created_by, email, token_hash, colony_id, colony_role, expires_at)
		VALUES ($1, $2, $3, $4, $5, now() + make_interval(days => $6))
		RETURNING id, email, colony_id, colony_role, expires_at, accepted_at, created_at`,
		actor.UserID, email, auth.HashToken(tok), in.ColonyID, role, in.ValidDays).
		Scan(&inv.ID, &inv.Email, &inv.ColonyID, &inv.ColonyRole, &inv.ExpiresAt, &inv.AcceptedAt, &inv.CreatedAt)
	if err != nil {
		return nil, problemFromDB(err)
	}
	inv.Link = strings.TrimRight(s.Cfg.PublicURL.String(), "/") + "/register?invite=" + tok
	return inv, nil
}

func (s *Service) ListInvitations(ctx context.Context, actor Actor) ([]Invitation, error) {
	rows, err := s.Pool.Query(ctx, `SELECT id, email, colony_id, colony_role, expires_at, accepted_at, created_at
		FROM invitations WHERE created_by = $1 OR $2 ORDER BY created_at DESC LIMIT 500`, actor.UserID, actor.IsAdmin)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (Invitation, error) {
		var i Invitation
		err := r.Scan(&i.ID, &i.Email, &i.ColonyID, &i.ColonyRole, &i.ExpiresAt, &i.AcceptedAt, &i.CreatedAt)
		return i, err
	})
}

func (s *Service) DeleteInvitation(ctx context.Context, actor Actor, id uuid.UUID) error {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM invitations WHERE id = $1 AND (created_by = $2 OR $3) AND accepted_at IS NULL`,
		id, actor.UserID, actor.IsAdmin)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return NotFound("invitation")
	}
	return nil
}

type SystemInfo struct {
	Version          string          `json:"version"`
	SchemaVersion    string          `json:"schema_version"`
	PendingMigration []string        `json:"pending_migrations"`
	DatabaseBytes    int64           `json:"database_bytes"`
	Users            int             `json:"users"`
	Colonies         int             `json:"colonies"`
	Photos           int             `json:"photos"`
	PhotoBytes       int64           `json:"photo_bytes"`
	PublicURL        string          `json:"public_url"`
	HTTPS            bool            `json:"https"`
	SMTP             bool            `json:"smtp"`
	RegistrationMode string          `json:"registration_mode"`
	Backup           json.RawMessage `json:"backup_status"`
	Warnings         []string        `json:"warnings"`
}

func (s *Service) SystemInfo(ctx context.Context, actor Actor, version, backupDir string) (*SystemInfo, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	si := &SystemInfo{Version: version, PublicURL: s.Cfg.PublicURL.String(), HTTPS: s.Cfg.SecureCookies(),
		SMTP: s.Mail.Enabled(), RegistrationMode: s.Cfg.RegistrationMode, Warnings: []string{}}
	applied, pending, err := db.MigrationStatus(ctx, s.Pool)
	if err != nil {
		return nil, err
	}
	if len(applied) > 0 {
		si.SchemaVersion = applied[len(applied)-1]
	}
	si.PendingMigration = pending
	if err := s.Pool.QueryRow(ctx, `SELECT pg_database_size(current_database()),
		(SELECT count(*) FROM users), (SELECT count(*) FROM colonies WHERE deleted_at IS NULL),
		(SELECT count(*) FROM photos WHERE deleted_at IS NULL), (SELECT COALESCE(sum(bytes), 0) FROM photos WHERE deleted_at IS NULL)`).
		Scan(&si.DatabaseBytes, &si.Users, &si.Colonies, &si.Photos, &si.PhotoBytes); err != nil {
		return nil, err
	}
	if !si.HTTPS {
		si.Warnings = append(si.Warnings, "PUBLIC_APP_URL uses http – fine in a trusted LAN, use HTTPS for internet access")
	}
	if !si.SMTP {
		si.Warnings = append(si.Warnings, "SMTP not configured – password reset only via admin link")
	}
	if backupDir != "" {
		b, err := os.ReadFile(filepath.Join(backupDir, "status.json"))
		switch {
		case err == nil && json.Valid(b):
			si.Backup = b
		case errors.Is(err, os.ErrNotExist):
			si.Warnings = append(si.Warnings, "no backup status found – is the backup container running?")
		}
	}
	return si, nil
}
