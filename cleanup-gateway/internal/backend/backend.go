// Package backend defines the LLM backend abstraction. The CleanupHandler is
// unaware of which backend is active; selection is config-driven.
package backend

import (
	"context"
	"net/http"
	"time"
)

// ProviderIdleTimeout is how long an idle connection to the LLM provider is
// kept before it is dropped.
//
// Go's default transport uses 90s, which is shorter than the gap between one
// dictation and the next (median ~124s measured against real traffic). The
// result was that most dictations re-paid DNS, TCP and a TLS handshake to
// Google before the model saw a single token: 1.86s for the first call against
// 1.29s once warm, on an identical prompt.
//
// Holding connections open for longer is safe here even though cleanup is a
// POST. The Gemini backend builds its request body with bytes.NewReader, so
// net/http populates Request.GetBody, and a request that goes out on a
// connection the peer has already closed is replayed transparently on a fresh
// one — the retry happens before any response byte is read, so it cannot
// duplicate a cleanup the server actually performed.
const ProviderIdleTimeout = 15 * time.Minute

// NewHTTPClient builds the HTTP client a backend uses to reach its provider.
//
// It clones the default transport rather than mutating it: http.DefaultTransport
// is process-global, and changing it in place would quietly re-tune every other
// HTTP client in the binary, including the Firestore SDK's.
func NewHTTPClient(timeout time.Duration) *http.Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.IdleConnTimeout = ProviderIdleTimeout
	// The gateway fans every device's traffic into a single provider host, so
	// the default of 2 idle connections per host is sized for the wrong shape:
	// past two concurrent dictations, connections would be closed on return and
	// the next request would hand-shake again.
	tr.MaxIdleConnsPerHost = 16
	return &http.Client{Timeout: timeout, Transport: tr}
}

// Backend is the interface every LLM backend implements.
type Backend interface {
	// Cleanup sends the full built prompt and returns the model's text response.
	Cleanup(ctx context.Context, prompt string) (string, error)
	// Name returns a human-readable backend identifier for logging/health.
	Name() string
	// Healthy reports whether the backend is reachable and ready to serve.
	Healthy(ctx context.Context) bool
}
