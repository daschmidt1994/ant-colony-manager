// Package config loads and validates all settings from environment variables.
// The server refuses to start with missing or weak secrets.
package config

import (
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Env          string // production | development
	ListenAddr   string
	InstanceName string
	BackupDir    string // read-only view of backup status (admin UI)

	PublicURL  *url.URL
	LegacyURLs []*url.URL

	DatabaseURL string

	JWTSecret      []byte
	InstanceSecret []byte

	StoragePath       string
	UploadMaxBytes    int64
	PhotoKeepOriginal bool

	RegistrationMode string // open | invite | closed
	RefreshTTL       time.Duration
	AccessTTL        time.Duration
	SetupToken       string // optional fixed setup token (automation); otherwise random

	SMTP SMTPConfig

	TrustedProxies []netip.Prefix

	AndroidAppID       string
	AndroidCertSHA256  []string
	TombstoneRetention time.Duration

	LogLevel  string
	LogFormat string

	// Update check against the public GitHub release list (no data is sent).
	UpdateCheck bool
	UpdateURL   string
}

type SMTPConfig struct {
	Host     string
	Port     int
	User     string
	Password string
	From     string
	TLS      string // starttls | tls | none
}

func (s SMTPConfig) Enabled() bool { return s.Host != "" && s.From != "" }

// Getenv abstracts os.Getenv for tests.
type Getenv func(string) string

func Load() (*Config, error) { return LoadFrom(os.Getenv) }

var weakMarkers = []string{"change-me", "changeme", "example", "secret", "password"}

// ReadFile is used for *_FILE variables (replaceable in tests).
var ReadFile = os.ReadFile

// fileSecrets may be given as KEY or KEY_FILE (Docker secrets, generated files).
var fileSecrets = []string{"JWT_SECRET", "INSTANCE_SECRET", "POSTGRES_PASSWORD", "SMTP_PASSWORD"}

