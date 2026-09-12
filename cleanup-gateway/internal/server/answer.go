package server

// The Suno Answer route (stage 2): POST /answer streams a grounded answer as
// server-sent events. The sidecar proxies this byte-for-byte, so the wire
// contract here is the wire contract the Swift client sees:
//
//	meta    {"lease": "..."}          — first event, always (lease refresh)
//	delta   {"text": "..."}           — one fragment of the answer
//	sources {"domains":[...],"queries":N}
//	done    {}                        — the stream ended cleanly
//	error   {"error":code,"message":"..."}  — terminal, taxonomy of D4
//
// No raw fallback ever (D4): a backend failure ends the stream with an error
// event, and pre-stream failures return the JSON error before any event.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/analytics"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/caller"
	"github.com/sunoflow/cleanup-gateway/internal/cleanup"
	"github.com/sunoflow/cleanup-gateway/internal/research"
)

// maxAnswerBody caps the /answer request body at 4MB (D2): a screenshot
// down-scaled to 1600px on the long edge, JPEG, base64, plus prompt text, with
// headroom. /cleanup keeps its own 1MB cap.
const maxAnswerBody = 4 << 20

// maxImageBytes is the practical cap on the inline screenshot. A 1600px JPEG
// lands well under 1MB; anything larger is rejected outright rather than
// silently sent to the model.
const maxImageBytes = 3 << 20

// answerRequest mirrors the /answer API contract.
type answerRequest struct {
	// Query is the user's question this turn.
	Query string `json:"query"`
	// History is the prior text turns, oldest first. Present on turns > 1.
	History []research.Turn `json:"history"`
	// ImageB64 is this turn's screenshot, base64 JPEG. Sent on every turn
	// (per-turn capture, 2026-09-05, superseding D11's turn-1-only): a follow-up
	// may point at a different part of the screen, so the client re-captures the
	// current screen each turn. The gateway uses whatever image the request
	// carries; an absent one is simply a text-only turn.
	ImageB64 string `json:"image"`
	// Dictionary is the user's own terms relevant to this query, selected by
	// the sidecar from its local corrections file.
	Dictionary []cleanup.Entry `json:"dictionary"`
}

// Server accessors the answer route needs, defined here rather than widening
// the Server struct with answer-specific fields — the struct stays cleanup-
// shaped, and the answer wiring stays in one file.

// answerBackend returns the streaming seam, or nil when the configured backend
// cannot stream (then /answer answers 501).
func (s *Server) answerBackend() backend.AnswerBackend {
	if ab, ok := s.Backend.(backend.AnswerBackend); ok {
		return ab
	}
	return nil
}

