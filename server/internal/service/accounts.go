package service

import (
	"context"
	"crypto/subtle"
	"errors"
	"net/http"
	"net/mail"
	"net/netip"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
	mailer "github.com/daschmidt1994/ant-colony-manager/server/internal/mail"
)

// refreshReuseGrace tolerates parallel refreshes (e.g. two browser tabs) with the
// same token without treating them as theft.
const refreshReuseGrace = 30 * time.Second

type Session struct {
	AccessToken      string    `json:"access_token"`
	AccessExpiresAt  time.Time `json:"access_expires_at"`
	RefreshToken     string    `json:"refresh_token,omitempty"`
	RefreshExpiresAt time.Time `json:"refresh_expires_at"`
	User             UserInfo  `json:"user"`
}

type UserInfo struct {
	ID           uuid.UUID `json:"id"`
	Email        string    `json:"email"`
	DisplayName  string    `json:"display_name"`
	InstanceRole string    `json:"instance_role"`
	CreatedAt    time.Time `json:"created_at"`
}

type ClientMeta struct {
	IP        netip.Addr
	UserAgent string
	Device    *DeviceInfo
}

// ---------------------------------------------------------------------------
// Setup

// EnsureSetupToken creates the one-time setup token if no user exists yet and
// returns it (empty once an account exists).
func (s *Service) EnsureSetupToken(ctx context.Context) (string, error) {
	var n int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&n); err != nil {
		return "", err
	}
	if n > 0 {
		s.setupToken = ""
		return "", nil
	}
	if s.setupToken == "" {
		s.setupToken = s.Cfg.SetupToken
		if s.setupToken == "" {
			s.setupToken = auth.NewToken(18)
		}
	}
	return s.setupToken, nil
}

func (s *Service) SetupRequired(ctx context.Context) (bool, error) {
	var exists bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users)`).Scan(&exists)
	return !exists, err
}

type RegisterInput struct {
	Email       string `json:"email"`
	Password    string `json:"password"`
	DisplayName string `json:"display_name"`
	InviteToken string `json:"invite_token,omitempty"`
	SetupToken  string `json:"setup_token,omitempty"`
}

func (in *RegisterInput) normalize() error {
	in.Email = strings.TrimSpace(strings.ToLower(in.Email))
	in.DisplayName = strings.TrimSpace(in.DisplayName)
	addr, err := mail.ParseAddress(in.Email)
	if err != nil || addr.Address != in.Email || len(in.Email) > 254 {
		return Invalid("email", "invalid e-mail address")
	}
	if in.DisplayName == "" {
		in.DisplayName = strings.Split(in.Email, "@")[0]
	}
	if len([]rune(in.DisplayName)) > 100 {
		return Invalid("display_name", "name is too long")
	}
	if err := auth.ValidatePassword(in.Password); err != nil {
		return Invalid("password", "%s", err.Error())
	}
	return nil
}

// Setup creates the first (admin) account. It requires the setup token printed
// in the server log so a freshly started public instance cannot be hijacked.
func (s *Service) Setup(ctx context.Context, in RegisterInput, meta ClientMeta) (*Session, error) {
	tok, err := s.EnsureSetupToken(ctx)
	if err != nil {
		return nil, err
	}
	if tok == "" {
		return nil, Conflict("setup.done", "setup was already completed")
	}
	if subtle.ConstantTimeCompare([]byte(in.SetupToken), []byte(tok)) != 1 {
		return nil, &Problem{Status: http.StatusForbidden, Code: "setup.invalid_token", Title: "setup token is wrong – see `docker compose logs app`"}
	}
	if err := in.normalize(); err != nil {
		return nil, err
	}
	var user uuid.UUID
	err = db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		// Lock to make concurrent setups impossible.
		if _, err := tx.Exec(ctx, `LOCK TABLE users IN EXCLUSIVE MODE`); err != nil {
			return err
		}
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users)`).Scan(&exists); err != nil {
			return err
		}
		if exists {
			return Conflict("setup.done", "setup was already completed")
		}
		user, err = s.createUser(ctx, tx, in, "admin")
		return err
	})
	if err != nil {
		return nil, err
	}
	s.setupToken = ""
	s.Audit(ctx, &user, "setup_completed", in.Email, nil, meta.IP)
	return s.newSession(ctx, user, meta)
}

