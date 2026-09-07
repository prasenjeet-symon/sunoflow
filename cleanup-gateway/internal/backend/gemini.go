package backend

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

// GeminiBackend calls Google's Gemini API (generativelanguage.googleapis.com)
// via generateContent. It is the gateway's only LLM backend.
//
// Why a flash-lite class model with thinking pinned to its floor: transcript
// tidying is mechanical, so any chain-of-thought the model emits before
// answering is pure latency on the dictation path. Reasoning-heavy models were
// measured at 6-24s per cleanup against roughly 1s here for the same output.
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

	// --- Suno Answer (separate seam, D6) ---
	// AnswerModel is the model answer requests go to (RESEARCH_MODEL). Empty
	// falls back to Model, so a deployment that never sets it still works.
	// Grounded answers are a different workload than tidying; the env split
	// keeps the two independently tunable.
	AnswerModel string
	// AnswerMediaResolution is the Gemini 3 media-resolution bucket for the
	// answer screenshot (ANSWER_MEDIA_RESOLUTION), e.g. MEDIA_RESOLUTION_MEDIUM.
	// It fixes the per-image token cost (medium≈560 vs the unset default of
	// high≈1120), so it is the real image-token lever now that the screenshot
	// rides every turn. Empty leaves it to the model default (high).
	AnswerMediaResolution string
	// AnswerTimeout is the total stream deadline for one answer request.
	// Zero falls back to Timeout.
	AnswerTimeout time.Duration

	// answerClient wraps b.Client's transport (built once) for the streaming
	// answer path — see answerHTTPClient.
	answerClientOnce sync.Once
	answerClient     *http.Client
}