// handleAnswer is the Suno Answer endpoint. Authentication and the answer
// quota run in the middleware chain; everything here is the streaming half.
func (s *Server) handleAnswer(w http.ResponseWriter, r *http.Request) {
	started := time.Now()

	ab := s.answerBackend()
	if ab == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "unavailable", "message": "no streaming backend"})
		return
	}

	// Read the body under the per-route cap.
	var req answerRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAnswerBody)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed json"})
		return
	}
	query := strings.TrimSpace(req.Query)
	if query == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": "empty query"})
		return
	}

	// The image (when present) is used for whatever turn it arrives on — the
	// client sends this turn's screenshot every turn (per-turn capture), so a
	// follow-up about a different part of the screen is grounded in what's there
	// now. An absent image is simply a text-only turn, not an error.
	image, err := decodeImage(req.ImageB64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": err.Error()})
		return
	}

	dict := cleanup.NormalizeDict(req.Dictionary)
	if len(dict) > research.MaxDictEntries {
		dict = dict[:research.MaxDictEntries]
	}

	prompt := research.AnswerPrompt{
		Query:      query,
		History:    req.History,
		Dictionary: dict,
	}
	if len(image) > 0 {
		prompt.Image = true
	}

	// Build the prompt text and the upstream stream.
	promptText := strings.Join(research.BuildAnswerPrompt(prompt), "\n")
	chunks, err := ab.StreamAnswer(r.Context(), promptText, image)
	if err != nil {
		s.Logger.Warn("answer stream failed to start", "err", err.Error())
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unavailable"})
		return
	}

	// SSE response headers. X-Accel-Buffering disables nginx response
	// buffering for this response; Flusher calls below keep chunks moving.
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	flusher, _ := w.(http.Flusher)

	writeEvent := func(event string, payload string) {
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, payload)
		if flusher != nil {
			flusher.Flush()
		}
	}

	// meta first, always: the lease refresh rides it (same lease /cleanup
	// carries, so a paid answer also keeps the offline entitlement fresh).
	writeEvent("meta", marshalJSON(map[string]string{"lease": leaseFor(r)}))

	// Track what happened for the terminal event and analytics.
	var (
		textLen     int
		domains     []string
		queries     int
		streamErr   error
		blockReason string
		usage       backend.Usage
	)
	ttfb := time.Duration(0)

	for chunk := range chunks {
		if ttfb == 0 && (chunk.Text != "" || chunk.Err != nil) {
			ttfb = time.Since(started)
		}
		// A chunk can carry text AND grounding metadata (Gemini attaches
		// grounding to the final candidate chunk, which also carries text).
		if len(chunk.Domains) > 0 || chunk.SearchQueries > 0 {
			// The LAST such chunk wins — grounding re-sends per candidate
			// chunk; the final one is the complete set.
			domains = chunk.Domains
			if chunk.SearchQueries > queries {
				queries = chunk.SearchQueries
			}
		}
		// Token accounting rides on or near the final chunk; the last reported
		// (non-zero) usage wins, so a later candidate does not clobber it.
		if chunk.Usage.TotalTokens > 0 {
			usage = chunk.Usage
		}
		switch {
		case chunk.Err != nil:
			streamErr = chunk.Err
		case chunk.BlockReason != "":
			blockReason = chunk.BlockReason
		case chunk.Text != "":
			textLen += len(chunk.Text)
			writeEvent("delta", marshalJSON(map[string]string{"text": chunk.Text}))
		}
	}

	// Aborted: the client (sidecar) gave up — deadline or disconnect. Nothing
	// to write to it any more; record the abandon point for analytics (D9).
	aborted := r.Context().Err() != nil

	// Terminal event. Stream died after the deadline → "timeout" (D3); a
	// prompt-level safety block → "blocked"; any other backend failure →
	// "unavailable". Never a raw fallback (D4).
	code := "unavailable"
	if streamErr != nil {
		if errors.Is(streamErr, context.DeadlineExceeded) {
			code = "timeout"
		}
		if !aborted {
			writeEvent("error", marshalJSON(map[string]string{"error": code, "message": "The answer couldn't be generated. Try again."}))
		}
	} else if blockReason != "" {
		code = "blocked"
		if !aborted {
			writeEvent("error", marshalJSON(map[string]string{"error": code, "message": "The question couldn't be answered. Try rephrasing."}))
		}
	} else if !aborted {
		if len(domains) > 0 {
			writeEvent("sources", marshalJSON(map[string]any{"domains": domains, "queries": queries}))
		}
		writeEvent("done", "{}")
	}

	// Analytics: zero content — lengths, flags, timings, outcome (D9).
	clientOS, clientVersion := parseClient(r.Header.Get(clientHeader))
	id, _ := caller.From(r.Context())
	outcome := "ok"
	if aborted {
		outcome = "aborted"
	} else if blockReason != "" {
		outcome = "blocked"
	} else if streamErr != nil {
		outcome = "error"
		if errors.Is(streamErr, context.DeadlineExceeded) {
			outcome = "timeout"
		}
	}
	props := map[string]any{
		"os":               clientOS,
		"app_version":      clientVersion,
		"had_image":        len(image) > 0,
		"turn_index":       len(req.History),
		"query_length":     len(query),
		"answer_chars":     textLen,
		"dict_entries":     len(dict),
		"context_chars":    len(promptText),
		"source_count":     len(domains),
		"search_queries":   queries,
		"outcome":          outcome,
		"model":            s.AnswerModel,
		"latency_ttfb_ms":  ttfb.Milliseconds(),
		"latency_total_ms": time.Since(started).Milliseconds(),
		// Per-request token usage from the provider (zero when unreported), so
		// answer cost is measured, not estimated. Thinking tokens are billed as
		// output but reported apart from the visible answer.
		"prompt_tokens":   usage.PromptTokens,
		"output_tokens":   usage.OutputTokens,
		"thinking_tokens": usage.ThinkingTokens,
		"total_tokens":    usage.TotalTokens,
	}
	if (streamErr != nil || blockReason != "") && !aborted {
		props["error_code"] = code
	}
	if blockReason != "" {
		props["block_reason"] = blockReason
	}
	if aborted {
		props["aborted_at_ms"] = time.Since(started).Milliseconds()
	}
	s.Analytics.Capture(analytics.Event{
		Name:       "answer",
		DistinctID: id.MeterKey(),
		Properties: props,
		PersonProperties: map[string]any{
			"os":          clientOS,
			"app_version": clientVersion,
		},
	})

	// Also to the gateway log, so token usage per answer is greppable during
	// calibration without opening the analytics dashboard.
	s.Logger.Info("answer",
		"model", s.AnswerModel,
		"outcome", outcome,
		"answer_chars", textLen,
		"dict_entries", len(dict),
		"context_chars", len(promptText),
		"prompt_tokens", usage.PromptTokens,
		"output_tokens", usage.OutputTokens,
		"thinking_tokens", usage.ThinkingTokens,
		"total_tokens", usage.TotalTokens,
		"latency_ms", time.Since(started).Milliseconds())
}

// decodeImage validates and decodes the turn-1 screenshot. Empty means "no
// image" and is fine; anything present must be base64 JPEG under the cap.
func decodeImage(b64 string) ([]byte, error) {
	if b64 == "" {
		return nil, nil
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, errors.New("image is not valid base64")
	}
	if len(raw) > maxImageBytes {
		return nil, errors.New("image too large")
	}
	return raw, nil
}

// marshalJSON is writeJSON's one-line twin for SSE payloads.
func marshalJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
