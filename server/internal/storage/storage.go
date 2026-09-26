// Package storage stores uploaded files. The default is a local directory
// (a Docker volume); keys are content-addressed and therefore immutable.
package storage

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
)

type BlobStore interface {
	// Put writes data under key atomically. Existing keys are left untouched.
	Put(key string, r io.Reader) error
	Open(key string) (io.ReadSeekCloser, int64, error)
	Exists(key string) bool
	Delete(key string) error
	// Writable checks that the store accepts writes (readiness probe).
	Writable() error
}

var validKey = regexp.MustCompile(`^[a-z0-9]{2}/[a-z0-9]{2}/[a-z0-9._-]{1,120}$`)

var ErrInvalidKey = errors.New("invalid storage key")

type FS struct{ Root string }

func NewFS(root string) (*FS, error) {
	if err := os.MkdirAll(root, 0o750); err != nil {
		return nil, fmt.Errorf("create storage dir: %w", err)
	}
	return &FS{Root: root}, nil
}

func (f *FS) path(key string) (string, error) {
	if !validKey.MatchString(key) {
		return "", ErrInvalidKey
	}
	return filepath.Join(f.Root, filepath.FromSlash(key)), nil
}

func (f *FS) Put(key string, r io.Reader) error {
	p, err := f.path(key)
	if err != nil {
		return err
	}
	if _, err := os.Stat(p); err == nil {
		return nil // content-addressed: same key == same content
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".upload-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) //nolint:errcheck // no-op after rename
	if _, err := io.Copy(tmp, r); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o640); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), p)
}

func (f *FS) Open(key string) (io.ReadSeekCloser, int64, error) {
	p, err := f.path(key)
	if err != nil {
		return nil, 0, err
	}
	fh, err := os.Open(p)
	if err != nil {
		return nil, 0, err
	}
	st, err := fh.Stat()
	if err != nil {
		fh.Close()
		return nil, 0, err
	}
	return fh, st.Size(), nil
}

func (f *FS) Exists(key string) bool {
	p, err := f.path(key)
	if err != nil {
		return false
	}
	_, err = os.Stat(p)
	return err == nil
}

func (f *FS) Delete(key string) error {
	p, err := f.path(key)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (f *FS) Writable() error {
	tmp, err := os.CreateTemp(f.Root, ".probe-*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	tmp.Close()
	return os.Remove(name)
}
