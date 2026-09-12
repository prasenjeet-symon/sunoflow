package backend

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
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

	// --- Suno Control (separate seam) ---
	// ControlModel is the model control requests go to (CONTROL_MODEL). Empty
	// falls back to Model, so a deployment that never sets it still works.
	// Choosing the next action is vision + judgement; same flash-lite class,
	// independently tunable.
	ControlModel string
	// ControlMediaResolution is the Gemini 3 media-resolution bucket for the
	// control screenshot (CONTROL_MEDIA_RESOLUTION). Same lever as the answer
	// one; empty leaves it to the model default (high).
	ControlMediaResolution string
	// ControlTimeout is the total deadline for one plan call. Zero falls back
	// to Timeout.
	ControlTimeout time.Duration
	// ControlUseTool switches PlanAction to Gemini's native computer_use tool:
	// the request declares the tool and the reply is a function_call action
	// (0-999 coords), which PlanAction maps into the same flat action JSON the
	// JSON-prompt path returns — so the gateway handler and the client are
	// unchanged. Default false (the free-form JSON-prompt path).
	ControlUseTool bool
	// ControlEnvironment is the computer_use environment when ControlUseTool is
	// on: ENVIRONMENT_DESKTOP (default), ENVIRONMENT_BROWSER or _MOBILE.
	ControlEnvironment string
	// ControlAutoProceedGuarded carries CONTROL_AUTOPROCEED_GUARDED into the
	// action mapping: when true, a require_confirmation safety_decision on a
	// guarded action (send/purchase/delete/sign-in) is performed rather than
	// refused — the spoken goal authorized it. Other decisions (a hard block, a
	// prompt-injection flag) still stop, and injection detection stays on.
	ControlAutoProceedGuarded bool
	// ControlThinkingLevel overrides ThinkingLevel for PlanAction only
	// (CONTROL_THINKING_LEVEL): control is a different workload from cleanup,
	// and in JSON-prompt mode (ControlUseTool=false) reasoning IS the dominant
	// per-call cost, so the planner can want a different floor than dictation.
	// Empty falls back to ThinkingLevel.
	ControlThinkingLevel string

	// --- Suno Try-on (separate seam) ---
	// TryonModel is the image model try-on requests go to (TRYON_MODEL; the
	// Nano Banana 2 preview, gemini-3.1-flash-image-preview). Unlike the other
	// seams there is NO fallback to Model: the cleanup model cannot emit
	// images, so a deployment that wants try-on must set the field
	// explicitly. Empty disables the /tryon route (the handler 501s).
	TryonModel string
	// TryonTimeout is the total deadline for one try-on call (TRYON_TIMEOUT).
	// Zero falls back to Timeout.
	TryonTimeout time.Duration
	// TryonImageSize is the imageConfig.imageSize bucket the request asks the
	// model for (TRYON_IMAGE_SIZE: "512"|"1K"|"2K"|"4K"). Empty omits it.
	TryonImageSize string
	// TryonAspectRatio is the imageConfig.aspectRatio (TRYON_ASPECT_RATIO,
	// e.g. "3:4" — a portrait that suits a person photo). Empty omits it.
	TryonAspectRatio string

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
	Contents         []geminiContent  `json:"contents"`
	GenerationConfig geminiGenConfig  `json:"generationConfig"`
	Tools            []geminiToolDecl `json:"tools,omitempty"`
	// SafetySettings relax Gemini's default block thresholds for the control
	// planner. Legitimate desktop automation reads to the filter like social
	// messaging/purchasing automation (seen live 2026-09-08: an Instagram goal
	// blocked step 0, PromptFeedback.BlockReason SAFETY), and defaults apply
	// whenever the request carries no safetySettings. BLOCK_ONLY_HIGH keeps the
	// true hard blocks while letting ordinary automation through.
	SafetySettings []geminiSafetySetting `json:"safetySettings,omitempty"`
}

// geminiSafetySetting sets the block threshold for one harm category. Threshold
// strings are the API's enum literals (BLOCK_NONE is allowed only for approved
// accounts, so BLOCK_ONLY_HIGH is the loosest we can ask for).
type geminiSafetySetting struct {
	Category  string `json:"category"`
	Threshold string `json:"threshold"`
}

