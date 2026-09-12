package server

// The Suno Control route: POST /control plans exactly ONE action from the
// current screen. The sidecar proxies it byte-for-byte, so the wire contract
// here is the wire contract the Swift client sees:
//
//	POST /control  {"goal","steps":[{"action","note"}],"image","context"}
//	200            flat action JSON: {"action","x","y",...,"note","lease"}
//	400            {"error":"malformed json"|"malformed request","message":...}
//	402-class      from the account middleware (same entitlement as /cleanup)
//	429            {"error":"limit"} + Retry-After (60=daily/hard, 1=per-minute)
//	502            {"error":"unavailable"} — backend failure or unparseable plan
//
// It is a NON-streaming one-shot (unlike /answer): the client loop calls it
// once per step. No raw fallback ever — if the planner cannot answer with a
// valid action the loop stops; moving the user's cursor on a guess is the one
// thing this endpoint must never do.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image"
	_ "image/jpeg" // register JPEG for image.DecodeConfig (the screen image)
	_ "image/png"  // register PNG too, for parity with test fixtures
	"net/http"
	"strings"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/analytics"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/caller"
	"github.com/sunoflow/cleanup-gateway/internal/cleanup"
	"github.com/sunoflow/cleanup-gateway/internal/control"
)

// maxControlBody caps the /control request body at 4MB — same budget as
// /answer: a 1600px JPEG screenshot (base64) plus prompt text with headroom.
const maxControlBody = 4 << 20

// controlRequest mirrors the /control API contract.
type controlRequest struct {
	// Goal is the user's dictated goal for this run.
	Goal string `json:"goal"`
	// Steps are the actions already taken this run, oldest first. Empty on
	// step one.
	Steps []control.Step `json:"steps"`
	// ImageB64 is the current screen, base64 JPEG. Empty means "no image" —
	// legal (the planner still answers, e.g. failed), though a run should
	// always carry one.
	ImageB64 string `json:"image"`
	// Dictionary is the user's own terms relevant to the goal, selected by
	// the sidecar from its local corrections file.
	Dictionary []cleanup.Entry `json:"dictionary"`
	// Context is what the client observed: frontmost app, focused window
	// title, cursor position in the screenshot's pixel space, and the
	// screenshot's dimensions (the client converts action coordinates to
	// screen points with them).
	Context controlContext `json:"context"`
}

// controlContext is the observed context block of a /control request.
type controlContext struct {
	App    string `json:"app"`
	Window string `json:"window"`
	// OS is the host operating system as the client reported it (name,
	// version, build, architecture). It pins the platform conventions the
	// planner must use; empty when the client is older and does not send it.
	OS          string `json:"os"`
	CursorX     *int   `json:"cursor_x"`
	CursorY     *int   `json:"cursor_y"`
	ImageWidth  *int   `json:"image_width"`
	ImageHeight *int   `json:"image_height"`
}

// controlResponse is the 200 body: the action fields flat, plus the lease.
type controlResponse struct {
	Action     string   `json:"action"`
	X          *int     `json:"x,omitempty"`
	Y          *int     `json:"y,omitempty"`
	X2         *int     `json:"x2,omitempty"`
	Y2         *int     `json:"y2,omitempty"`
	Text       *string  `json:"text,omitempty"`
	Key        *string  `json:"key,omitempty"`
	Modifiers  []string `json:"modifiers,omitempty"`
	Direction  *string  `json:"direction,omitempty"`
	Amount     *int     `json:"amount,omitempty"`
	Seconds    *float64 `json:"seconds,omitempty"`
	Note       *string  `json:"note,omitempty"`
	PressEnter *bool    `json:"press_enter,omitempty"`
	Lease      string   `json:"lease,omitempty"`
	// Usage is this step's token accounting, so the client can log per-step
	// cost. Omitted when the provider reported nothing (all zero).
	Usage *usageResponse `json:"usage,omitempty"`
}

