package service

import "testing"

// The release notes exactly as the CI writes them (app.yml).
func TestBreakingTextFromCINotes(t *testing.T) {
	notes := "## ⚠ Breaking Changes\n\nZeile 1\nZeile 2\n\n**Android-App:** app-arm64-v8a-release.apk …\n\n**Server:** …"
	if got := breakingText(notes); got != "Zeile 1\nZeile 2" {
		t.Fatalf("got %q", got)
	}
	if got := breakingText("**Android-App:** nur normale Notizen"); got != "" {
		t.Fatalf("no section: %q", got)
	}
	for v, want := range map[string][3]int{"1.2.3": {1, 2, 3}, "v2.0.0": {2, 0, 0}, "1.2.2-dev.abc1234": {1, 2, 2}} {
		if got, ok := parseVersion(v); !ok || got != want {
			t.Errorf("%s → %v", v, got)
		}
	}
	if _, ok := parseVersion("lokal"); ok {
		t.Error("non-version accepted")
	}
}
