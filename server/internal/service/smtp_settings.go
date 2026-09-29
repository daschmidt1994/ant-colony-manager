package service

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	netmail "net/mail"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/config"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/mail"
)

// SMTP settings edited by an administrator in the app. They are stored in
// instance_settings ('smtp'), the password encrypted with a key derived from
// INSTANCE_SECRET, and take precedence over SMTP_* from the environment.

const smtpSettingsKey = "smtp"

type storedSMTP struct {
	Host        string `json:"host"`
	Port        int    `json:"port"`
	User        string `json:"user"`
	From        string `json:"from"`
	TLS         string `json:"tls"`
	PasswordEnc string `json:"password_enc,omitempty"`
}

// SMTPSettings is the admin API shape; the password is write-only.
type SMTPSettings struct {
	Host          string  `json:"host"`
	Port          int     `json:"port"`
	User          string  `json:"user"`
	From          string  `json:"from"`
	TLS           string  `json:"tls"`
	Password      *string `json:"password,omitempty"` // input: nil = keep, "" = remove
	PasswordSet   bool    `json:"password_set"`
	Source        string  `json:"source"`         // app | env | none – what is used right now
	EnvConfigured bool    `json:"env_configured"` // SMTP_* set in the environment
}

func (s *Service) loadStoredSMTP(ctx context.Context) (*storedSMTP, error) {
	var raw []byte
	err := s.Pool.QueryRow(ctx, `SELECT value FROM instance_settings WHERE key = $1`, smtpSettingsKey).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var st storedSMTP
	if err := json.Unmarshal(raw, &st); err != nil {
		return nil, err
	}
	return &st, nil
}

// effectiveSMTP: app settings if present, otherwise the environment.
func (s *Service) effectiveSMTP(st *storedSMTP) (config.SMTPConfig, string) {
	if st != nil && st.Host != "" {
		pw, err := s.decryptSecret(st.PasswordEnc)
		if err != nil {
			s.Log.Error("stored SMTP password cannot be decrypted (INSTANCE_SECRET changed?)", "err", err)
		}
		return config.SMTPConfig{Host: st.Host, Port: st.Port, User: st.User, Password: pw, From: st.From, TLS: st.TLS}, "app"
	}
	if s.Cfg.SMTP.Enabled() {
		return s.Cfg.SMTP, "env"
	}
	return config.SMTPConfig{}, "none"
}

// ApplyMailSettings activates the stored or environment SMTP configuration.
// Only possible when the service was built with a *mail.Switch (the server);
// tests with a recorder keep it.
func (s *Service) ApplyMailSettings(ctx context.Context) error {
	sw, ok := s.Mail.(*mail.Switch)
	if !ok {
		return nil
	}
	st, err := s.loadStoredSMTP(ctx)
	if err != nil {
		return err
	}
	cfg, _ := s.effectiveSMTP(st)
	sw.Set(mail.New(cfg, s.Log))
	return nil
}

func (s *Service) GetSMTPSettings(ctx context.Context, actor Actor) (*SMTPSettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	st, err := s.loadStoredSMTP(ctx)
	if err != nil {
		return nil, err
	}
	out := &SMTPSettings{Port: 587, TLS: "starttls", EnvConfigured: s.Cfg.SMTP.Enabled()}
	_, out.Source = s.effectiveSMTP(st)
	switch {
	case st != nil:
		out.Host, out.Port, out.User, out.From, out.TLS, out.PasswordSet = st.Host, st.Port, st.User, st.From, st.TLS, st.PasswordEnc != ""
	case s.Cfg.SMTP.Enabled():
		// show the environment values as a starting point (never the password)
		e := s.Cfg.SMTP
		out.Host, out.Port, out.User, out.From, out.TLS = e.Host, e.Port, e.User, e.From, e.TLS
	}
	return out, nil
}

