package service

import (
	"context"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// Tables with tombstones, children before parents is not required because
// deleting a parent cascades.
var tombstoneTables = []string{"colony_events", "photos", "scan_links", "nfc_tags", "queens", "winter_rests",
	"care_schedules", "tasks", "care_round_colonies", "care_rounds", "habitats", "sensors", "colony_members",
	"colonies", "food_stocks", "food_items", "species", "locations"}

// Maintenance runs periodic cleanup. It is safe to run concurrently with
// normal traffic and idempotent.
func (s *Service) Maintenance(ctx context.Context) error {
	cutoff := s.Now().Add(-s.Cfg.TombstoneRetention)
	stmts := []string{
		`DELETE FROM applied_ops WHERE applied_at < now() - interval '90 days'`,
		`DELETE FROM sessions WHERE expires_at < now() - interval '7 days' OR revoked_at < now() - interval '30 days'`,
		`DELETE FROM device_link_codes WHERE expires_at < now() - interval '1 day'`,
		`DELETE FROM password_resets WHERE expires_at < now() - interval '1 day'`,
		`DELETE FROM sso_codes WHERE expires_at < now()`,
		`DELETE FROM invitations WHERE accepted_at IS NULL AND expires_at < now() - interval '30 days'`,
		`DELETE FROM audit_log WHERE at < now() - interval '180 days'`,
		`DELETE FROM sync_conflicts WHERE created_at < now() - interval '90 days'`,
		// users without active topics are not cleaned up by the notifier
		`DELETE FROM notification_log WHERE sent_at < now() - interval '60 days'`,
	}
	for _, q := range stmts {
		if _, err := s.Pool.Exec(ctx, q); err != nil {
			return fmt.Errorf("maintenance %q: %w", q[:40], err)
		}
	}
	return s.collectTombstones(ctx, cutoff)
}

// collectTombstones hard-deletes records deleted before cutoff, raises the
// tombstone horizon and trims change_log. Clients with an older cursor must
// then run a full snapshot (410 on pull).
func (s *Service) collectTombstones(ctx context.Context, cutoff time.Time) error {
	var orphanKeys []string
	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		var horizon int64
		if err := tx.QueryRow(ctx, `SELECT COALESCE(max(seq), 0) FROM change_log WHERE changed_at < $1`, cutoff).Scan(&horizon); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT storage_key, thumb_key, original_key FROM photos WHERE deleted_at < $1
			UNION ALL
			SELECT p.storage_key, p.thumb_key, p.original_key FROM photos p JOIN colonies c ON c.id = p.colony_id WHERE c.deleted_at < $1`, cutoff)
		if err != nil {
			return err
		}
		for rows.Next() {
			var a, b, c *string
			if err := rows.Scan(&a, &b, &c); err != nil {
				rows.Close()
				return err
			}
			for _, k := range []*string{a, b, c} {
				if k != nil {
					orphanKeys = append(orphanKeys, *k)
				}
			}
		}
		rows.Close()
		for _, t := range tombstoneTables {
			if _, err := tx.Exec(ctx, fmt.Sprintf(`DELETE FROM %s WHERE deleted_at < $1`, pgx.Identifier{t}.Sanitize()), cutoff); err != nil {
				return fmt.Errorf("gc %s: %w", t, err)
			}
		}
		if horizon == 0 {
			return nil
		}
		if _, err := tx.Exec(ctx, `DELETE FROM change_log WHERE seq <= $1`, horizon); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO instance_settings (key, value) VALUES ('tombstone_horizon_seq', to_jsonb($1::bigint))
			ON CONFLICT (key) DO UPDATE SET value = GREATEST((instance_settings.value #>> '{}')::bigint, $1)::text::jsonb, updated_at = now()`,
			horizon)
		return err
	})
	if err != nil {
		return err
	}
	// Files are content-addressed and may be shared by several photo rows.
	for _, k := range orphanKeys {
		var used bool
		if err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM photos WHERE storage_key = $1 OR thumb_key = $1 OR original_key = $1)`, k).Scan(&used); err != nil {
			return err
		}
		if !used {
			if err := s.Blobs.Delete(k); err != nil {
				s.Log.Warn("deleting orphaned file failed", "key", k, "err", err)
			}
		}
	}
	return nil
}

// Export returns all data visible to the user in a documented JSON structure.
type Export struct {
	Format     string    `json:"format"`
	ExportedAt time.Time `json:"exported_at"`
	User       UserInfo  `json:"user"`
	*Snapshot
}

func (s *Service) Export(ctx context.Context, actor Actor) (*Export, error) {
	snap, err := s.Snapshot(ctx, actor, nil)
	if err != nil {
		return nil, err
	}
	u, err := s.userInfo(ctx, s.Pool, actor.UserID)
	if err != nil {
		return nil, err
	}
	return &Export{Format: "ant-colony-manager/v1", ExportedAt: s.Now().UTC(), User: *u, Snapshot: snap}, nil
}

// MembersOf returns user ids that may see a colony (for realtime fan-out).
func (s *Service) MembersOf(ctx context.Context, colony uuid.UUID) ([]uuid.UUID, error) {
	rows, err := s.Pool.Query(ctx, `SELECT user_id FROM colony_members WHERE colony_id = $1 AND deleted_at IS NULL`, colony)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
}
