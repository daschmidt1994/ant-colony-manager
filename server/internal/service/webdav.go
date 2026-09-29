package service

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"
)

// webdav is a minimal WebDAV client (RFC 4918) for the off-site backup:
// MKCOL, PUT, DELETE and PROPFIND (depth 0/1) – enough for Nextcloud,
// ownCloud, NAS WebDAV servers and storage boxes.
type webdav struct {
	base       *url.URL
	user, pass string
	client     *http.Client
}

func newWebdav(raw, user, pass string) (*webdav, error) {
	u, err := url.Parse(strings.TrimRight(strings.TrimSpace(raw), "/"))
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return nil, Invalid("url", "enter the WebDAV address, e.g. https://cloud.example.com/remote.php/dav/files/NAME/acm-backups")
	}
	return &webdav{base: u, user: user, pass: pass, client: &http.Client{Timeout: 0}}, nil
}

// url of a path below the base folder ("" = the base folder itself).
func (d *webdav) url(p string) string {
	u := *d.base
	u.Path = strings.TrimRight(u.Path, "/") + "/" + strings.TrimLeft(p, "/")
	u.RawPath = ""
	return u.String()
}

func (d *webdav) do(ctx context.Context, method, p string, body io.Reader, size int64, hdr map[string]string, timeout time.Duration) (*http.Response, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	req, err := http.NewRequestWithContext(ctx, method, d.url(p), body)
	if err != nil {
		cancel()
		return nil, err
	}
	if size >= 0 && body != nil {
		req.ContentLength = size
	}
	if d.user != "" || d.pass != "" {
		req.SetBasicAuth(d.user, d.pass)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := d.client.Do(req)
	if err != nil {
		cancel()
		return nil, err
	}
	resp.Body = &cancelOnClose{ReadCloser: resp.Body, cancel: cancel}
	return resp, nil
}

type cancelOnClose struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (c *cancelOnClose) Close() error { err := c.ReadCloser.Close(); c.cancel(); return err }

func davError(method, p string, resp *http.Response) error {
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 300))
	msg := strings.TrimSpace(string(b))
	switch resp.StatusCode {
	case http.StatusUnauthorized, http.StatusForbidden:
		return fmt.Errorf("%s %s: %d – check user and password (Nextcloud: app password)", method, p, resp.StatusCode)
	case http.StatusInsufficientStorage:
		return fmt.Errorf("%s %s: storage is full", method, p)
	}
	if len(msg) > 120 || strings.Contains(msg, "<") {
		msg = ""
	}
	return fmt.Errorf("%s %s: HTTP %d %s", method, p, resp.StatusCode, msg)
}

// mkcol creates a folder; an existing one is fine.
func (d *webdav) mkcol(ctx context.Context, p string) error {
	resp, err := d.do(ctx, "MKCOL", p, nil, -1, nil, time.Minute)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusCreated, http.StatusOK, http.StatusMethodNotAllowed: // 405 = exists
		return nil
	}
	return davError("MKCOL", p, resp)
}

// mkdirAll creates every folder of p (a/b/c → a, a/b, a/b/c), skipping known ones.
func (d *webdav) mkdirAll(ctx context.Context, p string, known map[string]bool) error {
	parts := strings.Split(strings.Trim(p, "/"), "/")
	for i := range parts {
		dir := strings.Join(parts[:i+1], "/")
		if dir == "" || known[dir] {
			continue
		}
		if err := d.mkcol(ctx, dir); err != nil {
			return err
		}
		known[dir] = true
	}
	return nil
}

func (d *webdav) put(ctx context.Context, p string, body io.Reader, size int64) error {
	// generous: a large database dump over a slow upload line
	resp, err := d.do(ctx, http.MethodPut, p, body, size, map[string]string{"Content-Type": "application/octet-stream"}, 2*time.Hour)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return davError("PUT", p, resp)
	}
	return nil
}

func (d *webdav) delete(ctx context.Context, p string) error {
	resp, err := d.do(ctx, http.MethodDelete, p, nil, -1, nil, 10*time.Minute)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 && resp.StatusCode != http.StatusNotFound {
		return davError("DELETE", p, resp)
	}
	return nil
}

type davMultistatus struct {
	Responses []struct {
		Href       string `xml:"href"`
		Collection *struct {
			XMLName xml.Name
		} `xml:"propstat>prop>resourcetype>collection"`
	} `xml:"response"`
}

const davPropfind = `<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>`

// folders lists the names of the sub-folders of p (PROPFIND depth 1).
func (d *webdav) folders(ctx context.Context, p string) ([]string, error) {
	resp, err := d.do(ctx, "PROPFIND", p, strings.NewReader(davPropfind), int64(len(davPropfind)),
		map[string]string{"Depth": "1", "Content-Type": "application/xml"}, time.Minute)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMultiStatus {
		return nil, davError("PROPFIND", p, resp)
	}
	var ms davMultistatus
	if err := xml.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(&ms); err != nil {
		return nil, fmt.Errorf("PROPFIND %s: unreadable answer: %w", p, err)
	}
	su, _ := url.Parse(d.url(p))
	self := strings.TrimRight(su.Path, "/")
	var out []string
	for _, r := range ms.Responses {
		if r.Collection == nil {
			continue
		}
		h := r.Href
		if u, err := url.Parse(h); err == nil {
			h = u.Path // absolute or path-only href
		}
		h = strings.TrimRight(h, "/")
		if h == self || h == "" {
			continue
		}
		out = append(out, path.Base(h))
	}
	return out, nil
}

// check verifies address and login and creates the base folder if needed.
func (d *webdav) check(ctx context.Context) error {
	resp, err := d.do(ctx, "PROPFIND", "", strings.NewReader(davPropfind), int64(len(davPropfind)),
		map[string]string{"Depth": "0", "Content-Type": "application/xml"}, 30*time.Second)
	if err != nil {
		return err
	}
	resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusMultiStatus:
		return nil
	case resp.StatusCode == http.StatusNotFound:
		return d.mkcol(ctx, "")
	}
	return davError("PROPFIND", "/", resp)
}
