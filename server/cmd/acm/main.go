// Command acm is the Ant Colony Manager server.
//
//	acm serve                       start the server (default)
//	acm migrate status|up           inspect or apply database migrations
//	acm healthcheck                 exit 0 if the local server is ready (Docker HEALTHCHECK)
//	acm user reset-link <email>     print a password reset link (no SMTP needed)
//	acm user make-admin <email>     grant administrator rights
//	acm offsite-restore [--list] [--to DIR] [NAME]
//	                                download a backup from the off-site target
//	                                (decrypted, checked) for scripts/restore.sh
//	acm version
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata" // time zones in distroless images

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/api"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/config"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/mail"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/service"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/storage"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/webui"
)

// version is set at build time: -ldflags "-X main.version=1.2.3"
var version = "dev"

func main() {
	args := os.Args[1:]
	cmd := "serve"
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve()
	case "migrate":
		err = migrate(args)
	case "healthcheck":
		err = healthcheck()
	case "user":
		err = userCmd(args)
	case "offsite-restore":
		err = offsiteRestore(args)
	case "version", "--version", "-v":
		fmt.Println(version)
	default:
		err = fmt.Errorf("unknown command %q (serve, migrate, healthcheck, user, offsite-restore, version)", cmd)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// sensitiveKeys are never written to logs, whatever the call site passes.
var sensitiveKeys = []string{"password", "token", "secret", "authorization", "cookie", "api_key", "sig"}

func newLogger(level, format string) *slog.Logger {
	var lv slog.Level
	if err := lv.UnmarshalText([]byte(level)); err != nil {
		lv = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: lv, ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
		k := strings.ToLower(a.Key)
		for _, s := range sensitiveKeys {
			if strings.Contains(k, s) {
				return slog.String(a.Key, "[redacted]")
			}
		}
		return a
	}}
	if format == "text" {
		return slog.New(slog.NewTextHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, opts))
}

func setup(ctx context.Context) (*config.Config, *slog.Logger, *pgxpool.Pool, error) {
	cfg, err := config.Load()
	if err != nil {
		return nil, nil, nil, fmt.Errorf("configuration invalid:\n%w", err)
	}
	log := newLogger(cfg.LogLevel, cfg.LogFormat)
	var pool *pgxpool.Pool
	// The database container may still be starting.
	deadline := time.Now().Add(90 * time.Second)
	for {
		pool, err = db.Connect(ctx, cfg.DatabaseURL)
		if err == nil || time.Now().After(deadline) {
			break
		}
		log.Info("waiting for database", "err", err)
		select {
		case <-ctx.Done():
			return nil, nil, nil, ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	if err != nil {
		return nil, nil, nil, err
	}
	return cfg, log, pool, nil
}

func serve() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, log, pool, err := setup(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	log.Info("starting Ant Colony Manager", "version", version, "public_url", cfg.PublicURL.String(), "env", cfg.Env)

	if err := db.Migrate(ctx, pool, log); err != nil {
		return err
	}
	blobs, err := storage.NewFS(cfg.StoragePath)
	if err != nil {
		return err
	}
	svc, err := service.New(ctx, pool, cfg, log, mail.NewSwitch(mail.New(cfg.SMTP, log)), blobs)
	if err != nil {
		return err
	}
	// E-mail server set in the app (Mehr → Server-Verwaltung) wins over SMTP_*.
	if err := svc.ApplyMailSettings(ctx); err != nil {
		return err
	}
	if tok, err := svc.EnsureSetupToken(ctx); err != nil {
		return err
	} else if tok != "" {
		// Printed on purpose: the operator needs it once to create the admin account.
		fmt.Printf("\n  ┌─ Ersteinrichtung ────────────────────────────────────────────\n"+
			"  │ Öffne %s/setup und gib diesen Setup-Code ein:\n  │   %s\n"+
			"  └──────────────────────────────────────────────────────────────\n\n",
			strings.TrimRight(cfg.PublicURL.String(), "/"), tok)
	}

	broker := api.NewBroker(pool, svc, log)
	go broker.Run(ctx)
	srv := api.NewServer(svc, cfg, log, version, webui.FS(), broker)

	go func() {
		t := time.NewTicker(time.Hour)
		defer t.Stop()
		first := time.After(time.Minute)
		for {
			select {
			case <-ctx.Done():
				return
			case <-first:
			case <-t.C:
			}
			if err := svc.Maintenance(ctx); err != nil && ctx.Err() == nil {
				log.Error("maintenance failed", "err", err)
			}
			srv.GCLimiters()
		}
	}()

	// Daily digest (e-mail/ntfy, once per day at each user's time) and
	// notifications (overdue, sensor alarm, winter rest): checked every minute.
	go func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
			if n, err := svc.SendDigests(ctx); err != nil && ctx.Err() == nil {
				log.Error("digest failed", "err", err)
			} else if n > 0 {
				log.Info("digest sent", "count", n)
			}
			if n, err := svc.SendNotifications(ctx); err != nil && ctx.Err() == nil {
				log.Error("notifications failed", "err", err)
			} else if n > 0 {
				log.Info("notifications sent", "count", n)
			}
		}
	}()

	// Off-site backup: upload each new local backup (WebDAV, set up by the admin).
	go func() {
		t := time.NewTicker(10 * time.Minute)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
			}
			if _, err := svc.OffsiteSync(ctx, false); err != nil && ctx.Err() == nil {
				log.Error("off-site backup failed", "err", err)
			}
			if _, err := svc.OffsiteWatch(ctx); err != nil && ctx.Err() == nil {
				log.Error("off-site backup warning failed", "err", err)
			}
		}
	}()

	// Home Assistant: colonies as devices via MQTT discovery (set up by the admin).
	go svc.MQTTRun(ctx)
	go svc.HARun(ctx)

	httpSrv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       5 * time.Minute, // large photo uploads on slow mobile links
		WriteTimeout:      2 * time.Minute,
		IdleTimeout:       2 * time.Minute,
		MaxHeaderBytes:    64 << 10,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}
	errCh := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", cfg.ListenAddr)
		errCh <- httpSrv.ListenAndServe()
	}()
	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func migrate(args []string) error {
	ctx := context.Background()
	_, log, pool, err := setup(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	sub := "status"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "up":
		return db.Migrate(ctx, pool, log)
	case "status":
		applied, pending, err := db.MigrationStatus(ctx, pool)
		if err != nil {
			return err
		}
		for _, v := range applied {
			fmt.Println("applied  ", v)
		}
		for _, v := range pending {
			fmt.Println("pending  ", v)
		}
		return nil
	}
	return fmt.Errorf("usage: acm migrate status|up")
}