// controlSafetySettings is the safetySettings block PlanAction attaches — all
// four categories at BLOCK_ONLY_HIGH. Cleanup keeps Gemini's defaults: its
// prompts are the user's own dictation, which the filter does not object to.
var controlSafetySettings = []geminiSafetySetting{
	{Category: "HARM_CATEGORY_HARASSMENT", Threshold: "BLOCK_ONLY_HIGH"},
	{Category: "HARM_CATEGORY_HATE_SPEECH", Threshold: "BLOCK_ONLY_HIGH"},
	{Category: "HARM_CATEGORY_SEXUALLY_EXPLICIT", Threshold: "BLOCK_ONLY_HIGH"},
	{Category: "HARM_CATEGORY_DANGEROUS_CONTENT", Threshold: "BLOCK_ONLY_HIGH"},
}

// geminiToolDecl is a built-in tool declaration on a generateContent request.
// Only the computer_use seam is modeled here; nil fields are omitted, so an
// empty declaration is never sent.
type geminiToolDecl struct {
	ComputerUse *geminiComputerUse `json:"computer_use,omitempty"`
}

// geminiComputerUse configures the native computer-use tool (Suno Control tool
// mode). Environment scopes the action space (ENVIRONMENT_DESKTOP for the Mac);
// prompt-injection detection is Google's own guard on top of our framing.
type geminiComputerUse struct {
	Environment                    string `json:"environment"`
	EnablePromptInjectionDetection bool   `json:"enable_prompt_injection_detection,omitempty"`
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
	// FunctionCall is present on a part when the model invoked a tool — the
	// computer_use tool answers here (Suno Control tool mode) rather than in
	// Text. Nil on ordinary text/reasoning parts.
	FunctionCall *geminiFunctionCall `json:"functionCall,omitempty"`
	// InlineData carries a generated image (Suno Try-on): the image models
	// answer with an inlineData part next to any caption text. Nil on
	// text/thinking parts. NOTE: camelCase, unlike the request-side
	// geminiInline (mime_type/data) — the RESPONSE is plain JSON the gateway
	// itself unmarshals, so only the exact wire spelling parses; the request
	// side tolerates snake_case only because protobuf JSON accepts both.
	InlineData *geminiRespInline `json:"inlineData,omitempty"`
}

// geminiRespInline is one inline (base64) data part in a RESPONSE. Tags are
// camelCase — see the note on geminiRespPart.InlineData.
type geminiRespInline struct {
	MimeType string `json:"mimeType"`
	Data     string `json:"data"` // base64
}

// geminiFunctionCall is one tool invocation. Args stays raw so the caller
// decodes only the fields the specific action carries.
type geminiFunctionCall struct {
	Name string          `json:"name"`
	Args json.RawMessage `json:"args"`
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
	// UsageMetadata is the token accounting for the call. thoughtsTokenCount is
	// the reasoning (thinking) tokens, reported apart from candidatesTokenCount
	// (the visible answer); both bill at the output rate. Absent on some error
	// responses, so callers treat zero as "unreported".
	UsageMetadata struct {
		PromptTokenCount     int `json:"promptTokenCount"`
		CandidatesTokenCount int `json:"candidatesTokenCount"`
		ThoughtsTokenCount   int `json:"thoughtsTokenCount"`
		TotalTokenCount      int `json:"totalTokenCount"`
	} `json:"usageMetadata"`
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
	// UsageMetadata is the token accounting for the call, attached to the final
	// candidate chunk. Same shape as geminiResponse's so usageFromResponse maps
	// it onto the backend Usage shape for analytics.
	UsageMetadata struct {
		PromptTokenCount     int `json:"promptTokenCount"`
		CandidatesTokenCount int `json:"candidatesTokenCount"`
		ThoughtsTokenCount   int `json:"thoughtsTokenCount"`
		TotalTokenCount      int `json:"totalTokenCount"`
	} `json:"usageMetadata"`
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

	return b.callOneShot(ctx, body, b.Model, b.Timeout)
}

