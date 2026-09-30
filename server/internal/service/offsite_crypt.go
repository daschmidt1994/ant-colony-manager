package service

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strings"

	"filippo.io/age"
)

// Encrypted off-site backups (age, https://age-encryption.org). The server
// generates an X25519 key pair once and encrypts every file with the public
// key – fast, also for thousands of photos. The private key is stored on the
// target as "key.age", encrypted with the administrator's passphrase
// (scrypt), so that a restore needs nothing but the passphrase. The server
// never stores the passphrase; its own copy of the private key is encrypted
// with INSTANCE_SECRET (needed to wrap it again when the passphrase changes).
//
// Encrypted files get ".age" appended: db.dump.age, uploads/c1/a.jpg.age, OK.age.

const (
	offsiteKeyFile   = "key.age"
	minPassphrase    = 12
	ageChunk         = 64 << 10
	ageChunkOverhead = 16
)

type offsiteCrypt struct {
	recipient *age.X25519Recipient
	header    int64 // bytes before the payload (header + nonce)
}

func newOffsiteCrypt(recipient string) (*offsiteCrypt, error) {
	r, err := age.ParseX25519Recipient(recipient)
	if err != nil {
		return nil, fmt.Errorf("stored backup key is invalid: %w", err)
	}
	// the header has a fixed length per recipient; an empty file is header + nonce + one empty chunk
	var b bytes.Buffer
	w, err := age.Encrypt(&b, r)
	if err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return &offsiteCrypt{recipient: r, header: int64(b.Len()) - ageChunkOverhead}, nil
}

// size of the encrypted form of n bytes (WebDAV wants the length up front).
func (c *offsiteCrypt) size(n int64) int64 {
	chunks := (n + ageChunk - 1) / ageChunk
	if chunks == 0 {
		chunks = 1
	}
	return c.header + n + chunks*ageChunkOverhead
}

// reader encrypts src on the fly.
func (c *offsiteCrypt) reader(src io.Reader) io.ReadCloser {
	pr, pw := io.Pipe()
	go func() {
		w, err := age.Encrypt(pw, c.recipient)
		if err == nil {
			_, err = io.Copy(w, src)
			if cerr := w.Close(); err == nil {
				err = cerr
			}
		}
		pw.CloseWithError(err)
	}()
	return pr
}

// newOffsiteKey creates a key pair: the public key (for encrypting), the
// private key (to keep, encrypted by the caller) and key.age for the target.
func newOffsiteKey(passphrase string) (recipient, identity string, keyFile []byte, err error) {
	id, err := age.GenerateX25519Identity()
	if err != nil {
		return "", "", nil, err
	}
	keyFile, err = wrapOffsiteKey(id.String(), passphrase)
	return id.Recipient().String(), id.String(), keyFile, err
}

// wrapOffsiteKey encrypts the private key with the passphrase (key.age).
func wrapOffsiteKey(identity, passphrase string) ([]byte, error) {
	r, err := age.NewScryptRecipient(passphrase)
	if err != nil {
		return nil, err
	}
	var b bytes.Buffer
	w, err := age.Encrypt(&b, r)
	if err != nil {
		return nil, err
	}
	if _, err := io.WriteString(w, identity+"\n"); err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// unwrapOffsiteKey opens key.age with the passphrase.
func unwrapOffsiteKey(keyFile []byte, passphrase string) (*age.X25519Identity, error) {
	s, err := age.NewScryptIdentity(passphrase)
	if err != nil {
		return nil, err
	}
	r, err := age.Decrypt(bytes.NewReader(keyFile), s)
	if err != nil {
		var noMatch *age.NoIdentityMatchError
		if errors.As(err, &noMatch) || strings.Contains(err.Error(), "incorrect passphrase") {
			return nil, errors.New("wrong passphrase")
		}
		return nil, fmt.Errorf("key.age cannot be opened: %w", err)
	}
	b, err := io.ReadAll(io.LimitReader(r, 4096))
	if err != nil {
		return nil, err
	}
	return age.ParseX25519Identity(strings.TrimSpace(string(b)))
}
