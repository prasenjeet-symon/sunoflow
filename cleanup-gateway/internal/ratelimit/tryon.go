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

// TryonLimiter meters Suno Try-on (the virtual try-on image feature) on its
// own ledger, separate from the dictation, answer and control limiters: one
// try-on call is one paid composed image — the most expensive request the
// gateway serves — so it gets its own per-minute bucket, its own (tight)
// daily allowance, and a gateway-side hard ceiling no per-account
// configuration can exceed.
//
// An image is counted when the request comes in — the same "count on the way
// in" posture as answer and control (D5): the increment happens before the
// handler runs, so an aborted composition has still spent quota.
type TryonLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucketEntry
	store   *store.Store
	log     *slog.Logger

	rpm   int // default per-account try-on images/minute
	daily int // default per-account try-on images/day
	hard  int // gateway hard ceiling, applies regardless of per-account config
}

// NewTryon creates a TryonLimiter reading its daily ledger from the store.
// log may be nil, in which case a discarding logger is used.
func NewTryon(s *store.Store, rpm, daily, hard int, log *slog.Logger) *TryonLimiter {
	if log == nil {
		log = slog.New(slog.NewTextHandler(discard{}, nil))
	}
	return &TryonLimiter{
		buckets: make(map[string]*bucketEntry),
		store:   s,
		log:     log,
		rpm:     rpm,
		daily:   daily,
		hard:    hard,
	}
}

// Middleware enforces (1) the hard ceiling, (2) the per-account daily
// allowance, then (3) the per-minute token bucket, all over the tryon
// ledger. On exceed it writes 429 with body {"error":"limit"}.
//
// Must be chained after an authenticating middleware, same as Limiter.
func (l *TryonLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, ok := caller.From(r.Context())
		if !ok || id.MeterKey() == "" {
			l.log.Error("tryon limiter reached with no caller identity — check the middleware chain",
				"path", r.URL.Path)
			writeJSON(w, http.StatusInternalServerError,
				`{"error":"internal","message":"Couldn't check your subscription just now. Try again shortly."}`)
			return
		}
		meterKey := id.MeterKey()

		used, err := l.store.TryonUsageForToday(r.Context(), meterKey)
		if err != nil {
			// Fail open on DB error, bounded by the per-minute bucket — same
			// posture as dictation, answer and control. Logged so the outage
			// is visible.
			l.log.Warn("tryon daily quota lookup failed; allowing", "err", err)
			used = 0
		}
		if l.hard > 0 && used >= l.hard {
			l.log.Info("tryon hard ceiling reached", "meter", meterKey, "used", used)
			l.writeLimit(w, 60)
			return
		}
		if used >= l.daily {
			l.log.Info("tryon daily quota exceeded", "meter", meterKey, "used", used)
			l.writeLimit(w, 60)
			return
		}
		if !l.allow(meterKey) {
			l.writeLimit(w, 1)
			return
		}

		// Count when the request comes in. Best-effort: a failed write must
		// not fail a request the backend is about to compose.
		_ = l.store.IncrementTryonUsage(r.Context(), meterKey)
		next.ServeHTTP(w, r)
	})
}

// allow fetches-or-creates the per-minute bucket for meterKey and checks it.
func (l *TryonLimiter) allow(meterKey string) bool {
	l.mu.Lock()
	entry, ok := l.buckets[meterKey]
	if !ok {
		entry = &bucketEntry{
			limiter: &rateLimiter{limiter: rate.NewLimiter(rate.Every(time.Minute/time.Duration(l.rpm)), l.rpm)},
			rpm:     l.rpm,
		}
		l.buckets[meterKey] = entry
	}
	l.mu.Unlock()
	return entry.limiter.Allow()
}

func (l *TryonLimiter) writeLimit(w http.ResponseWriter, retryAfter int) {
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSON(w, http.StatusTooManyRequests, `{"error":"limit"}`)
}