// usageResponse is the per-step token block echoed to the client (for the
// control log). Mirrors backend.Usage; thinking tokens are billed as output
// but kept separate for visibility.
type usageResponse struct {
	PromptTokens   int `json:"prompt_tokens"`
	OutputTokens   int `json:"output_tokens"`
	ThinkingTokens int `json:"thinking_tokens"`
	TotalTokens    int `json:"total_tokens"`
}

// controlImageDims returns the screen image's pixel size for normalized→pixel
// conversion: the client-reported dimensions when present and sane, otherwise
// the image's own header, otherwise (0,0) — in which case the caller skips
// conversion rather than emit a wrong coordinate.
func controlImageDims(ctx controlContext, img []byte) (int, int) {
	if ctx.ImageWidth != nil && ctx.ImageHeight != nil && *ctx.ImageWidth > 0 && *ctx.ImageHeight > 0 {
		return *ctx.ImageWidth, *ctx.ImageHeight
	}
	if len(img) > 0 {
		if cfg, _, err := image.DecodeConfig(bytes.NewReader(img)); err == nil {
			return cfg.Width, cfg.Height
		}
	}
	return 0, 0
}

// controlBackend returns the control seam, or nil when the configured backend
// cannot plan actions (then /control answers 501).
func (s *Server) controlBackend() backend.ControlBackend {
	if cb, ok := s.Backend.(backend.ControlBackend); ok {
		return cb
	}
	return nil
}