// PlanAction implements backend.ControlBackend (Suno Control): the one-shot
// call with the screen image riding as its own inline part before the prompt
// text — the same image-first order the answer path uses, which is what Gemini
// expects for interleaved text-and-image contents.
func (b *GeminiBackend) PlanAction(ctx context.Context, prompt string, imageJPEG []byte) (string, Usage, error) {
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

	reqBody := geminiRequest{
		Contents:         []geminiContent{content},
		GenerationConfig: geminiGenConfig{Temperature: 0.0},
	}
	// The media-resolution bucket only matters when an image rides — it caps
	// the image's token cost (same lever as the answer screenshot).
	if len(imageJPEG) > 0 && b.ControlMediaResolution != "" {
		reqBody.GenerationConfig.MediaResolution = b.ControlMediaResolution
	}
	// planningThinking resolves the thinking level one PlanAction call should
	// send: the control-specific override (ControlThinkingLevel) when set,
	// falling back to the shared cleanup level (ThinkingLevel).
	planningThinking := b.ControlThinkingLevel
	if planningThinking == "" {
		planningThinking = b.ThinkingLevel
	}
	if planningThinking != "" {
		reqBody.GenerationConfig.ThinkingConfig = &geminiThinkingConfig{
			ThinkingLevel: planningThinking,
		}
	}
	// Tool mode: declare the native computer_use tool. The model then answers
	// with a function_call action (0-999 coords) instead of our JSON schema,
	// and PlanAction maps that back to the same flat action JSON below.
	if b.ControlUseTool {
		env := b.ControlEnvironment
		if env == "" {
			env = "ENVIRONMENT_DESKTOP"
		}
		reqBody.Tools = []geminiToolDecl{{ComputerUse: &geminiComputerUse{
			Environment:                    env,
			EnablePromptInjectionDetection: true,
		}}}
	}
	// Control-only safety thresholds: ordinary desktop automation reads to
	// Gemini's default filter like social/purchasing automation and gets
	// blocked step 0 (live 2026-09-08, Instagram goal). BLOCK_ONLY_HIGH keeps
	// hard blocks blocked — both attempts — while letting normal goals run.
	reqBody.SafetySettings = controlSafetySettings

	body, err := json.Marshal(reqBody)
	if err != nil {
		return "", Usage{}, fmt.Errorf("marshal gemini request: %w", err)
	}

	timeout := b.Timeout
	if b.ControlTimeout > 0 {
		timeout = b.ControlTimeout
	}

	// Both paths read the raw response so the call's token usage travels back to
	// the handler (control analytics) alongside the action.
	//
	// The prompt-level safety filter is nondeterministic on image+text requests
	// (the same goal passed at one screenshot and blocked at another on
	// 2026-09-08), and a block fails fast — the model never generates. So one
	// immediate retry is cheap and usually clears a marginal block, while
	// BLOCK_ONLY_HIGH keeps genuine hard blocks blocked on both attempts.
	// Deliberately NOT a general network retry: this is the planner path, and a
	// retried step could double-execute on a changed screen — the retry fires
	// only on ErrSafetyBlock, where nothing was produced to execute.
	started := time.Now()
	out, err := b.callOneShotRaw(ctx, body, b.controlModel(), timeout)
	if errors.Is(err, ErrSafetyBlock) {
		if remain := timeout - time.Since(started); remain > 2*time.Second {
			out, err = b.callOneShotRaw(ctx, body, b.controlModel(), remain)
		}
	}
	if err != nil {
		return "", Usage{}, err
	}
	if b.ControlUseTool {
		js, err := actionJSONFromResponse(out, b.ControlAutoProceedGuarded)
		return js, usageFromResponse(out), err
	}
	text, err := textFromResponse(out)
	return text, usageFromResponse(out), err
}

// computerUseArgs decodes the args of a computer_use function_call. Fields are
// pointers/slices so an absent one is distinguishable from a zero value; both
// the Gemini 3.x names and the 2.5-era fallbacks (magnitude) are accepted.
type computerUseArgs struct {
	X               *int                  `json:"x"`
	Y               *int                  `json:"y"`
	StartX          *int                  `json:"start_x"`
	StartY          *int                  `json:"start_y"`
	EndX            *int                  `json:"end_x"`
	EndY            *int                  `json:"end_y"`
	Text            *string               `json:"text"`
	PressEnter      *bool                 `json:"press_enter"`
	Key             *string               `json:"key"`
	Keys            []string              `json:"keys"`
	Direction       *string               `json:"direction"`
	MagnitudePixels *int                  `json:"magnitude_in_pixels"`
	Magnitude       *int                  `json:"magnitude"` // 2.5-era name
	Seconds         *float64              `json:"seconds"`
	Intent          string                `json:"intent"`
	SafetyDecision  *geminiSafetyDecision `json:"safety_decision"`
}

