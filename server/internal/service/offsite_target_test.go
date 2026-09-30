package service

import (
	"testing"

	"github.com/google/uuid"
)

func TestSMBAddress(t *testing.T) {
	for raw, want := range map[string]smbTarget{
		"smb://nas/backup":                  {host: "nas", port: "445", share: "backup"},
		"smb://192.168.178.5:1445/b/acm/x/": {host: "192.168.178.5", port: "1445", share: "b", dir: "acm/x"},
		" smb://nas/Backup Share/acm ":      {host: "nas", port: "445", share: "Backup Share", dir: "acm"},
	} {
		got, err := newSMBTarget(raw, `FIRMA\anna`, "pw")
		if err != nil {
			t.Fatalf("%q: %v", raw, err)
		}
		if got.host != want.host || got.port != want.port || got.share != want.share || got.dir != want.dir ||
			got.user != "anna" || got.domain != "FIRMA" {
			t.Errorf("%q: %+v", raw, got)
		}
	}
	for _, raw := range []string{"", "nas/backup", "smb://nas", "smb://nas/", "smb://user:pw@nas/b", "https://nas/b",
		`smb://nas/b\c`, "smb://nas/b/../c", "smb://nas:0/b"} {
		if _, err := newSMBTarget(raw, "", ""); err == nil {
			t.Errorf("%q accepted", raw)
		}
	}
	if p := (&smbTarget{dir: "acm"}).path("2026/OK"); p != "acm/2026/OK" {
		t.Error(p)
	}
	if p := (&smbTarget{}).path("/uploads/a.jpg"); p != "uploads/a.jpg" {
		t.Error(p)
	}
}

func TestEntitySlug(t *testing.T) {
	id := uuid.MustParse("01a0f17d-5770-7ce8-af9a-2ace6f67da11")
	for in, want := range map[string]string{"Ben Müller": "ben_mueller", "Anna M.": "anna_m", "  Groß  ": "gross",
		"🐜": "user_01a0f1", "Sehr langer Name mit vielen Teilen": "sehr_langer_name_mit"} {
		if got := entitySlug(in, id); got != want {
			t.Errorf("%q → %q, want %q", in, got, want)
		}
	}
}
