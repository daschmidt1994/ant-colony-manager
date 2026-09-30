package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Update button: the optional updater service (deploy/updater/updater.sh)
// watches UPDATE_DIR. The server only writes a request file there – it never
// talks to Docker itself. The updater writes a heartbeat every few seconds
// and its progress to status.json.

// UpdaterStatus is what the app shows.
type UpdaterStatus struct {
	Available bool       `json:"available"` // updater runs (heartbeat within a minute)
	State     string     `json:"state"`     // idle | requested | running | done | failed
	Message   string     `json:"message,omitempty"`
	At        *time.Time `json:"at,omitempty"`
	Log       string     `json:"log,omitempty"` // end of update.log after a failure
}

func (s *Service) updaterStatus() UpdaterStatus {
	dir := s.Cfg.UpdateDir
	out := UpdaterStatus{State: "idle"}
	if dir == "" {
		return out
	}
	if b, err := os.ReadFile(filepath.Join(dir, "heartbeat")); err == nil {
		if sec, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64); err == nil {
			out.Available = s.Now().Sub(time.Unix(sec, 0)) < time.Minute
		}
	}
	if b, err := os.ReadFile(filepath.Join(dir, "status.json")); err == nil {
		var st struct {
			State   string    `json:"state"`
			Message string    `json:"message"`
			At      time.Time `json:"at"`
		}
		if json.Unmarshal(b, &st) == nil && st.State != "" {
			out.State, out.Message = st.State, st.Message
			if !st.At.IsZero() {
				out.At = &st.At
			}
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "request")); err == nil {
		out.State = "requested"
	}
	if out.State == "failed" {
		if f, err := os.Open(filepath.Join(dir, "update.log")); err == nil {
			defer f.Close()
			if fi, err := f.Stat(); err == nil && fi.Size() > 4000 {
				_, _ = f.Seek(fi.Size()-4000, io.SeekStart)
			}
			b, _ := io.ReadAll(f)
			out.Log = string(b)
		}
	}
	return out
}

func (s *Service) UpdaterStatus(ctx context.Context, actor Actor) (*UpdaterStatus, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	st := s.updaterStatus()
	return &st, nil
}

// StartUpdate asks the updater to update now.
func (s *Service) StartUpdate(ctx context.Context, actor Actor, meta ClientMeta) (*UpdaterStatus, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	st := s.updaterStatus()
	if !st.Available {
		return nil, &Problem{Status: 409, Code: "update.no_updater",
			Title: "the update service is not running (COMPOSE_PROFILES=updater, see docs)"}
	}
	if st.State == "requested" || st.State == "running" {
		return nil, &Problem{Status: 409, Code: "update.running", Title: "an update is already running"}
	}
	req, _ := json.Marshal(map[string]any{"by": actor.UserID, "at": s.Now().UTC()})
	f := filepath.Join(s.Cfg.UpdateDir, "request")
	if err := os.WriteFile(f+".tmp", req, 0o644); err != nil {
		if errors.Is(err, fs.ErrPermission) {
			return nil, errors.New("update folder not writable – restart the stack once so that init creates it")
		}
		return nil, err
	}
	if err := os.Rename(f+".tmp", f); err != nil {
		return nil, err
	}
	s.Audit(ctx, &actor.UserID, "update_requested", "", nil, meta.IP)
	st = s.updaterStatus()
	return &st, nil
}
