// Package testenv starts a complete server against a real PostgreSQL database
// for integration tests. Each test gets its own database cloned from a
// migrated template, so tests are isolated and fast.
//
// Set TEST_DATABASE_URL to a PostgreSQL 18 superuser connection, e.g.
// postgres://postgres:test@localhost:55432/postgres?sslmode=disable
// (scripts/test-server.sh does this automatically).
package testenv

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/api"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/config"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/mail"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/storage"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/webui"
)

const SetupToken = "test-setup-token-0123456789"

var (
	templateOnce sync.Once
	templateErr  error
	templateName string
)

func adminURL(t testing.TB) string {
	u := os.Getenv("TEST_DATABASE_URL")
	if u == "" {
		t.Skip("TEST_DATABASE_URL not set – run scripts/test-server.sh")
	}
	return u
}

func withDB(base, name string) string {
	u, _ := url.Parse(base)
	u.Path = "/" + name
	return u.String()
}

func prepareTemplate(t testing.TB) {
	templateOnce.Do(func() {
		ctx := context.Background()
		base := adminURL(t)
		templateName = fmt.Sprintf("acm_tpl_%d", time.Now().UnixNano())
		conn, err := pgx.Connect(ctx, base)
		if err != nil {
			templateErr = err
			return
		}
		defer conn.Close(ctx)
		if _, err := conn.Exec(ctx, "CREATE DATABASE "+templateName); err != nil {
			templateErr = err
			return
		}
		pool, err := db.Connect(ctx, withDB(base, templateName))
		if err != nil {
			templateErr = err
			return
		}
		templateErr = db.Migrate(ctx, pool, slog.New(slog.NewTextHandler(io.Discard, nil)))
		pool.Close()
	})
	if templateErr != nil {
		t.Fatalf("prepare template database: %v", templateErr)
	}
}

type Options struct {
	RegistrationMode string // default "open"
	Env              map[string]string
}

type Env struct {
	T       testing.TB
	Cfg     *config.Config
	Pool    *pgxpool.Pool
	Svc     *service.Service
	Server  *api.Server
	HTTP    *httptest.Server
	Mail    *mail.Recorder
	Storage string
	Clock   *Clock
}

// Clock is a controllable time source for the service.
type Clock struct {
	mu     sync.Mutex
	offset time.Duration
}

func (c *Clock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return time.Now().Add(c.offset)
}

func (c *Clock) Advance(d time.Duration) {
	c.mu.Lock()
	c.offset += d
	c.mu.Unlock()
}

func New(t testing.TB, opts ...Options) *Env {
	t.Helper()
	prepareTemplate(t)
	ctx := context.Background()
	base := adminURL(t)
	name := "acm_t_" + strings.ReplaceAll(uuid.NewString(), "-", "")[:20]
	conn, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, fmt.Sprintf("CREATE DATABASE %s TEMPLATE %s", name, templateName)); err != nil {
		t.Fatal(err)
	}
	conn.Close(ctx)

	var o Options
	if len(opts) > 0 {
		o = opts[0]
	}
	if o.RegistrationMode == "" {
		o.RegistrationMode = "open"
	}
	storageDir := t.TempDir()
	vars := map[string]string{
		"APP_ENV":           "development",
		"PUBLIC_APP_URL":    "https://ants.test",
		"DATABASE_URL":      withDB(base, name),
		"JWT_SECRET":        "jwt-0123456789abcdefghijklmnopqrstuvwxyz",
		"INSTANCE_SECRET":   "inst-0123456789abcdefghijklmnopqrstuvwxyz",
		"STORAGE_PATH":      storageDir,
		"REGISTRATION_MODE": o.RegistrationMode,
		"SETUP_TOKEN":       SetupToken,
		"UPLOAD_MAX_MB":     "2",
		"BACKUP_STATUS_DIR": "",
	}
	for k, v := range o.Env {
		vars[k] = v
	}
	cfg, err := config.LoadFrom(func(k string) string { return vars[k] })
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	if os.Getenv("TEST_VERBOSE_LOG") != "" {
		log = slog.New(slog.NewTextHandler(os.Stderr, nil))
	}
	blobs, err := storage.NewFS(storageDir)
	if err != nil {
		t.Fatal(err)
	}
	rec := &mail.Recorder{}
	svc, err := service.New(ctx, pool, cfg, log, rec, blobs)
	if err != nil {
		t.Fatal(err)
	}
	clock := &Clock{}
	svc.Now = clock.Now
	broker := api.NewBroker(pool, svc, log)
	bctx, cancel := context.WithCancel(context.Background())
	go broker.Run(bctx)
	srv := api.NewServer(svc, cfg, log, "test", webui.FS(), broker)
	hs := httptest.NewServer(srv.Handler())

	env := &Env{T: t, Cfg: cfg, Pool: pool, Svc: svc, Server: srv, HTTP: hs, Mail: rec, Storage: storageDir, Clock: clock}
	t.Cleanup(func() {
		hs.Close()
		cancel()
		pool.Close()
		c, err := pgx.Connect(context.Background(), base)
		if err == nil {
			_, _ = c.Exec(context.Background(), "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)")
			c.Close(context.Background())
		}
	})
	return env
}

func init() {
	// Fast password hashing in tests (production parameters are tested in auth).
	auth.Params = auth.Argon2Params{Memory: 1024, Time: 1, Threads: 1}
}

// ---------------------------------------------------------------------------
// HTTP client helpers

type Client struct {
	Env          *Env
	Token        string
	RefreshToken string
	UserID       uuid.UUID
	Email        string
	DeviceID     uuid.UUID
	Headers      map[string]string
}

type Response struct {
	Status int
	Header http.Header
	Body   []byte
}

