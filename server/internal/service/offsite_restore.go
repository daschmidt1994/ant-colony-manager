package service

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"filippo.io/age"
)

// Restoring from the off-site target (acm offsite-restore, restore.sh
// --from-offsite): download a backup into a local folder – decrypted if
// needed, photos from the shared uploads/ folder, every file checked against
// uploads.sha256 – so that the normal restore can use it.

// OffsiteTargetConfig describes a target without the database (disaster:
// the server is new, its settings are gone).
type OffsiteTargetConfig struct {
	Type, URL, User, Password string
}

// OpenOffsiteTarget connects to a target described by hand.
func OpenOffsiteTarget(c OffsiteTargetConfig) (OffsiteTarget, error) {
	switch c.Type {
	case "", offsiteWebDAV:
		return newWebdav(c.URL, c.User, c.Password)
	case offsiteSMB:
		return newSMBTarget(c.URL, c.User, c.Password)
	case offsiteFolder:
		return newFolderTarget(c.URL)
	}
	return nil, fmt.Errorf("unknown type %q (webdav, smb or folder)", c.Type)
}

// CloseOffsiteTarget ends the connection (SMB).
func CloseOffsiteTarget(d OffsiteTarget) { d.close() }

// OffsiteTargetFromSettings opens the target saved in the app.
func (s *Service) OffsiteTargetFromSettings(ctx context.Context) (OffsiteTarget, error) {
	d, _, err := s.offsiteClient(ctx)
	if err == nil && d == nil {
		err = errors.New("no off-site backup set up in the app – give the target with ACM_OFFSITE_URL")
	}
	return d, err
}

// OffsiteRemoteBackups lists the complete backups on the target, newest first,
// and whether they are encrypted.
func OffsiteRemoteBackups(ctx context.Context, d OffsiteTarget) ([]string, bool, error) {
	encrypted := exists(ctx, d, offsiteKeyFile)
	dirs, err := d.folders(ctx, "")
	if err != nil {
		return nil, false, err
	}
	var out []string
	for _, n := range dirs {
		if backupNameRe.MatchString(n) && (exists(ctx, d, n+"/OK") || exists(ctx, d, n+"/OK.age")) {
			out = append(out, n)
		}
	}
	sort.Sort(sort.Reverse(sort.StringSlice(out)))
	return out, encrypted, nil
}

func exists(ctx context.Context, d OffsiteTarget, p string) bool {
	r, err := d.get(ctx, p)
	if err != nil {
		return false
	}
	r.Close()
	return true
}

// OffsiteFetch downloads backup name (newest if empty) to <to>/<name>.
// passphrase is needed for encrypted backups. progress may be nil.
func OffsiteFetch(ctx context.Context, d OffsiteTarget, name, to, passphrase string, progress func(string)) (string, error) {
	if progress == nil {
		progress = func(string) {}
	}
	list, encrypted, err := OffsiteRemoteBackups(ctx, d)
	if err != nil {
		return "", err
	}
	if len(list) == 0 {
		return "", errors.New("no complete backup on the target")
	}
	if name == "" {
		name = list[0]
	} else if !contains(list, name) {
		return "", fmt.Errorf("backup %s not on the target (there: %s)", name, strings.Join(list, ", "))
	}
	var id *age.X25519Identity
	suffix := ""
	if encrypted {
		if passphrase == "" {
			return "", errors.New("the backups are encrypted – the passphrase is needed (ACM_OFFSITE_PASSPHRASE)")
		}
		r, err := d.get(ctx, offsiteKeyFile)
		if err != nil {
			return "", err
		}
		keyFile, err := io.ReadAll(io.LimitReader(r, 64<<10))
		r.Close()
		if err != nil {
			return "", err
		}
		if id, err = unwrapOffsiteKey(keyFile, passphrase); err != nil {
			return "", err
		}
		suffix = ".age"
	}
	dir := filepath.Join(to, name)
	if _, err := os.Stat(filepath.Join(dir, "OK")); err == nil {
		return "", fmt.Errorf("%s already exists locally – restore it directly", dir)
	}
	// download one file; returns the SHA-256 of the plain content
	fetch := func(remote, local string) (string, error) {
		r, err := d.get(ctx, remote+suffix)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return "", fmt.Errorf("%s missing on the target", remote)
			}
			return "", err
		}
		defer r.Close()
		var src io.Reader = r
		if id != nil {
			if src, err = age.Decrypt(r, id); err != nil {
				return "", fmt.Errorf("%s cannot be decrypted: %w", remote, err)
			}
		}
		if err := os.MkdirAll(filepath.Dir(local), 0o755); err != nil {
			return "", err
		}
		out, err := os.Create(local + ".part")
		if err != nil {
			return "", err
		}
		h := sha256.New()
		_, err = io.Copy(io.MultiWriter(out, h), src)
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err == nil {
			err = os.Rename(local+".part", local)
		}
		if err != nil {
			_ = os.Remove(local + ".part")
			return "", fmt.Errorf("%s: %w", remote, err)
		}
		return hex.EncodeToString(h.Sum(nil)), nil
	}

	for _, f := range []string{"manifest.json", "uploads.sha256", "db.dump"} {
		progress(f)
		if _, err := fetch(name+"/"+f, filepath.Join(dir, f)); err != nil {
			return "", err
		}
	}
	if _, err := fetch(name+"/env.redacted", filepath.Join(dir, "env.redacted")); err != nil {
		progress("env.redacted: " + err.Error()) // optional
	}
	sums, err := os.Open(filepath.Join(dir, "uploads.sha256"))
	if err != nil {
		return "", err
	}
	defer sums.Close()
	sc := bufio.NewScanner(sums)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	photos := 0
	for sc.Scan() {
		sha, rel, ok := strings.Cut(sc.Text(), "  ")
		if !ok || !strings.HasPrefix(rel, "uploads/") || strings.Contains(rel, "..") {
			continue
		}
		got, err := fetch(rel, filepath.Join(dir, filepath.FromSlash(rel)))
		if err != nil {
			return "", err
		}
		if got != sha {
			return "", fmt.Errorf("%s: checksum wrong – the copy on the target is damaged", rel)
		}
		photos++
		if photos%100 == 0 {
			progress(fmt.Sprintf("%d photos", photos))
		}
	}
	if err := sc.Err(); err != nil {
		return "", err
	}
	progress(fmt.Sprintf("%d photos", photos))
	// OK last: only a complete download counts as a backup
	if err := os.WriteFile(filepath.Join(dir, "OK"), []byte("restored from off-site\n"), 0o644); err != nil {
		return "", err
	}
	return name, nil
}
