// Package config loads all gateway settings from environment variables (12-factor).
// No configuration lives in the binary; everything is env-driven and loaded once at startup.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds all runtime configuration for the gateway.
type Config struct {
	GatewayAddr string // listen address (loopback; Nginx proxies to it)
	Backend     string // active backend; gemini is the only implementation

	// Gemini backend. GeminiAPIKey comes from the environment only — it is
	// never written to source or logged.
	GeminiAPIKey  string
	GeminiModel   string
	GeminiURL     string
	GeminiTimeout time.Duration
	// How hard the model may reason before answering: minimal|low|medium|high.
	// Empty omits the field (needed for older 2.5-era models).
	GeminiThinking string
	DBPath         string // SQLite path
	AdminToken     string // token for /admin/* endpoints (required)
	LogLevel       string // debug|info|warn|error
	// Account entitlement (Firestore). When FirebaseProject is empty the
	// gateway keeps using only its own SQLite keys, so an existing deployment
	// is unaffected until it is configured.
	FirebaseProject     string // Firebase project id, e.g. sunoflow-app
	FirebaseCredentials string // path to a service-account json; empty = ADC

	// Product analytics (PostHog). An empty PostHogAPIKey disables it entirely
	// and nothing is sent anywhere, which is how a local or self-hosted
	// deployment runs — the same posture as an empty FirebaseProject.
	//
	// This is the ingest (project) key, which is write-only by design. It is
	// still configuration rather than source: a deployment that wants no
	// analytics should not have to edit code to get it.
	PostHogAPIKey string
	PostHogHost   string

	QuotaRPM   int // default per-key requests/minute
	QuotaDaily int // default per-key requests/day

	// Suno Answer (the paid ask-a-question feature). Model, deadline and quota
	// are all separately tunable from cleanup: answers are grounded (web search)
	// and streamed, so a different model class and a much longer ceiling apply.
	// ResearchModel defaults to the same flash-lite class as cleanup.
	ResearchModel string
	// AnswerMediaResolution is the Gemini 3 media-resolution bucket for the
	// answer screenshot (MEDIA_RESOLUTION_LOW/MEDIUM/HIGH/ULTRA_HIGH). It fixes
	// the per-image token cost; the model default is HIGH (≈1120 tokens/image),
	// so we default to MEDIUM (≈560) — half the image tokens per turn, still
	// legible for typical UI, now that the screenshot rides every turn. Set to
	// MEDIA_RESOLUTION_HIGH for dense-text/OCR screenshots, or LOW to save more.
	AnswerMediaResolution string
	AnswerTimeout         time.Duration // total stream deadline per answer request
	AnswerQuotaRPM        int           // default per-account answer messages/minute
	AnswerQuotaDaily      int           // default per-account answer messages/day
	AnswerHardDaily       int           // gateway-side hard ceiling on messages/day

	// Suno Control (the agent-loop computer-control feature). Like answer, its
	// own model + deadline + quota: a run is a burst of paid planning calls
	// (the client runs up to 100 steps, one call each), and each call carries a
	// screenshot. ControlModel defaults to the same flash-lite class as
	// cleanup.
	ControlModel           string
	ControlMediaResolution string        // Gemini 3 media-resolution bucket for the control screenshot
	ControlTimeout         time.Duration // total deadline per plan call
	ControlQuotaRPM        int           // default per-account control steps/minute
	ControlQuotaDaily      int           // default per-account control steps/day
	ControlHardDaily       int           // gateway-side hard ceiling on steps/day
	// ControlCoordSpace is how the control model expresses click coordinates:
	// "pixel" (answers in image pixels — the default, right for a general
	// model) or "normalized" (answers 0-1000 on each axis, what Gemini's
	// purpose-built spatial / computer-use models emit). The gateway converts
	// normalized coords back to image pixels before replying, so the sidecar
	// and the app's executor are identical either way — this is purely which
	// model dialect the gateway speaks.
	ControlCoordSpace string
	// ControlUseTool switches Suno Control from the free-form JSON-prompt path
	// to Gemini's native computer_use tool: the gateway declares the tool, the
	// model answers with function_call actions (0-999 coords), and the gateway
	// maps those to the same action schema the client already executes. Implies
	// normalized coordinates. Default off (the JSON-prompt path).
	ControlUseTool bool
	// ControlEnvironment is the computer_use environment when ControlUseTool is
	// on: ENVIRONMENT_DESKTOP (default — driving the whole Mac), _BROWSER or
	// _MOBILE.
	ControlEnvironment string
	// ControlAutoProceedGuarded lets Suno Control carry out a step the tool
	// flags for confirmation (send a message, purchase, delete, sign-in) when
	// the spoken goal asked for it, instead of stopping. The prompt framing only
	// lets the model reach such a step when the goal explicitly and
	// unambiguously requested it, and prompt-injection detection stays on — so
	// an action induced by on-screen content is still refused. OFF by default:
	// enabling it means the agent will send/buy/delete without a separate
	// confirmation, so it is a deliberate per-deployment choice.
	ControlAutoProceedGuarded bool
	// ControlThinking is a planner-specific thinking-level override
	// (CONTROL_THINKING_LEVEL: minimal|low|medium|high). Empty falls back to the
	// shared GEMINI_THINKING_LEVEL — control is a different workload from
	// cleanup, and in JSON-prompt mode (ControlUseTool=false) the model's
	// reasoning IS the dominant per-call cost, so it can want a different floor.
	ControlThinking string

	// Cloud STT (the warm-start dictation path): a new install can dictate
	// immediately over the cloud while its local model downloads in the
	// background, then the sidecar cuts over to on-device and stops calling here.
	//
	// Defaults to "groq" — measured ~3-4x faster than the alternatives (a
	// dedicated Whisper on Groq's LPUs, ~0.3-0.6s vs ~2s), and more accurate too.
	// It activates only once STT_API_KEY is set: a groq/openrouter provider with
	// no key SOFT-DISABLES the /stt route (it answers 501) with a warning at
	// boot rather than failing to start, so a gateway with no STT key still runs
	// exactly as before. Set STT_PROVIDER="" to disable STT explicitly.
	//
	// Three providers are supported. "groq" is a dedicated Whisper endpoint
	// (OpenAI-compatible /audio/transcriptions) — the fast default, needs its own
	// key. "openrouter" sends the audio to an audio-capable model via OpenRouter's
	// OpenAI-compatible chat endpoint (default model Mistral Voxtral) — one key
	// covers STT plus any model swap, but ~3-4x slower. "gemini" reuses
	// GeminiAPIKey and needs no new credential, at the cost of transcribing
	// through the same flash-lite class used for cleanup.
	STTProvider string // "groq" (default) | "openrouter" | "gemini" | "" (disabled)
	STTAPIKey   string // provider key for "groq"/"openrouter"; "gemini" reuses GeminiAPIKey
	STTModel    string // e.g. whisper-large-v3-turbo (groq); empty falls back per provider
	STTBaseURL  string // provider API root
	// STTLanguage is an optional BCP-47 hint passed to the provider (e.g. "en").
	// Empty lets the provider auto-detect, which is the right default for a
	// multilingual user base.
	STTLanguage   string
	STTTimeout    time.Duration // per-call timeout for a transcription
	STTQuotaRPM   int           // default per-account transcriptions/minute
	STTQuotaDaily int           // default per-account transcriptions/day
	STTHardDaily  int           // gateway-side hard ceiling on transcriptions/day

	// LeaseSecret signs the offline entitlement leases the gateway hands to
	// entitled devices. The sidecar verifies them with the same value, so the
	// two must match: changing it here without shipping a matching sidecar
	// invalidates every lease in the field. Empty uses the built-in default,
	// which is what almost every deployment should do — see
	// internal/account/lease.go for why this is not really a secret.
	LeaseSecret string
}

