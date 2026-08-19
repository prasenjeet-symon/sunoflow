// Command gateway is the SunoFlow cleanup gateway — a single static Go binary
// that authenticates clients, rate-limits per key, and proxies cleanup requests
// to a local Ollama instance. It is the sole caller of Ollama.
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

	// Build the active backend (v1: ollama only; openai/claude are interface-only).
	var be backend.Backend
	switch cfg.Backend {
	case "ollama":
		be = &backend.OllamaBackend{
			URL:     cfg.OllamaURL,
			Model:   cfg.OllamaModel,
			Timeout: cfg.OllamaTimeout,
			Client:  &http.Client{Timeout: cfg.OllamaTimeout + 5*time.Second},
		}
	default:
		logger.Error("unsupported backend in v1", "backend", cfg.Backend)
		os.Exit(1)
	}

	srv := &server.Server{
		Backend:    be,
		Store:      st,
		Logger:     logger,
		QuotaRPM:   cfg.QuotaRPM,
		QuotaDaily: cfg.QuotaDaily,
	}
	limiter := ratelimit.New(st, cfg.QuotaRPM, cfg.QuotaDaily)
	handler := server.NewMux(srv, limiter, cfg.AdminToken)

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
		logger.Info("gateway listening", "addr", cfg.GatewayAddr, "backend", be.Name(), "model", cfg.OllamaModel)
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