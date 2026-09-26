package auth

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestPasswordHashRoundtripWithProductionParams(t *testing.T) {
	h, err := HashPassword("Messor-barbarus-12")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$v=19$m=65536,t=3,p=1$") {
		t.Fatalf("unexpected hash format %s", h)
	}
	if ok, _ := VerifyPassword("Messor-barbarus-12", h); !ok {
		t.Fatal("correct password rejected")
	}
	if ok, _ := VerifyPassword("messor-barbarus-12", h); ok {
		t.Fatal("wrong password accepted")
	}
	if _, err := VerifyPassword("x", "$bcrypt$nope"); err == nil {
		t.Fatal("invalid hash must error")
	}
}

func TestValidatePassword(t *testing.T) {
	if ValidatePassword("Qwertyuiop") == nil {
		t.Error("common password accepted")
	}
	if ValidatePassword("kurz") == nil {
		t.Error("short password accepted")
	}
	if err := ValidatePassword("Lasius flavus im Garten"); err != nil {
		t.Error(err)
	}
}

func TestScanTokens(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 2000; i++ {
		tok := NewScanToken()
		if !ValidScanToken(tok) {
			t.Fatalf("invalid token %q", tok)
		}
		if seen[tok] {
			t.Fatal("duplicate token")
		}
		seen[tok] = true
	}
	for _, bad := range []string{"", "short", "0123456789abcde_", "0123456789abcdef0", "../../etc/passwd!"} {
		if ValidScanToken(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestAccessTokens(t *testing.T) {
	iss := TokenIssuer{Secret: []byte("0123456789abcdef0123456789abcdef"), TTL: time.Minute, Issuer: "acm"}
	u, s := uuid.New(), uuid.New()
	tok, _, err := iss.Issue(u, s, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	gu, gs, err := iss.Parse(tok)
	if err != nil || gu != u || gs != s {
		t.Fatalf("parse: %v %v %v", gu, gs, err)
	}
	expired, _, _ := iss.Issue(u, s, time.Now().Add(-2*time.Minute))
	if _, _, err := iss.Parse(expired); err == nil {
		t.Fatal("expired token accepted")
	}
	other := TokenIssuer{Secret: []byte("another-secret-another-secret-123"), TTL: time.Minute, Issuer: "acm"}
	if _, _, err := other.Parse(tok); err == nil {
		t.Fatal("token with foreign signature accepted")
	}
	// alg=none must never be accepted.
	parts := strings.Split(tok, ".")
	none := "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0." + parts[1] + "."
	if _, _, err := iss.Parse(none); err == nil {
		t.Fatal("alg=none accepted")
	}
}