// answerHTTPClient is the client the streaming answer path uses. It shares
// b.Client's transport (the same connection pool cleanup uses), so cleanup's
// frequent traffic keeps the provider's warm TLS/H2 connections available for
// the infrequent, paid answer stream — instead of the stream re-handshaking on
// its own private pool. Only the wrapper differs: no overall Timeout, because a
// healthy 90s stream must not be killed; the per-request context is the clock.
func (b *GeminiBackend) answerHTTPClient() *http.Client {
	b.answerClientOnce.Do(func() {
		var transport http.RoundTripper = http.DefaultTransport
		if b.Client != nil && b.Client.Transport != nil {
			transport = b.Client.Transport
		}
		b.answerClient = &http.Client{Transport: transport}
	})
	return b.answerClient
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

// geminiPart is either a text part or an inline (base64) data part — the image
// rides as its own part next to the prompt text.
type geminiPart struct {
	Text       string        `json:"text,omitempty"`
	InlineData *geminiInline `json:"inline_data,omitempty"`
}

type geminiInline struct {
	MimeType string `json:"mime_type"`
	Data     string `json:"data"` // base64
}

type geminiGenConfig struct {
	Temperature float64 `json:"temperature"`
	// MediaResolution caps the tokens Gemini 3 spends per input image
	// (MEDIA_RESOLUTION_LOW≈280 / MEDIUM≈560 / HIGH≈1120 / ULTRA_HIGH≈2240).
	// On Gemini 3 the per-image token cost is set by this bucket, NOT by the
	// pixel dimensions the client uploads, and it defaults to HIGH (1120) when
	// unset — so this is the only lever that actually trims image tokens.
	// Omitted (empty) for cleanup, which sends no media.
	MediaResolution string                `json:"mediaResolution,omitempty"`
	ThinkingConfig  *geminiThinkingConfig `json:"thinkingConfig,omitempty"`
}

type geminiThinkingConfig struct {
	ThinkingLevel string `json:"thinkingLevel"`
}

// geminiTool requests Google Search grounding for an answer turn (C6).
type geminiTool struct {
	GoogleSearch struct{} `json:"googleSearch"`
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

// geminiGroundingChunk is one source the grounding tool used. Domain, when
// present, is the bare host; URI is the full page the chunk came from.
type geminiGroundingChunk struct {
	Web struct {
		URI    string `json:"uri"`
		Domain string `json:"domain"`
	} `json:"web"`
}

type geminiGroundingMetadata struct {
	GroundingChunks  []geminiGroundingChunk `json:"groundingChunks"`
	WebSearchQueries []string               `json:"webSearchQueries"`
}

// geminiStreamResponse is one SSE `data:` payload from
// :streamGenerateContent?alt=sse — the same shape as geminiResponse, but one
// chunk of the answer, with grounding metadata attached to the candidate.
type geminiStreamResponse struct {
	Candidates []struct {
		Content struct {
			Parts []geminiRespPart `json:"parts"`
		} `json:"content"`
		FinishReason      string                   `json:"finishReason"`
		GroundingMetadata *geminiGroundingMetadata `json:"groundingMetadata"`
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
// systemInstruction + user content, so the bytes on the wire are exactly what
// cleanup.BuildPrompt produced. Keeping the prompt provider-agnostic is
// deliberate: a future backend can be swapped in without re-tuning it.
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

// --- Suno Answer streaming (D6 seam) ---

// StreamAnswer implements AnswerBackend. It POSTs to
// :streamGenerateContent?alt=sse and returns a channel of text chunks plus,
// once near the end, the grounding metadata the final chunks carry.
//
// The decode loop runs on its own goroutine and closes the channel when the
// stream ends. ctx (carrying the answer deadline) is handed to the request, so
// a caller that gives up — a client disconnect, or the 90s ceiling — also
// cancels the upstream request.
//
// Why a separate client: b.Client carries an overall Timeout sized for
// single-shot cleanups (25s). A client-level timeout kills a healthy 90s
// stream, so answer requests use a client without one; the per-request context
// deadline below is the only clock. The transport is shared, so warm TLS
// connections to the provider are reused across both paths.
func (b *GeminiBackend) StreamAnswer(ctx context.Context, prompt string, imageJPEG []byte) (<-chan AnswerChunk, error) {
	timeout := b.AnswerTimeout
	if timeout <= 0 {
		timeout = b.Timeout
	}
	c, cancel := context.WithTimeout(ctx, timeout)

	req, err := b.buildAnswerRequest(prompt, imageJPEG, c)
	if err != nil {
		cancel()
		return nil, err
	}

	resp, err := b.answerHTTPClient().Do(req)
	if err != nil {
		cancel()
		return nil, classifyHTTPError(err)
	}
	if resp.StatusCode != http.StatusOK {
		// Read a small amount for diagnostics; never log prompt or screen.
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		resp.Body.Close()
		cancel()
		return nil, classifyHTTPError(fmt.Errorf("gemini returned %d: %s", resp.StatusCode, string(snippet)))
	}

	out := make(chan AnswerChunk, 64)
	go func() {
		defer cancel()
		defer resp.Body.Close()
		defer close(out)
		streamAnswerChunks(c, resp.Body, out)
	}()
	return out, nil
}

// streamAnswerChunks decodes the SSE body, emitting text and source chunks on
// out. Every send is ctx-aware: once the caller stops reading (its ctx
// cancelled), the loop returns instead of blocking forever on a full channel.
//
// Tolerant by design: a malformed chunk is skipped, not fatal — one bad SSE
// line must not end an answer the user is watching render.
func streamAnswerChunks(ctx context.Context, body io.Reader, out chan<- AnswerChunk) {
	sc := bufio.NewScanner(body)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var sawText bool
	for sc.Scan() {
		if ctx.Err() != nil {
			return // caller gave up; no terminal event needed
		}
		line := sc.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := strings.TrimPrefix(line, "data: ")
		if payload == "" {
			continue
		}
		var ev geminiStreamResponse
		if err := json.Unmarshal([]byte(payload), &ev); err != nil {
			continue
		}
		if ev.Error.Code != 0 {
			sendChunk(ctx, out, AnswerChunk{Err: fmt.Errorf("gemini error %d (%s)", ev.Error.Code, ev.Error.Status)})
			return
		}
		if ev.PromptFeedback.BlockReason != "" {
			sendChunk(ctx, out, AnswerChunk{Err: fmt.Errorf("gemini blocked the prompt: %s", ev.PromptFeedback.BlockReason)})
			return
		}
		if len(ev.Candidates) == 0 {
			continue
		}
		cand := ev.Candidates[0]

		// Grounding metadata rides its own chunk(s), usually near the end.
		if gm := cand.GroundingMetadata; gm != nil {
			domains := dedupeDomains(gm.GroundingChunks)
			queries := len(gm.WebSearchQueries)
			if len(domains) > 0 || queries > 0 {
				sendChunk(ctx, out, AnswerChunk{Domains: domains, SearchQueries: queries})
			}
		}

		for _, p := range cand.Content.Parts {
			if p.Thought || p.Metadata.IsThinking {
				continue // reasoning trace, not output
			}
			if p.Text == "" {
				continue
			}
			sawText = true
			if !sendChunk(ctx, out, AnswerChunk{Text: p.Text}) {
				return
			}
		}

		if cand.FinishReason != "" && cand.FinishReason != "FINISH_REASON_UNSPECIFIED" {
			// Terminal chunk. A finish with no text at all (safety block, empty
			// completion) is an error; anything else just ends the stream.
			if !sawText {
				sendChunk(ctx, out, AnswerChunk{Err: fmt.Errorf("gemini returned no text (finish reason %q)", cand.FinishReason)})
			}
			return
		}
	}
	if err := sc.Err(); err != nil {
		sendChunk(ctx, out, AnswerChunk{Err: fmt.Errorf("read gemini stream: %w", err)})
		return
	}
	// Body ended without a finish reason (provider closed early).
	if !sawText {
		sendChunk(ctx, out, AnswerChunk{Err: fmt.Errorf("gemini returned no text (stream ended)")})
	}
}

// sendChunk delivers one chunk unless the consumer has gone away. Reports
// whether the consumer is still listening.
func sendChunk(ctx context.Context, out chan<- AnswerChunk, c AnswerChunk) bool {
	select {
	case out <- c:
		return true
	case <-ctx.Done():
		return false
	}
}

// buildAnswerRequest assembles the :streamGenerateContent request. The single
// user content carries the framed prompt text and, when present, the
// screenshot as a preceding inline part.
func (b *GeminiBackend) buildAnswerRequest(prompt string, imageJPEG []byte, ctx context.Context) (*http.Request, error) {
	reqBody := b.answerRequestBody(prompt, imageJPEG)

	body, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("marshal gemini answer request: %w", err)
	}

	url := fmt.Sprintf("%s/models/%s:streamGenerateContent?alt=sse",
		strings.TrimRight(b.BaseURL, "/"), b.answerModel())
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build gemini answer request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-goog-api-key", b.APIKey)
	return req, nil
}

// answerRequest extends the cleanup request shape with the grounding tool.
type answerRequest struct {
	Contents         []geminiContent `json:"contents"`
	GenerationConfig geminiGenConfig `json:"generationConfig"`
	Tools            []geminiTool    `json:"tools"`
}

// answerRequestBody assembles the :streamGenerateContent request body. The
// single user content carries the framed prompt text plus, when present, the
// screenshot as an inline_data part before it. ThinkingConfig reuses the
// cleanup pin: grounded answers are still conversational, and long reasoning
// is pure TTFB on a stream the user is staring at.
func (b *GeminiBackend) answerRequestBody(prompt string, imageJPEG []byte) answerRequest {
	content := geminiContent{Role: "user"}
	if len(imageJPEG) > 0 {
		content.Parts = append(content.Parts, geminiPart{
			InlineData: &geminiInline{
				MimeType: "image/jpeg",
				Data:     base64.StdEncoding.EncodeToString(imageJPEG),
			},
		})
	}
	content.Parts = append(content.Parts, geminiPart{Text: prompt})

	genConfig := geminiGenConfig{Temperature: 0.0}
	// The media-resolution bucket only matters when an image rides — it caps
	// the image's token cost. Setting it text-only is harmless but pointless.
	if len(imageJPEG) > 0 && b.AnswerMediaResolution != "" {
		genConfig.MediaResolution = b.AnswerMediaResolution
	}

	reqBody := answerRequest{
		Contents:         []geminiContent{content},
		GenerationConfig: genConfig,
		// Google Search grounding (C6): sources must ride the stream, so the
		// tool is always on for answers.
		Tools: []geminiTool{{}},
	}
	if b.ThinkingLevel != "" {
		reqBody.GenerationConfig.ThinkingConfig = &geminiThinkingConfig{
			ThinkingLevel: b.ThinkingLevel,
		}
	}
	return reqBody
}

// answerModel resolves which model answer requests use (RESEARCH_MODEL; falls
// back to the cleanup model when unset).
func (b *GeminiBackend) answerModel() string {
	if b.AnswerModel != "" {
		return b.AnswerModel
	}
	return b.Model
}