// handleControl is the Suno Control endpoint. Authentication and the control
// quota run in the middleware chain; everything here is the one-shot plan.
func (s *Server) handleControl(w http.ResponseWriter, r *http.Request) {
	started := time.Now()

	cb := s.controlBackend()
	if cb == nil {
		writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "unavailable", "message": "no control backend"})
		return
	}

	// Read the body under the per-route cap.
	var req controlRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxControlBody)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed json"})
		return
	}
	goal := strings.TrimSpace(req.Goal)
	if goal == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": "empty goal"})
		return
	}

	// The screen image: like /answer, an absent one is legal (a text-only
	// turn — the planner may still answer failed), anything present must be
	// base64 JPEG under the cap.
	image, err := decodeImage(req.ImageB64)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed request", "message": err.Error()})
		return
	}

	dict := cleanup.NormalizeDict(req.Dictionary)
	if len(dict) > control.MaxDictEntries {
		dict = dict[:control.MaxDictEntries]
	}

	// Which coordinate dialect the configured model speaks. Tool mode (native
	// computer_use) always answers 0-999, so it implies normalized; otherwise
	// it follows CONTROL_COORD_SPACE. Normalized coords are converted back to
	// image pixels below, so the client only ever sees pixels.
	normalized := s.ControlUseTool || strings.EqualFold(s.ControlCoordSpace, "normalized")

	// Build the prompt: framing → [SCREEN] → [STEPS ALREADY TAKEN] →
	// [DICTIONARY] → [GOAL] → context line. Tool mode drops the JSON schema and
	// coordinate rule (the tool defines both).
	steps := req.Steps
	if len(steps) > control.MaxSteps {
		steps = steps[len(steps)-control.MaxSteps:]
	}
	promptInput := control.Prompt{
		Goal:        goal,
		Steps:       steps,
		Dictionary:  dict,
		App:         req.Context.App,
		Window:      req.Context.Window,
		OS:          req.Context.OS,
		CursorX:     req.Context.CursorX,
		CursorY:     req.Context.CursorY,
		ImageWidth:  req.Context.ImageWidth,
		ImageHeight: req.Context.ImageHeight,
		Image:       len(image) > 0,
		Normalized:  normalized,
	}
	buildPrompt := control.BuildPrompt
	if s.ControlUseTool {
		buildPrompt = control.BuildToolPrompt
	}
	promptText := strings.Join(buildPrompt(promptInput), "\n")

	text, usage, err := cb.PlanAction(r.Context(), promptText, image)
	if err != nil {
		// A safety block is not an outage: the filter declined this specific
		// goal, so the client should say so (and the user can rephrase)
		// instead of "try again shortly". Report a distinct error code with a
		// fixed message; never echo prompt/goal content back.
		if errors.Is(err, backend.ErrSafetyBlock) {
			s.Logger.Warn("control plan blocked by safety filter")
			writeJSON(w, http.StatusBadGateway, map[string]string{
				"error":   "safety_block",
				"message": "Suno Control's AI planner declined this goal. Try phrasing it differently.",
			})
			return
		}
		s.Logger.Warn("control plan failed", "err", err.Error())
		code := http.StatusBadGateway
		body := map[string]string{"error": "unavailable"}
		if errors.Is(err, context.DeadlineExceeded) {
			body["message"] = "timed out"
		}
		writeJSON(w, code, body)
		return
	}

	action, err := control.ParseAction(text)
	if err != nil {
		// The planner spoke, but not in our vocabulary. This is a backend
		// failure for the loop's purposes: 502, no action, the client stops.
		s.Logger.Warn("control plan unparseable", "err", err.Error())
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "unavailable"})
		return
	}

	// Normalized models answer 0-1000 per axis; convert to image pixels so the
	// response carries the same pixel coordinates the pixel dialect does — the
	// client's executor is identical either way. Needs the image's size: the
	// client reports it, and the image header is the fallback.
	if normalized {
		if w, h := controlImageDims(req.Context, image); w > 0 && h > 0 {
			action.Denormalize(w, h)
		}
	}

	// Echo token usage to the client (control log) only when the provider
	// actually reported it, so omitempty drops the block otherwise.
	var usageResp *usageResponse
	if usage.TotalTokens > 0 || usage.PromptTokens > 0 {
		usageResp = &usageResponse{
			PromptTokens:   usage.PromptTokens,
			OutputTokens:   usage.OutputTokens,
			ThinkingTokens: usage.ThinkingTokens,
			TotalTokens:    usage.TotalTokens,
		}
	}

	writeJSON(w, http.StatusOK, controlResponse{
		Action:     action.Name,
		X:          action.X,
		Y:          action.Y,
		X2:         action.X2,
		Y2:         action.Y2,
		Text:       action.Text,
		Key:        action.Key,
		Modifiers:  action.Modifiers,
		Direction:  action.Direction,
		Amount:     action.Amount,
		Seconds:    action.Seconds,
		Note:       action.Note,
		PressEnter: action.PressEnter,
		Lease:      leaseFor(r),
		Usage:      usageResp,
	})

	// Analytics: zero content — lengths, counts, flags, timings, outcome.
	clientOS, clientVersion := parseClient(r.Header.Get(clientHeader))
	id, _ := caller.From(r.Context())
	props := map[string]any{
		"os":               clientOS,
		"app_version":      clientVersion,
		"had_image":        len(image) > 0,
		"step_index":       len(req.Steps),
		"goal_length":      len(goal),
		"action":           action.Name,
		"model":            s.ControlModel,
		"tool":             s.ControlUseTool,
		"latency_total_ms": time.Since(started).Milliseconds(),
		// Per-step token usage from the provider (zero when unreported), so cost
		// per step is measured, not estimated. Thinking tokens are billed as
		// output but reported apart from the visible answer.
		"prompt_tokens":   usage.PromptTokens,
		"output_tokens":   usage.OutputTokens,
		"thinking_tokens": usage.ThinkingTokens,
		"total_tokens":    usage.TotalTokens,
	}
	s.Analytics.Capture(analytics.Event{
		Name:       "control",
		DistinctID: id.MeterKey(),
		Properties: props,
		PersonProperties: map[string]any{
			"os":          clientOS,
			"app_version": clientVersion,
		},
	})

	// Also to the gateway log, so token usage per step is greppable during
	// calibration without opening the analytics dashboard.
	s.Logger.Info("control step",
		"model", s.ControlModel,
		"action", action.Name,
		"prompt_tokens", usage.PromptTokens,
		"output_tokens", usage.OutputTokens,
		"thinking_tokens", usage.ThinkingTokens,
		"total_tokens", usage.TotalTokens,
		"latency_ms", time.Since(started).Milliseconds())
}
