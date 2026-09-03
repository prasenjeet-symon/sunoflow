// Package server wires the HTTP router, middleware chain, and request handlers.
package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/account"
	"github.com/sunoflow/cleanup-gateway/internal/analytics"
	"github.com/sunoflow/cleanup-gateway/internal/auth"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/caller"
	"github.com/sunoflow/cleanup-gateway/internal/cleanup"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// Server holds the dependencies injected into handlers.
type Server struct {
	Backend    backend.Backend
	Store      *store.Store
	Logger     *slog.Logger
	QuotaRPM   int
	QuotaDaily int
	// LeaseSecret signs the offline entitlement leases handed to entitled
	// callers. Empty falls back to account.DefaultLeaseSecret.
	LeaseSecret string
	// Analytics counts dictations and users. Nil, or configured without an API
	// key, means nothing is reported and every call here is a no-op.
	Analytics *analytics.Client
}

// clientHeader is how a sidecar says what it is: "<os>/<version>", e.g.
// "mac/1.1.2". Absent on installs that predate it, which is why both halves
// default rather than being required.
const clientHeader = "X-SunoFlow-Client"

// parseClient splits the client header into an OS and a version, defaulting
// both to "unknown" so a missing or malformed header shows up in the numbers as
// an old install rather than as no install.
func parseClient(h string) (os, version string) {
	h = strings.TrimSpace(h)
	if h == "" {
		return "unknown", "unknown"
	}
	// Bounded before use: this is an attacker-controlled header, and an
	// unbounded one would become an unbounded property in every event.
	if len(h) > 64 {
		h = h[:64]
	}
	osPart, verPart, found := strings.Cut(h, "/")
	osPart = strings.TrimSpace(osPart)
	verPart = strings.TrimSpace(verPart)
	if osPart == "" {
		osPart = "unknown"
	}
	if !found || verPart == "" {
		verPart = "unknown"
	}
	return osPart, verPart
}

// now is overridable for tests.
var now = func() time.Time { return time.Now() }

// cleanupRequest mirrors the /cleanup API contract (§5.1).
//
// `dictionary` is the user's own saved terms. It is stored only on their
// machine; the sidecar sends just the entries that look relevant to this one
// transcript, and the gateway keeps them for the length of the request — they
// are never persisted and never logged.
type cleanupRequest struct {
	Text    string   `json:"text"`
	Context string   `json:"context"`
	Recent  []string `json:"recent"`
	Screen  string   `json:"screen"`
	// App is what the client's own OS reported about where the words are
	// going: the frontmost process id, the host when that process is a
	// browser, and the focused window's title. It costs the device nothing to
	// read and, unlike anything inferred from a screenshot, it is observed
	// rather than guessed. The gateway owns every meaning attached to it —
	// see cleanup.App.
	App        string          `json:"app"`
	AppSite    string          `json:"app_site"`
	AppDetail  string          `json:"app_detail"`
	Dictionary []cleanup.Entry `json:"dictionary"`
	// Tone is the ID of the voice the user picked in the app — "formal", not
	// the wording that produces formal output. The gateway owns every
	// instruction the model sees, so an ID it does not serve is not an error:
	// it normalizes to the faithful tone, which is also what an older client
	// that never sends the field gets. Either way the user's own wording is
	// what survives.
	Tone string `json:"tone"`
}

// cleanupResponse is the single response shape.
//
// `lease` rides along on the normal cleanup path so a device in daily use keeps
// a fresh offline lease without ever making an extra request for one. Older
// sidecars ignore the field; it is omitted entirely when no account was
// resolved (the legacy key table issues no leases).
type cleanupResponse struct {
	Cleaned string `json:"cleaned"`
	Lease   string `json:"lease,omitempty"`
}

