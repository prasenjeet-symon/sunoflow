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

// ControlLimiter meters Suno Control (the agent-loop computer-control feature)
// on its own ledger, separate from the dictation and answer limiters: a
// control run is a burst of paid planning calls (the client runs up to 12
// steps, one gateway call each), so it gets its own per-minute bucket, its own
// daily allowance, and a gateway-side hard ceiling no per-account
// configuration can exceed.
//
// A step is counted when the request comes in — the same "count on the way
// in" posture as answer (D5): the increment happens before the handler runs,
// so an aborted step has still spent quota.
type ControlLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucketEntry
	store   *store.Store
	log     *slog.Logger

	rpm   int // default per-account control steps/minute
	daily int // default per-account control steps/day
	hard  int // gateway hard ceiling, applies regardless of per-account config
}

// NewControl creates a ControlLimiter reading its daily ledger from the store.
// log may be nil, in which case a discarding logger is used.
func NewControl(s *store.Store, rpm, daily, hard int, log *slog.Logger) *ControlLimiter {
	if log == nil {
		log = slog.New(slog.NewTextHandler(discard{}, nil))
	}
	return &ControlLimiter{
		buckets: make(map[string]*bucketEntry),
		store:   s,
		log:     log,
		rpm:     rpm,
		daily:   daily,
		hard:    hard,
	}
}

// Middleware enforces (1) the hard ceiling, (2) the per-account daily
// allowance, then (3) the per-minute token bucket, all over the control
// ledger. On exceed it writes 429 with body {"error":"limit"} — the exact
// token the sidecar maps to the loop's stop reason.
//
// Must be chained after an authenticating middleware, same as Limiter.
func (l *ControlLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, ok := caller.From(r.Context())
		if !ok || id.MeterKey() == "" {
			l.log.Error("control limiter reached with no caller identity — check the middleware chain",
				"path", r.URL.Path)
			writeJSON(w, http.StatusInternalServerError,
				`{"error":"internal","message":"Couldn't check your subscription just now. Try again shortly."}`)
			return
		}
		meterKey := id.MeterKey()

		used, err := l.store.ControlUsageForToday(r.Context(), meterKey)
		if err != nil {
			// Fail open on DB error, bounded by the per-minute bucket — same
			// posture as dictation and answer. Logged so the outage is visible.
			l.log.Warn("control daily quota lookup failed; allowing", "err", err)
			used = 0
		}
		if l.hard > 0 && used >= l.hard {
			l.log.Info("control hard ceiling reached", "meter", meterKey, "used", used)
			l.writeLimit(w, 60)
			return
		}
		if used >= l.daily {
			l.log.Info("control daily quota exceeded", "meter", meterKey, "used", used)
			l.writeLimit(w, 60)
			return
		}
		if !l.allow(meterKey) {
			l.writeLimit(w, 1)
			return
		}

		// Count when the request comes in. Best-effort: a failed write must
		// not fail a request the backend is about to plan.
		_ = l.store.IncrementControlUsage(r.Context(), meterKey)
		next.ServeHTTP(w, r)
	})
}

// allow fetches-or-creates the per-minute bucket for meterKey and checks it.
func (l *ControlLimiter) allow(meterKey string) bool {
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

func (l *ControlLimiter) writeLimit(w http.ResponseWriter, retryAfter int) {
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSON(w, http.StatusTooManyRequests, `{"error":"limit"}`)
}
