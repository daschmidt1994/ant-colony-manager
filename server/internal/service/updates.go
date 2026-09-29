package service

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Update check: the public GitHub release list, cached for 6 hours. Nothing
// is sent except the plain request (UPDATE_CHECK=false turns it off). Releases
// with breaking changes carry a „⚠ Breaking Changes“ section in their notes
// (scripts/release.sh --breaking); a new major version always counts as one.

const updateCacheFor = 6 * time.Hour

var updateCache struct {
	sync.Mutex
	at       time.Time
	url      string
	releases []releaseInfo
}

type releaseInfo struct {
	Version      string    `json:"version"`
	URL          string    `json:"url"`
	PublishedAt  time.Time `json:"published_at"`
	Breaking     bool      `json:"breaking"`
	BreakingText string    `json:"breaking_text,omitempty"`
}

type UpdateInfo struct {
	Enabled         bool          `json:"enabled"`
	Current         string        `json:"current"`
	Latest          string        `json:"latest,omitempty"`
	UpdateAvailable bool          `json:"update_available"`
	Breaking        bool          `json:"breaking"` // any newer release has breaking changes
	Newer           []releaseInfo `json:"newer"`    // newest first
	Error           string        `json:"error,omitempty"`
}

var semverRe = regexp.MustCompile(`^v?(\d+)\.(\d+)\.(\d+)`)

// parseVersion reads "1.2.3", "v1.2.3" and "1.2.3-dev.abc" (→ 1.2.3).
func parseVersion(v string) ([3]int, bool) {
	m := semverRe.FindStringSubmatch(strings.TrimSpace(v))
	if m == nil {
		return [3]int{}, false
	}
	var out [3]int
	for i := range out {
		out[i], _ = strconv.Atoi(m[i+1])
	}
	return out, true
}

func versionLess(a, b [3]int) bool {
	for i := range a {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return false
}

var breakingRe = regexp.MustCompile(`(?s)##\s*⚠?\s*Breaking Changes\s*\n(.*?)(\n##\s|\n\*\*Android-App|\z)`)

// breakingText extracts the „Breaking Changes“ section of release notes.
func breakingText(body string) string {
	m := breakingRe.FindStringSubmatch(strings.ReplaceAll(body, "\r\n", "\n"))
	if m == nil {
		return ""
	}
	return strings.TrimSpace(m[1])
}

func (s *Service) fetchReleases(ctx context.Context) ([]releaseInfo, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.Cfg.UpdateURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := notifyClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("release list: HTTP %d", resp.StatusCode)
	}
	var raw []struct {
		Tag         string    `json:"tag_name"`
		URL         string    `json:"html_url"`
		Body        string    `json:"body"`
		Draft       bool      `json:"draft"`
		Prerelease  bool      `json:"prerelease"`
		PublishedAt time.Time `json:"published_at"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(&raw); err != nil {
		return nil, err
	}
	out := make([]releaseInfo, 0, len(raw))
	for _, r := range raw {
		if r.Draft || r.Prerelease {
			continue
		}
		if _, ok := parseVersion(r.Tag); !ok {
			continue
		}
		text := breakingText(r.Body)
		out = append(out, releaseInfo{Version: strings.TrimPrefix(r.Tag, "v"), URL: r.URL,
			PublishedAt: r.PublishedAt, Breaking: text != "", BreakingText: text})
	}
	return out, nil
}

// Updates lists releases newer than current (the running server version).
func (s *Service) Updates(ctx context.Context, current string) *UpdateInfo {
	info := &UpdateInfo{Enabled: s.Cfg.UpdateCheck, Current: current, Newer: []releaseInfo{}}
	cur, ok := parseVersion(current)
	if !s.Cfg.UpdateCheck || !ok {
		return info
	}
	updateCache.Lock()
	defer updateCache.Unlock()
	if updateCache.url != s.Cfg.UpdateURL || s.Now().Sub(updateCache.at) > updateCacheFor {
		list, err := s.fetchReleases(ctx)
		if err != nil {
			s.Log.Warn("update check failed", "err", err)
			info.Error = "Update-Prüfung nicht möglich"
			if updateCache.url != s.Cfg.UpdateURL {
				return info
			}
		} else {
			updateCache.at, updateCache.url, updateCache.releases = s.Now(), s.Cfg.UpdateURL, list
		}
	}
	for _, r := range updateCache.releases {
		v, _ := parseVersion(r.Version)
		if !versionLess(cur, v) {
			continue
		}
		if v[0] > cur[0] && !r.Breaking {
			r.Breaking = true // a new major version never fits the old app/server
		}
		info.Newer = append(info.Newer, r)
		info.Breaking = info.Breaking || r.Breaking
	}
	sort.Slice(info.Newer, func(i, j int) bool { // newest first
		a, _ := parseVersion(info.Newer[i].Version)
		b, _ := parseVersion(info.Newer[j].Version)
		return versionLess(b, a)
	})
	if len(info.Newer) > 0 {
		info.UpdateAvailable, info.Latest = true, info.Newer[0].Version
	}
	return info
}