// Load reads configuration from the environment. Fatal on missing ADMIN_TOKEN.
func Load() (Config, error) {
	cfg := Config{
		GatewayAddr: envStr("GATEWAY_ADDR", "127.0.0.1:8080"),
		Backend:     envStr("BACKEND", "gemini"),

		GeminiAPIKey:   envStr("GEMINI_API_KEY", ""),
		GeminiModel:    envStr("GEMINI_MODEL", "gemini-3.5-flash-lite"),
		GeminiURL:      envStr("GEMINI_URL", "https://generativelanguage.googleapis.com/v1beta"),
		GeminiTimeout:  envDuration("GEMINI_TIMEOUT", 20*time.Second),
		GeminiThinking: envStr("GEMINI_THINKING_LEVEL", "low"),
		DBPath:         envStr("DB_PATH", "/var/lib/sunoflow-gateway/keys.db"),
		AdminToken:     envStr("ADMIN_TOKEN", ""),

		FirebaseProject:     envStr("FIREBASE_PROJECT", ""),
		FirebaseCredentials: envStr("FIREBASE_CREDENTIALS", ""),
		LogLevel:            envStr("LOG_LEVEL", "info"),
		PostHogAPIKey:       envStr("POSTHOG_API_KEY", ""),
		PostHogHost:         envStr("POSTHOG_HOST", "https://us.i.posthog.com"),
		QuotaRPM:            envInt("DEFAULT_QUOTA_RPM", 60),
		QuotaDaily:          envInt("DEFAULT_QUOTA_DAILY", 5000),
		LeaseSecret:         envStr("LEASE_SECRET", ""),

		ResearchModel:         envStr("RESEARCH_MODEL", "gemini-3.5-flash-lite"),
		AnswerMediaResolution: envStr("ANSWER_MEDIA_RESOLUTION", "MEDIA_RESOLUTION_MEDIUM"),
		AnswerTimeout:         envDuration("ANSWER_TIMEOUT", 90*time.Second),
		AnswerQuotaRPM:        envInt("ANSWER_QUOTA_RPM", 5),
		AnswerQuotaDaily:      envInt("ANSWER_QUOTA_DAILY", 50),
		AnswerHardDaily:       envInt("ANSWER_HARD_DAILY", 100),

		ControlModel:              envStr("CONTROL_MODEL", "gemini-3.5-flash-lite"),
		ControlMediaResolution:    envStr("CONTROL_MEDIA_RESOLUTION", "MEDIA_RESOLUTION_MEDIUM"),
		ControlTimeout:            envDuration("CONTROL_TIMEOUT", 30*time.Second),
		ControlQuotaRPM:           envInt("CONTROL_QUOTA_RPM", 20),
		ControlQuotaDaily:         envInt("CONTROL_QUOTA_DAILY", 200),
		ControlHardDaily:          envInt("CONTROL_HARD_DAILY", 300),
		ControlCoordSpace:         envStr("CONTROL_COORD_SPACE", "pixel"),
		ControlUseTool:            envBool("CONTROL_USE_TOOL", false),
		ControlEnvironment:        envStr("CONTROL_ENVIRONMENT", "ENVIRONMENT_DESKTOP"),
		ControlAutoProceedGuarded: envBool("CONTROL_AUTOPROCEED_GUARDED", false),
		ControlThinking:           envStr("CONTROL_THINKING_LEVEL", ""),

		STTProvider:   envStr("STT_PROVIDER", "groq"),
		STTAPIKey:     envStr("STT_API_KEY", ""),
		STTModel:      envStr("STT_MODEL", ""),
		STTBaseURL:    envStr("STT_BASE_URL", ""),
		STTLanguage:   envStr("STT_LANGUAGE", ""),
		STTTimeout:    envDuration("STT_TIMEOUT", 30*time.Second),
		STTQuotaRPM:   envInt("STT_QUOTA_RPM", 15),
		STTQuotaDaily: envInt("STT_QUOTA_DAILY", 300),
		STTHardDaily:  envInt("STT_HARD_DAILY", 600),
	}
	if cfg.AdminToken == "" {
		return Config{}, fmt.Errorf("ADMIN_TOKEN is required")
	}
	// BACKEND is kept as an explicit selector so adding a provider stays a
	// config change rather than a code change at the call site, but Gemini is
	// the only backend that exists. Anything else is a typo, not a feature.
	switch cfg.Backend {
	case "gemini":
	default:
		return Config{}, fmt.Errorf("BACKEND must be gemini, got %q", cfg.Backend)
	}
	// Fail at startup rather than on the first user request: a gateway that
	// boots without a key would soft-fail every cleanup to raw text silently.
	if cfg.GeminiAPIKey == "" {
		return Config{}, fmt.Errorf("GEMINI_API_KEY is required")
	}
	// Cloud STT is opt-in. When configured, validate it here so a typo is a
	// boot failure rather than a 501 on the first warm-start dictation.
	// Only the provider name is validated here (a typo should fail loudly). A
	// groq/openrouter provider with no STT_API_KEY is NOT a boot error: main
	// soft-disables STT with a warning so the gateway still starts — important
	// now that "groq" is the default, so a deployment that never set an STT key
	// keeps booting exactly as before.
	switch cfg.STTProvider {
	case "", "groq", "openrouter", "gemini":
	default:
		return Config{}, fmt.Errorf("STT_PROVIDER must be groq, openrouter, gemini, or empty to disable; got %q", cfg.STTProvider)
	}
	return cfg, nil
}

func envStr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

func envBool(key string, def bool) bool {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		switch strings.ToLower(strings.TrimSpace(v)) {
		case "1", "true", "yes", "on":
			return true
		case "0", "false", "no", "off":
			return false
		}
	}
	return def
}

// Sanitize normalizes the log level for comparison.
func (c Config) SanitizedAddr() string {
	return strings.TrimSpace(c.GatewayAddr)
}
