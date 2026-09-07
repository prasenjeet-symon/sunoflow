package backend

// Cloud speech-to-text backends for the warm-start dictation path (POST /stt).
//
// Two providers implement STTBackend:
//
//   - GroqSTTBackend  — a dedicated Whisper endpoint (OpenAI-compatible
//     /audio/transcriptions, multipart). Recommended: a purpose-built STT is
//     faster and cheaper per second of audio than a general audio-LLM, which is
//     what a short-lived warm-start path wants.
//   - GeminiSTTBackend — reuses the Gemini key/generateContent with the audio as
//     an inline_data part. No new credential; transcribes through the flash-lite
//     class used for cleanup.
//
// Both return a hard error on failure. There is no raw text to fall back to the
// way /cleanup has, so the caller (the sidecar) owns the fallback decision.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
	"time"
)

// transcribePrompt asks the model for the words and nothing else. The /cleanup
// pass does the tidying; STT must stay verbatim so cleanup has the real
// transcript to work from.
const transcribePrompt = "Transcribe the audio verbatim. Output only the exact words spoken, with no commentary, labels, speaker names, or timestamps. If there is no intelligible speech, output nothing."

// audioFilename maps a mime type to a filename with the extension Whisper-style
// endpoints use to detect the container. Defaults to .wav — the format the
// SunoFlow recorder produces (16kHz mono PCM).
func audioFilename(mime string) string {
	switch mime {
	case "audio/mpeg", "audio/mp3":
		return "audio.mp3"
	case "audio/mp4", "audio/m4a", "audio/x-m4a":
		return "audio.m4a"
	case "audio/ogg":
		return "audio.ogg"
	case "audio/flac", "audio/x-flac":
		return "audio.flac"
	case "audio/webm":
		return "audio.webm"
	default:
		return "audio.wav"
	}
}

// --- Groq (OpenAI-compatible Whisper) ---

// GroqSTTBackend transcribes via an OpenAI-compatible /audio/transcriptions
// endpoint (Groq hosts whisper-large-v3-turbo). The audio is uploaded as
// multipart/form-data; the response is JSON {"text": "..."}.
type GroqSTTBackend struct {
	APIKey   string        // never logged; injected from env
	Model    string        // e.g. whisper-large-v3-turbo
	BaseURL  string        // API root, e.g. https://api.groq.com/openai/v1
	Language string        // optional BCP-47 hint; empty = auto-detect
	Timeout  time.Duration // per-call timeout
	Client   *http.Client
}

// STTName identifies the provider.
func (b *GroqSTTBackend) STTName() string { return "groq" }

