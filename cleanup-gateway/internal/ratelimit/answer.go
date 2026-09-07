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

// AnswerLimiter meters Suno Answer (the paid ask-a-question feature) on its own
// ledger, separate from the dictation Limiter: answers cost real money per
// message (grounded generation + streaming), so they get their own per-minute
// bucket, their own daily allowance, and a gateway-side hard ceiling that no
// per-account configuration can exceed.
//
// A message is counted when its stream STARTS (D5): the increment happens on
// the way in, so a client that aborts mid-stream has still spent the message.
// That is the deliberate, recorded cost of counting at stream start instead of
// stream end — there is no reliable signal for "the user never saw a word"
// that doesn't let a broken client dodge the meter.
//
// AnswerLimiter holds a per-minute token bucket per meter key, created lazily
// on first use.
type AnswerLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucketEntry
	store   *store.Store
	log     *slog.Logger

	rpm   int // default per-account answer messages/minute
	daily int // default per-account answer messages/day
	hard  int // gateway hard ceiling, applies regardless of per-account config
}

// NewAnswer creates an AnswerLimiter reading its daily ledger from the store.
// log may be nil, in which case a discarding logger is used.
func NewAnswer(s *store.Store, rpm, daily, hard int, log *slog.Logger) *AnswerLimiter {
	if log == nil {
		log = slog.New(slog.NewTextHandler(discard{}, nil))
	}
	return &AnswerLimiter{
		buckets: make(map[string]*bucketEntry),
		store:   s,
		log:     log,
		rpm:     rpm,
		daily:   daily,
		hard:    hard,
	}
}

// Middleware enforces (1) the hard ceiling, (2) the per-account daily
// allowance, then (3) the per-minute token bucket, all over the answer ledger.
// On exceed it writes 429 with body {"error":"limit"} — the exact token the
// sidecar maps to the "limit reached — resets tomorrow" error card (D4).
//
// Must be chained after an authenticating middleware, same as Limiter.
func (l *AnswerLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, ok := caller.From(r.Context())
		if !ok || id.MeterKey() == "" {
			l.log.Error("answer limiter reached with no caller identity — check the middleware chain",
				"path", r.URL.Path)
			writeJSON(w, http.StatusInternalServerError,
				`{"error":"internal","message":"Couldn't check your subscription just now. Try again shortly."}`)
			return
		}
		meterKey := id.MeterKey()

		used, err := l.store.AnswerUsageForToday(r.Context(), meterKey)
		if err != nil {
			// Fail open on DB error, bounded by the per-minute bucket — same
			// posture as dictation. Logged so the outage is visible.
			l.log.Warn("answer daily quota lookup failed; allowing", "err", err)
			used = 0
		}
		if l.hard > 0 && used >= l.hard {
			l.log.Info("answer hard ceiling reached", "meter", meterKey, "used", used)
			l.writeLimit(w, 60)
			return
		}
		if used >= l.daily {
			l.log.Info("answer daily quota exceeded", "meter", meterKey, "used", used)
			l.writeLimit(w, 60)
			return
		}
		if !l.allow(meterKey) {
			l.writeLimit(w, 1)
			return
		}

		// Count when the stream starts. Best-effort: a failed write must not
		// fail a request the backend is about to stream.
		_ = l.store.IncrementAnswerUsage(r.Context(), meterKey)
		next.ServeHTTP(w, r)
	})
}

// allow fetches-or-creates the per-minute bucket for meterKey and checks it.
func (l *AnswerLimiter) allow(meterKey string) bool {
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

func (l *AnswerLimiter) writeLimit(w http.ResponseWriter, retryAfter int) {
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSON(w, http.StatusTooManyRequests, `{"error":"limit"}`)
}