func (s *Service) createUser(ctx context.Context, q db.Querier, in RegisterInput, role string) (uuid.UUID, error) {
	hash, err := auth.HashPassword(in.Password)
	if err != nil {
		return uuid.Nil, err
	}
	var id uuid.UUID
	err = q.QueryRow(ctx, `INSERT INTO users (email, password_hash, display_name, instance_role, email_verified_at)
		VALUES ($1, $2, $3, $4, CASE WHEN $4 = 'admin' THEN now() END) RETURNING id`,
		in.Email, hash, in.DisplayName, role).Scan(&id)
	if db.PgCode(err) == db.CodeUniqueViolation {
		return uuid.Nil, Conflict("user.exists", "an account with this e-mail address already exists")
	}
	if err != nil {
		return uuid.Nil, err
	}
	if _, err := q.Exec(ctx, `INSERT INTO user_settings (id, owner_id) VALUES ($1, $1)`, id); err != nil {
		return uuid.Nil, err
	}
	return id, nil
}

// Register creates an account according to REGISTRATION_MODE.
func (s *Service) Register(ctx context.Context, in RegisterInput, meta ClientMeta) (*Session, error) {
	if setup, err := s.SetupRequired(ctx); err != nil {
		return nil, err
	} else if setup {
		return nil, Conflict("setup.required", "the server has not been set up yet")
	}
	if err := in.normalize(); err != nil {
		return nil, err
	}
	var user uuid.UUID
	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		var inviteID uuid.UUID
		var colony *uuid.UUID
		var colonyRole *string
		if in.InviteToken != "" {
			var invEmail *string
			err := tx.QueryRow(ctx, `SELECT id, email, colony_id, colony_role FROM invitations
				WHERE token_hash = $1 AND accepted_at IS NULL AND expires_at > now() FOR UPDATE`,
				auth.HashToken(in.InviteToken)).Scan(&inviteID, &invEmail, &colony, &colonyRole)
			if errors.Is(err, pgx.ErrNoRows) {
				return Invalid("invite_token", "invitation is invalid or expired")
			}
			if err != nil {
				return err
			}
			if invEmail != nil && !strings.EqualFold(*invEmail, in.Email) {
				return Invalid("email", "this invitation is for a different e-mail address")
			}
		} else if s.Cfg.RegistrationMode != "open" {
			return &Problem{Status: http.StatusForbidden, Code: "registration.closed", Title: "registration requires an invitation"}
		}
		var err error
		user, err = s.createUser(ctx, tx, in, "user")
		if err != nil {
			return err
		}
		if inviteID != uuid.Nil {
			if _, err := tx.Exec(ctx, `UPDATE invitations SET accepted_at = now(), accepted_by = $2 WHERE id = $1`, inviteID, user); err != nil {
				return err
			}
			if colony != nil && colonyRole != nil {
				if _, err := tx.Exec(ctx, `INSERT INTO colony_members (colony_id, user_id, role) VALUES ($1, $2, $3)`,
					*colony, user, *colonyRole); err != nil {
					return err
				}
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, &user, "user_registered", in.Email, nil, meta.IP)
	return s.newSession(ctx, user, meta)
}

// ---------------------------------------------------------------------------
// Sessions

func (s *Service) Login(ctx context.Context, email, password string, meta ClientMeta) (*Session, error) {
	email = strings.TrimSpace(strings.ToLower(email))
	var id uuid.UUID
	var hash string
	var disabled *time.Time
	err := s.Pool.QueryRow(ctx, `SELECT id, password_hash, disabled_at FROM users WHERE email = $1`, email).Scan(&id, &hash, &disabled)
	if errors.Is(err, pgx.ErrNoRows) {
		auth.BurnPasswordCheck(password)
		s.Audit(ctx, nil, "login_failed", email, map[string]any{"reason": "unknown_user"}, meta.IP)
		return nil, ErrInvalidCredentials
	}
	if err != nil {
		return nil, err
	}
	ok, err := auth.VerifyPassword(password, hash)
	if err != nil {
		return nil, err
	}
	if !ok {
		s.Audit(ctx, &id, "login_failed", email, map[string]any{"reason": "password"}, meta.IP)
		return nil, ErrInvalidCredentials
	}
	if disabled != nil {
		return nil, &Problem{Status: http.StatusForbidden, Code: "user.disabled", Title: "this account is disabled"}
	}
	_, _ = s.Pool.Exec(ctx, `UPDATE users SET last_login_at = now() WHERE id = $1`, id)
	s.Audit(ctx, &id, "login", "", nil, meta.IP)
	return s.newSession(ctx, id, meta)
}

func (s *Service) newSession(ctx context.Context, user uuid.UUID, meta ClientMeta) (*Session, error) {
	return s.issueSession(ctx, s.Pool, user, uuid.Must(uuid.NewV7()), meta)
}

func (s *Service) issueSession(ctx context.Context, q db.Querier, user, family uuid.UUID, meta ClientMeta) (*Session, error) {
	actor := Actor{UserID: user}
	var deviceID *uuid.UUID
	if meta.Device != nil && meta.Device.ID != uuid.Nil {
		// A fresh sign-in on a device that was signed out before re-enables it.
		if _, err := q.Exec(ctx, `UPDATE devices SET revoked_at = NULL WHERE id = $1 AND user_id = $2`, meta.Device.ID, user); err != nil {
			return nil, err
		}
		if err := s.RegisterDevice(ctx, actor, *meta.Device); err != nil {
			return nil, err
		}
		deviceID = &meta.Device.ID
	}
	refresh := auth.NewToken(32)
	now := s.Now()
	sess := &Session{RefreshToken: refresh, RefreshExpiresAt: now.Add(s.Cfg.RefreshTTL)}
	var sid uuid.UUID
	if err := q.QueryRow(ctx, `INSERT INTO sessions (user_id, device_id, family_id, token_hash, expires_at, user_agent)
		VALUES ($1, $2, $3, $4, $5, left($6, 300)) RETURNING id`,
		user, deviceID, family, auth.HashToken(refresh), sess.RefreshExpiresAt, meta.UserAgent).Scan(&sid); err != nil {
		return nil, err
	}
	access, exp, err := s.Tokens.Issue(user, sid, now)
	if err != nil {
		return nil, err
	}
	sess.AccessToken, sess.AccessExpiresAt = access, exp
	info, err := s.userInfo(ctx, q, user)
	if err != nil {
		return nil, err
	}
	sess.User = *info
	return sess, nil
}

func (s *Service) userInfo(ctx context.Context, q db.Querier, id uuid.UUID) (*UserInfo, error) {
	var u UserInfo
	err := q.QueryRow(ctx, `SELECT id, email, display_name, instance_role, created_at FROM users WHERE id = $1`, id).
		Scan(&u.ID, &u.Email, &u.DisplayName, &u.InstanceRole, &u.CreatedAt)
	return &u, err
}

func (s *Service) Me(ctx context.Context, actor Actor) (*UserInfo, error) {
	return s.userInfo(ctx, s.Pool, actor.UserID)
}

// Refresh rotates a refresh token. Presenting an already rotated token outside
// the grace period revokes the whole token family (theft detection).
func (s *Service) Refresh(ctx context.Context, token string, meta ClientMeta) (*Session, error) {
	if token == "" {
		return nil, ErrUnauthorized
	}
	var out *Session
	var theft *uuid.UUID
	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		var id, user, family uuid.UUID
		var device *uuid.UUID
		var expires time.Time
		var rotated, revoked, disabled, deviceRevoked *time.Time
		err := tx.QueryRow(ctx, `SELECT s.id, s.user_id, s.family_id, s.device_id, s.expires_at, s.rotated_at, s.revoked_at,
			u.disabled_at, d.revoked_at
			FROM sessions s JOIN users u ON u.id = s.user_id LEFT JOIN devices d ON d.id = s.device_id
			WHERE s.token_hash = $1 FOR UPDATE OF s`,
			auth.HashToken(token)).Scan(&id, &user, &family, &device, &expires, &rotated, &revoked, &disabled, &deviceRevoked)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrUnauthorized
		}
		if err != nil {
			return err
		}
		now := s.Now()
		switch {
		case revoked != nil && deviceRevoked != nil:
			// Signed out from another device: the app must wipe its local data.
			return ErrDeviceRevoked
		case revoked != nil, disabled != nil, now.After(expires):
			return ErrUnauthorized
		case rotated != nil:
			if now.Sub(*rotated) <= refreshReuseGrace {
				return &Problem{Status: http.StatusUnauthorized, Code: "auth.token_rotated", Title: "token was just rotated – use the newer token"}
			}
			if _, err := tx.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE family_id = $1 AND revoked_at IS NULL`, family); err != nil {
				return err
			}
			theft = &user
			return nil
		}
		if _, err := tx.Exec(ctx, `UPDATE sessions SET rotated_at = now(), last_used_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		m := meta
		m.Device = nil // the device is already registered; keep it without re-registering
		out, err = s.issueSession(ctx, tx, user, family, m)
		if err == nil && device != nil {
			_, err = tx.Exec(ctx, `UPDATE sessions SET device_id = $1 WHERE token_hash = $2`, *device, auth.HashToken(out.RefreshToken))
		}
		return err
	})
	if theft != nil {
		s.Audit(ctx, theft, "refresh_token_reuse", "", nil, meta.IP)
		return nil, &Problem{Status: http.StatusUnauthorized, Code: "auth.token_reused", Title: "session was revoked for security reasons – please log in again"}
	}
	return out, err
}

