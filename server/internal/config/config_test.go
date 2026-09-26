package config

import (
	"os"
	"strings"
	"testing"
)

func env(m map[string]string) Getenv { return func(k string) string { return m[k] } }

func valid() map[string]string {
	return map[string]string{
		"PUBLIC_APP_URL":    "https://ants.example.com/",
		"POSTGRES_USER":     "acm",
		"POSTGRES_PASSWORD": "p@ss word/with:chars",
		"POSTGRES_DB":       "acm",
		"JWT_SECRET":        "Zx8Qm2Lr7Vt4Np9Ks3Hd6Wf1Yb5Gc0Ja8Ue2Io7",
		"INSTANCE_SECRET":   "Hq3Wn8Rt1Zm6Kv4Ls9Dp2Xc7Bf5Gj0Ya3Te8Uo1",
		"TRUSTED_PROXIES":   "172.16.0.0/12, 10.0.0.5",
	}
}

func TestValidConfig(t *testing.T) {
	c, err := LoadFrom(env(valid()))
	if err != nil {
		t.Fatal(err)
	}
	if c.ScanURL("AbC") != "https://ants.example.com/c/AbC" {
		t.Fatalf("scan url %q", c.ScanURL("AbC"))
	}
	if !strings.Contains(c.DatabaseURL, "p%40ss%20word%2Fwith%3Achars@db:5432/acm") {
		t.Fatalf("password must be URL-escaped: %s", c.DatabaseURL)
	}
	if len(c.TrustedProxies) != 2 || !c.SecureCookies() || c.RegistrationMode != "invite" {
		t.Fatalf("unexpected: %+v", c)
	}
}

func TestLocalNetworkURLAllowed(t *testing.T) {
	m := valid()
	m["PUBLIC_APP_URL"] = "http://192.168.1.50:8080"
	c, err := LoadFrom(env(m))
	if err != nil {
		t.Fatal(err)
	}
	if c.SecureCookies() {
		t.Fatal("http must not set secure cookies")
	}
}

func TestRejectsMissingAndWeakSecrets(t *testing.T) {
	cases := map[string]func(map[string]string){
		"JWT_SECRET is required":          func(m map[string]string) { delete(m, "JWT_SECRET") },
		"at least 32":                     func(m map[string]string) { m["JWT_SECRET"] = "short" },
		"placeholder":                     func(m map[string]string) { m["INSTANCE_SECRET"] = "change-me-change-me-change-me-change-me" },
		"must differ":                     func(m map[string]string) { m["INSTANCE_SECRET"] = m["JWT_SECRET"] },
		"PUBLIC_APP_URL is required":      func(m map[string]string) { delete(m, "PUBLIC_APP_URL") },
		"must start with http":            func(m map[string]string) { m["PUBLIC_APP_URL"] = "ants.example.com" },
		"REGISTRATION_MODE":               func(m map[string]string) { m["REGISTRATION_MODE"] = "sometimes" },
		"TRUSTED_PROXIES":                 func(m map[string]string) { m["TRUSTED_PROXIES"] = "not-an-ip" },
		"POSTGRES_USER/POSTGRES_PASSWORD": func(m map[string]string) { delete(m, "POSTGRES_PASSWORD") },
	}
	for want, mutate := range cases {
		m := valid()
		mutate(m)
		_, err := LoadFrom(env(m))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("expected error containing %q, got %v", want, err)
		}
	}
}

func TestSecretsFromFiles(t *testing.T) {
	m := valid()
	delete(m, "JWT_SECRET")
	delete(m, "POSTGRES_PASSWORD")
	m["JWT_SECRET_FILE"] = "/run/secrets/jwt"
	m["POSTGRES_PASSWORD_FILE"] = "/run/secrets/pg"
	files := map[string]string{"/run/secrets/jwt": "Qm2Lr7Vt4Np9Ks3Hd6Wf1Yb5Gc0Ja8Ue2Io7Zx8\n", "/run/secrets/pg": "db-pass\n"}
	ReadFile = func(p string) ([]byte, error) {
		v, ok := files[p]
		if !ok {
			return nil, os.ErrNotExist
		}
		return []byte(v), nil
	}
	defer func() { ReadFile = os.ReadFile }()
	c, err := LoadFrom(env(m))
	if err != nil {
		t.Fatal(err)
	}
	if string(c.JWTSecret) != "Qm2Lr7Vt4Np9Ks3Hd6Wf1Yb5Gc0Ja8Ue2Io7Zx8" || !strings.Contains(c.DatabaseURL, "acm:db-pass@") {
		t.Fatalf("file secrets not used: %s", c.DatabaseURL)
	}
	m["INSTANCE_SECRET_FILE"] = "/missing"
	delete(m, "INSTANCE_SECRET")
	if _, err := LoadFrom(env(m)); err == nil || !strings.Contains(err.Error(), "INSTANCE_SECRET_FILE") {
		t.Fatalf("missing file must be reported, got %v", err)
	}
}
