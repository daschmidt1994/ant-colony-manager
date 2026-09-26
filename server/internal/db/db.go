// Package db owns the PostgreSQL connection pool, transactions and schema migrations.
package db

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrationFS embed.FS

// migrationLockID is an arbitrary constant for pg_advisory_lock so that only one
// app instance migrates at a time.
const migrationLockID = 7_314_159_265

// Querier is implemented by *pgxpool.Pool and pgx.Tx.
type Querier interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

func Connect(ctx context.Context, url string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	cfg.MaxConns = 10
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("database not reachable: %w", err)
	}
	return pool, nil
}

// InTx runs fn inside a transaction and commits if fn returns nil.
func InTx(ctx context.Context, pool *pgxpool.Pool, fn func(tx pgx.Tx) error) error {
	return InTxOpts(ctx, pool, pgx.TxOptions{}, fn)
}

func InTxOpts(ctx context.Context, pool *pgxpool.Pool, opts pgx.TxOptions, fn func(tx pgx.Tx) error) error {
	tx, err := pool.BeginTx(ctx, opts)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after commit
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

type migration struct {
	version string
	sql     string
}

func loadMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrationFS, "migrations")
	if err != nil {
		return nil, err
	}
	var out []migration
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".sql") {
			continue
		}
		b, err := migrationFS.ReadFile("migrations/" + name)
		if err != nil {
			return nil, err
		}
		out = append(out, migration{version: strings.TrimSuffix(name, ".sql"), sql: string(b)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].version < out[j].version })
	return out, nil
}

// LatestVersion is the newest migration embedded in this binary.
func LatestVersion() string {
	ms, err := loadMigrations()
	if err != nil || len(ms) == 0 {
		return ""
	}
	return ms[len(ms)-1].version
}

// MigrationStatus returns applied and pending migration versions.
func MigrationStatus(ctx context.Context, pool *pgxpool.Pool) (applied, pending []string, err error) {
	ms, err := loadMigrations()
	if err != nil {
		return nil, nil, err
	}
	done, err := appliedVersions(ctx, pool)
	if err != nil {
		return nil, nil, err
	}
	for _, m := range ms {
		if done[m.version] {
			applied = append(applied, m.version)
		} else {
			pending = append(pending, m.version)
		}
	}
	return applied, pending, nil
}

func appliedVersions(ctx context.Context, q Querier) (map[string]bool, error) {
	if _, err := q.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return nil, err
	}
	rows, err := q.Query(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return nil, err
	}
	versions, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	done := make(map[string]bool, len(versions))
	for _, v := range versions {
		done[v] = true
	}
	return done, nil
}

// ErrSchemaTooNew means the database was migrated by a newer app version.
var ErrSchemaTooNew = errors.New("database schema is newer than this application – refusing to start (downgrade?)")

// Migrate applies all pending migrations, each in its own transaction, guarded by
// an advisory lock.
func Migrate(ctx context.Context, pool *pgxpool.Pool, log *slog.Logger) error {
	ms, err := loadMigrations()
	if err != nil {
		return err
	}
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock($1)`, migrationLockID); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock($1)`, migrationLockID) //nolint:errcheck

	done, err := appliedVersions(ctx, conn)
	if err != nil {
		return err
	}
	known := make(map[string]bool, len(ms))
	for _, m := range ms {
		known[m.version] = true
	}
	for v := range done {
		if !known[v] {
			return fmt.Errorf("%w: unknown migration %s", ErrSchemaTooNew, v)
		}
	}
	for _, m := range ms {
		if done[m.version] {
			continue
		}
		log.Info("applying migration", "version", m.version)
		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		// Simple protocol (no args) allows multi-statement scripts.
		if _, err := tx.Exec(ctx, m.sql); err != nil {
			_ = tx.Rollback(ctx)
			return fmt.Errorf("migration %s: %w", m.version, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations (version) VALUES ($1)`, m.version); err != nil {
			_ = tx.Rollback(ctx)
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
	}
	return nil
}

// PG error helpers ----------------------------------------------------------

func PgCode(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code
	}
	return ""
}

func PgError(err error) *pgconn.PgError {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr
	}
	return nil
}

const (
	CodeUniqueViolation     = "23505"
	CodeForeignKeyViolation = "23503"
	CodeCheckViolation      = "23514"
	CodeNotNullViolation    = "23502"
	CodeInvalidText         = "22P02"
	CodeInvalidDatetime     = "22007"
	CodeDatetimeOverflow    = "22008"
	CodeNumericOutOfRange   = "22003"
	CodeStringTooLong       = "22001"
	CodeInvalidJSON         = "22023"
)

// IsDataError reports whether err was caused by invalid client input rather than
// a server fault.
func IsDataError(err error) bool {
	c := PgCode(err)
	return strings.HasPrefix(c, "22") || strings.HasPrefix(c, "23")
}