// NewMux builds the full router with the middleware chain applied in order:
// request-id + logging → (per-route) auth → rate-limit → handler.
func NewMux(s *Server, limiter *ratelimit.Limiter, adminToken string, accounts *account.Resolver) http.Handler {
	mux := http.NewServeMux()

	// Unauthenticated endpoints.
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /ready", s.handleReady)

	// Authenticated + rate-limited cleanup endpoint.
	// Device keys are issued by the pairing function and checked against
	// Firestore, which is also where entitlement lives. Where no Firebase
	// project is configured the gateway falls back to its own key table, so
	// existing installs keep working while devices migrate across.
	keyCheck := auth.Middleware(s.Store)
	if accounts != nil {
		// nil: no legacy fallback. The migration window is over — a key that
		// Firestore does not know is refused, including the shared key that
		// used to ship inside every install. Every caller must now be a paired
		// device belonging to an account in good standing.
		keyCheck = account.Middleware(accounts, nil, s.LeaseSecret, s.Logger)
	}
	cleanupChain := chain(
		http.HandlerFunc(s.handleCleanup),
		keyCheck,
		limiter.Middleware,
	)
	mux.Handle("POST /cleanup", cleanupChain)

	// Entitlement-only probe. Same auth and the same verdict as /cleanup, but no
	// LLM call — so a client that has cleanup switched off can still be told it
	// is out of subscription, instead of dictating free forever.
	mux.Handle("GET /entitlement", chain(
		http.HandlerFunc(s.handleEntitlement),
		keyCheck,
	))

	// Admin endpoints (separate admin token).
	adminAuth := auth.AdminMiddleware(adminToken)
	mux.Handle("GET /admin/keys", chain(http.HandlerFunc(s.handleAdminListKeys), adminAuth))
	mux.Handle("POST /admin/keys", chain(http.HandlerFunc(s.handleAdminCreateKey), adminAuth))
	mux.Handle("DELETE /admin/keys/{id}", chain(http.HandlerFunc(s.handleAdminRevokeKey), adminAuth))

	// Wrap everything in request-id + structured logging.
	return withLogging(s.Logger, mux)
}

// handleHealth is a liveness probe.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleReady checks backend reachability.
func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
	ok := s.Backend.Healthy(r.Context())
	status := "ready"
	if !ok {
		status = "degraded"
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":     status,
		"backend":    s.Backend.Name(),
		"backend_ok": ok,
	})
}

// handleCleanup is the primary endpoint. It builds the prompt, calls the backend,
// applies the echo-retry guard, and always returns 200 with at least the raw text.
func (s *Server) handleCleanup(w http.ResponseWriter, r *http.Request) {
	var req cleanupRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed json"})
		return
	}
	text := strings.TrimSpace(req.Text)
	if text == "" {
		writeJSON(w, http.StatusOK, cleanupResponse{Cleaned: "", Lease: leaseFor(r)})
		return
	}
	context := strings.TrimSpace(req.Context)
	screen := strings.TrimSpace(req.Screen)
	recent := req.Recent
	if recent == nil {
		recent = []string{}
	}
	dict := cleanup.NormalizeDict(req.Dictionary)
	tone := cleanup.NormalizeTone(req.Tone)
	app := cleanup.App{
		ID:     strings.TrimSpace(req.App),
		Site:   strings.TrimSpace(req.AppSite),
		Detail: strings.TrimSpace(req.AppDetail),
	}

	started := time.Now()
	cleaned := s.runCleanup(r.Context(), text, context, recent, screen, app, dict, tone)
	writeJSON(w, http.StatusOK, cleanupResponse{Cleaned: cleaned, Lease: leaseFor(r)})

	// One dictation, counted. Lengths and flags only — the transcript, the
	// cleaned text, the screen OCR and the dictionary are all in scope right
	// here and none of them leave this function.
	clientOS, clientVersion := parseClient(r.Header.Get(clientHeader))
	id, _ := caller.From(r.Context())
	// Where the user dictates, as a dimension. `app_category` is a closed set,
	// and `app` is only ever a name this gateway already knows — an id we do
	// not recognise is somebody's internal or personal tool, and counting it by
	// name would put that in a third-party dashboard. The window title is never
	// reported: it is the one part of this that carries content.
	_, appCat, appName := app.Resolve()
	s.Analytics.Capture(analytics.Event{
		Name:       "dictation",
		DistinctID: id.MeterKey(),
		Properties: map[string]any{
			"os":               clientOS,
			"app_version":      clientVersion,
			"cleanup":          true,
			"transcript_chars": len(text),
			"cleaned_chars":    len(cleaned),
			"had_screen":       screen != "",
			"had_context":      context != "",
			"app_category":     string(appCat),
			"app":              appName,
			"dictionary_terms": len(dict),
			"tone":             tone.String(),
			"latency_ms":       time.Since(started).Milliseconds(),
		},
		PersonProperties: map[string]any{
			"os":          clientOS,
			"app_version": clientVersion,
		},
	})
}

