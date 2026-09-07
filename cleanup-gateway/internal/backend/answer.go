package backend

import (
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// MaxSourceDomains caps the source chips under an answer (C6: 2-4 domains).
// Fewer than two is still fine — a fully offline answer (e.g. "what's 2+2")
// has no sources, and that's the honest answer.
const MaxSourceDomains = 4

// ErrAnswerUnavailable wraps every provider-side failure the answer path can
// surface. The answer route maps it to the "unavailable" error card (D4) —
// there is no raw-text fallback for answers, ever.
var ErrAnswerUnavailable = errors.New("answer backend unavailable")

// classifyHTTPError maps any stream-path failure into the answer taxonomy: one
// sentinel the server can test with errors.Is. The wording stays technical
// here; the user-facing copy is chosen by the client.
func classifyHTTPError(err error) error {
	return fmt.Errorf("%w: %w", ErrAnswerUnavailable, err)
}

// dedupeDomains normalizes grounding chunks into unique lowercase host names,
// capped at MaxSourceDomains (C6: 2-4 chips). Hosts only — the chip links to
// the domain, and path/query strings would leak page content into the UI.
// Empty hosts are skipped; the domain field is used when Gemini supplies it,
// with the URI's host as fallback.
func dedupeDomains(chunks []geminiGroundingChunk) []string {
	seen := make(map[string]bool, len(chunks))
	var out []string
	for _, ch := range chunks {
		host := strings.ToLower(strings.TrimSpace(ch.Web.Domain))
		if host == "" {
			if u, err := url.Parse(ch.Web.URI); err == nil && u.Host != "" {
				host = strings.ToLower(u.Host)
			}
		}
		if host == "" {
			continue
		}
		host = strings.TrimPrefix(host, "www.")
		if seen[host] {
			continue
		}
		seen[host] = true
		out = append(out, host)
		if len(out) >= MaxSourceDomains {
			break
		}
	}
	return out
}

// The answer stream client lives on GeminiBackend (see answerHTTPClient there):
// it shares the cleanup client's transport, so cleanup's frequent traffic keeps
// the provider's TLS/H2 connections warm for the infrequent, paid answer stream.