func LoadFrom(getenv Getenv) (*Config, error) {
	var errs []error
	get := func(k string) string {
		if v := getenv(k); v != "" {
			return v
		}
		for _, s := range fileSecrets {
			if s == k {
				if path := getenv(k + "_FILE"); path != "" {
					b, err := ReadFile(path)
					if err != nil {
						errs = append(errs, fmt.Errorf("%s_FILE: %w", k, err))
						return ""
					}
					return strings.TrimSpace(string(b))
				}
			}
		}
		return ""
	}
	str := func(key, def string) string {
		if v := strings.TrimSpace(get(key)); v != "" {
			return v
		}
		return def
	}
	integer := func(key string, def int) int {
		v := str(key, "")
		if v == "" {
			return def
		}
		n, err := strconv.Atoi(v)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: not a number", key))
			return def
		}
		return n
	}
	boolean := func(key string, def bool) bool {
		v := strings.ToLower(str(key, ""))
		switch v {
		case "":
			return def
		case "1", "true", "yes", "on":
			return true
		case "0", "false", "no", "off":
			return false
		}
		errs = append(errs, fmt.Errorf("%s: expected true/false", key))
		return def
	}
	secret := func(key string) []byte {
		v := get(key)
		if v == "" {
			errs = append(errs, fmt.Errorf("%s is required (generate with: openssl rand -base64 48)", key))
			return nil
		}
		if len(v) < 32 {
			errs = append(errs, fmt.Errorf("%s must be at least 32 characters", key))
		}
		lv := strings.ToLower(v)
		for _, m := range weakMarkers {
			if strings.Contains(lv, m) {
				errs = append(errs, fmt.Errorf("%s looks like a placeholder value – please generate a random secret", key))
				break
			}
		}
		return []byte(v)
	}

	c := &Config{
		Env:                str("APP_ENV", "production"),
		ListenAddr:         str("LISTEN_ADDR", ":8080"),
		InstanceName:       str("INSTANCE_NAME", "Ant Colony Manager"),
		BackupDir:          str("BACKUP_STATUS_DIR", "/data/backups"),
		StoragePath:        str("STORAGE_PATH", "/data/uploads"),
		UploadMaxBytes:     int64(integer("UPLOAD_MAX_MB", 20)) << 20,
		PhotoKeepOriginal:  boolean("PHOTO_KEEP_ORIGINAL", false),
		RegistrationMode:   str("REGISTRATION_MODE", "invite"),
		RefreshTTL:         time.Duration(integer("SESSION_REFRESH_DAYS", 90)) * 24 * time.Hour,
		AccessTTL:          time.Duration(integer("ACCESS_TOKEN_MINUTES", 15)) * time.Minute,
		SetupToken:         str("SETUP_TOKEN", ""),
		AndroidAppID:       str("ANDROID_APP_ID", "at.antcolony.manager"),
		TombstoneRetention: time.Duration(integer("TOMBSTONE_RETENTION_DAYS", 180)) * 24 * time.Hour,
		LogLevel:           str("LOG_LEVEL", "info"),
		LogFormat:          str("LOG_FORMAT", "json"),
		UpdateCheck:        boolean("UPDATE_CHECK", true),
		UpdateURL:          str("UPDATE_URL", "https://api.github.com/repos/daschmidt1994/ant-colony-manager/releases?per_page=20"),
		SMTP: SMTPConfig{
			Host:     str("SMTP_HOST", ""),
			Port:     integer("SMTP_PORT", 587),
			User:     str("SMTP_USER", ""),
			Password: get("SMTP_PASSWORD"),
			From:     str("SMTP_FROM", ""),
			TLS:      str("SMTP_TLS", "starttls"),
		},
	}

	// Public URL -----------------------------------------------------------
	pub := str("PUBLIC_APP_URL", "")
	if pub == "" {
		errs = append(errs, errors.New("PUBLIC_APP_URL is required, e.g. https://ants.example.com or http://192.168.1.50:8080"))
	} else if u, err := parseBaseURL(pub); err != nil {
		errs = append(errs, fmt.Errorf("PUBLIC_APP_URL: %w", err))
	} else {
		c.PublicURL = u
	}
	for _, raw := range splitList(get("LEGACY_APP_URLS")) {
		u, err := parseBaseURL(raw)
		if err != nil {
			errs = append(errs, fmt.Errorf("LEGACY_APP_URLS: %w", err))
			continue
		}
		c.LegacyURLs = append(c.LegacyURLs, u)
	}

	// Database -------------------------------------------------------------
	c.DatabaseURL = str("DATABASE_URL", "")
	if c.DatabaseURL == "" {
		user, pass, name := get("POSTGRES_USER"), get("POSTGRES_PASSWORD"), get("POSTGRES_DB")
		if user == "" || pass == "" || name == "" {
			errs = append(errs, errors.New("DATABASE_URL or POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB is required"))
		} else {
			host := str("POSTGRES_HOST", "db")
			c.DatabaseURL = (&url.URL{
				Scheme:   "postgres",
				User:     url.UserPassword(user, pass),
				Host:     host + ":" + str("POSTGRES_PORT", "5432"),
				Path:     "/" + name,
				RawQuery: "sslmode=" + str("POSTGRES_SSLMODE", "disable"),
			}).String()
		}
	}

	c.JWTSecret = secret("JWT_SECRET")
	c.InstanceSecret = secret("INSTANCE_SECRET")
	if c.JWTSecret != nil && string(c.JWTSecret) == string(c.InstanceSecret) {
		errs = append(errs, errors.New("JWT_SECRET and INSTANCE_SECRET must differ"))
	}

	switch c.RegistrationMode {
	case "open", "invite", "closed":
	default:
		errs = append(errs, errors.New("REGISTRATION_MODE must be open, invite or closed"))
	}
	switch c.Env {
	case "production", "development":
	default:
		errs = append(errs, errors.New("APP_ENV must be production or development"))
	}
	if c.RefreshTTL < 24*time.Hour {
		errs = append(errs, errors.New("SESSION_REFRESH_DAYS must be at least 1"))
	}
	if c.UploadMaxBytes <= 0 {
		errs = append(errs, errors.New("UPLOAD_MAX_MB must be positive"))
	}
	if c.SMTP.Enabled() {
		switch c.SMTP.TLS {
		case "starttls", "tls", "none":
		default:
			errs = append(errs, errors.New("SMTP_TLS must be starttls, tls or none"))
		}
	}

	for _, raw := range splitList(get("TRUSTED_PROXIES")) {
		p, err := netip.ParsePrefix(raw)
		if err != nil {
			a, aerr := netip.ParseAddr(raw)
			if aerr != nil {
				errs = append(errs, fmt.Errorf("TRUSTED_PROXIES: invalid entry %q", raw))
				continue
			}
			p = netip.PrefixFrom(a, a.BitLen())
		}
		c.TrustedProxies = append(c.TrustedProxies, p.Masked())
	}
	for _, fp := range splitList(get("ANDROID_CERT_SHA256")) {
		c.AndroidCertSHA256 = append(c.AndroidCertSHA256, strings.ToUpper(fp))
	}

	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	return c, nil
}

func (c *Config) Development() bool { return c.Env == "development" }

// SecureCookies is true when the public URL uses HTTPS.
func (c *Config) SecureCookies() bool { return c.PublicURL.Scheme == "https" }

// ScanURL builds the public link for a scan token.
func (c *Config) ScanURL(token string) string {
	return strings.TrimRight(c.PublicURL.String(), "/") + "/c/" + token
}

func parseBaseURL(raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil {
		return nil, err
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("%q must start with http:// or https://", raw)
	}
	if u.Host == "" {
		return nil, fmt.Errorf("%q has no host", raw)
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return nil, fmt.Errorf("%q must not contain query or fragment", raw)
	}
	return u, nil
}

func splitList(v string) []string {
	var out []string
	for _, p := range strings.FieldsFunc(v, func(r rune) bool { return r == ',' || r == ' ' || r == '\n' }) {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}