// healthcheck only needs LISTEN_ADDR, so it works even if other settings are broken.
func healthcheck() error {
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		return err
	}
	c := http.Client{Timeout: 4 * time.Second}
	resp, err := c.Get("http://127.0.0.1:" + port + "/readyz")
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("not ready: %s", resp.Status)
	}
	return nil
}

func userCmd(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: acm user reset-link|make-admin <email>")
	}
	ctx := context.Background()
	cfg, log, pool, err := setup(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	svc, err := service.New(ctx, pool, cfg, log, mail.New(config.SMTPConfig{}, log), nil)
	if err != nil {
		return err
	}
	switch args[0] {
	case "reset-link":
		link, err := svc.AdminResetLink(ctx, args[1])
		if err != nil {
			return err
		}
		fmt.Println("Passwort-Reset-Link (30 Minuten gültig):")
		fmt.Println(link)
		return nil
	case "make-admin":
		tag, err := pool.Exec(ctx, `UPDATE users SET instance_role = 'admin' WHERE email = $1`, strings.ToLower(args[1]))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return fmt.Errorf("no user with e-mail %s", args[1])
		}
		fmt.Println("done")
		return nil
	}
	return fmt.Errorf("unknown user command %q", args[0])
}

// offsiteRestore downloads a backup from the off-site target into DIR/NAME
// (default /data/backups), ready for scripts/restore.sh. The target comes
// from ACM_OFFSITE_TYPE/URL/USER/PASSWORD – for a new server without the old
// settings – or else from the settings in the app. Encrypted backups need
// ACM_OFFSITE_PASSPHRASE (or it is asked for). Prints the backup name last.
func offsiteRestore(args []string) error {
	to, name, list := "/data/backups", "", false
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--list":
			list = true
		case a == "--to" && i+1 < len(args):
			to = args[i+1]
			i++
		case strings.HasPrefix(a, "-"):
			return fmt.Errorf("usage: acm offsite-restore [--list] [--to DIR] [NAME]")
		default:
			name = a
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var d service.OffsiteTarget
	var err error
	if u := os.Getenv("ACM_OFFSITE_URL"); u != "" {
		d, err = service.OpenOffsiteTarget(service.OffsiteTargetConfig{Type: os.Getenv("ACM_OFFSITE_TYPE"), URL: u,
			User: os.Getenv("ACM_OFFSITE_USER"), Password: os.Getenv("ACM_OFFSITE_PASSWORD")})
	} else {
		cfg, log, pool, serr := setup(ctx)
		if serr != nil {
			return fmt.Errorf("%w\n(without the old database: give the target with ACM_OFFSITE_TYPE, ACM_OFFSITE_URL, ACM_OFFSITE_USER, ACM_OFFSITE_PASSWORD)", serr)
		}
		defer pool.Close()
		svc, serr := service.New(ctx, pool, cfg, log, mail.New(config.SMTPConfig{}, log), nil)
		if serr != nil {
			return serr
		}
		d, err = svc.OffsiteTargetFromSettings(ctx)
	}
	if err != nil {
		return err
	}
	defer service.CloseOffsiteTarget(d)

	backups, encrypted, err := service.OffsiteRemoteBackups(ctx, d)
	if err != nil {
		return err
	}
	if list {
		for _, b := range backups {
			fmt.Println(b)
		}
		if encrypted {
			fmt.Fprintln(os.Stderr, "(verschlüsselt – zum Wiederherstellen wird die Passphrase gebraucht)")
		}
		return nil
	}
	pass := os.Getenv("ACM_OFFSITE_PASSPHRASE")
	if encrypted && pass == "" {
		fmt.Fprint(os.Stderr, "Passphrase der verschlüsselten Backups: ")
		line, rerr := bufio.NewReader(os.Stdin).ReadString('\n')
		if rerr != nil && line == "" {
			return fmt.Errorf("no passphrase: %w", rerr)
		}
		pass = strings.TrimRight(line, "\r\n")
	}
	got, err := service.OffsiteFetch(ctx, d, name, to, pass, func(step string) {
		fmt.Fprintln(os.Stderr, "  "+step)
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "Backup %s liegt vollständig in %s\n", got, filepath.Join(to, got))
	fmt.Println(got)
	return nil
}
