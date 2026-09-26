// Package auth contains password hashing, access tokens and random token helpers.
package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	_ "embed"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"golang.org/x/crypto/argon2"
)

// Argon2id parameters (OWASP recommendation, ~300 ms on a Raspberry Pi 4).
type Argon2Params struct {
	Memory  uint32 // KiB
	Time    uint32
	Threads uint8
}

var DefaultParams = Argon2Params{Memory: 64 * 1024, Time: 3, Threads: 1}

// Params is used for new hashes. Tests lower it for speed.
var Params = DefaultParams

const MinPasswordLength = 10

var (
	ErrPasswordTooShort = fmt.Errorf("password must be at least %d characters", MinPasswordLength)
	ErrPasswordTooLong  = errors.New("password must be at most 256 characters")
	ErrPasswordCommon   = errors.New("password is too common")
)

//go:embed common-passwords.txt
var commonPasswordsRaw string

var commonPasswords = func() map[string]struct{} {
	m := map[string]struct{}{}
	for _, l := range strings.Split(commonPasswordsRaw, "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
			m[strings.ToLower(l)] = struct{}{}
		}
	}
	return m
}()

func ValidatePassword(pw string) error {
	n := utf8.RuneCountInString(pw)
	if n < MinPasswordLength {
		return ErrPasswordTooShort
	}
	if n > 256 {
		return ErrPasswordTooLong
	}
	if _, ok := commonPasswords[strings.ToLower(pw)]; ok {
		return ErrPasswordCommon
	}
	return nil
}

// HashPassword returns a PHC-formatted argon2id hash.
func HashPassword(pw string) (string, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	p := Params
	key := argon2.IDKey([]byte(pw), salt, p.Time, p.Memory, p.Threads, 32)
	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, p.Memory, p.Time, p.Threads, b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

var errBadHash = errors.New("invalid password hash format")

// VerifyPassword checks pw against a PHC argon2id hash in constant time.
func VerifyPassword(pw, encoded string) (bool, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false, errBadHash
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil || version != argon2.Version {
		return false, errBadHash
	}
	var p Argon2Params
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &p.Memory, &p.Time, &p.Threads); err != nil {
		return false, errBadHash
	}
	b64 := base64.RawStdEncoding
	salt, err := b64.DecodeString(parts[4])
	if err != nil {
		return false, errBadHash
	}
	want, err := b64.DecodeString(parts[5])
	if err != nil {
		return false, errBadHash
	}
	got := argon2.IDKey([]byte(pw), salt, p.Time, p.Memory, p.Threads, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// dummyHash is verified against when a user does not exist so that login timing
// does not reveal whether an e-mail address is registered.
var dummyHash, _ = HashPassword("timing-equalizer-password")

func BurnPasswordCheck(pw string) { _, _ = VerifyPassword(pw, dummyHash) }

// Random tokens ---------------------------------------------------------------

// NewToken returns a URL-safe random token with n bytes of entropy.
func NewToken(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand never fails on supported platforms
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func HashToken(t string) []byte {
	h := sha256.Sum256([]byte(t))
	return h[:]
}

const base62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// NewScanToken returns a 16 character base62 token (~95 bits).
func NewScanToken() string {
	out := make([]byte, 16)
	buf := make([]byte, 32)
	i := 0
	for i < len(out) {
		if _, err := rand.Read(buf); err != nil {
			panic(err)
		}
		for _, b := range buf {
			if b >= 248 { // rejection sampling: 248 = 62*4, avoids modulo bias
				continue
			}
			out[i] = base62[b%62]
			i++
			if i == len(out) {
				break
			}
		}
	}
	return string(out)
}

func ValidScanToken(t string) bool {
	if len(t) != 16 {
		return false
	}
	for i := 0; i < len(t); i++ {
		if !strings.ContainsRune(base62, rune(t[i])) {
			return false
		}
	}
	return true
}

// HMAC returns HMAC-SHA256(key, msg).
func HMAC(key []byte, msg string) []byte {
	m := hmac.New(sha256.New, key)
	m.Write([]byte(msg))
	return m.Sum(nil)
}

// Access tokens (JWT) --------------------------------------------------------

type Claims struct {
	SessionID uuid.UUID `json:"sid"`
	jwt.RegisteredClaims
}

type TokenIssuer struct {
	Secret []byte
	TTL    time.Duration
	Issuer string
}

func (t TokenIssuer) Issue(userID, sessionID uuid.UUID, now time.Time) (string, time.Time, error) {
	exp := now.Add(t.TTL)
	claims := Claims{
		SessionID: sessionID,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID.String(),
			Issuer:    t.Issuer,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(exp),
		},
	}
	s, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(t.Secret)
	return s, exp, err
}

func (t TokenIssuer) Parse(token string) (userID, sessionID uuid.UUID, err error) {
	var c Claims
	_, err = jwt.ParseWithClaims(token, &c, func(*jwt.Token) (any, error) { return t.Secret, nil },
		jwt.WithValidMethods([]string{"HS256"}), jwt.WithIssuer(t.Issuer), jwt.WithExpirationRequired())
	if err != nil {
		return uuid.Nil, uuid.Nil, err
	}
	userID, err = uuid.Parse(c.Subject)
	if err != nil {
		return uuid.Nil, uuid.Nil, err
	}
	return userID, c.SessionID, nil
}