// geminiSafetyDecision is the tool's guard on a risky action: when present with
// a decision other than "allow", the model wants human confirmation before the
// step runs.
type geminiSafetyDecision struct {
	Decision    string `json:"decision"`
	Explanation string `json:"explanation"`
}

// actionJSONFromResponse turns a computer_use reply into the flat action JSON
// the gateway already parses. The first function_call is the action; when the
// model returns no function_call it has nothing left to do, which is the tool's
// termination signal — mapped to "done" with any trailing text as the note.
func actionJSONFromResponse(out *geminiResponse, autoProceedGuarded bool) (string, error) {
	var fc *geminiFunctionCall
	var textSB strings.Builder
	for i := range out.Candidates[0].Content.Parts {
		p := out.Candidates[0].Content.Parts[i]
		if p.FunctionCall != nil {
			if fc == nil {
				fc = p.FunctionCall
			}
			continue
		}
		if p.Thought || p.Metadata.IsThinking {
			continue
		}
		textSB.WriteString(p.Text)
	}

	var action map[string]any
	if fc != nil {
		var args computerUseArgs
		if len(fc.Args) > 0 {
			if err := json.Unmarshal(fc.Args, &args); err != nil {
				return "", fmt.Errorf("decode computer_use args: %w", err)
			}
		}
		action = mapComputerUseCall(fc.Name, args, autoProceedGuarded)
	} else {
		note := strings.TrimSpace(textSB.String())
		if note == "" {
			note = "Done."
		}
		action = map[string]any{"action": "done", "note": note}
	}

	buf, err := json.Marshal(action)
	if err != nil {
		return "", fmt.Errorf("marshal mapped action: %w", err)
	}
	return string(buf), nil
}

// hotkeyModifiers maps computer_use modifier-key names onto the executor's four
// modifiers. The non-modifier key in a hotkey combination becomes the key.
// The _l/_r entries are the X11 keysym names the computer_use protocol itself
// speaks — the model emits "super_l" for the left Super/Command key. Without
// them a hotkey like ["super_l","space"] loses its modifier entirely: the
// keysym falls through as the key and "space" overwrites it, degrading ⌘Space
// to a bare Space press (seen live 2026-09-08: three wasted Spotlight steps,
// then a lone "super_l" the executor refused, killing the run).
var hotkeyModifiers = map[string]string{
	"cmd": "command", "command": "command", "meta": "command", "super": "command", "win": "command",
	"cmd_l": "command", "cmd_r": "command",
	"super_l": "command", "super_r": "command",
	"meta_l": "command", "meta_r": "command",
	"win_l": "command", "win_r": "command",
	"ctrl": "control", "control": "control",
	"ctrl_l": "control", "ctrl_r": "control",
	"alt": "option", "opt": "option", "option": "option",
	"alt_l": "option", "alt_r": "option",
	"shift":   "shift",
	"shift_l": "shift", "shift_r": "shift",
}

// keyNameAliases maps the X11 keysym names the computer_use protocol speaks
// onto the executor's key names. Unlisted names pass through unchanged — the
// executor's own key table then decides, and an unknown one is refused
// honestly downstream.
var keyNameAliases = map[string]string{
	"esc":        "escape",
	"back_space": "delete",
	"backspace":  "delete",
	"spacebar":   "space",
	"pgup":       "pageup",
	"page_up":    "pageup",
	"pgdn":       "pagedown",
	"page_down":  "pagedown",
	"arrowup":    "up",
	"arrowdown":  "down",
	"arrowleft":  "left",
	"arrowright": "right",
	"uparrow":    "up",
	"downarrow":  "down",
	"leftarrow":  "left",
	"rightarrow": "right",
}

// modifierKeyNames are the executor's modifier names. Pressed alone they do
// nothing on the user's machine, and the executor's key table cannot perform
// them — pressKey would refuse and kill the run. The tool emits a lone
// modifier press when a hotkey step went wrong (seen live 2026-09-08:
// press_key("super_l") after three degraded hotkey attempts); a short wait
// keeps the loop alive and lets the model correct itself on the next
// screenshot instead of stopping honestly on a step nothing could ever do.
var modifierKeyNames = map[string]bool{
	"command": true, "option": true, "control": true, "shift": true,
}