// JSON decodes the body into a generic map.
func (r *Response) JSON() map[string]any {
	var m map[string]any
	_ = json.Unmarshal(r.Body, &m)
	return m
}

func (r *Response) Decode(t testing.TB, v any) {
	t.Helper()
	if err := json.Unmarshal(r.Body, v); err != nil {
		t.Fatalf("decode %s: %v", r.Body, err)
	}
}

// Code returns the problem code of an error response.
func (r *Response) Code() string {
	c, _ := r.JSON()["code"].(string)
	return c
}

func (e *Env) Anon() *Client { return &Client{Env: e, Headers: map[string]string{}} }

func (c *Client) Do(method, path string, body any, headers ...string) *Response {
	c.Env.T.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case []byte:
		rd = bytes.NewReader(b)
	case string:
		rd = strings.NewReader(b)
	default:
		j, err := json.Marshal(b)
		if err != nil {
			c.Env.T.Fatal(err)
		}
		rd = bytes.NewReader(j)
	}
	req, err := http.NewRequest(method, c.Env.HTTP.URL+path, rd)
	if err != nil {
		c.Env.T.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	for k, v := range c.Headers {
		req.Header.Set(k, v)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.Env.T.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return &Response{Status: resp.StatusCode, Header: resp.Header, Body: b}
}

// Must fails the test unless the status matches.
func (r *Response) Must(t testing.TB, status int) *Response {
	t.Helper()
	if r.Status != status {
		t.Fatalf("expected HTTP %d, got %d: %s", status, r.Status, r.Body)
	}
	return r
}

type sessionJSON struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	User         struct {
		ID    uuid.UUID `json:"id"`
		Email string    `json:"email"`
	} `json:"user"`
}

func (e *Env) clientFrom(t testing.TB, r *Response) *Client {
	t.Helper()
	var s sessionJSON
	r.Decode(t, &s)
	return &Client{Env: e, Token: s.AccessToken, RefreshToken: s.RefreshToken, UserID: s.User.ID, Email: s.User.Email,
		DeviceID: uuid.Must(uuid.NewV7()), Headers: map[string]string{}}
}

// Admin completes the setup and returns the admin client.
func (e *Env) Admin(t testing.TB) *Client {
	t.Helper()
	r := e.Anon().Do("POST", "/api/v1/setup", map[string]any{"email": "admin@ants.test", "password": "Formicarium-2026!",
		"display_name": "Admin", "setup_token": SetupToken}).Must(t, http.StatusCreated)
	return e.clientFrom(t, r)
}

// User registers a new account (setup must be done; mode open).
func (e *Env) User(t testing.TB, name string) *Client {
	t.Helper()
	if setup, _ := e.Svc.SetupRequired(context.Background()); setup {
		e.Admin(t)
	}
	email := strings.ToLower(name) + "@ants.test"
	r := e.Anon().Do("POST", "/api/v1/auth/register", map[string]any{"email": email, "password": "Messor-barbarus-12",
		"display_name": name}).Must(t, http.StatusCreated)
	return e.clientFrom(t, r)
}

// ---------------------------------------------------------------------------
// Sync helpers

type Op = service.Op

func NewID() uuid.UUID { return uuid.Must(uuid.NewV7()) }

func Payload(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

type PushResult struct {
	Results []struct {
		OpID      uuid.UUID `json:"op_id"`
		Status    string    `json:"status"`
		Version   int64     `json:"version"`
		Conflicts []string  `json:"conflicts"`
		Error     *struct {
			Code  string `json:"code"`
			Title string `json:"title"`
			Field string `json:"field"`
		} `json:"error"`
		Extra map[string]any `json:"extra"`
	} `json:"results"`
	ServerSeq int64 `json:"server_seq"`
}

func (c *Client) Push(t testing.TB, ops ...Op) PushResult {
	t.Helper()
	r := c.Do("POST", "/api/v1/sync/push", map[string]any{"device_id": c.DeviceID, "platform": "android",
		"device_name": "Test-Handy", "ops": ops}).Must(t, http.StatusOK)
	var pr PushResult
	r.Decode(t, &pr)
	return pr
}

type Change struct {
	Seq    int64           `json:"seq"`
	Entity string          `json:"entity"`
	Op     string          `json:"op"`
	ID     uuid.UUID       `json:"id"`
	Data   json.RawMessage `json:"data"`
}

type PullResult struct {
	Changes []Change `json:"changes"`
	Next    int64    `json:"next"`
	HasMore bool     `json:"has_more"`
}

func (c *Client) Pull(t testing.TB, since int64) PullResult {
	t.Helper()
	r := c.Do("GET", fmt.Sprintf("/api/v1/sync/pull?since=%d", since), nil).Must(t, http.StatusOK)
	var pr PullResult
	r.Decode(t, &pr)
	return pr
}

// CreateColony creates a colony via REST and returns its id.
func (c *Client) CreateColony(t testing.TB, fields map[string]any) uuid.UUID {
	t.Helper()
	if fields == nil {
		fields = map[string]any{}
	}
	if _, ok := fields["name"]; !ok {
		fields["name"] = "Messor #1"
	}
	if _, ok := fields["species_text"]; !ok {
		fields["species_text"] = "Messor barbarus"
	}
	r := c.Do("POST", "/api/v1/colonies", fields).Must(t, http.StatusCreated)
	var w struct {
		Data struct {
			ID uuid.UUID `json:"id"`
		} `json:"data"`
	}
	r.Decode(t, &w)
	return w.Data.ID
}

// Count runs SELECT count(*) with args.
func (e *Env) Count(t testing.TB, sql string, args ...any) int {
	t.Helper()
	var n int
	if err := e.Pool.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
