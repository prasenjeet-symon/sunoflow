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

// AnswerChunk is one piece of a streamed answer.
type AnswerChunk struct {
	// Text is the next fragment of the user-visible answer. Empty when the
	// chunk carries only metadata.
	Text string
	// Sources, populated at most once per stream, usually on the final chunks:
	// the domains grounding used and how many web searches the model ran.
	Domains []string
	// SearchQueries counts the web searches the model ran for this answer.
	SearchQueries int
	// Err, on the final value before the channel closes, ends the stream with
	// an error after some text may already have been emitted.
	Err error
	// BlockReason reports the provider's prompt-level safety block (Gemini's
	// PromptFeedback.BlockReason). Set on its own chunk, without Text or Err,
	// so the handler can surface a distinct "blocked" outcome in analytics
	// instead of folding it into a generic error.
	BlockReason string
	// Usage reports the provider's token accounting for the call. It rides a
	// chunk near the end of the stream (Gemini attaches usageMetadata to the
	// final candidate chunk); zero fields mean the provider did not report a
	// count. Kept per-request so Suno Answer cost is measured, not estimated.
	Usage Usage
}

// AnswerBackend is the optional streaming seam for Suno Answer (D6). Backends
// that cannot stream simply don't implement it; the answer route is wired only
// when a backend supports it, so cleanup's Backend stays untouched.
type AnswerBackend interface {
	// StreamAnswer streams a grounded answer for the given prompt. promptText
	// is the text half (joined prompt lines); imageJPEG is the turn-1
	// screenshot as JPEG bytes, or nil.
	//
	// The returned channel yields chunks until the stream ends; the channel is
	// then closed. An error mid-stream is signalled by closing the channel —
	// the last value before close carries Err set. ctx governs the whole
	// stream: the caller's deadline (or a client disconnect, if propagated)
	// must abort the upstream request.
	StreamAnswer(ctx context.Context, prompt string, imageJPEG []byte) (<-chan AnswerChunk, error)
}

// ControlBackend is the optional one-shot computer-control seam (Suno
// Control). Backends that cannot plan actions simply don't implement it; the
// /control route is wired only when a backend supports it, so cleanup's
// Backend stays untouched.
type ControlBackend interface {
	// PlanAction sends the built control prompt (plus the current screen
	// image, which may be nil) and returns the model's raw text — one JSON
	// object choosing the next action — together with the call's token usage.
	// One-shot, like Cleanup, with an image: the loop is a series of these
	// calls, each a fresh decision from the screen as it is now.
	PlanAction(ctx context.Context, prompt string, imageJPEG []byte) (string, Usage, error)
}

// Usage is the token accounting for one backend call, lifted from the
// provider's usage metadata. A zero field means the provider did not report
// that count (so it is safe to record even when usage is unavailable). Thinking
// tokens are billed as output but reported separately, so they are kept
// separate here for per-step cost visibility.
type Usage struct {
	PromptTokens   int // input tokens (prompt text + image)
	OutputTokens   int // visible answer tokens (candidates)
	ThinkingTokens int // reasoning tokens (billed as output)
	TotalTokens    int // provider's total for the call
}

// STTBackend is the optional cloud speech-to-text seam (the warm-start
// dictation path). It is a distinct provider from the cleanup Backend — the
// gateway may transcribe on Whisper while it cleans up on Gemini — so it is its
// own interface injected as its own field, rather than a method bolted onto
// Backend. When no STT backend is configured the /stt route answers 501.
type STTBackend interface {
	// Transcribe returns the verbatim transcript of the given audio. audio is
	// the raw encoded file bytes (e.g. a 16kHz mono WAV); mime is its content
	// type ("audio/wav"). It returns a hard error on failure — unlike cleanup
	// there is no raw text to fall back to, so the caller (the sidecar) decides
	// whether to retry, wait for the local model, or surface nothing.
	Transcribe(ctx context.Context, audio []byte, mime string) (string, error)
	// STTName identifies the provider for logging and analytics ("groq"/"gemini").
	STTName() string
}

// TryonBackend is the optional one-shot image seam for Suno Try-on. Like the
// control and STT seams, it is its own interface: the /tryon route is wired
// only when a backend supports it, so a backend without image generation keeps
// cleanup, answer and control untouched.
type TryonBackend interface {
	// TryOn composes a virtual try-on image. prompt is the built prompt text
	// (framing + item + request, from the tryon package); personJPEG is the
	// user's stored photo (always JPEG) and garmentJPEG the garment screenshot
	// from the current screen. The returned bytes are the composed image
	// (mimeType reports its actual encoding — providers emit PNG). It returns
	// a hard error on failure; there is no degraded mode for a photo, so the
	// caller surfaces the error rather than falling back.
	TryOn(ctx context.Context, prompt string, personJPEG, garmentJPEG []byte) (image []byte, mimeType string, usage Usage, err error)
	// TryonName identifies the provider for logging and analytics.
	TryonName() string
}
