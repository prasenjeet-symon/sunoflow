package account

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/sunoflow/cleanup-gateway/internal/caller"
)

type ctxKey int

const resolutionKey ctxKey = 1

// FromContext returns the resolved account for a request, if there is one.
func FromContext(ctx context.Context) (Resolution, bool) {
	v, ok := ctx.Value(resolutionKey).(Resolution)
	return v, ok
}

func bearer(h http.Header) string {
	v := h.Get("Authorization")
	if len(v) < 7 || !strings.EqualFold(v[:7], "Bearer ") {
		return ""
	}
	return strings.TrimSpace(v[7:])
}

// userMessage is what the Mac app shows when a request is refused, so the app
// does not have to know the vocabulary of plan states.
func userMessage(r Reason) string {
	switch r {
	case ReasonTrialExpired:
		return "Your free trial has ended. Activate your subscription to keep dictating."
	case ReasonCanceled, ReasonLapsed:
		return "Your subscription has ended. Reactivate it to keep dictating."
	case ReasonRevoked:
		return "This device was disconnected from your account. Connect it again to keep dictating."
	default:
		return "This device isn't linked to an active SunoFlow account."
	}
}

// LegacyLookup verifies a key issued before device pairing existed — the
// gateway's own SQLite table. Returning true lets the request through.
type LegacyLookup func(ctx context.Context, plaintext string) bool

// Middleware authenticates the device key and enforces entitlement.
//
// A key that exists but is not entitled gets 402 rather than 401, so the app can
// tell "you need to pay" apart from "your credentials are wrong" and show the
// right thing instead of asking the user to sign in again.
//
// Both are refusals and both stop dictation. That distinction is for the
// wording the user sees, and nothing else — a client that resumes on one but
// not the other is a client that serves a disconnected device for free. The
// rule the sidecars implement, and the one any future client must: every 401,
// 402 and 403 carrying a JSON `error` body is a hard stop; 429 and 5xx and
// transport failures are outages and soft-fail to raw text.
//
// An entitled request also leaves with a signed lease (see lease.go), which is
// what lets the sidecar tell a genuine outage from a gateway that has been
// blocked to dodge the check.
//
// `legacy` may be nil. When set, a key Firestore has never seen is offered to
// the old key table before being refused, so turning entitlement on does not
// instantly lock out every install that has not paired yet. Once devices have
// migrated, pass nil and the old keys stop working.
func Middleware(r *Resolver, legacy LegacyLookup, leaseSecret string, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			key := bearer(req.Header)
			if key == "" {
				writeJSON(w, http.StatusUnauthorized, map[string]string{
					"error":   "missing_key",
					"message": "This device isn't connected to a SunoFlow account.",
				})
				return
			}

			res, err := r.Resolve(req.Context(), key)
			if err != nil {
				if errors.Is(err, ErrUnknownKey) {
					// Not a paired device. Give the pre-pairing key table a look
					// before refusing, so existing installs keep working.
					if legacy != nil && legacy(req.Context(), key) {
						log.Info("cleanup served on a pre-pairing key")
						// No account behind a legacy key, so it meters against
						// itself. Set even though this branch is dead in
						// production: the limiter refuses a request with no
						// identity, and whoever re-enables the fallback should
						// not have to rediscover that.
						next.ServeHTTP(w, req.WithContext(
							caller.With(req.Context(), caller.Identity{KeyID: KeyID(key)})))
						return
					}
					writeJSON(w, http.StatusUnauthorized, map[string]string{
						"error":   "invalid_key",
						"message": "This device isn't connected to a SunoFlow account.",
					})
					return
				}
				// A Firestore outage must not look like an auth failure.
				log.Error("account lookup failed", "err", err)
				writeJSON(w, http.StatusServiceUnavailable, map[string]string{
					"error":   "account_unavailable",
					"message": "Couldn't check your subscription just now. Try again shortly.",
				})
				return
			}

			if !res.Entitled {
				code := http.StatusPaymentRequired
				if res.Reason == ReasonRevoked {
					code = http.StatusUnauthorized
				}
				writeJSON(w, code, map[string]string{
					"error":   string(res.Reason),
					"message": userMessage(res.Reason),
				})
				return
			}

			// Best-effort heartbeat; never blocks or fails the request.
			go r.TouchDevice(context.WithoutCancel(req.Context()), res.UID, res.DeviceID)

			// Mint the offline lease here rather than in the resolver, so it is
			// never served from the 60s decision cache: every allowed request
			// carries a full-length lease and an app in daily use never drifts
			// towards its expiry.
			res.Lease = SignLease(leaseSecret, res.KeyID, res.UID, r.now(), LeaseTTL)

			// Two things travel downstream: the full resolution (the handlers
			// read the lease off it) and the metering identity the rate limiter
			// bills against. The limiter refuses a request without the latter,
			// so this must be set on every path that reaches a handler.
			ctx := context.WithValue(req.Context(), resolutionKey, res)
			ctx = caller.With(ctx, caller.Identity{KeyID: res.KeyID, UID: res.UID})
			next.ServeHTTP(w, req.WithContext(ctx))
		})
	}
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(body)
}
