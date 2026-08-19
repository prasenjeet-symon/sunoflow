// Package backend defines the LLM backend abstraction. The CleanupHandler is
// unaware of which backend is active; selection is config-driven.
package backend

import "context"

// Backend is the interface every LLM backend implements.
type Backend interface {
	// Cleanup sends the full built prompt and returns the model's text response.
	Cleanup(ctx context.Context, prompt string) (string, error)
	// Name returns a human-readable backend identifier for logging/health.
	Name() string
	// Healthy reports whether the backend is reachable and ready to serve.
	Healthy(ctx context.Context) bool
}