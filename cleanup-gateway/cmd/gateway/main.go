// Command gateway is the SunoFlow cleanup gateway — a single static Go binary
// that authenticates clients, rate-limits per key, and proxies cleanup requests
// to the Gemini API. It is the sole holder of the provider API key: no client
// ever sees it, which is the whole reason cleanup is server-side.
package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/account"
	"github.com/sunoflow/cleanup-gateway/internal/analytics"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/config"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/server"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n", err)
		os.Exit(1)
	}

	logger := newLogger(cfg.LogLevel)

	// Open the key store.
	st, err := store.New(cfg.DBPath)
	if err != nil {
		logger.Error("failed to open key store", "err", err, "path", cfg.DBPath)
		os.Exit(1)
	}
	defer st.Close()

	// Build the active backend. Gemini is the only implementation; adding
	// another means implementing backend.Backend and adding a case here.
	var be backend.Backend
	var activeModel string
	switch cfg.Backend {
	case "gemini":
		activeModel = cfg.GeminiModel
		be = &backend.GeminiBackend{
			APIKey:        cfg.GeminiAPIKey,
			Model:         cfg.GeminiModel,
			BaseURL:       cfg.GeminiURL,
			Timeout:       cfg.GeminiTimeout,
			ThinkingLevel: cfg.GeminiThinking,
			Client:        backend.NewHTTPClient(cfg.GeminiTimeout + 5*time.Second),
		}
	default:
		logger.Error("unsupported backend", "backend", cfg.Backend)
		os.Exit(1)
	}
	logger.Info("backend selected", "backend", be.Name(), "model", activeModel)

	// Product analytics. An empty POSTHOG_API_KEY leaves this disabled and every
	// Capture below becomes a no-op — no key, no events, no network calls.
	stats := analytics.New(cfg.PostHogAPIKey, analytics.Host(cfg.PostHogHost), logger)
	defer stats.Close()
	if stats.Enabled() {
		logger.Info("analytics enabled", "host", analytics.Host(cfg.PostHogHost))
	} else {
		logger.Info("analytics disabled (no POSTHOG_API_KEY)")
	}

	srv := &server.Server{
		Backend:     be,
		Store:       st,
		Logger:      logger,
		QuotaRPM:    cfg.QuotaRPM,
		QuotaDaily:  cfg.QuotaDaily,
		LeaseSecret: cfg.LeaseSecret,
		Analytics:   stats,
	}
	limiter := ratelimit.New(st, cfg.QuotaRPM, cfg.QuotaDaily, logger)

	// Entitlement lives in Firestore alongside the accounts. Without a project
	// configured the gateway keeps to its own key table and no subscription is
	// enforced — fine for local runs, not for production.
	var accounts *account.Resolver
	if cfg.FirebaseProject != "" {
		accounts, err = account.New(context.Background(), cfg.FirebaseProject, cfg.FirebaseCredentials)
		if err != nil {
			logger.Error("could not reach Firestore for account checks", "err", err)
			os.Exit(1)
		}
		defer func() { _ = accounts.Close() }()
		logger.Info("account entitlement enabled",
			"project", cfg.FirebaseProject,
			"lease_ttl", account.LeaseTTL.String(),
			"lease_secret", map[bool]string{true: "default", false: "custom"}[cfg.LeaseSecret == ""])
	} else {
		logger.Warn("FIREBASE_PROJECT not set — subscriptions are NOT enforced")
	}

	handler := server.NewMux(srv, limiter, cfg.AdminToken, accounts)

	httpServer := &http.Server{
		Addr:              cfg.GatewayAddr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// Ensure the DB directory exists for non-default paths.
	if cfg.DBPath != "" {
		_ = os.MkdirAll(dirOf(cfg.DBPath), 0o755)
	}

	go func() {
		logger.Info("gateway listening", "addr", cfg.GatewayAddr, "backend", be.Name(), "model", activeModel)
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server error", "err", err)
			os.Exit(1)
		}
	}()

	// Graceful shutdown on SIGINT/SIGTERM.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	logger.Info("shutting down")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = httpServer.Shutdown(ctx)
}

func newLogger(level string) *slog.Logger {
	var l slog.Level
	switch level {
	case "debug":
		l = slog.LevelDebug
	case "warn":
		l = slog.LevelWarn
	case "error":
		l = slog.LevelError
	default:
		l = slog.LevelInfo
	}
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: l}))
}

// dirOf returns the directory portion of a path, or "." if none.
func dirOf(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			if i == 0 {
				return "/"
			}
			return path[:i]
		}
	}
	return "."
}
