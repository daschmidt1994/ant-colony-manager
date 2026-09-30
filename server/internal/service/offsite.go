package service

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// Off-site backup: after the backup container finished a backup, the server
// copies it to another place – a WebDAV folder (Nextcloud, NAS, storage box),
// an SMB share (Windows, NAS) or a folder mounted into the container (NFS,
// USB disk). Layout there:
//
//	<folder>/<backup name>/db.dump, manifest.json, uploads.sha256, env.redacted, OK
//	<folder>/uploads/…      photos, shared by all backups – each photo is sent once
//
// OK is written last: a remote backup without it is incomplete. Old remote
// backups beyond "keep" are deleted; photos are never deleted remotely.

const (
	offsiteKey      = "offsite"
	offsiteStateKey = "offsite_state"
)

const (
	offsiteWebDAV = "webdav"
	offsiteSMB    = "smb"
	offsiteFolder = "folder"
)

type storedOffsite struct {
	Enabled     bool   `json:"enabled"`
	Type        string `json:"type,omitempty"` // "" = webdav (before SMB and folders existed)
	URL         string `json:"url"`            // WebDAV/SMB address or folder path
	User        string `json:"user"`
	PasswordEnc string `json:"password_enc,omitempty"`
	Keep        int    `json:"keep"`
	// when it was switched on – the warning counts from here until the first success
	EnabledAt *time.Time `json:"enabled_at,omitempty"`
}

// OffsiteStatus is what the last runs did.
type OffsiteStatus struct {
	LastName    string     `json:"last_name,omitempty"`
	LastSuccess *time.Time `json:"last_success,omitempty"`
	LastError   string     `json:"last_error,omitempty"`
	LastErrorAt *time.Time `json:"last_error_at,omitempty"`
	LastBytes   int64      `json:"last_bytes,omitempty"`
	LastPhotos  int        `json:"last_photos,omitempty"`
	LastWarned  *time.Time `json:"last_warned,omitempty"` // admins were told it fails
	Running     bool       `json:"running"`
	// the newest complete local backup (empty: backup folder not visible)
	LocalLatest string `json:"local_latest,omitempty"`
}

// OffsiteSettings is the admin API shape; the password is write-only.
type OffsiteSettings struct {
	Enabled     bool          `json:"enabled"`
	Type        string        `json:"type"` // webdav | smb | folder
	URL         string        `json:"url"`  // https://…, smb://server/share/folder or /offsite
	User        string        `json:"user"`
	Password    *string       `json:"password,omitempty"` // input: nil = keep, "" = remove
	PasswordSet bool          `json:"password_set"`
	Keep        int           `json:"keep"`
	Status      OffsiteStatus `json:"status"`
}

var offsiteRun sync.Mutex

func (s *Service) loadJSONSetting(ctx context.Context, key string, v any) (bool, error) {
	var raw []byte
	err := s.Pool.QueryRow(ctx, `SELECT value FROM instance_settings WHERE key = $1`, key).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, json.Unmarshal(raw, v)
}

func (s *Service) saveJSONSetting(ctx context.Context, key string, v any) error {
	raw, _ := json.Marshal(v)
	_, err := s.Pool.Exec(ctx, `INSERT INTO instance_settings (key, value) VALUES ($1, $2)
		ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = now()`, key, raw)
	return err
}

func (s *Service) GetOffsiteSettings(ctx context.Context, actor Actor) (*OffsiteSettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	var st storedOffsite
	if _, err := s.loadJSONSetting(ctx, offsiteKey, &st); err != nil {
		return nil, err
	}
	out := &OffsiteSettings{Enabled: st.Enabled, Type: st.kind(), URL: st.URL, User: st.User, PasswordSet: st.PasswordEnc != "", Keep: st.Keep}
	if out.Keep == 0 {
		out.Keep = 7
	}
	if _, err := s.loadJSONSetting(ctx, offsiteStateKey, &out.Status); err != nil {
		return nil, err
	}
	if offsiteRun.TryLock() {
		offsiteRun.Unlock()
	} else {
		out.Status.Running = true
	}
	out.Status.LocalLatest, _ = s.latestLocalBackup()
	return out, nil
}

