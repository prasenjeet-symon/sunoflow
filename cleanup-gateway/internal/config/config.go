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
	GatewayAddr   string        // listen address (loopback; Nginx proxies to it)
	OllamaURL     string        // Ollama /api/generate endpoint
	OllamaModel   string        // model name (server-controlled)
	Backend       string        // active backend: ollama|openai|claude
	OllamaTimeout time.Duration // per-call timeout
	DBPath        string        // SQLite path
	AdminToken    string        // token for /admin/* endpoints (required)
	LogLevel      string        // debug|info|warn|error
	QuotaRPM      int           // default per-key requests/minute
	QuotaDaily    int           // default per-key requests/day
}

// Load reads configuration from the environment. Fatal on missing ADMIN_TOKEN.
func Load() (Config, error) {
	cfg := Config{
		GatewayAddr:   envStr("GATEWAY_ADDR", "127.0.0.1:8080"),
		OllamaURL:     envStr("OLLAMA_URL", "http://127.0.0.1:11434/api/generate"),
		OllamaModel:   envStr("OLLAMA_MODEL", "llama3.2:3b"),
		Backend:       envStr("BACKEND", "ollama"),
		OllamaTimeout: envDuration("OLLAMA_TIMEOUT", 20*time.Second),
		DBPath:        envStr("DB_PATH", "/var/lib/sunoflow-gateway/keys.db"),
		AdminToken:    envStr("ADMIN_TOKEN", ""),
		LogLevel:      envStr("LOG_LEVEL", "info"),
		QuotaRPM:      envInt("DEFAULT_QUOTA_RPM", 60),
		QuotaDaily:    envInt("DEFAULT_QUOTA_DAILY", 5000),
	}
	if cfg.AdminToken == "" {
		return Config{}, fmt.Errorf("ADMIN_TOKEN is required")
	}
	if cfg.Backend != "ollama" && cfg.Backend != "openai" && cfg.Backend != "claude" {
		return Config{}, fmt.Errorf("BACKEND must be ollama|openai|claude, got %q", cfg.Backend)
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