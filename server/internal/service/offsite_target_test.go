package service

import "testing"

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