func (s *Service) SetOffsiteSettings(ctx context.Context, actor Actor, in OffsiteSettings, meta ClientMeta) (*OffsiteSettings, error) {
	if err := requireAdmin(actor); err != nil {
		return nil, err
	}
	in.URL = strings.TrimSpace(in.URL)
	in.User = strings.TrimSpace(in.User)
	if in.Type == "" {
		in.Type = offsiteWebDAV
	}
	if in.Keep < 1 || in.Keep > 365 {
		return nil, Invalid("keep", "keep 1–365 backups")
	}
	if in.URL != "" {
		t, err := s.newOffsiteTarget(in.Type, in.URL, in.User, "")
		if err != nil {
			return nil, err
		}
		t.close()
	} else if in.Enabled {
		return nil, Invalid("url", "enter where the backups should go")
	}
	if strings.ContainsAny(in.User, "\r\n") || len(in.User) > 320 ||
		(in.Password != nil && (strings.ContainsAny(*in.Password, "\r\n") || len(*in.Password) > 500)) {
		return nil, Invalid("user", "invalid user or password")
	}
	var old storedOffsite
	if _, err := s.loadJSONSetting(ctx, offsiteKey, &old); err != nil {
		return nil, err
	}
	st := storedOffsite{Enabled: in.Enabled, Type: in.Type, URL: in.URL, User: in.User, Keep: in.Keep, PasswordEnc: old.PasswordEnc,
		EnabledAt: old.EnabledAt}
	if in.Enabled && (!old.Enabled || st.EnabledAt == nil) {
		now := s.Now().UTC()
		st.EnabledAt = &now
	}
	if in.Password != nil {
		st.PasswordEnc = ""
		if *in.Password != "" {
			var err error
			if st.PasswordEnc, err = s.encryptSecret(*in.Password); err != nil {
				return nil, err
			}
		}
	}
	// another target: the photos there are unknown – send them all again
	if old.URL != "" && (old.URL != st.URL || old.kind() != st.kind()) {
		if _, err := s.Pool.Exec(ctx, `DELETE FROM offsite_files`); err != nil {
			return nil, err
		}
		_ = s.saveJSONSetting(ctx, offsiteStateKey, OffsiteStatus{})
	}
	if err := s.saveJSONSetting(ctx, offsiteKey, st); err != nil {
		return nil, err
	}
	s.Audit(ctx, &actor.UserID, "offsite_settings_changed", "", map[string]any{"type": st.Type, "url": st.URL, "enabled": st.Enabled}, meta.IP)
	return s.GetOffsiteSettings(ctx, actor)
}

func (st storedOffsite) kind() string {
	if st.Type == "" {
		return offsiteWebDAV
	}
	return st.Type
}

// offsiteTarget is where the backups go. Paths are relative to the target
// folder and use "/".
type offsiteTarget interface {
	check(ctx context.Context) error // address, login; creates the folder if needed
	mkdirAll(ctx context.Context, p string, known map[string]bool) error
	put(ctx context.Context, p string, body io.Reader, size int64) error
	delete(ctx context.Context, p string) error // a folder with everything in it
	folders(ctx context.Context, p string) ([]string, error)
	close()
}

func (s *Service) newOffsiteTarget(kind, raw, user, pass string) (offsiteTarget, error) {
	switch kind {
	case offsiteWebDAV:
		return newWebdav(raw, user, pass)
	case offsiteSMB:
		return newSMBTarget(raw, user, pass)
	case offsiteFolder:
		return newFolderTarget(raw, s.Cfg.BackupDir, s.Cfg.StoragePath)
	}
	return nil, Invalid("type", "type must be webdav, smb or folder")
}

// offsiteClient returns the configured target (nil if none); close it after use.
func (s *Service) offsiteClient(ctx context.Context) (offsiteTarget, *storedOffsite, error) {
	var st storedOffsite
	found, err := s.loadJSONSetting(ctx, offsiteKey, &st)
	if err != nil || !found || st.URL == "" {
		return nil, nil, err
	}
	pw, err := s.decryptSecret(st.PasswordEnc)
	if err != nil {
		return nil, nil, fmt.Errorf("stored off-site password cannot be decrypted (INSTANCE_SECRET changed?): %w", err)
	}
	if st.Keep == 0 {
		st.Keep = 7
	}
	d, err := s.newOffsiteTarget(st.kind(), st.URL, st.User, pw)
	if err != nil {
		return nil, nil, err
	}
	return d, &st, nil
}

// TestOffsite checks address and login (and creates the folder).
func (s *Service) TestOffsite(ctx context.Context, actor Actor) error {
	if err := requireAdmin(actor); err != nil {
		return err
	}
	d, _, err := s.offsiteClient(ctx)
	if err != nil {
		return err
	}
	if d == nil {
		return Invalid("url", "enter and save the target first")
	}
	defer d.close()
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	if err := d.check(ctx); err != nil {
		return &Problem{Status: 502, Code: "offsite.failed", Title: err.Error()}
	}
	return nil
}

