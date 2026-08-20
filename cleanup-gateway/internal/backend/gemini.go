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

// GeminiBackend calls Google's Gemini API (generativelanguage.googleapis.com)
// via generateContent.
//
// Why this exists: the Ollama cloud tags are all large reasoning models
// (even "nano" resolves to a 30b-cloud tag), and they emit chain-of-thought
// before answering. For mechanical transcript tidying that reasoning is pure
// latency — measured at 6-24s per cleanup. A flash-lite class model with
// thinking pinned to its floor does the same job in a fraction of that.
type GeminiBackend struct {
	APIKey  string        // never logged; injected from env
	Model   string        // e.g. gemini-3.5-flash-lite
	BaseURL string        // API root, e.g. https://generativelanguage.googleapis.com/v1beta
	Timeout time.Duration // per-call timeout
	// ThinkingLevel caps how much the model reasons before answering:
	// "minimal" | "low" | "medium" | "high". Cleanup is mechanical, so the
	// floor is what we want — reasoning here is pure latency.
	//
	// Gemini 3.x replaced the older integer `thinkingBudget` with this string
	// field; sending thinkingBudget to a 3.x model returns 400 INVALID_ARGUMENT.
	// Empty string omits thinkingConfig entirely, which is the escape hatch for
	// older 2.5-era models that only understand the budget form.
	ThinkingLevel string
	Client        *http.Client
}

// --- request shapes ---

type geminiRequest struct {
	Contents         []geminiContent `json:"contents"`
	GenerationConfig geminiGenConfig `json:"generationConfig"`
}

type geminiContent struct {
	Role  string       `json:"role,omitempty"`
	Parts []geminiPart `json:"parts"`
}

type geminiPart struct {
	Text string `json:"text"`
}

type geminiGenConfig struct {
	Temperature    float64               `json:"temperature"`
	ThinkingConfig *geminiThinkingConfig `json:"thinkingConfig,omitempty"`
}

type geminiThinkingConfig struct {
	ThinkingLevel string `json:"thinkingLevel"`
}

// --- response shapes ---

// geminiRespPart mirrors a candidate part. Reasoning parts are flagged with
// `thought` (and, on some API versions, metadata.isThinking); either marks a
// part we must not treat as output text.
type geminiRespPart struct {
	Text     string `json:"text"`
	Thought  bool   `json:"thought"`
	Metadata struct {
		IsThinking bool `json:"isThinking"`
	} `json:"metadata"`
}

type geminiResponse struct {
	Candidates []struct {
		Content struct {
			Parts []geminiRespPart `json:"parts"`
		} `json:"content"`
		FinishReason string `json:"finishReason"`
	} `json:"candidates"`
	PromptFeedback struct {
		BlockReason string `json:"blockReason"`
	} `json:"promptFeedback"`
	Error struct {
		Code    int    `json:"code"`
		Status  string `json:"status"`
		Message string `json:"message"`
	} `json:"error"`
}

// Cleanup sends the built prompt to Gemini and returns the model's text.
//
// The whole prompt goes in as a single user part rather than being split into
// systemInstruction + user content, so the bytes on the wire stay identical to
// what the Ollama backend sends. Prompt parity across backends is deliberate —
// see cleanup.BuildPrompt.
func (b *GeminiBackend) Cleanup(ctx context.Context, prompt string) (string, error) {
	reqBody := geminiRequest{
		Contents: []geminiContent{{
			Role:  "user",
			Parts: []geminiPart{{Text: prompt}},
		}},
		GenerationConfig: geminiGenConfig{Temperature: 0.0},
	}
	if b.ThinkingLevel != "" {
		reqBody.GenerationConfig.ThinkingConfig = &geminiThinkingConfig{
			ThinkingLevel: b.ThinkingLevel,
		}
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal gemini request: %w", err)
	}

	c, cancel := context.WithTimeout(ctx, b.Timeout)
	defer cancel()

	url := fmt.Sprintf("%s/models/%s:generateContent", strings.TrimRight(b.BaseURL, "/"), b.Model)
	req, err := http.NewRequestWithContext(c, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build gemini request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	// Header auth, not ?key= — keeps the credential out of URLs, and therefore
	// out of proxy logs and error strings.
	req.Header.Set("x-goog-api-key", b.APIKey)

	resp, err := b.Client.Do(req)
	if err != nil {
		return "", fmt.Errorf("gemini call: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Read a small amount for diagnostics; never log transcript content.
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("gemini returned %d: %s", resp.StatusCode, string(snippet))
	}

	var out geminiResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("decode gemini response: %w", err)
	}
	if out.Error.Code != 0 {
		return "", fmt.Errorf("gemini error %d (%s)", out.Error.Code, out.Error.Status)
	}
	// A safety block returns no candidates. Surface it as an error so the
	// caller soft-fails to the raw transcript rather than pasting nothing.
	if out.PromptFeedback.BlockReason != "" {
		return "", fmt.Errorf("gemini blocked the prompt: %s", out.PromptFeedback.BlockReason)
	}
	if len(out.Candidates) == 0 {
		return "", fmt.Errorf("gemini returned no candidates")
	}

	var sb strings.Builder
	for _, p := range out.Candidates[0].Content.Parts {
		if p.Thought || p.Metadata.IsThinking {
			continue // reasoning trace, not output
		}
		sb.WriteString(p.Text)
	}
	text := sb.String()
	if strings.TrimSpace(text) == "" {
		return "", fmt.Errorf("gemini returned empty text (finish reason %q)",
			out.Candidates[0].FinishReason)
	}
	return text, nil
}

// Name identifies the backend in logs and /ready.
func (b *GeminiBackend) Name() string { return "gemini" }

// Healthy probes the configured model's metadata endpoint. This is a plain GET
// that costs no generation quota, so /ready stays cheap enough to poll.
func (b *GeminiBackend) Healthy(ctx context.Context) bool {
	c, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	url := fmt.Sprintf("%s/models/%s", strings.TrimRight(b.BaseURL, "/"), b.Model)
	req, err := http.NewRequestWithContext(c, http.MethodGet, url, nil)
	if err != nil {
		return false
	}
	req.Header.Set("x-goog-api-key", b.APIKey)

	resp, err := b.Client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