// normalizeKeyName maps one computer_use key name onto the executor's names.
func normalizeKeyName(k string) string {
	lowered := strings.ToLower(k)
	// A bare space character is the space key, not an empty name.
	if strings.TrimSpace(lowered) == "" && lowered != "" {
		return "space"
	}
	kk := strings.TrimSpace(lowered)
	if a, ok := keyNameAliases[kk]; ok {
		return a
	}
	return kk
}

// keyOrWait maps a normalized key name to the flat key action, falling back to
// a short wait when the name is a lone modifier (see modifierKeyNames) —
// including the raw keysym names (super_l) the tool emits for a modifier
// pressed by itself, which the executor's key table could never perform.
func keyOrWait(key string, mods []string) map[string]any {
	if modifierKeyNames[key] || hotkeyModifiers[key] != "" {
		return map[string]any{"action": "wait", "seconds": 0.5}
	}
	m := map[string]any{"action": "key", "key": key}
	if len(mods) > 0 {
		m["modifiers"] = mods
	}
	return m
}

func splitHotkey(keys []string) (key string, mods []string) {
	for _, k := range keys {
		kk := strings.ToLower(strings.TrimSpace(k))
		if kk == "" {
			continue
		}
		if m, ok := hotkeyModifiers[kk]; ok {
			mods = append(mods, m)
		} else {
			key = kk // the last non-modifier is the key being pressed
		}
	}
	return key, mods
}

// scrollTicks converts a pixel scroll magnitude into the executor's wheel-tick
// amount (~100px per tick, 1-10). Zero means "unspecified" — the action schema
// then applies its own default.
func scrollTicks(a computerUseArgs) int {
	px := 0
	switch {
	case a.MagnitudePixels != nil:
		px = *a.MagnitudePixels
	case a.Magnitude != nil:
		px = *a.Magnitude
	}
	if px <= 0 {
		return 0
	}
	t := (px + 99) / 100
	if t > 10 {
		t = 10
	}
	return t
}