// Transcribe uploads the audio and returns the transcript text.
func (b *GroqSTTBackend) Transcribe(ctx context.Context, audio []byte, mime string) (string, error) {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)

	fw, err := mw.CreateFormFile("file", audioFilename(mime))
	if err != nil {
		return "", fmt.Errorf("build stt form: %w", err)
	}
	if _, err := fw.Write(audio); err != nil {
		return "", fmt.Errorf("write stt audio: %w", err)
	}
	// response_format=json returns {"text": ...}; verbose_json is heavier and we
	// need only the words. Temperature 0 keeps transcription deterministic.
	fields := map[string]string{
		"model":           b.Model,
		"response_format": "json",
		"temperature":     "0",
	}
	if b.Language != "" {
		fields["language"] = b.Language
	}
	for k, v := range fields {
		if err := mw.WriteField(k, v); err != nil {
			return "", fmt.Errorf("write stt field %s: %w", k, err)
		}
	}
	if err := mw.Close(); err != nil {
		return "", fmt.Errorf("close stt form: %w", err)
	}

	c, cancel := context.WithTimeout(ctx, b.Timeout)
	defer cancel()

	url := strings.TrimRight(b.BaseURL, "/") + "/audio/transcriptions"
	req, err := http.NewRequestWithContext(c, http.MethodPost, url, &buf)
	if err != nil {
		return "", fmt.Errorf("build stt request: %w", err)
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+b.APIKey)

	resp, err := b.Client.Do(req)
	if err != nil {
		return "", fmt.Errorf("stt call: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Read a small amount for diagnostics; never log the audio or transcript.
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("stt returned %d: %s", resp.StatusCode, string(snippet))
	}

	var out struct {
		Text  string `json:"text"`
		Error struct {
			Message string `json:"message"`
			Type    string `json:"type"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("decode stt response: %w", err)
	}
	if out.Error.Message != "" {
		return "", fmt.Errorf("stt error (%s): %s", out.Error.Type, out.Error.Message)
	}
	return strings.TrimSpace(out.Text), nil
}

// --- OpenRouter (OpenAI-compatible chat completions with inline audio) ---

// formatFromMime maps a content type to the short container name an OpenAI-style
// input_audio part expects ("wav"/"mp3"). Defaults to wav — the format the
// SunoFlow recorder produces.
func formatFromMime(mime string) string {
	switch mime {
	case "audio/mpeg", "audio/mp3":
		return "mp3"
	case "audio/ogg":
		return "ogg"
	case "audio/flac", "audio/x-flac":
		return "flac"
	case "audio/webm":
		return "webm"
	default:
		return "wav"
	}
}

// OpenRouterSTTBackend transcribes via OpenRouter's OpenAI-compatible
// /chat/completions endpoint, sending the audio as an `input_audio` content part
// to an audio-capable model and asking it to transcribe verbatim.
//
// OpenRouter has no dedicated /audio/transcriptions (Whisper) endpoint, so STT
// there is an audio-in chat model. The default model is Mistral's Voxtral, a
// purpose-built speech model — in head-to-head testing it was both the fastest
// and the most accurate of OpenRouter's audio models on hard proper nouns, which
// is what a warm-start path wants. This same request shape works for OpenAI's
// gpt-audio models and Google's Gemini via OpenRouter, so the model is swappable
// by config alone.
type OpenRouterSTTBackend struct {
	APIKey  string        // never logged; injected from env
	Model   string        // e.g. mistralai/voxtral-small-24b-2507
	BaseURL string        // API root, e.g. https://openrouter.ai/api/v1
	Timeout time.Duration // per-call timeout
	Client  *http.Client
}

// STTName identifies the provider.
func (b *OpenRouterSTTBackend) STTName() string { return "openrouter" }

// openRouterRequest is the subset of the OpenAI chat-completions body we send.
type openRouterRequest struct {
	Model       string  `json:"model"`
	Temperature float64 `json:"temperature"`
	// TopP is pinned to 1 alongside Temperature 0: some providers behind
	// OpenRouter (Voxtral) reject greedy sampling unless top_p is 1, and 1 is a
	// no-op for the others, so sending it keeps the request portable across models.
	TopP     float64             `json:"top_p"`
	Messages []openRouterMessage `json:"messages"`
}

type openRouterMessage struct {
	Role    string           `json:"role"`
	Content []openRouterPart `json:"content"`
}

// openRouterPart is a text part or an input_audio part.
type openRouterPart struct {
	Type       string           `json:"type"`
	Text       string           `json:"text,omitempty"`
	InputAudio *openRouterAudio `json:"input_audio,omitempty"`
}

type openRouterAudio struct {
	Data   string `json:"data"`   // base64
	Format string `json:"format"` // "wav" | "mp3" | …
}

// Transcribe returns the verbatim transcript of the audio.
func (b *OpenRouterSTTBackend) Transcribe(ctx context.Context, audio []byte, mime string) (string, error) {
	reqBody := openRouterRequest{
		Model:       b.Model,
		Temperature: 0,
		TopP:        1,
		Messages: []openRouterMessage{{
			Role: "user",
			Content: []openRouterPart{
				{Type: "text", Text: transcribePrompt},
				{Type: "input_audio", InputAudio: &openRouterAudio{
					Data:   base64.StdEncoding.EncodeToString(audio),
					Format: formatFromMime(mime),
				}},
			},
		}},
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal openrouter stt request: %w", err)
	}

	c, cancel := context.WithTimeout(ctx, b.Timeout)
	defer cancel()

	url := strings.TrimRight(b.BaseURL, "/") + "/chat/completions"
	req, err := http.NewRequestWithContext(c, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build openrouter stt request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+b.APIKey)
	// Optional attribution headers OpenRouter recommends; harmless if unused.
	req.Header.Set("X-Title", "SunoFlow")

	resp, err := b.Client.Do(req)
	if err != nil {
		return "", fmt.Errorf("openrouter stt call: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("openrouter stt returned %d: %s", resp.StatusCode, string(snippet))
	}

	var out struct {
		Choices []struct {
			Message struct {
				// Content is a string for these models, but OpenRouter can also
				// return an array of parts; decode into RawMessage and handle both.
				Content json.RawMessage `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Error struct {
			Message string `json:"message"`
			Code    any    `json:"code"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("decode openrouter stt response: %w", err)
	}
	if out.Error.Message != "" {
		return "", fmt.Errorf("openrouter stt error: %s", out.Error.Message)
	}
	if len(out.Choices) == 0 {
		return "", fmt.Errorf("openrouter stt returned no choices")
	}
	return strings.TrimSpace(parseORContent(out.Choices[0].Message.Content)), nil
}

// parseORContent extracts text from a message content that is either a JSON
// string or an array of {type:"text", text:"..."} parts.
func parseORContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &parts); err == nil {
		var sb strings.Builder
		for _, p := range parts {
			sb.WriteString(p.Text)
		}
		return sb.String()
	}
	return ""
}

// --- Gemini (generateContent with inline audio) ---

// GeminiSTTBackend transcribes by sending the audio to Gemini generateContent
// as an inline_data part alongside a verbatim-transcription prompt. It is a
// standalone object (its own client) rather than a method on GeminiBackend, so
// the cleanup backend stays single-purpose and STT can be swapped out wholesale.
type GeminiSTTBackend struct {
	APIKey        string        // never logged; injected from env
	Model         string        // e.g. gemini-3.5-flash-lite
	BaseURL       string        // API root, e.g. https://generativelanguage.googleapis.com/v1beta
	ThinkingLevel string        // "minimal".."high"; empty omits thinkingConfig
	Timeout       time.Duration // per-call timeout
	Client        *http.Client
}

// STTName identifies the provider.
func (b *GeminiSTTBackend) STTName() string { return "gemini" }

// Transcribe returns the verbatim transcript of the audio.
func (b *GeminiSTTBackend) Transcribe(ctx context.Context, audio []byte, mime string) (string, error) {
	if mime == "" {
		mime = "audio/wav"
	}
	reqBody := geminiRequest{
		Contents: []geminiContent{{
			Role: "user",
			Parts: []geminiPart{
				{InlineData: &geminiInline{MimeType: mime, Data: base64.StdEncoding.EncodeToString(audio)}},
				{Text: transcribePrompt},
			},
		}},
		GenerationConfig: geminiGenConfig{Temperature: 0.0},
	}
	if b.ThinkingLevel != "" {
		reqBody.GenerationConfig.ThinkingConfig = &geminiThinkingConfig{ThinkingLevel: b.ThinkingLevel}
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("marshal gemini stt request: %w", err)
	}

	c, cancel := context.WithTimeout(ctx, b.Timeout)
	defer cancel()

	url := fmt.Sprintf("%s/models/%s:generateContent", strings.TrimRight(b.BaseURL, "/"), b.Model)
	req, err := http.NewRequestWithContext(c, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build gemini stt request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-goog-api-key", b.APIKey)

	resp, err := b.Client.Do(req)
	if err != nil {
		return "", fmt.Errorf("gemini stt call: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return "", fmt.Errorf("gemini stt returned %d: %s", resp.StatusCode, string(snippet))
	}

	var out geminiResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return "", fmt.Errorf("decode gemini stt response: %w", err)
	}
	if out.Error.Code != 0 {
		return "", fmt.Errorf("gemini stt error %d (%s)", out.Error.Code, out.Error.Status)
	}
	if out.PromptFeedback.BlockReason != "" {
		return "", fmt.Errorf("gemini blocked the audio: %s", out.PromptFeedback.BlockReason)
	}
	if len(out.Candidates) == 0 {
		return "", fmt.Errorf("gemini stt returned no candidates")
	}
	var sb strings.Builder
	for _, p := range out.Candidates[0].Content.Parts {
		if p.Thought || p.Metadata.IsThinking {
			continue // reasoning trace, not output
		}
		sb.WriteString(p.Text)
	}
	// Empty is a legitimate transcript for silence (the prompt says "output
	// nothing"), so it is not an error the way an empty cleanup would be.
	return strings.TrimSpace(sb.String()), nil
}
