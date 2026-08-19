package backend

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// OllamaBackend calls a local Ollama /api/generate endpoint. It is the sole
// caller of Ollama, which must bind 127.0.0.1 only and never be internet-facing.
type OllamaBackend struct {
	URL     string        // e.g. http://127.0.0.1:11434/api/generate
	Model   string        // server-controlled model name
	Timeout time.Duration // per-call timeout
	Client  *http.Client
}

// ollamaRequest is the JSON body sent to /api/generate. Mirrors sidecar/server.py.
type ollamaRequest struct {
	Model   string         `json:"model"`
	Prompt  string         `json:"prompt"`
	Stream  bool           `json:"stream"`
	Options ollamaOptions `json:"options"`
}

type ollamaOptions struct {
	Temperature float64 `json:"temperature"`
}

type ollamaResponse struct {
	Response string `json:"response"`
}

// Cleanup calls Ollama with the built prompt and returns the trimmed response.
func (b *OllamaBackend) Cleanup(ctx context.Context, prompt string) (string, error) {
	body, err := json.Marshal(ollamaRequest{
		Model:  b.Model,
		Prompt: prompt,
		Stream: false,
		Options: ollamaOptions{
			Temperature: 0.0,
		},
	})
	if err != nil {
		return "", fmt.Errorf("marshal ollama request: %w", err)
	}

	c, cancel := context.WithTimeout(ctx, b.Timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(c, http.MethodPost, b.URL, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build ollama request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := b.Client.Do(req)
	if err != nil {
		return "", fmt.Errorf("ollama call: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Read a small amount for diagnostics; never log transcript content.
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("ollama returned %d: %s", resp.StatusCode, string(snippet))
	}

	var out ollamaResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("decode ollama response: %w", err)
	}
	return out.Response, nil
}

// Name identifies the backend in logs and /ready.
func (b *OllamaBackend) Name() string { return "ollama" }

// Healthy probes Ollama by issuing a trivial tags request. Used by /ready.
// Derives the tags URL from the configured generate URL so it works whether
// Ollama is a compose service (http://ollama:11434) or the host
// (http://host.ollama:11434) — never hardcode 127.0.0.1, which inside a
// container refers to the container itself.
func (b *OllamaBackend) Healthy(ctx context.Context) bool {
	tagsURL := strings.Replace(b.URL, "/api/generate", "/api/tags", 1)
	c, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(c, http.MethodGet, tagsURL, nil)
	if err != nil {
		return false
	}
	resp, err := b.Client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}