// mapComputerUseCall translates one computer_use function_call into the flat
// action schema Suno Control validates and executes. Coordinates stay in the
// tool's 0-999 space; the gateway handler denormalizes them to image pixels
// (tool mode implies normalized coordinates). Actions the executor cannot
// perform, and any action the model flagged for safety confirmation, map to
// "failed" so the loop stops honestly rather than acting on a guess.
func mapComputerUseCall(name string, args computerUseArgs, autoProceedGuarded bool) map[string]any {
	note := strings.TrimSpace(args.Intent)
	withNote := func(m map[string]any) map[string]any {
		if _, ok := m["note"]; !ok && note != "" {
			m["note"] = note
		}
		return m
	}
	// failed reports the diagnostic cause (why the step could not run), not the
	// model's intent — that is what's useful in the capsule and the logs when
	// something the executor can't do comes back.
	failed := func(reason string) map[string]any {
		return map[string]any{"action": "failed", "note": reason}
	}
	coord := func(action string, x, y *int) map[string]any {
		if x == nil || y == nil {
			return failed("missing coordinates for " + action)
		}
		return map[string]any{"action": action, "x": *x, "y": *y}
	}

	// The tool flagged this step (a sign-in, purchase, delete, message send…).
	// A require_confirmation asks a human to okay a guarded action; the spoken
	// goal is that okay — the framing only lets the model reach such a step when
	// the goal explicitly asked — so with auto-proceed on we perform it, and the
	// switch below maps the underlying action. Any OTHER decision (a hard block,
	// or a prompt-injection flag) still stops: that is the on-screen-hijack case
	// the guard exists for, and the goal never authorizes it.
	if sd := args.SafetyDecision; sd != nil && sd.Decision != "" && !strings.EqualFold(sd.Decision, "allow") {
		proceed := autoProceedGuarded && strings.EqualFold(sd.Decision, "require_confirmation")
		if !proceed {
			reason := strings.TrimSpace(sd.Explanation)
			if reason == "" {
				reason = "Stopped for safety: this step needs confirmation Suno Control can't give."
			}
			return map[string]any{"action": "failed", "note": reason}
		}
	}

	switch strings.ToLower(strings.TrimSpace(name)) {
	case "click", "left_click", "click_at":
		return withNote(coord("click", args.X, args.Y))
	case "double_click", "double_click_at":
		return withNote(coord("double_click", args.X, args.Y))
	case "triple_click": // no triple in the executor — double is the closest
		return withNote(coord("double_click", args.X, args.Y))
	case "middle_click": // no middle button — best-effort left click
		return withNote(coord("click", args.X, args.Y))
	case "right_click", "right_click_at":
		return withNote(coord("right_click", args.X, args.Y))
	case "move", "mouse_move", "hover", "hover_at":
		return withNote(coord("move", args.X, args.Y))
	case "mouse_down": // rare; a full click is the best single-step stand-in
		return withNote(coord("click", args.X, args.Y))
	case "mouse_up":
		return withNote(map[string]any{"action": "wait", "seconds": 0.3})
	case "type", "type_text", "type_text_at":
		if args.Text == nil {
			return failed("nothing to type")
		}
		m := map[string]any{"action": "type", "text": *args.Text}
		if args.PressEnter != nil && *args.PressEnter {
			m["press_enter"] = true
		}
		return withNote(m)
	case "drag_and_drop", "drag":
		m := coord("drag", args.StartX, args.StartY)
		if m["action"] == "failed" {
			return withNote(m)
		}
		if args.EndX == nil || args.EndY == nil {
			return failed("missing drag destination")
		}
		m["x2"], m["y2"] = *args.EndX, *args.EndY
		return withNote(m)
	case "scroll", "scroll_at", "scroll_document":
		m := map[string]any{"action": "scroll"}
		if args.Direction != nil {
			m["direction"] = strings.ToLower(strings.TrimSpace(*args.Direction))
		}
		if args.X != nil && args.Y != nil {
			m["x"], m["y"] = *args.X, *args.Y
		}
		if t := scrollTicks(args); t > 0 {
			m["amount"] = t
		}
		return withNote(m)
	case "wait":
		m := map[string]any{"action": "wait"}
		if args.Seconds != nil {
			m["seconds"] = *args.Seconds
		}
		return withNote(m)
	case "take_screenshot": // the loop always re-captures next step — just pause
		return withNote(map[string]any{"action": "wait", "seconds": 0.5})
	case "press_key", "key_press", "keypress":
		if args.Key == nil || strings.TrimSpace(*args.Key) == "" {
			return failed("no key to press")
		}
		return withNote(keyOrWait(normalizeKeyName(*args.Key), nil))
	case "key_down":
		if args.Key == nil || strings.TrimSpace(*args.Key) == "" {
			return failed("no key")
		}
		return withNote(keyOrWait(normalizeKeyName(*args.Key), nil))
	case "key_up":
		return withNote(map[string]any{"action": "wait", "seconds": 0.3})
	case "hotkey", "key_combination", "hotkey_at":
		key, mods := splitHotkey(args.Keys)
		if key == "" {
			if len(mods) > 0 {
				// A combination of only modifiers presses nothing — wait instead
				// of failing the run.
				return withNote(map[string]any{"action": "wait", "seconds": 0.5})
			}
			return failed("no key in the combination")
		}
		return withNote(keyOrWait(normalizeKeyName(key), mods))
	default:
		// Browser chrome (navigate/go_back/go_forward/open_web_page/search) and
		// anything unknown: we drive the desktop, not a browser's UI, and won't
		// fake it — stop honestly.
		return failed("unsupported action: " + name)
	}
}

// ErrSafetyBlock is returned when Gemini's prompt-level safety filter blocked
// the request before any action was produced (PromptFeedback.BlockReason).
// The /control handler maps it to a distinct 502 error code so the client can
// say "the planner declined this goal" instead of reporting an outage.
var ErrSafetyBlock = errors.New("gemini safety filter blocked the prompt")

