// Package server wires the HTTP router, middleware chain, and request handlers.
package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/auth"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/cleanup"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// Server holds the dependencies injected into handlers.
type Server struct {
	Backend     backend.Backend
	Store       *store.Store
	Logger      *slog.Logger
	QuotaRPM    int
	QuotaDaily  int
}

// now is overridable for tests.
var now = func() time.Time { return time.Now() }

// cleanupRequest mirrors the /cleanup API contract (§5.1).
type cleanupRequest struct {
	Text    string   `json:"text"`
	Context string   `json:"context"`
	Recent  []string `json:"recent"`
	Screen  string   `json:"screen"`
}

// cleanupResponse is the single response shape.
type cleanupResponse struct {
	Cleaned string `json:"cleaned"`
}

// NewMux builds the full router with the middleware chain applied in order:
// request-id + logging → (per-route) auth → rate-limit → handler.
func NewMux(s *Server, limiter *ratelimit.Limiter, adminToken string) http.Handler {
	mux := http.NewServeMux()

	// Unauthenticated endpoints.
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /ready", s.handleReady)

	// Authenticated + rate-limited cleanup endpoint.
	cleanupChain := chain(
		http.HandlerFunc(s.handleCleanup),
		auth.Middleware(s.Store),
		limiter.Middleware,
	)
	mux.Handle("POST /cleanup", cleanupChain)

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
		writeJSON(w, http.StatusOK, cleanupResponse{Cleaned: ""})
		return
	}
	context := strings.TrimSpace(req.Context)
	screen := strings.TrimSpace(req.Screen)
	recent := req.Recent
	if recent == nil {
		recent = []string{}
	}

	cleaned := s.runCleanup(r.Context(), text, context, recent, screen)
	writeJSON(w, http.StatusOK, cleanupResponse{Cleaned: cleaned})
}

// runCleanup reproduces clean_with_ollama from sidecar/server.py:
// 1. context-aware pass; if non-echo → return.
// 2. on echo, retry context-free; if length ok → return.
// 3. otherwise return raw text. Any backend error → raw text.
func (s *Server) runCleanup(ctx context.Context, text, context string, recent []string, screen string) string {
	// First pass: context-aware cleanup (better name/term correction).
	cleaned, err := s.Backend.Cleanup(ctx, cleanup.BuildPrompt(text, context, recent, screen))
	cleaned = strings.TrimSpace(cleaned)
	if err == nil && cleaned != "" && !cleanup.LooksLikeEcho(cleaned, text, context, recent, screen) {
		return cleaned
	}

	// The backend echoed reference material (or errored). Retry with NO context,
	// history, or screen — it can't repeat what it was never given.
	if context != "" || len(recent) > 0 || screen != "" {
		s.Logger.Info("cleanup echoed reference material; retrying context-free")
		cleaned, err = s.Backend.Cleanup(ctx, cleanup.BuildPrompt(text, "", nil, ""))
		cleaned = strings.TrimSpace(cleaned)
		if err == nil && cleaned != "" && !cleanup.TooLong(cleaned, text) {
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