// StartOffsite runs an upload now (in the background) – also when the latest
// backup is already there (then it only fills gaps).
func (s *Service) StartOffsite(ctx context.Context, actor Actor) error {
	if err := requireAdmin(actor); err != nil {
		return err
	}
	d, _, err := s.offsiteClient(ctx)
	if err != nil || d == nil {
		if err == nil {
			err = Invalid("url", "enter and save the target first")
		}
		return err
	}
	d.close()
	go func() {
		bg, cancel := context.WithTimeout(context.WithoutCancel(ctx), 6*time.Hour)
		defer cancel()
		if _, err := s.OffsiteSync(bg, true); err != nil {
			s.Log.Error("off-site backup failed", "err", err)
		}
	}()
	return nil
}

var backupNameRe = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{4}`)

// latestLocalBackup: newest complete backup in the (read-only) backup folder.
func (s *Service) latestLocalBackup() (string, error) {
	dir := s.Cfg.BackupDir
	if dir == "" {
		return "", nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() && backupNameRe.MatchString(e.Name()) {
			if _, err := os.Stat(filepath.Join(dir, e.Name(), "OK")); err == nil {
				names = append(names, e.Name())
			}
		}
	}
	if len(names) == 0 {
		return "", nil
	}
	sort.Strings(names)
	return names[len(names)-1], nil
}

// OffsiteSync uploads the newest local backup if it is not there yet (or
// always with force). Returns whether something was uploaded. Called every
// few minutes by the server and by „Jetzt hochladen“.
func (s *Service) OffsiteSync(ctx context.Context, force bool) (bool, error) {
	d, st, err := s.offsiteClient(ctx)
	if err != nil || d == nil {
		return false, err
	}
	defer d.close()
	if !st.Enabled && !force {
		return false, nil
	}
	if !offsiteRun.TryLock() {
		return false, nil // already running
	}
	defer offsiteRun.Unlock()
	var state OffsiteStatus
	if _, err := s.loadJSONSetting(ctx, offsiteStateKey, &state); err != nil {
		return false, err
	}
	name, err := s.latestLocalBackup()
	if err != nil || name == "" {
		if err == nil && force {
			err = errors.New("no complete backup found – is the backup folder mounted into the app container (/data/backups)?")
		}
		return false, s.offsiteFailed(ctx, &state, err)
	}
	if name == state.LastName && !force {
		return false, nil
	}
	bytes, photos, err := s.offsiteUpload(ctx, d, st.Keep, name)
	if err != nil {
		return false, s.offsiteFailed(ctx, &state, err)
	}
	now := s.Now().UTC()
	state = OffsiteStatus{LastName: name, LastSuccess: &now, LastBytes: bytes, LastPhotos: photos}
	s.Log.Info("off-site backup uploaded", "backup", name, "bytes", bytes, "photos", photos)
	return true, s.saveJSONSetting(ctx, offsiteStateKey, state)
}

func (s *Service) offsiteFailed(ctx context.Context, state *OffsiteStatus, err error) error {
	if err == nil {
		return nil
	}
	now := s.Now().UTC()
	state.LastError, state.LastErrorAt = err.Error(), &now
	_ = s.saveJSONSetting(ctx, offsiteStateKey, state)
	return err
}

func (s *Service) offsiteUpload(ctx context.Context, d offsiteTarget, keep int, name string) (int64, int, error) {
	local := filepath.Join(s.Cfg.BackupDir, name)
	if err := d.check(ctx); err != nil {
		return 0, 0, err
	}
	known := map[string]bool{}
	var total int64
	send := func(rel, remote string) error {
		f, err := os.Open(filepath.Join(local, rel))
		if err != nil {
			return err
		}
		defer f.Close()
		fi, err := f.Stat()
		if err != nil {
			return err
		}
		if err := d.mkdirAll(ctx, filepath.ToSlash(filepath.Dir(remote)), known); err != nil {
			return err
		}
		if err := d.put(ctx, remote, f, fi.Size()); err != nil {
			return err
		}
		total += fi.Size()
		return nil
	}

	// 1. Photos: only new or changed ones (uploads.sha256: "<sha>  uploads/<path>")
	uploaded := map[string]string{}
	rows, err := s.Pool.Query(ctx, `SELECT path, sha256 FROM offsite_files`)
	if err != nil {
		return 0, 0, err
	}
	var p, h string
	if _, err := pgx.ForEachRow(rows, []any{&p, &h}, func() error { uploaded[p] = h; return nil }); err != nil {
		return 0, 0, err
	}
	sums, err := os.Open(filepath.Join(local, "uploads.sha256"))
	if err != nil {
		return 0, 0, err
	}
	defer sums.Close()
	photos := 0
	sc := bufio.NewScanner(sums)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		sha, rel, ok := strings.Cut(sc.Text(), "  ")
		if !ok || !strings.HasPrefix(rel, "uploads/") || strings.Contains(rel, "..") {
			continue
		}
		if uploaded[rel] == sha {
			continue
		}
		if err := send(rel, rel); err != nil {
			return total, photos, fmt.Errorf("photo %s: %w", rel, err)
		}
		if _, err := s.Pool.Exec(ctx, `INSERT INTO offsite_files (path, sha256) VALUES ($1, $2)
			ON CONFLICT (path) DO UPDATE SET sha256 = excluded.sha256, uploaded_at = now()`, rel, sha); err != nil {
			return total, photos, err
		}
		photos++
	}
	if err := sc.Err(); err != nil {
		return total, photos, err
	}

	// 2. The backup itself, OK last. Never the unredacted "env" (secrets) –
	// only env.redacted leaves the server.
	for _, f := range []string{"db.dump", "manifest.json", "uploads.sha256", "env.redacted", "OK"} {
		if _, err := os.Stat(filepath.Join(local, f)); err != nil {
			continue
		}
		if err := send(f, name+"/"+f); err != nil {
			return total, photos, err
		}
	}

	// 3. Retention: keep the newest <keep> backups remotely
	dirs, err := d.folders(ctx, "")
	if err != nil {
		return total, photos, err
	}
	var backups []string
	for _, n := range dirs {
		if backupNameRe.MatchString(n) {
			backups = append(backups, n)
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(backups)))
	for i, n := range backups {
		if i >= keep && n != name {
			if err := d.delete(ctx, n); err != nil {
				return total, photos, err
			}
		}
	}
	return total, photos, nil
}

// offsiteWarnAfter: without a successful off-site backup for this long, the
// administrators are told (again at most once a day).
const offsiteWarnAfter = 48 * time.Hour

// OffsiteWatch warns the administrators (e-mail and their ntfy) when the
// off-site backup has not worked for 48 hours. Returns whether it warned.
func (s *Service) OffsiteWatch(ctx context.Context) (bool, error) {
	var st storedOffsite
	if found, err := s.loadJSONSetting(ctx, offsiteKey, &st); err != nil || !found || !st.Enabled {
		return false, err
	}
	var state OffsiteStatus
	if _, err := s.loadJSONSetting(ctx, offsiteStateKey, &state); err != nil {
		return false, err
	}
	since := st.EnabledAt
	if state.LastSuccess != nil && (since == nil || state.LastSuccess.After(*since)) {
		since = state.LastSuccess
	}
	now := s.Now()
	if since == nil || now.Sub(*since) < offsiteWarnAfter ||
		(state.LastWarned != nil && now.Sub(*state.LastWarned) < 24*time.Hour) {
		return false, nil
	}
	rows, err := s.Pool.Query(ctx, `SELECT u.id, u.email, us.locale, u.lang_hint,
			COALESCE(np.ntfy_url, ''), COALESCE(np.ntfy_token, '')
		FROM users u JOIN user_settings us ON us.id = u.id
		LEFT JOIN notification_prefs np ON np.user_id = u.id
		WHERE u.instance_role = 'admin' AND u.disabled_at IS NULL`)
	if err != nil {
		return false, err
	}
	admins, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (recipient, error) {
		var r recipient
		var locale, hint *string
		err := row.Scan(&r.id, &r.email, &locale, &hint, &r.ntfyURL, &r.token)
		r.lang = resolveLang(locale, hint)
		return r, err
	})
	if err != nil {
		return false, err
	}
	hours := int(now.Sub(*since).Hours())
	warned := false
	for _, r := range admins {
		body := tl(r.lang, "Seit %d Stunden hat kein Backup außer Haus geklappt.", hours)
		if state.LastError != "" {
			body += " " + tl(r.lang, "Letzter Fehler: %s", state.LastError)
		}
		n := notice{Title: tl(r.lang, "Backup außer Haus fehlt"), Body: body, Priority: 4, Tags: []string{"warning"},
			Click: s.publicURL() + "/settings/offsite"}
		if s.deliver(ctx, r, true, true, n) {
			warned = true
		}
	}
	if warned {
		state.LastWarned = &now
		if err := s.saveJSONSetting(ctx, offsiteStateKey, state); err != nil {
			return true, err
		}
		s.Log.Warn("off-site backup failing – administrators warned", "hours", hours)
	}
	return warned, nil
}