// SetSMTPSettings saves (or with an empty host removes) the app settings and
// activates them immediately.
func (s *Service) SetSMTPSettings(ctx context.Context, actor Actor, in SMTPSettings, meta ClientMeta) (*SMTPSettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	in.Host = strings.TrimSpace(in.Host)
	if in.Host == "" {
		if _, err := s.Pool.Exec(ctx, `DELETE FROM instance_settings WHERE key = $1`, smtpSettingsKey); err != nil {
			return nil, err
		}
	} else {
		if err := validateSMTP(&in); err != nil {
			return nil, err
		}
		old, err := s.loadStoredSMTP(ctx)
		if err != nil {
			return nil, err
		}
		st := storedSMTP{Host: in.Host, Port: in.Port, User: in.User, From: in.From, TLS: in.TLS}
		switch {
		case in.Password == nil && old != nil:
			st.PasswordEnc = old.PasswordEnc
		case in.Password != nil && *in.Password != "":
			if st.PasswordEnc, err = s.encryptSecret(*in.Password); err != nil {
				return nil, err
			}
		}
		raw, _ := json.Marshal(st)
		if _, err := s.Pool.Exec(ctx, `INSERT INTO instance_settings (key, value) VALUES ($1, $2)
			ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = now()`, smtpSettingsKey, raw); err != nil {
			return nil, err
		}
	}
	s.Audit(ctx, &actor.UserID, "smtp_settings_changed", "", map[string]any{"host": in.Host}, meta.IP)
	if err := s.ApplyMailSettings(ctx); err != nil {
		return nil, err
	}
	return s.GetSMTPSettings(ctx, actor)
}

func validateSMTP(in *SMTPSettings) error {
	if strings.ContainsAny(in.Host, " /:\r\n") || len(in.Host) > 253 {
		return Invalid("host", "enter only the server name, e.g. smtp.example.com")
	}
	if in.Port < 1 || in.Port > 65535 {
		return Invalid("port", "port must be 1–65535")
	}
	switch in.TLS {
	case "starttls", "tls", "none":
	default:
		return Invalid("tls", "tls must be starttls, tls or none")
	}
	in.From = strings.TrimSpace(in.From)
	if a, err := netmail.ParseAddress(in.From); err != nil || strings.ContainsAny(in.From, "\r\n") {
		return Invalid("from", "sender must be an e-mail address, e.g. ameisen@example.com")
	} else if a.Name == "" {
		in.From = a.Address
	}
	in.User = strings.TrimSpace(in.User)
	if strings.ContainsAny(in.User, "\r\n") || len(in.User) > 320 ||
		(in.Password != nil && (strings.ContainsAny(*in.Password, "\r\n") || len(*in.Password) > 500)) {
		return Invalid("user", "invalid user or password")
	}
	return nil
}

// SendTestMail sends a test e-mail to the administrator with the active settings.
func (s *Service) SendTestMail(ctx context.Context, actor Actor) error {
	if err := requireAdmin(actor); err != nil {
		return err
	}
	if !s.Mail.Enabled() {
		return Invalid("host", "no e-mail server configured")
	}
	var email string
	if err := s.Pool.QueryRow(ctx, `SELECT email FROM users WHERE id = $1`, actor.UserID).Scan(&email); err != nil {
		return err
	}
	lang := s.userLang(ctx, actor.UserID)
	err := s.Mail.Send(ctx, mail.Message{To: email, Subject: tl(lang, "Ant Colony Manager: Test-E-Mail"),
		Body: tl(lang, "Der E-Mail-Versand funktioniert. 🐜") + "\n\n" + s.publicURL() + "/\n"})
	if err != nil {
		return &Problem{Status: 502, Code: "smtp.failed", Title: tl(lang, "E-Mail-Versand fehlgeschlagen: %v", err)}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Secrets at rest: AES-256-GCM with a key derived from INSTANCE_SECRET.

func (s *Service) secretAEAD() (cipher.AEAD, error) {
	block, err := aes.NewCipher(auth.HMAC(s.Cfg.InstanceSecret, "acm:stored-secrets:v1"))
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func (s *Service) encryptSecret(plain string) (string, error) {
	aead, err := s.secretAEAD()
	if err != nil {
		return "", err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(aead.Seal(nonce, nonce, []byte(plain), nil)), nil
}

func (s *Service) decryptSecret(enc string) (string, error) {
	if enc == "" {
		return "", nil
	}
	raw, err := base64.StdEncoding.DecodeString(enc)
	if err != nil {
		return "", err
	}
	aead, err := s.secretAEAD()
	if err != nil {
		return "", err
	}
	if len(raw) < aead.NonceSize() {
		return "", fmt.Errorf("stored secret too short")
	}
	plain, err := aead.Open(nil, raw[:aead.NonceSize()], raw[aead.NonceSize():], nil)
	return string(plain), err
}
