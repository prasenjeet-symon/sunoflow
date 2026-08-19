// Package ratelimit implements per-key rate limiting: a token bucket (per minute)
// backed by golang.org/x/time/rate, plus a daily request quota tracked in SQLite.
package ratelimit

import (
	"net/http"
	"strconv"
	"sync"
	"time"

	"golang.org/x/time/rate"

	"github.com/sunoflow/cleanup-gateway/internal/auth"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// Limiter holds a token bucket per key id, created lazily on first use.
type Limiter struct {
	mu       sync.Mutex
	buckets  map[string]*bucketEntry
	store    *store.Store
	defaultRPM int
	defaultDaily int
}

type bucketEntry struct {
	limiter *rateLimiter
	rpm     int
}

// rateLimiter is a thin wrapper over x/time/rate.Limiter so we can mock it.
type rateLimiter struct {
	limiter *rate.Limiter
}

// Allow reports whether a request is allowed right now.
func (r *rateLimiter) Allow() bool { return r.limiter.Allow() }

// New creates a Limiter using the given store for daily-quota checks.
func New(s *store.Store, defaultRPM, defaultDaily int) *Limiter {
	return &Limiter{
		buckets:      make(map[string]*bucketEntry),
		store:        s,
		defaultRPM:   defaultRPM,
		defaultDaily: defaultDaily,
	}
}

// Middleware enforces (1) daily quota from the store, then (2) per-minute token
// bucket. On exceed it writes 429 with a Retry-After header.
func (l *Limiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		keyID := auth.FromContext(r.Context())
		if keyID == "" {
			// No auth context — let the handler decide; shouldn't happen here.
			next.ServeHTTP(w, r)
			return
		}

		// Daily quota check first (cheap DB read).
		used, err := l.store.UsageForToday(r.Context(), keyID)
		if err != nil {
			// Fail open on DB error: never break dictation because the quota store is down.
			used = 0
		}
		if used >= l.defaultDaily {
			writeTooMany(w, 60)
			return
		}

		// Per-minute token bucket.
		if !l.allow(keyID) {
			writeTooMany(w, 1)
			return
		}

		// Count this request against the daily quota. Best-effort.
		_ = l.store.IncrementUsage(r.Context(), keyID)
		next.ServeHTTP(w, r)
	})
}

// allow fetches-or-creates the bucket for keyID and checks the token bucket.
func (l *Limiter) allow(keyID string) bool {
	l.mu.Lock()
	entry, ok := l.buckets[keyID]
	if !ok {
		entry = &bucketEntry{
			limiter: &rateLimiter{limiter: rate.NewLimiter(rate.Every(time.Minute/time.Duration(l.defaultRPM)), l.defaultRPM)},
			rpm:     l.defaultRPM,
		}
		l.buckets[keyID] = entry
	}
	l.mu.Unlock()
	return entry.limiter.Allow()
}

func writeTooMany(w http.ResponseWriter, retryAfter int) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	w.WriteHeader(http.StatusTooManyRequests)
	_, _ = w.Write([]byte(`{"error":"rate limit exceeded"}`))
}