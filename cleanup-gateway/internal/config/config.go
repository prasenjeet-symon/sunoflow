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

	QuotaRPM   int // default per-key requests/minute
	QuotaDaily int // default per-key requests/day

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
		QuotaRPM:            envInt("DEFAULT_QUOTA_RPM", 60),
		QuotaDaily:          envInt("DEFAULT_QUOTA_DAILY", 5000),
		LeaseSecret:         envStr("LEASE_SECRET", ""),
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

// Sanitize normalizes the log level for comparison.
func (c Config) SanitizedAddr() string {
	return strings.TrimSpace(c.GatewayAddr)
}
