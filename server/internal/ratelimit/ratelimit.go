// Package ratelimit implements an in-memory token bucket limiter keyed by string.
// A single self-hosted instance does not need Redis for this.
package ratelimit

import (
	"math"
	"sync"
	"time"
)

type bucket struct {
	tokens float64
	last   time.Time
}

type Limiter struct {
	mu      sync.Mutex
	rate    float64 // tokens per second
	burst   float64
	buckets map[string]*bucket
	now     func() time.Time
}

// New allows `burst` requests at once and refills `perHour` tokens per hour.
func New(perHour float64, burst int) *Limiter {
	return &Limiter{
		rate:    perHour / 3600,
		burst:   float64(burst),
		buckets: map[string]*bucket{},
		now:     time.Now,
	}
}

// Allow consumes a token for key. If none is available it returns false and the
// duration until the next token.
func (l *Limiter) Allow(key string) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b, ok := l.buckets[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
		if len(l.buckets) > 100_000 {
			l.gcLocked(now)
		}
	}
	b.tokens = math.Min(l.burst, b.tokens+now.Sub(b.last).Seconds()*l.rate)
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := time.Duration((1 - b.tokens) / l.rate * float64(time.Second))
	return false, wait
}

// Reset forgets a key (e.g. after a successful login).
func (l *Limiter) Reset(key string) {
	l.mu.Lock()
	delete(l.buckets, key)
	l.mu.Unlock()
}

// GC removes buckets that are full again; call periodically.
func (l *Limiter) GC() {
	l.mu.Lock()
	l.gcLocked(l.now())
	l.mu.Unlock()
}

func (l *Limiter) gcLocked(now time.Time) {
	for k, b := range l.buckets {
		if b.tokens+now.Sub(b.last).Seconds()*l.rate >= l.burst {
			delete(l.buckets, k)
		}
	}
}

// SetClock replaces the time source (tests).
func (l *Limiter) SetClock(now func() time.Time) { l.now = now }