// callOneShotRaw POSTs a marshalled generateContent body to the given model
// and returns the decoded response, after the shared error checks (HTTP status,
// API error, safety block, no candidates). Text extraction (callOneShot) and
// function-call extraction (the computer_use path) build on top of this.
func (b *GeminiBackend) callOneShotRaw(ctx context.Context, body []byte, model string, timeout time.Duration) (*geminiResponse, error) {
	c, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	url := fmt.Sprintf("%s/models/%s:generateContent", strings.TrimRight(b.BaseURL, "/"), model)
	req, err := http.NewRequestWithContext(c, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build gemini request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	// Header auth, not ?key= — keeps the credential out of URLs, and therefore
	// out of proxy logs and error strings.
	req.Header.Set("x-goog-api-key", b.APIKey)

	resp, err := b.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("gemini call: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Read a small amount for diagnostics; never log transcript content.
		snippet, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("gemini returned %d: %s", resp.StatusCode, string(snippet))
	}

	var out geminiResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("decode gemini response: %w", err)
	}
	if out.Error.Code != 0 {
		return nil, fmt.Errorf("gemini error %d (%s)", out.Error.Code, out.Error.Status)
	}
	// A safety block returns no candidates. Surface it as ErrSafetyBlock so the
	// caller can distinguish it from a real outage (and the /control handler
	// can report "the planner declined this goal" instead of one).
	if out.PromptFeedback.BlockReason != "" {
		return nil, fmt.Errorf("%w: %s", ErrSafetyBlock, out.PromptFeedback.BlockReason)
	}
	if len(out.Candidates) == 0 {
		return nil, fmt.Errorf("gemini returned no candidates")
	}
	return &out, nil
}

// callOneShot POSTs a marshalled generateContent body and returns the
// response's text. Shared by cleanup and the JSON-prompt control path; the
// streaming answer path keeps its own reader. timeout governs the whole call.
func (b *GeminiBackend) callOneShot(ctx context.Context, body []byte, model string, timeout time.Duration) (string, error) {
	out, err := b.callOneShotRaw(ctx, body, model, timeout)
	if err != nil {
		return "", err
	}
	return textFromResponse(out)
}

