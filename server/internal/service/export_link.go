package service

import (
	"context"
	"crypto/hmac"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strconv"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/auth"
)

// ExportLink returns a short-lived download URL for the ZIP export, so the
// Android app can hand the download to the browser without a login there.
// The link is bound to the session: signing out invalidates it.
func (s *Service) ExportLink(actor Actor, photos bool) *PhotoURL {
	p := "0"
	if photos {
		p = "1"
	}
	exp := s.Now().Add(signedURLMaxAge)
	q := url.Values{
		"s":      {actor.SessionID.String()},
		"u":      {actor.UserID.String()},
		"photos": {p},
		"exp":    {strconv.FormatInt(exp.Unix(), 10)},
	}
	q.Set("sig", s.signExport(q))
	return &PhotoURL{URL: "/api/v1/export/download?" + q.Encode(), ExpiresAt: exp}
}

func (s *Service) signExport(q url.Values) string {
	msg := fmt.Sprintf("export:%s:%s:%s:%s", q.Get("u"), q.Get("s"), q.Get("photos"), q.Get("exp"))
	return base64.RawURLEncoding.EncodeToString(auth.HMAC(s.Cfg.InstanceSecret, msg))
}

// ExportLinkActor verifies a link from ExportLink and returns its actor and
// whether photos are included. Invalid, expired or revoked links are 401.
func (s *Service) ExportLinkActor(ctx context.Context, q url.Values) (Actor, bool, error) {
	exp, err := strconv.ParseInt(q.Get("exp"), 10, 64)
	if err != nil || s.Now().Unix() > exp || !hmac.Equal([]byte(s.signExport(q)), []byte(q.Get("sig"))) {
		return Actor{}, false, ErrUnauthorized
	}
	user, err1 := uuid.Parse(q.Get("u"))
	sid, err2 := uuid.Parse(q.Get("s"))
	if err1 != nil || err2 != nil {
		return Actor{}, false, ErrUnauthorized
	}
	var role string
	var ok bool
	err = s.Pool.QueryRow(ctx, `SELECT u.instance_role, s.revoked_at IS NULL AND u.disabled_at IS NULL
		FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.id = $1 AND s.user_id = $2`, sid, user).Scan(&role, &ok)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !ok) {
		return Actor{}, false, ErrUnauthorized
	}
	if err != nil {
		return Actor{}, false, err
	}
	return Actor{UserID: user, SessionID: sid, IsAdmin: role == "admin"}, q.Get("photos") != "0", nil
}
