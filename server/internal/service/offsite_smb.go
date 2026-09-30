package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/hirochachacha/go-smb2"
)

// smbTarget copies the off-site backup to an SMB share (Windows, Synology,
// QNAP, Unraid, Samba) – SMB 2/3 with NTLM login, no mount in the container
// needed. Address: smb://server[:port]/share/folder.
type smbTarget struct {
	host, port, share, dir string
	user, pass, domain     string

	conn net.Conn
	sess *smb2.Session
	fs   *smb2.Share
}

func newSMBTarget(raw, user, pass string) (*smbTarget, error) {
	bad := Invalid("url", "enter the share as smb://server/share/folder, e.g. smb://nas/backup/acm")
	u, err := url.Parse(strings.TrimRight(strings.TrimSpace(raw), "/"))
	if err != nil || u.Scheme != "smb" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || len(raw) > 500 {
		return nil, bad
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if parts[0] == "" || strings.ContainsAny(u.Path, `\`) {
		return nil, bad
	}
	for _, p := range parts {
		if p == ".." || p == "." {
			return nil, bad
		}
	}
	port := u.Port()
	if port == "" {
		port = "445"
	} else if n, err := strconv.Atoi(port); err != nil || n < 1 || n > 65535 {
		return nil, bad
	}
	t := &smbTarget{host: u.Hostname(), port: port, share: parts[0], dir: strings.Join(parts[1:], "/"), user: user, pass: pass}
	// "DOMAIN\user" (Windows, Active Directory)
	if d, name, ok := strings.Cut(user, `\`); ok {
		t.domain, t.user = d, name
	}
	return t, nil
}

func (t *smbTarget) connect(ctx context.Context) error {
	if t.fs != nil {
		return nil
	}
	dialCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(dialCtx, "tcp", net.JoinHostPort(t.host, t.port))
	if err != nil {
		return fmt.Errorf("SMB server not reachable: %w", err)
	}
	d := &smb2.Dialer{Initiator: &smb2.NTLMInitiator{User: t.user, Password: t.pass, Domain: t.domain}}
	sess, err := d.DialContext(dialCtx, conn)
	if err != nil {
		conn.Close()
		return smbError("login", err)
	}
	share, err := sess.Mount(`\\` + t.host + `\` + t.share)
	if err != nil {
		_ = sess.Logoff()
		conn.Close()
		return smbError("share "+t.share, err)
	}
	t.conn, t.sess, t.fs = conn, sess, share
	return nil
}

// smbError turns NT status codes into hints.
func smbError(what string, err error) error {
	var re *smb2.ResponseError
	if what == "login" && (!errors.As(err, &re) || re.Code != 0xC000006D) {
		// some servers answer a wrong password with a malformed error
		return fmt.Errorf("SMB login failed – check user and password (%v)", err)
	}
	if errors.As(err, &re) {
		switch re.Code {
		case 0xC000006D: // STATUS_LOGON_FAILURE
			return fmt.Errorf("SMB %s: wrong user or password", what)
		case 0xC0000022: // STATUS_ACCESS_DENIED
			return fmt.Errorf("SMB %s: access denied – check the permissions of the user on the share", what)
		case 0xC00000CC: // STATUS_BAD_NETWORK_NAME
			return fmt.Errorf("SMB %s: share not found", what)
		}
	}
	return fmt.Errorf("SMB %s: %w", what, err)
}

// smbNotExist: the file or folder is not there.
func smbNotExist(err error) bool {
	var re *smb2.ResponseError
	return errors.Is(err, fs.ErrNotExist) ||
		(errors.As(err, &re) && (re.Code == 0xC000000F || re.Code == 0xC0000034 || re.Code == 0xC000003A)) // NO_SUCH_FILE, OBJECT_NAME/PATH_NOT_FOUND
}

// mounted returns the share bound to ctx (after connecting).
func (t *smbTarget) mounted(ctx context.Context) (*smb2.Share, error) {
	if err := t.connect(ctx); err != nil {
		return nil, err
	}
	return t.fs.WithContext(ctx), nil
}

func (t *smbTarget) path(p string) string {
	p = strings.Trim(p, "/")
	switch {
	case t.dir == "":
		return p
	case p == "":
		return t.dir
	}
	return t.dir + "/" + p
}

func (t *smbTarget) check(ctx context.Context) error {
	fs, err := t.mounted(ctx)
	if err != nil {
		return err
	}
	if t.dir != "" {
		if err := fs.MkdirAll(t.dir, 0o755); err != nil {
			return smbError("create folder "+t.dir, err)
		}
	}
	probe := t.path(".acm-write-test")
	if err := fs.WriteFile(probe, []byte("ok"), 0o644); err != nil {
		return smbError("write", err)
	}
	return fs.Remove(probe)
}

func (t *smbTarget) mkdirAll(ctx context.Context, p string, known map[string]bool) error {
	if known[p] {
		return nil
	}
	fs, err := t.mounted(ctx)
	if err != nil {
		return err
	}
	if err := fs.MkdirAll(t.path(p), 0o755); err != nil {
		return smbError("create folder "+p, err)
	}
	known[p] = true
	return nil
}

// put writes "<name>.part" first and renames it: an interrupted copy never
// looks complete.
func (t *smbTarget) put(ctx context.Context, p string, body io.Reader, size int64) error {
	share, err := t.mounted(ctx)
	if err != nil {
		return err
	}
	dst := t.path(p)
	tmp := dst + ".part"
	f, err := share.Create(tmp)
	if err != nil {
		return smbError("write "+p, err)
	}
	_, err = io.Copy(f, body)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = share.Remove(tmp)
		return smbError("write "+p, err)
	}
	if err := share.Remove(dst); err != nil && !smbNotExist(err) {
		return smbError("replace "+p, err)
	}
	if err := share.Rename(tmp, dst); err != nil {
		return smbError("rename "+p, err)
	}
	return nil
}

func (t *smbTarget) delete(ctx context.Context, p string) error {
	if strings.Trim(p, "/") == "" {
		return fmt.Errorf("refusing to delete the backup folder itself")
	}
	share, err := t.mounted(ctx)
	if err != nil {
		return err
	}
	if err := share.RemoveAll(t.path(p)); err != nil && !smbNotExist(err) {
		return smbError("delete "+p, err)
	}
	return nil
}

func (t *smbTarget) folders(ctx context.Context, p string) ([]string, error) {
	share, err := t.mounted(ctx)
	if err != nil {
		return nil, err
	}
	entries, err := share.ReadDir(t.path(p))
	if err != nil {
		return nil, smbError("list "+p, err)
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, e.Name())
		}
	}
	return out, nil
}

func (t *smbTarget) get(ctx context.Context, p string) (io.ReadCloser, error) {
	share, err := t.mounted(ctx)
	if err != nil {
		return nil, err
	}
	f, err := share.Open(t.path(p))
	if smbNotExist(err) {
		return nil, fs.ErrNotExist
	}
	if err != nil {
		return nil, smbError("read "+p, err)
	}
	return f, nil
}

// close logs off politely, but does not wait for a server that does not answer.
func (t *smbTarget) close() {
	if t.fs == nil {
		return
	}
	share, sess, conn := t.fs, t.sess, t.conn
	t.fs, t.sess, t.conn = nil, nil, nil
	done := make(chan struct{})
	go func() {
		_ = share.Umount()
		_ = sess.Logoff()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
	}
	conn.Close()
}