func (s *Service) Logout(ctx context.Context, actor Actor, all bool) error {
	var err error
	if all {
		_, err = s.Pool.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`, actor.UserID)
	} else {
		_, err = s.Pool.Exec(ctx, `UPDATE sessions SET revoked_at = now()
			WHERE family_id = (SELECT family_id FROM sessions WHERE id = $1) AND user_id = $2 AND revoked_at IS NULL`,
			actor.SessionID, actor.UserID)
	}
	return err
}

// Authenticate validates an access token and checks that its session is alive.
func (s *Service) Authenticate(ctx context.Context, token string) (Actor, error) {
	user, sid, err := s.Tokens.Parse(token)
	if err != nil {
		return Actor{}, ErrUnauthorized
	}
	var role string
	var ok bool
	var device *uuid.UUID
	err = s.Pool.QueryRow(ctx, `SELECT u.instance_role, s.revoked_at IS NULL AND u.disabled_at IS NULL, s.device_id
		FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.id = $1 AND s.user_id = $2`, sid, user).Scan(&role, &ok, &device)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !ok) {
		return Actor{}, ErrUnauthorized
	}
	if err != nil {
		return Actor{}, err
	}
	a := Actor{UserID: user, SessionID: sid, IsAdmin: role == "admin"}
	if device != nil {
		a.DeviceID = *device
	}
	return a, nil
}

type SessionInfo struct {
	ID         uuid.UUID  `json:"id"`
	DeviceID   *uuid.UUID `json:"device_id"`
	DeviceName *string    `json:"device_name"`
	Platform   *string    `json:"platform"`
	UserAgent  *string    `json:"user_agent"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at"`
	Current    bool       `json:"current"`
}

// ListSessions returns the newest live session of every token family.
func (s *Service) ListSessions(ctx context.Context, actor Actor) ([]SessionInfo, error) {
	rows, err := s.Pool.Query(ctx, `
		SELECT DISTINCT ON (s.family_id) s.id, s.device_id, d.name, d.platform, s.user_agent, first.created_at,
		       COALESCE(s.last_used_at, s.created_at),
		       s.family_id = (SELECT family_id FROM sessions WHERE id = $2)
		FROM sessions s
		LEFT JOIN devices d ON d.id = s.device_id
		JOIN LATERAL (SELECT min(created_at) AS created_at FROM sessions f WHERE f.family_id = s.family_id) first ON true
		WHERE s.user_id = $1 AND s.revoked_at IS NULL AND s.rotated_at IS NULL AND s.expires_at > now()
		ORDER BY s.family_id, s.created_at DESC`, actor.UserID, actor.SessionID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (SessionInfo, error) {
		var x SessionInfo
		err := r.Scan(&x.ID, &x.DeviceID, &x.DeviceName, &x.Platform, &x.UserAgent, &x.CreatedAt, &x.LastUsedAt, &x.Current)
		return x, err
	})
}

// RevokeSession ends a session family; if it had a device, the device is marked
// revoked so the app wipes its local data on next contact.
func (s *Service) RevokeSession(ctx context.Context, actor Actor, id uuid.UUID) error {
	return db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		var family uuid.UUID
		var device *uuid.UUID
		err := tx.QueryRow(ctx, `SELECT family_id, device_id FROM sessions WHERE id = $1 AND user_id = $2`, id, actor.UserID).Scan(&family, &device)
		if errors.Is(err, pgx.ErrNoRows) {
			return NotFound("session")
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE family_id = $1 AND revoked_at IS NULL`, family); err != nil {
			return err
		}
		if device != nil {
			_, err = tx.Exec(ctx, `UPDATE devices SET revoked_at = now() WHERE id = $1 AND user_id = $2`, *device, actor.UserID)
		}
		return err
	})
}

// ---------------------------------------------------------------------------
// Passwords

func (s *Service) ChangePassword(ctx context.Context, actor Actor, oldPw, newPw string) error {
	var hash string
	if err := s.Pool.QueryRow(ctx, `SELECT password_hash FROM users WHERE id = $1`, actor.UserID).Scan(&hash); err != nil {
		return err
	}
	if ok, err := auth.VerifyPassword(oldPw, hash); err != nil || !ok {
		return Invalid("old_password", "current password is wrong")
	}
	if err := auth.ValidatePassword(newPw); err != nil {
		return Invalid("password", "%s", err.Error())
	}
	newHash, err := auth.HashPassword(newPw)
	if err != nil {
		return err
	}
	return db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE users SET password_hash = $2, updated_at = now() WHERE id = $1`, actor.UserID, newHash); err != nil {
			return err
		}
		// Keep the current session family, end all others.
		_, err := tx.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL
			AND family_id <> (SELECT family_id FROM sessions WHERE id = $2)`, actor.UserID, actor.SessionID)
		return err
	})
}

const passwordResetTTL = 30 * time.Minute

// createResetToken returns a new reset token for user.
func (s *Service) createResetToken(ctx context.Context, user uuid.UUID) (string, error) {
	tok := auth.NewToken(32)
	_, err := s.Pool.Exec(ctx, `INSERT INTO password_resets (user_id, token_hash, expires_at) VALUES ($1, $2, $3)`,
		user, auth.HashToken(tok), s.Now().Add(passwordResetTTL))
	return tok, err
}

func (s *Service) resetLink(tok string) string {
	return strings.TrimRight(s.Cfg.PublicURL.String(), "/") + "/reset-password?token=" + tok
}

// ForgotPassword sends a reset link if the account exists. The caller always
// answers identically so accounts cannot be enumerated.
func (s *Service) ForgotPassword(ctx context.Context, email string, meta ClientMeta) error {
	if !s.Mail.Enabled() {
		return nil
	}
	email = strings.TrimSpace(strings.ToLower(email))
	var id uuid.UUID
	var name string
	err := s.Pool.QueryRow(ctx, `SELECT id, display_name FROM users WHERE email = $1 AND disabled_at IS NULL`, email).Scan(&id, &name)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	tok, err := s.createResetToken(ctx, id)
	if err != nil {
		return err
	}
	s.Audit(ctx, &id, "password_reset_requested", "", nil, meta.IP)
	lang := s.userLang(ctx, id)
	body := tl(lang, "Hallo %s,\n\nüber diesen Link kannst du dein Passwort für Ant Colony Manager zurücksetzen (30 Minuten gültig):\n\n%s\n\nWenn du das nicht angefordert hast, kannst du diese E-Mail ignorieren.\n",
		name, s.resetLink(tok))
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		if err := s.Mail.Send(ctx, mailer.Message{To: email, Subject: tl(lang, "Passwort zurücksetzen"), Body: body}); err != nil {
			s.Log.Error("sending reset mail failed", "err", err)
		}
	}()
	return nil
}

// AdminResetLink creates a reset link without e-mail (admin UI / CLI).
func (s *Service) AdminResetLink(ctx context.Context, email string) (string, error) {
	var id uuid.UUID
	err := s.Pool.QueryRow(ctx, `SELECT id FROM users WHERE email = $1`, strings.TrimSpace(strings.ToLower(email))).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", NotFound("user")
	}
	if err != nil {
		return "", err
	}
	tok, err := s.createResetToken(ctx, id)
	if err != nil {
		return "", err
	}
	return s.resetLink(tok), nil
}

func (s *Service) ResetPassword(ctx context.Context, token, newPw string, meta ClientMeta) error {
	if err := auth.ValidatePassword(newPw); err != nil {
		return Invalid("password", "%s", err.Error())
	}
	hash, err := auth.HashPassword(newPw)
	if err != nil {
		return err
	}
	var user uuid.UUID
	err = db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		var id uuid.UUID
		err := tx.QueryRow(ctx, `SELECT id, user_id FROM password_resets WHERE token_hash = $1 AND used_at IS NULL
			AND expires_at > now() FOR UPDATE`, auth.HashToken(token)).Scan(&id, &user)
		if errors.Is(err, pgx.ErrNoRows) {
			return Invalid("token", "reset link is invalid or expired")
		}
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE password_resets SET used_at = now() WHERE id = $1`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE users SET password_hash = $2, updated_at = now() WHERE id = $1`, user, hash); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`, user)
		return err
	})
	if err == nil {
		s.Audit(ctx, &user, "password_reset", "", nil, meta.IP)
	}
	return err
}