// textFromResponse extracts the visible answer text from a decoded response,
// skipping reasoning parts. Empty text is an error — a healthy one-shot call
// always produces some output.
func textFromResponse(out *geminiResponse) (string, error) {
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

// usageFromResponse maps the provider's usage metadata onto the backend Usage
// shape. Safe on any decoded response — unreported counts come back zero.
func usageFromResponse(out *geminiResponse) Usage {
	u := out.UsageMetadata
	return Usage{
		PromptTokens:   u.PromptTokenCount,
		OutputTokens:   u.CandidatesTokenCount,
		ThinkingTokens: u.ThoughtsTokenCount,
		TotalTokens:    u.TotalTokenCount,
	}
}

// geminiTryonRequest is the generateContent body for Suno Try-on. A dedicated
// shape rather than geminiRequest, for two reasons: image generation takes
// generationConfig fields the text models do not (responseModalities,
// imageConfig), and it must NOT carry a temperature — image models are
// tuned at their default temperature and pinning cleanup's 0.0 visibly
// degrades composition.
type geminiTryonRequest struct {
	Contents         []geminiContent      `json:"contents"`
	GenerationConfig geminiTryonGenConfig `json:"generationConfig"`
}

// geminiTryonGenConfig is the generationConfig image generation understands.
// ResponseModalities must name both TEXT and IMAGE: the models may emit a
// caption part next to the image, and an IMAGE-only value is rejected.
type geminiTryonGenConfig struct {
	ResponseModalities []string           `json:"responseModalities"`
	ImageConfig        *geminiImageConfig `json:"imageConfig,omitempty"`
}

// geminiImageConfig sizes the composed image: aspectRatio ("3:4"…) and
// imageSize ("512"|"1K"|"2K"|"4K"). Both optional; empty fields omitted.
type geminiImageConfig struct {
	AspectRatio string `json:"aspectRatio,omitempty"`
	ImageSize   string `json:"imageSize,omitempty"`
}

// TryOn implements backend.TryonBackend (Suno Try-on): one generateContent
// call to the image model with the person photo and garment screenshot riding
// as inline parts before the prompt text — the same image-first order the
// answer and control paths use, which is what Gemini expects for interleaved
// text-and-image contents.
func (b *GeminiBackend) TryOn(ctx context.Context, prompt string, personJPEG, garmentJPEG []byte) ([]byte, string, Usage, error) {
	if len(personJPEG) == 0 || len(garmentJPEG) == 0 {
		return nil, "", Usage{}, fmt.Errorf("tryon requires a person photo and a garment image")
	}
	content := geminiContent{
		Role: "user",
		Parts: []geminiPart{
			{InlineData: &geminiInline{
				MimeType: "image/jpeg",
				Data:     base64.StdEncoding.EncodeToString(personJPEG),
			}},
			{InlineData: &geminiInline{
				MimeType: "image/jpeg",
				Data:     base64.StdEncoding.EncodeToString(garmentJPEG),
			}},
			{Text: prompt},
		},
	}
	reqBody := geminiTryonRequest{
		Contents: []geminiContent{content},
		GenerationConfig: geminiTryonGenConfig{
			ResponseModalities: []string{"TEXT", "IMAGE"},
		},
	}
	// Size the composed image only when the deployment asked for a bucket;
	// sending an empty imageConfig is equivalent to omitting it, but omitting
	// keeps the wire minimal.
	if b.TryonAspectRatio != "" || b.TryonImageSize != "" {
		reqBody.GenerationConfig.ImageConfig = &geminiImageConfig{
			AspectRatio: b.TryonAspectRatio,
			ImageSize:   b.TryonImageSize,
		}
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return nil, "", Usage{}, fmt.Errorf("marshal gemini request: %w", err)
	}

	out, err := b.callOneShotRaw(ctx, body, b.tryonModel(), b.tryonTimeout())
	if err != nil {
		return nil, "", Usage{}, err
	}
	return imageFromResponse(out)
}

// imageFromResponse extracts the first generated image from a decoded
// response. The image models answer with an inlineData part, possibly next to
// a caption text part; reasoning parts never carry the image.
func imageFromResponse(out *geminiResponse) ([]byte, string, Usage, error) {
	for _, p := range out.Candidates[0].Content.Parts {
		if p.Thought || p.Metadata.IsThinking {
			continue
		}
		if p.InlineData == nil || p.InlineData.Data == "" {
			continue
		}
		data, err := base64.StdEncoding.DecodeString(p.InlineData.Data)
		if err != nil {
			return nil, "", Usage{}, fmt.Errorf("decode tryon image: %w", err)
		}
		mime := p.InlineData.MimeType
		if mime == "" {
			mime = "image/png" // the models emit PNG when they don't say
		}
		return data, mime, usageFromResponse(out), nil
	}
	return nil, "", Usage{}, fmt.Errorf("gemini returned no image (finish reason %q)",
		out.Candidates[0].FinishReason)
}

// tryonName identifies the image provider for logging and analytics.
func (b *GeminiBackend) TryonName() string { return "gemini" }

// tryonModel resolves which model try-on requests use (TRYON_MODEL). Unlike
// the other seams there is no fallback: Model is a text model and cannot
// emit images. The caller only reaches here when TryonModel was set.
func (b *GeminiBackend) tryonModel() string {
	if b.TryonModel != "" {
		return b.TryonModel
	}
	return b.Model
}

// tryonTimeout is the total deadline for one try-on call. Zero falls back to
// Timeout.
func (b *GeminiBackend) tryonTimeout() time.Duration {
	if b.TryonTimeout != 0 {
		return b.TryonTimeout
	}
	return b.Timeout
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
		if br := ev.PromptFeedback.BlockReason; br != "" {
			// A prompt-level safety block is its own signal, not a backend error:
			// emit it as metadata so the handler can record a distinct "blocked"
			// outcome (and an error_code) instead of a generic "unavailable".
			sendChunk(ctx, out, AnswerChunk{BlockReason: br})
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

		// Token accounting rides the final candidate chunk (Gemini attaches
		// usageMetadata there). Emit it as its own chunk so the handler can pass
		// exact per-request usage on to analytics; a zero-total (not yet reported)
		// chunk carries nothing useful and is skipped.
		if u := ev.UsageMetadata; u.TotalTokenCount > 0 {
			sendChunk(ctx, out, AnswerChunk{Usage: Usage{
				PromptTokens:   u.PromptTokenCount,
				OutputTokens:   u.CandidatesTokenCount,
				ThinkingTokens: u.ThoughtsTokenCount,
				TotalTokens:    u.TotalTokenCount,
			}})
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

// controlModel resolves which model control requests use (CONTROL_MODEL; falls
// back to the cleanup model when unset).
func (b *GeminiBackend) controlModel() string {
	if b.ControlModel != "" {
		return b.ControlModel
	}
	return b.Model
}
