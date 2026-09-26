package service

import (
	"encoding/json"
	"os"
	"testing"
	"time"
)

func TestClassifySharedVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../test-vectors/due.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Cases []struct {
			Name      string     `json:"name"`
			Now       time.Time  `json:"now"`
			NextDueAt *time.Time `json:"next_due_at"`
			Timezone  string     `json:"timezone"`
			SoonDays  int        `json:"soon_days"`
			Status    string     `json:"status"`
			Group     string     `json:"group"`
			Days      int        `json:"days"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	for _, c := range v.Cases {
		loc, err := time.LoadLocation(c.Timezone)
		if err != nil {
			t.Fatal(err)
		}
		st, g, d := Classify(c.NextDueAt, c.Now, loc, c.SoonDays)
		if st != c.Status || g != c.Group || d != c.Days {
			t.Errorf("%s: got %s/%s/%d want %s/%s/%d", c.Name, st, g, d, c.Status, c.Group, c.Days)
		}
	}
}

func TestReadEXIFIsDefensive(t *testing.T) {
	for _, b := range [][]byte{nil, {0xFF}, {0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF}, []byte("not a jpeg at all")} {
		if o, ts := readEXIF(b); o != 1 || ts != nil {
			t.Errorf("garbage %v gave orientation %d", b, o)
		}
	}
}

func TestSensorKeyFormat(t *testing.T) {
	p, s := newSensorKey()
	prefix, secret, ok := SensorKeyPrefix("acm_sk_" + p + "_" + s)
	if !ok || prefix != p || secret != s {
		t.Fatalf("roundtrip failed: %q %q", prefix, secret)
	}
	for _, bad := range []string{"", "acm_sk_", "Bearer x", "acm_pk_a_b"} {
		if _, _, ok := SensorKeyPrefix(bad); ok {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestLikeEscape(t *testing.T) {
	if got := likeEscape(`50%_a\b`); got != `%50\%\_a\\b%` {
		t.Fatalf("got %q", got)
	}
}
