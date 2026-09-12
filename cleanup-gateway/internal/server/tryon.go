package server

// The Suno Try-on route: POST /tryon composes ONE image of the user wearing
// the garment they are looking at. The sidecar proxies it byte-for-byte, so
// the wire contract here is the wire contract the Swift client sees:
//
//	POST /tryon  {"person","garment","item","query","context"}
//	200          {"image","mime_type","lease"} — image is base64
//	400          {"error":"malformed json"|"malformed request","message":...}
//	402-class    from the account middleware (same entitlement as /cleanup)
//	429          {"error":"limit"} + Retry-After (60=daily/hard, 1=per-minute)
//	502          {"error":"unavailable"|"safety_block"} — backend failure
//
// It is a NON-streaming one-shot (unlike /answer): the app calls it once per
// turn, after the answer stream signals try-on intent. There is no degraded
// mode — if the model cannot compose the image the client shows the error;
// showing a wrong photo would be worse than showing none.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/analytics"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/caller"
	"github.com/sunoflow/cleanup-gateway/internal/tryon"
)

// maxTryonBody caps the /tryon request body at 8MB: two images (each up to
// maxImageBytes decoded, base64-inflated on the wire) plus prompt text with
// headroom. Double /answer's cap because there are two images, not one.
const maxTryonBody = 8 << 20

// tryonRequest mirrors the /tryon API contract.
type tryonRequest struct {
	// PersonB64 is the user's stored photo, base64 (JPEG — the app normalizes
	// to JPEG when it saves it). REQUIRED.
	PersonB64 string `json:"person"`
	// GarmentB64 is the garment screenshot from the user's current screen,
	// base64 JPEG. REQUIRED.
	GarmentB64 string `json:"garment"`
	// Item is the short item label the answer model extracted ("the grey
	// hoodie on this page"). REQUIRED — it is what the composition is of.
	Item string `json:"item"`
	// Query is the user's full spoken question, for nuance. Optional.
	Query string `json:"query"`
	// Context is what the client observed: frontmost app and focused window
	// title (a garment's label often lives in the page title).
	Context tryonContext `json:"context"`
}

// tryonContext is the observed context block of a /tryon request.
type tryonContext struct {
	App    string `json:"app"`
	Window string `json:"window"`
}

// tryonResponse is the 200 body: the composed image plus its encoding.
type tryonResponse struct {
	Image    string `json:"image"` // base64
	MimeType string `json:"mime_type"`
	Lease    string `json:"lease,omitempty"`
}

// tryonBackend returns the try-on seam, or nil when the configured backend
// cannot compose images (then /tryon answers 501).
func (s *Server) tryonBackend() backend.TryonBackend {
	if tb, ok := s.Backend.(backend.TryonBackend); ok {
		return tb
	}
	return nil
}

// handleTryon is the Suno Try-on endpoint. Authentication and the try-on
// quota run in the middleware chain; everything here is the one-shot
// composition.
func (s *Server) handleTryon(w http.ResponseWriter, r *http.Request) {
	started := time.Now()

	tb := s.tryonBackend()
	if tb == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "unavailable", "message": "no tryon backend"})
		return
	}

	// Read the body under the per-route cap.
	var req tryonRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxTryonBody)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed json"})
		return
	}
	item := strings.TrimSpace(req.Item)
	if item == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": "empty item"})
		return
	}

	// Both images are required — a try-on without either is not a request this
	// endpoint can serve. Each is validated (base64 JPEG/PNG) and capped by
	// decodeImage, exactly as the answer/control screenshots are.
	person, err := decodeImage(req.PersonB64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": err.Error()})
		return
	}
	if len(person) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": "empty person photo"})
		return
	}
	garment, err := decodeImage(req.GarmentB64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": err.Error()})
		return
	}
	if len(garment) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": "empty garment image"})
		return
	}

	// Build the prompt: framing → [ITEM] → [REQUEST] → context line.
	promptText := strings.Join(tryon.BuildPrompt(tryon.Prompt{
		Item:   item,
		Query:  req.Query,
		App:    req.Context.App,
		Window: req.Context.Window,
	}), "\n")

	image, mimeType, usage, err := tb.TryOn(r.Context(), promptText, person, garment)
	if err != nil {
		// A safety block is not an outage: the filter declined this specific
		// image, so the client should say so instead of "try again shortly".
		if errors.Is(err, backend.ErrSafetyBlock) {
			s.Logger.Warn("tryon blocked by safety filter")
			writeJSON(w, http.StatusBadGateway, map[string]string{
				"error":   "safety_block",
				"message": "Suno Try-on declined this request. Try a different photo or item.",
			})
			return
		}
		s.Logger.Warn("tryon failed", "err", err.Error())
		code := http.StatusBadGateway
		body := map[string]string{"error": "unavailable"}
		if errors.Is(err, context.DeadlineExceeded) {
			body["message"] = "timed out"
		}
		writeJSON(w, code, body)
		return
	}

	writeJSON(w, http.StatusOK, tryonResponse{
		Image:    base64.StdEncoding.EncodeToString(image),
		MimeType: mimeType,
		Lease:    leaseFor(r),
	})

	// Analytics: zero content — lengths, counts, flags, timings, outcome.
	clientOS, clientVersion := parseClient(r.Header.Get(clientHeader))
	id, _ := caller.From(r.Context())
	props := map[string]any{
		"os":               clientOS,
		"app_version":      clientVersion,
		"item_length":      len(item),
		"query_length":     len(req.Query),
		"had_context":      req.Context.App != "" || req.Context.Window != "",
		"image_bytes":      len(image),
		"mime_type":        mimeType,
		"model":            s.TryonModel,
		"latency_total_ms": time.Since(started).Milliseconds(),
		// Token usage from the provider (zero when unreported), so cost per
		// image is measured, not estimated.
		"prompt_tokens": usage.PromptTokens,
		"output_tokens": usage.OutputTokens,
		"total_tokens":  usage.TotalTokens,
	}
	s.Analytics.Capture(analytics.Event{
		Name:       "tryon",
		DistinctID: id.MeterKey(),
		Properties: props,
		PersonProperties: map[string]any{
			"os":          clientOS,
			"app_version": clientVersion,
		},
	})

	// Also to the gateway log, so cost per image is greppable during
	// calibration without opening the analytics dashboard.
	s.Logger.Info("tryon image",
		"model", s.TryonModel,
		"mime_type", mimeType,
		"prompt_tokens", usage.PromptTokens,
		"output_tokens", usage.OutputTokens,
		"total_tokens", usage.TotalTokens,
		"latency_ms", time.Since(started).Milliseconds())
}
