package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// folderTarget writes the off-site backup into a folder mounted into the
// container – an NFS share (Docker mounts it, see docs/25), an SMB mount of
// the host or a USB disk. The folder must exist: a missing mount must not
// quietly fill the container.
type folderTarget struct{ root string }

func newFolderTarget(raw string, protected ...string) (*folderTarget, error) {
	root := filepath.Clean(strings.TrimSpace(raw))
	if !filepath.IsAbs(root) || root == "/" || len(raw) > 500 {
		return nil, Invalid("url", "enter the folder in the container, e.g. /offsite")
	}
	for _, p := range protected {
		if p == "" {
			continue
		}
		p = filepath.Clean(p)
		// the local backups or photos themselves – retention would delete them
		if root == p || strings.HasPrefix(root+"/", p+"/") || strings.HasPrefix(p+"/", root+"/") {
			return nil, Invalid("url", "choose a folder outside %s – that is where the local data lives", p)
		}
	}
	return &folderTarget{root: root}, nil
}

// file maps a relative target path into the folder (never outside it).
func (f *folderTarget) file(p string) (string, error) {
	p = strings.Trim(p, "/")
	if p == ".." || strings.HasPrefix(p, "../") || strings.Contains(p, "/../") || strings.HasSuffix(p, "/..") {
		return "", fmt.Errorf("invalid path %q", p)
	}
	return filepath.Join(f.root, filepath.FromSlash(p)), nil
}

func (f *folderTarget) check(ctx context.Context) error {
	fi, err := os.Stat(f.root)
	if errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("folder %s does not exist in the container – is the volume (NFS, disk) mounted there?", f.root)
	}
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		return fmt.Errorf("%s is not a folder", f.root)
	}
	probe := filepath.Join(f.root, ".acm-write-test")
	if err := os.WriteFile(probe, []byte("ok"), 0o644); err != nil {
		return fmt.Errorf("cannot write to %s (permissions of the share or PUID/PGID?): %w", f.root, err)
	}
	return os.Remove(probe)
}

func (f *folderTarget) mkdirAll(ctx context.Context, p string, known map[string]bool) error {
	if known[p] {
		return nil
	}
	dir, err := f.file(p)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	known[p] = true
	return nil
}

// put writes to "<name>.part" first: an interrupted copy never looks complete.
func (f *folderTarget) put(ctx context.Context, p string, body io.Reader, size int64) error {
	dst, err := f.file(p)
	if err != nil {
		return err
	}
	tmp := dst + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, readerWithContext(ctx, body))
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

func (f *folderTarget) delete(ctx context.Context, p string) error {
	dir, err := f.file(p)
	if err != nil || dir == f.root {
		return fmt.Errorf("refusing to delete %q", p)
	}
	return os.RemoveAll(dir)
}

func (f *folderTarget) folders(ctx context.Context, p string) ([]string, error) {
	dir, err := f.file(p)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, e.Name())
		}
	}
	return out, nil
}

func (f *folderTarget) close() {}

// readerWithContext stops a long copy when ctx ends.
func readerWithContext(ctx context.Context, r io.Reader) io.Reader {
	return readerFunc(func(p []byte) (int, error) {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		return r.Read(p)
	})
}

type readerFunc func([]byte) (int, error)

func (f readerFunc) Read(p []byte) (int, error) { return f(p) }
