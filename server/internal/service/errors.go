package service

import (
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/daschmidt1994/ant-colony-manager/server/internal/db"
)

// Problem is a client-facing error (RFC 9457). Anything that is not a *Problem is
// treated as an internal error and never shown to clients.
type Problem struct {
	Status     int           `json:"status"`
	Code       string        `json:"code"`
	Title      string        `json:"title"`
	Field      string        `json:"field,omitempty"`
	RetryAfter time.Duration `json:"-"`
}

func (p *Problem) Error() string { return p.Code + ": " + p.Title }

func newProblem(status int, code, title string) *Problem {
	return &Problem{Status: status, Code: code, Title: title}
}

func Invalid(field, format string, args ...any) *Problem {
	return &Problem{Status: http.StatusUnprocessableEntity, Code: "validation", Title: fmt.Sprintf(format, args...), Field: field}
}

// NotFound is also used for "exists but you may not see it" so that existence is
// never revealed.
func NotFound(what string) *Problem {
	return newProblem(http.StatusNotFound, what+".not_found", "not found")
}

var (
	ErrUnauthorized       = newProblem(http.StatusUnauthorized, "auth.unauthorized", "authentication required")
	ErrInvalidCredentials = newProblem(http.StatusUnauthorized, "auth.invalid_credentials", "e-mail or password is wrong")
	ErrForbidden          = newProblem(http.StatusForbidden, "auth.forbidden", "not allowed")
	ErrGone               = newProblem(http.StatusGone, "entity.deleted", "this record was deleted")
	ErrDeviceRevoked      = newProblem(http.StatusUnauthorized, "device.revoked", "this device was signed out – local data must be removed")
)

func Conflict(code, title string) *Problem { return newProblem(http.StatusConflict, code, title) }

func RateLimited(retry time.Duration) *Problem {
	p := newProblem(http.StatusTooManyRequests, "rate_limited", "too many requests – please wait")
	p.RetryAfter = retry
	return p
}

// AsProblem extracts a *Problem from err.
func AsProblem(err error) (*Problem, bool) {
	var p *Problem
	if errors.As(err, &p) {
		return p, true
	}
	return nil, false
}

// problemFromDB turns constraint violations caused by client data into
// validation problems; other errors pass through unchanged.
func problemFromDB(err error) error {
	pe := db.PgError(err)
	if pe == nil || !db.IsDataError(err) {
		return err
	}
	field := pe.ColumnName
	switch pe.Code {
	case db.CodeUniqueViolation:
		return &Problem{Status: http.StatusConflict, Code: "unique", Title: "value already in use (" + pe.ConstraintName + ")", Field: field}
	case db.CodeForeignKeyViolation:
		return Invalid(field, "referenced record does not exist (%s)", pe.ConstraintName)
	case db.CodeCheckViolation:
		return Invalid(field, "value not allowed (%s)", pe.ConstraintName)
	case db.CodeNotNullViolation:
		return Invalid(field, "field %s is required", pe.ColumnName)
	default:
		return Invalid(field, "invalid value: %s", pe.Message)
	}
}
