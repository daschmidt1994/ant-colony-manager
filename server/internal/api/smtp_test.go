package api_test

import (
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/config"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/mail"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/testenv"
)

func TestSMTPSettingsInTheApp(t *testing.T) {
	env := testenv.New(t)
	admin := env.Admin(t)
	anna := env.User(t, "Anna")

	anna.Do("GET", "/api/v1/admin/smtp", nil).Must(t, http.StatusForbidden)
	anna.Do("PUT", "/api/v1/admin/smtp", map[string]any{"host": "smtp.evil.test"}).Must(t, http.StatusForbidden)

	// Server without SMTP_*: nothing configured, e-mail off until saved in the app.
	env.Svc.Mail = mail.NewSwitch(mail.New(config.SMTPConfig{}, slog.New(slog.NewTextHandler(io.Discard, nil))))
	st := admin.Do("GET", "/api/v1/admin/smtp", nil).Must(t, 200).JSON()
	if st["source"] != "none" || st["port"] != 587.0 || st["tls"] != "starttls" || env.Svc.Mail.Enabled() {
		t.Fatalf("initial: %v", st)
	}

	in := map[string]any{"host": "smtp.example.com", "port": 465, "tls": "tls", "user": "ameisen@example.com",
		"password": "geheim-123", "from": "Ameisen <ameisen@example.com>"}
	st = admin.Do("PUT", "/api/v1/admin/smtp", in).Must(t, 200).JSON()
	if st["source"] != "app" || st["password_set"] != true || st["password"] != nil || st["from"] != "Ameisen <ameisen@example.com>" {
		t.Fatalf("saved: %v", st)
	}
	if !env.Svc.Mail.Enabled() {
		t.Fatal("settings not active without restart")
	}
	// The password is stored encrypted, never in plain text.
	var raw string
	if err := env.Pool.QueryRow(t.Context(), `SELECT value::text FROM instance_settings WHERE key = 'smtp'`).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(raw, "geheim-123") || !strings.Contains(raw, "password_enc") {
		t.Fatalf("stored: %s", raw)
	}
	// Password omitted → kept; "" → removed.
	delete(in, "password")
	if st := admin.Do("PUT", "/api/v1/admin/smtp", in).Must(t, 200).JSON(); st["password_set"] != true {
		t.Fatalf("password lost: %v", st)
	}
	in["password"] = ""
	if st := admin.Do("PUT", "/api/v1/admin/smtp", in).Must(t, 200).JSON(); st["password_set"] != false {
		t.Fatalf("password not removed: %v", st)
	}

	for name, body := range map[string]map[string]any{
		"url as host": {"host": "smtp://x.com", "port": 587, "tls": "starttls", "from": "a@b.c"},
		"bad port":    {"host": "x.com", "port": 0, "tls": "starttls", "from": "a@b.c"},
		"bad tls":     {"host": "x.com", "port": 587, "tls": "ssl3", "from": "a@b.c"},
		"bad from":    {"host": "x.com", "port": 587, "tls": "starttls", "from": "keine adresse"},
		"crlf user":   {"host": "x.com", "port": 587, "tls": "starttls", "from": "a@b.c", "user": "a\r\nRCPT TO:x"},
	} {
		if r := admin.Do("PUT", "/api/v1/admin/smtp", body); r.Status < 400 || r.Status >= 500 {
			t.Errorf("%s: want 4xx, got %d", name, r.Status)
		}
	}

	// Empty host removes the app settings → e-mail off again.
	st = admin.Do("PUT", "/api/v1/admin/smtp", map[string]any{"host": ""}).Must(t, 200).JSON()
	if st["source"] != "none" || env.Svc.Mail.Enabled() {
		t.Fatalf("after removing: %v", st)
	}
	admin.Do("POST", "/api/v1/admin/smtp/test", nil).Must(t, 422)

	// Test e-mail goes to the administrator (recorder instead of a real server).
	env.Svc.Mail = env.Mail
	admin.Do("POST", "/api/v1/admin/smtp/test", nil).Must(t, 204)
	msgs := env.Mail.Messages()
	if m := msgs[len(msgs)-1]; !strings.Contains(m.Subject, "Test-E-Mail") || m.To == "" {
		t.Fatalf("test mail: %+v", m)
	}
}
