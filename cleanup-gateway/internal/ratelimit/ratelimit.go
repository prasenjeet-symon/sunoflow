// Package ratelimit implements per-account rate limiting: a token bucket (per
// minute) backed by golang.org/x/time/rate, plus a daily request quota tracked
// in SQLite.
//
// Both quotas were dead in production for as long as entitlement has been on.
// The limiter read the caller's identity from the `auth` package's context key,
// but the account middleware — the one actually in the chain once Firestore is
// configured — wrote its own, under a different unexported type. Go compares
// context keys by type as well as value, so the lookup always missed, and the
// "no auth context — shouldn't happen here" branch served the request anyway.
// A single account on a seven-day trial could drive an unbounded provider bill,
// and a leaked key could not be contained by throttling.
//
// Two things stop that recurring. Identity now lives in one place
// (internal/caller) that every authenticating middleware populates, and a
// request that arrives without one is refused rather than waved through — so
// the same mistake fails loudly on a dev machine instead of silently on an
// invoice.
package ratelimit

import (
	"log/slog"
	"net/http"
	"strconv"
	"sync"
	"time"

	"golang.org/x/time/rate"

	"github.com/sunoflow/cleanup-gateway/internal/caller"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// Limiter holds a token bucket per meter key, created lazily on first use.
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucketEntry
	store   *store.Store
	log     *slog.Logger

	defaultRPM   int
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

// New creates a Limiter using the given store for daily-quota checks. log may be
// nil, in which case a discarding logger is used.
func New(s *store.Store, defaultRPM, defaultDaily int, log *slog.Logger) *Limiter {
	if log == nil {
		log = slog.New(slog.NewTextHandler(discard{}, nil))
	}
	return &Limiter{
		buckets:      make(map[string]*bucketEntry),
		store:        s,
		log:          log,
		defaultRPM:   defaultRPM,
		defaultDaily: defaultDaily,
	}
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

// Middleware enforces (1) daily quota from the store, then (2) per-minute token
// bucket. On exceed it writes 429 with a Retry-After header.
//
// Must be chained *after* an authenticating middleware. Without one there is
// nothing to meter against, which is a bug in the route's chain rather than
// anything the caller did — so it answers 500 and says so in the log. It does
// not serve the request: an unmeterable request is exactly the one that used to
// cost us money silently.
func (l *Limiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, ok := caller.From(r.Context())
		if !ok || id.MeterKey() == "" {
			l.log.Error("rate limiter reached with no caller identity — check the middleware chain",
				"path", r.URL.Path)
			writeJSON(w, http.StatusInternalServerError,
				`{"error":"internal","message":"Couldn't check your subscription just now. Try again shortly."}`)
			return
		}
		meterKey := id.MeterKey()

		// Daily quota check first (cheap DB read).
		used, err := l.store.UsageForToday(r.Context(), meterKey)
		if err != nil {
			// Fail open on DB error: never break dictation because the quota
			// store is down. Unlike a missing identity this is a real outage,
			// it is bounded by the per-minute bucket below, and it is logged.
			l.log.Warn("daily quota lookup failed; allowing", "err", err)
			used = 0
		}
		if used >= l.defaultDaily {
			l.log.Info("daily quota exceeded", "meter", meterKey, "used", used)
			writeTooMany(w, 60)
			return
		}

		// Per-minute token bucket.
		if !l.allow(meterKey) {
			writeTooMany(w, 1)
			return
		}

		// Count this request against the daily quota. Best-effort.
		_ = l.store.IncrementUsage(r.Context(), meterKey)
		next.ServeHTTP(w, r)
	})
}

// allow fetches-or-creates the bucket for meterKey and checks the token bucket.
func (l *Limiter) allow(meterKey string) bool {
	l.mu.Lock()
	entry, ok := l.buckets[meterKey]
	if !ok {
		entry = &bucketEntry{
			limiter: &rateLimiter{limiter: rate.NewLimiter(rate.Every(time.Minute/time.Duration(l.defaultRPM)), l.defaultRPM)},
			rpm:     l.defaultRPM,
		}
		l.buckets[meterKey] = entry
	}
	l.mu.Unlock()
	return entry.limiter.Allow()
}

func writeTooMany(w http.ResponseWriter, retryAfter int) {
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSON(w, http.StatusTooManyRequests, `{"error":"rate limit exceeded"}`)
}

func writeJSON(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}