// ---------------------------------------------------------------------------
// Device linking („Android-App verbinden“)

const deviceLinkTTL = 2 * time.Minute

type DeviceLink struct {
	Code      string    `json:"code"`
	ServerURL string    `json:"server_url"`
	QRPayload string    `json:"qr_payload"`
	ExpiresAt time.Time `json:"expires_at"`
}

func (s *Service) CreateDeviceLink(ctx context.Context, actor Actor) (*DeviceLink, error) {
	code := auth.NewToken(24)
	exp := s.Now().Add(deviceLinkTTL)
	if _, err := s.Pool.Exec(ctx, `INSERT INTO device_link_codes (code_hash, user_id, expires_at) VALUES ($1, $2, $3)`,
		auth.HashToken(code), actor.UserID, exp); err != nil {
		return nil, err
	}
	base := strings.TrimRight(s.Cfg.PublicURL.String(), "/")
	return &DeviceLink{Code: code, ServerURL: base, QRPayload: base + "/link#code=" + code, ExpiresAt: exp}, nil
}

func (s *Service) RedeemDeviceLink(ctx context.Context, code string, meta ClientMeta) (*Session, error) {
	var user uuid.UUID
	err := s.Pool.QueryRow(ctx, `UPDATE device_link_codes SET redeemed_at = now()
		WHERE code_hash = $1 AND redeemed_at IS NULL AND expires_at > now() RETURNING user_id`, auth.HashToken(code)).Scan(&user)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, Invalid("code", "code is invalid or expired – show a new one in the web app")
	}
	if err != nil {
		return nil, err
	}
	s.Audit(ctx, &user, "device_linked", "", nil, meta.IP)
	return s.newSession(ctx, user, meta)
}

