package ratelimit

import (
	"testing"
	"time"
)

func TestBucket(t *testing.T) {
	now := time.Unix(0, 0)
	l := New(60, 3) // 1 per minute, burst 3
	l.SetClock(func() time.Time { return now })
	for i := 0; i < 3; i++ {
		if ok, _ := l.Allow("a"); !ok {
			t.Fatalf("request %d should pass", i)
		}
	}
	ok, wait := l.Allow("a")
	if ok || wait <= 0 || wait > time.Minute {
		t.Fatalf("4th request: ok=%v wait=%v", ok, wait)
	}
	if ok, _ := l.Allow("b"); !ok {
		t.Fatal("keys are independent")
	}
	now = now.Add(61 * time.Second)
	if ok, _ := l.Allow("a"); !ok {
		t.Fatal("token should be refilled")
	}
	l.Reset("a")
	now = now.Add(time.Hour)
	l.GC()
	if len(l.buckets) != 0 {
		t.Fatalf("GC should drop full buckets, %d left", len(l.buckets))
	}
}
