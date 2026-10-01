// Package service contains the business logic. HTTP handlers are thin adapters
// around it; every write – REST or sync – goes through ApplyOp.
package service

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/config"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/mail"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/storage"
)

type Service struct {
	Pool   *pgxpool.Pool
	Cfg    *config.Config
	Log    *slog.Logger
	Mail   mail.Sender
	Blobs  storage.BlobStore
	Tokens auth.TokenIssuer
	Now    func() time.Time
	// MQTTDial connects to the MQTT broker (Home Assistant); tests replace it.
	MQTTDial func(context.Context, MQTTOptions) (MQTTConn, error)
	// AIBaseURL overrides the Anthropic API address (tests).
	AIBaseURL string
	// OIDCClient talks to the SSO provider (tests replace it).
	OIDCClient *http.Client

	mqtt       mqttState
	oidc       oidcRuntime
	aiJobsMu   sync.Mutex
	aiJobs     map[uuid.UUID]*aiJob
	columns    map[string]map[string]bool // table -> column set (loaded at start)
	setupToken string
	imageSem   chan struct{}
}

func New(ctx context.Context, pool *pgxpool.Pool, cfg *config.Config, log *slog.Logger, m mail.Sender, blobs storage.BlobStore) (*Service, error) {
	s := &Service{
		Pool:  pool,
		Cfg:   cfg,
		Log:   log,
		Mail:  m,
		Blobs: blobs,
		Tokens: auth.TokenIssuer{
			Secret: cfg.JWTSecret,
			TTL:    cfg.AccessTTL,
			Issuer: "acm",
		},
		Now:      time.Now,
		MQTTDial: pahoDial,
		imageSem: make(chan struct{}, 2),
	}
	s.mqtt.kick = make(chan struct{}, 1)
	s.mqtt.haKick = make(chan struct{}, 1)
	if err := s.loadColumns(ctx); err != nil {
		return nil, err
	}
	if err := s.validateRegistry(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Service) loadColumns(ctx context.Context) error {
	rows, err := s.Pool.Query(ctx, `
		SELECT table_name, column_name FROM information_schema.columns
		WHERE table_schema = current_schema()`)
	if err != nil {
		return err
	}
	defer rows.Close()
	s.columns = map[string]map[string]bool{}
	for rows.Next() {
		var t, c string
		if err := rows.Scan(&t, &c); err != nil {
			return err
		}
		if s.columns[t] == nil {
			s.columns[t] = map[string]bool{}
		}
		s.columns[t][c] = true
	}
	return rows.Err()
}

func (s *Service) hasColumn(table, col string) bool { return s.columns[table][col] }

// validateRegistry makes sure every configured field exists in the schema, so a
// typo fails at startup instead of silently dropping data.
func (s *Service) validateRegistry() error {
	for name, e := range entities {
		if s.columns[name] == nil {
			return fmt.Errorf("registry: table %s missing", name)
		}
		for _, list := range [][]string{e.Fields, e.Immutable, e.OwnerOnly, e.Hidden, e.HexBytea} {
			for _, f := range list {
				if !s.columns[name][f] {
					return fmt.Errorf("registry: %s.%s does not exist", name, f)
				}
			}
		}
		for _, r := range e.Refs {
			if !s.columns[name][r.Field] {
				return fmt.Errorf("registry: ref %s.%s does not exist", name, r.Field)
			}
		}
	}
	return nil
}

// Audit writes a security-relevant event. Never pass secrets in meta.
func (s *Service) Audit(ctx context.Context, user *uuid.UUID, action, target string, meta map[string]any, ip netip.Addr) {
	var ipArg any
	if ip.IsValid() {
		ipArg = ip.String()
	}
	if _, err := s.Pool.Exec(ctx, `INSERT INTO audit_log (user_id, action, target, meta, ip) VALUES ($1, $2, NULLIF($3, ''), $4, $5)`,
		user, action, target, meta, ipArg); err != nil {
		s.Log.Warn("audit log write failed", "action", action, "err", err)
	}
}