// runCleanup applies the two-pass cleanup contract:
// 1. context-aware pass; if non-echo → return.
// 2. on echo, retry context-free; if length ok → return.
// 3. otherwise return raw text. Any backend error → raw text.
func (s *Server) runCleanup(ctx context.Context, text, context string, recent []string, screen string, app cleanup.App, dict []cleanup.Entry, tone cleanup.Tone) string {
	// First pass: context-aware cleanup (better name/term correction).
	cleaned, err := s.Backend.Cleanup(ctx, cleanup.BuildPrompt(text, context, recent, screen, app, dict, tone))
	cleaned = strings.TrimSpace(cleaned)
	if err == nil && cleaned != "" && !cleanup.LooksLikeEcho(cleaned, text, context, recent, screen, app, dict, tone) {
		return cleaned
	}

	// The backend echoed reference material (or errored). Retry with NO context,
	// history, or screen — it can't repeat what it was never given. The
	// dictionary and the tone stay: both are short, structured, and the thing
	// the user explicitly asked us to apply, so dropping either would silently
	// turn the feature off on exactly the dictations that needed a second
	// attempt — and a retry that quietly reverted to the faithful voice would
	// read to the user as the tone key having missed the press. The bulky,
	// noisy sources are the ones that get echoed, and those are gone.
	if context != "" || len(recent) > 0 || screen != "" {
		s.Logger.Info("cleanup echoed reference material; retrying context-free")
		cleaned, err = s.Backend.Cleanup(ctx, cleanup.BuildPrompt(text, "", nil, "", app, dict, tone))
		cleaned = strings.TrimSpace(cleaned)
		if err == nil && cleaned != "" && !cleanup.TooLong(cleaned, text, dict, tone) {
			return cleaned
		}
	}

	if err != nil {
		s.Logger.Warn("backend cleanup failed, falling back to raw text", "err", err.Error())
	}
	return text
}

// writeJSON marshals v and writes it with the given status.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// chain composes middleware around a final handler. Middlewares are applied
// left-to-right (first runs first); the handler runs last.
func chain(handler http.Handler, middlewares ...func(http.Handler) http.Handler) http.Handler {
	h := handler
	for i := len(middlewares) - 1; i >= 0; i-- {
		h = middlewares[i](h)
	}
	return h
}

// handleEntitlement answers 200 for a caller the middleware already allowed.
// Anything not entitled never reaches here — the middleware has already
// returned 402 or 401 with a message for the user.
//
// This is the endpoint a client with cleanup switched off calls, so it is also
// where that client collects its offline lease.
func (s *Server) handleEntitlement(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "lease": leaseFor(r)})

	// Deliberately NOT counted as a dictation. This endpoint is what a client
	// with cleanup switched off calls, but the sidecar caches a successful
	// check for ten minutes, so it fires roughly once per ten minutes of use
	// rather than once per dictation. Counting it as a dictation would report a
	// number that is wrong by however much someone dictates in that window.
	//
	// It is still worth an event: without one, a user who turns cleanup off
	// disappears from the user count entirely, which is a worse answer than
	// counting them as active with their dictations unknown.
	clientOS, clientVersion := parseClient(r.Header.Get(clientHeader))
	id, _ := caller.From(r.Context())
	s.Analytics.Capture(analytics.Event{
		Name:       "entitlement_check",
		DistinctID: id.MeterKey(),
		Properties: map[string]any{
			"os":          clientOS,
			"app_version": clientVersion,
			"cleanup":     false,
		},
		PersonProperties: map[string]any{
			"os":          clientOS,
			"app_version": clientVersion,
		},
	})
}

// leaseFor returns the lease the account middleware minted for this request, or
// "" when the request was authenticated some other way.
func leaseFor(r *http.Request) string {
	res, ok := account.FromContext(r.Context())
	if !ok {
		return ""
	}
	return res.Lease
}
