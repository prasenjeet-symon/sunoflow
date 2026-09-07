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

// STTLimiter meters the cloud speech-to-text warm-start path on its own ledger,
// separate from both the dictation Limiter and the AnswerLimiter. Cloud STT
// costs real money per call, so — like Answer — it gets its own per-minute
// bucket, its own daily allowance, and a gateway-side hard ceiling that no
// per-account configuration can exceed.
//
// The whole point of this path is to be temporary: a new device transcribes in
// the cloud only until its local model has downloaded and validated, then the
// sidecar cuts over and stops calling here. The ceiling exists so a device that
// never manages to cut over (a stalled download, a slow machine) still cannot
// run an unbounded cloud bill — it degrades to "wait for local" instead.
//
// A transcription is counted on the way in, before the backend call: a client
// that abandons a request has still spent the transcription, and there is no
// reliable "the user never used it" signal that a broken client couldn't abuse.
type STTLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucketEntry
	store   *store.Store
	log     *slog.Logger

	rpm   int // default per-account transcriptions/minute
	daily int // default per-account transcriptions/day
	hard  int // gateway hard ceiling, applies regardless of per-account config
}

// NewSTT creates an STTLimiter reading its daily ledger from the store. log may
// be nil, in which case a discarding logger is used.
func NewSTT(s *store.Store, rpm, daily, hard int, log *slog.Logger) *STTLimiter {
	if log == nil {
		log = slog.New(slog.NewTextHandler(discard{}, nil))
	}
	return &STTLimiter{
		buckets: make(map[string]*bucketEntry),
		store:   s,
		log:     log,
		rpm:     rpm,
		daily:   daily,
		hard:    hard,
	}
}

// Middleware enforces (1) the hard ceiling, (2) the per-account daily
// allowance, then (3) the per-minute token bucket, all over the STT ledger. On
// exceed it writes 429 with body {"error":"limit"} — the sidecar maps this to
// "no warm-start budget left; fall back to waiting for the local model."
//
// Must be chained after an authenticating middleware, same as Limiter.
func (l *STTLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, ok := caller.From(r.Context())
		if !ok || id.MeterKey() == "" {
			l.log.Error("stt limiter reached with no caller identity — check the middleware chain",
				"path", r.URL.Path)
			writeJSON(w, http.StatusInternalServerError,
				`{"error":"internal","message":"Couldn't check your subscription just now. Try again shortly."}`)
			return
		}
		meterKey := id.MeterKey()

		used, err := l.store.STTUsageForToday(r.Context(), meterKey)
		if err != nil {
			// Fail open on DB error, bounded by the per-minute bucket — same
			// posture as dictation and answer. Logged so the outage is visible.
			l.log.Warn("stt daily quota lookup failed; allowing", "err", err)
			used = 0
		}
		if l.hard > 0 && used >= l.hard {
			l.log.Info("stt hard ceiling reached", "meter", meterKey, "used", used)
			l.writeLimit(w, 60)
			return
		}
		if used >= l.daily {
			l.log.Info("stt daily quota exceeded", "meter", meterKey, "used", used)
			l.writeLimit(w, 60)
			return
		}
		if !l.allow(meterKey) {
			l.writeLimit(w, 1)
			return
		}

		// Count when the request enters. Best-effort: a failed write must not
		// fail a transcription the backend is about to perform.
		_ = l.store.IncrementSTTUsage(r.Context(), meterKey)
		next.ServeHTTP(w, r)
	})
}

// allow fetches-or-creates the per-minute bucket for meterKey and checks it.
func (l *STTLimiter) allow(meterKey string) bool {
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

func (l *STTLimiter) writeLimit(w http.ResponseWriter, retryAfter int) {
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSON(w, http.StatusTooManyRequests, `{"error":"limit"}`)
}