// ---------------------------------------------------------------------------
// Account deletion

func (s *Service) DeleteAccount(ctx context.Context, actor Actor, password string) error {
	var hash string
	if err := s.Pool.QueryRow(ctx, `SELECT password_hash FROM users WHERE id = $1`, actor.UserID).Scan(&hash); err != nil {
		return err
	}
	if ok, _ := auth.VerifyPassword(password, hash); !ok {
		return Invalid("password", "password is wrong")
	}
	var admins int
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) FROM users WHERE instance_role = 'admin' AND disabled_at IS NULL AND id <> $1`,
		actor.UserID).Scan(&admins); err != nil {
		return err
	}
	if actor.IsAdmin && admins == 0 {
		return Conflict("user.last_admin", "the last administrator cannot delete their account")
	}
	return s.deleteUser(ctx, actor.UserID)
}

// AdminDeleteUser deletes another account with all its colonies, photos and
// data. [confirmEmail] must repeat the account's e-mail – a guard against
// deleting the wrong row. Never your own account.
func (s *Service) AdminDeleteUser(ctx context.Context, actor Actor, id uuid.UUID, confirmEmail string, meta ClientMeta) error {
	if err := requireAdmin(actor); err != nil {
		return err
	}
	if id == actor.UserID {
		return Invalid("id", "you cannot delete your own account here – another administrator can")
	}
	var email string
	err := s.Pool.QueryRow(ctx, `SELECT email FROM users WHERE id = $1`, id).Scan(&email)
	if errors.Is(err, pgx.ErrNoRows) {
		return NotFound("user")
	}
	if err != nil {
		return err
	}
	if !strings.EqualFold(strings.TrimSpace(confirmEmail), email) {
		return Invalid("confirm_email", "type the e-mail address of the account to confirm")
	}
	if err := s.deleteUser(ctx, id); err != nil {
		return err
	}
	s.Audit(ctx, &actor.UserID, "user_deleted", email, nil, meta.IP)
	return nil
}

// deleteUser removes an account: owned colonies cascade (members of shared
// colonies lose access; their devices receive the colony_members deletion
// before the rows disappear), then the photo files nobody uses any more.
func (s *Service) deleteUser(ctx context.Context, id uuid.UUID) error {
	var keys []string
	err := db.InTx(ctx, s.Pool, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT unnest(ARRAY[storage_key, thumb_key, original_key]) FROM photos
			WHERE owner_id = $1 OR colony_id IN (SELECT id FROM colonies WHERE owner_id = $1)`, id)
		if err != nil {
			return err
		}
		for rows.Next() {
			var k *string
			if err := rows.Scan(&k); err != nil {
				rows.Close()
				return err
			}
			if k != nil {
				keys = append(keys, *k)
			}
		}
		rows.Close()
		if _, err := tx.Exec(ctx, `UPDATE colony_members SET deleted_at = now()
			WHERE colony_id IN (SELECT id FROM colonies WHERE owner_id = $1) AND deleted_at IS NULL AND user_id <> $1`, id); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `DELETE FROM users WHERE id = $1`, id)
		return err
	})
	if err != nil {
		return err
	}
	return s.deleteUnusedBlobs(ctx, keys)
}
