package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sunoflow/cleanup-gateway/internal/auth"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// controlTestBackend implements backend.Backend + backend.ControlBackend over
// a scripted reply. fakeBackend is embedded by value (its methods have pointer
// receivers and promote through the addressable field).
type controlTestBackend struct {
	fakeBackend
	reply string
	usage backend.Usage
	err   error
}

func (c *controlTestBackend) PlanAction(_ context.Context, prompt string, image []byte) (string, backend.Usage, error) {
	c.calls = append(c.calls, fmt.Sprintf("%s|image=%d", prompt, len(image)))
	if c.err != nil {
		return "", backend.Usage{}, c.err
	}
	return c.reply, c.usage, nil
}

// newControlServer wires a mux with the control limiter enabled (20 rpm / 200
// daily / 300 hard) and the scripted control backend, using the same
// in-memory store + issued key setup as newTestServer.
func newControlServer(t *testing.T, cb backend.Backend) (*httptest.Server, string) {
	t.Helper()
	st, err := store.New(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	id, plaintext, hash, err := auth.IssueKey()
	if err != nil {
		t.Fatalf("issue key: %v", err)
	}
	if err := st.CreateKey(context.Background(), id, hash, "test", 1000, 100000); err != nil {
		t.Fatalf("create key: %v", err)
	}

	srv := &Server{
		Backend:      cb,
		Store:        st,
		Logger:       testLogger(),
		QuotaRPM:     1000,
		QuotaDaily:   100000,
		ControlModel: "test-control-model",
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	controlLimiter := ratelimit.NewControl(st, 20, 200, 300, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, nil, nil, controlLimiter, "admin-secret", nil))
	t.Cleanup(ts.Close)
	return ts, plaintext
}

func postControl(t *testing.T, ts *httptest.Server, key, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/control", strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post /control: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func TestControl_OK(t *testing.T) {
	cb := &controlTestBackend{reply: `{"action":"click","x":100,"y":50,"note":"open Calculator"}`}
	ts, key := newControlServer(t, cb)

	body := `{"goal":"open calculator","steps":[],"image":"","context":{}}`
	resp := postControl(t, ts, key, body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out["action"] != "click" {
		t.Errorf("action = %v", out["action"])
	}
	if out["x"].(float64) != 100 || out["y"].(float64) != 50 {
		t.Errorf("coords = %v %v", out["x"], out["y"])
	}
	if out["note"] != "open Calculator" {
		t.Errorf("note = %v", out["note"])
	}

	// The prompt reached the backend with the goal in it, under the goal header.
	if len(cb.calls) != 1 {
		t.Fatalf("calls = %d", len(cb.calls))
	}
	if !strings.Contains(cb.calls[0], "[GOAL]\nopen calculator") {
		t.Errorf("prompt missing goal: %.200q", cb.calls[0])
	}
}

func TestControl_OSRidesToPrompt(t *testing.T) {
	cb := &controlTestBackend{reply: `{"action":"done","note":"ok"}`}
	ts, key := newControlServer(t, cb)

	resp := postControl(t, ts, key, `{"goal":"g","context":{"os":"macOS 15.5 · arm64"}}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if len(cb.calls) != 1 {
		t.Fatalf("calls = %d", len(cb.calls))
	}
	if !strings.Contains(cb.calls[0], "Target operating system: macOS 15.5 · arm64") {
		t.Errorf("client-reported OS missing from prompt: %.300q", cb.calls[0])
	}
}

func TestControl_LeaseAndOmittedFields(t *testing.T) {
	// done: only note rides; the omitted optional fields must not appear in
	// the JSON at all (omitempty). Lease only rides when the account
	// middleware minted one — these tests run against the legacy key table,
	// so lease must be absent here (omitempty) rather than empty-string.
	cb := &controlTestBackend{reply: `{"action":"done","note":"finished"}`}
	ts, key := newControlServer(t, cb)

	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var raw map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if raw["action"] != "done" {
		t.Errorf("action = %v", raw["action"])
	}
	for _, k := range []string{"x", "y", "x2", "y2", "text", "key", "modifiers", "direction", "amount", "seconds"} {
		if _, ok := raw[k]; ok {
			t.Errorf("%s should be omitted on done: %v", k, raw)
		}
	}
	if _, ok := raw["lease"]; ok {
		t.Errorf("lease should be omitted without the account middleware: %v", raw)
	}
}

func TestControl_UsageInResponse(t *testing.T) {
	cb := &controlTestBackend{
		reply: `{"action":"click","x":10,"y":20,"note":"tap"}`,
		usage: backend.Usage{PromptTokens: 1503, OutputTokens: 48, ThinkingTokens: 214, TotalTokens: 1765},
	}
	ts, key := newControlServer(t, cb)
	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var out struct {
		Usage *struct {
			PromptTokens   int `json:"prompt_tokens"`
			OutputTokens   int `json:"output_tokens"`
			ThinkingTokens int `json:"thinking_tokens"`
			TotalTokens    int `json:"total_tokens"`
		} `json:"usage"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Usage == nil {
		t.Fatal("usage block missing from response")
	}
	if out.Usage.PromptTokens != 1503 || out.Usage.OutputTokens != 48 ||
		out.Usage.ThinkingTokens != 214 || out.Usage.TotalTokens != 1765 {
		t.Errorf("usage = %+v", out.Usage)
	}
}

func TestControl_UsageOmittedWhenZero(t *testing.T) {
	// No usage reported → the block is omitted (omitempty), not an empty object.
	cb := &controlTestBackend{reply: `{"action":"done","note":"ok"}`}
	ts, key := newControlServer(t, cb)
	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	var raw map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&raw)
	if _, ok := raw["usage"]; ok {
		t.Errorf("usage should be omitted when zero: %v", raw)
	}
}

func TestControl_Malformed(t *testing.T) {
	cb := &controlTestBackend{reply: `{}`}
	ts, key := newControlServer(t, cb)

	tests := []struct {
		name string
		body string
		want string
	}{
		{"bad json", `{"goal":`, "malformed json"},
		{"empty goal", `{"goal":"   ","context":{}}`, "malformed request"},
		{"bad image", `{"goal":"g","image":"!!!notbase64","context":{}}`, "malformed request"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp := postControl(t, ts, key, tt.body)
			if resp.StatusCode != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", resp.StatusCode)
			}
			var out map[string]string
			_ = json.NewDecoder(resp.Body).Decode(&out)
			if out["error"] != tt.want {
				t.Errorf("error = %q, want %q", out["error"], tt.want)
			}
		})
	}
}

func TestControl_BackendError(t *testing.T) {
	cb := &controlTestBackend{err: errBackendDown}
	ts, key := newControlServer(t, cb)

	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
	var out map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out["error"] != "unavailable" {
		t.Errorf("error = %q", out["error"])
	}
}

// A safety block is NOT an outage: the client gets a distinct error code plus
// the rephrase guidance, so the capsule can say the planner declined this goal
// instead of "unavailable right now".
func TestControl_SafetyBlock(t *testing.T) {
	cb := &controlTestBackend{err: fmt.Errorf("wrapped: %w", backend.ErrSafetyBlock)}
	ts, key := newControlServer(t, cb)

	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
	var out map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out["error"] != "safety_block" {
		t.Errorf("error = %q, want safety_block", out["error"])
	}
	if !strings.Contains(out["message"], "declined") {
		t.Errorf("message = %q, want rephrase guidance", out["message"])
	}
}

func TestControl_UnparseableReply(t *testing.T) {
	cb := &controlTestBackend{reply: "I cannot do that, sorry."}
	ts, key := newControlServer(t, cb)

	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
	var out map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out["error"] != "unavailable" {
		t.Errorf("error = %q", out["error"])
	}
}

func TestControl_StepsCapped(t *testing.T) {
	cb := &controlTestBackend{reply: `{"action":"done","note":"ok"}`}
	ts, key := newControlServer(t, cb)

	var steps []map[string]string
	for i := 0; i < 130; i++ {
		steps = append(steps, map[string]string{"action": "click", "note": fmt.Sprintf("step %03d", i)})
	}
	b, _ := json.Marshal(map[string]any{"goal": "g", "steps": steps, "context": map[string]any{}})
	resp := postControl(t, ts, key, string(b))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	// The prompt must contain only the last MaxSteps=100 steps.
	prompt := cb.calls[0]
	if strings.Contains(prompt, "step 029") {
		t.Error("old steps leaked into the prompt")
	}
	if !strings.Contains(prompt, "step 030") || !strings.Contains(prompt, "step 129") {
		t.Error("recent steps missing from the prompt")
	}
	if strings.Contains(prompt, "101. ") {
		t.Error("more than 100 steps rendered into the prompt")
	}
}

func TestControl_ImageRidesAsPart(t *testing.T) {
	cb := &controlTestBackend{reply: `{"action":"move","x":1,"y":2,"note":"n"}`}
	ts, key := newControlServer(t, cb)

	// 1x1 PNG bytes, base64 — decodeImage only checks base64 + size.
	img := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
	resp := postControl(t, ts, key, `{"goal":"g","image":"`+img+`","context":{}}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if !strings.Contains(cb.calls[0], "image=70") {
		t.Errorf("image bytes not forwarded: %.120q", cb.calls[0])
	}
}

func TestControl_NoBackend(t *testing.T) {
	// A backend that implements only Backend (fakeBackend) → 501.
	ts, key := newControlServer(t, &fakeBackend{})
	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("status = %d, want 501", resp.StatusCode)
	}
}

func TestControl_Limit(t *testing.T) {
	cb := &controlTestBackend{reply: `{"action":"done","note":"ok"}`}
	ts, key := newControlServerWithQuotas(t, cb, 1, 1000, 100000) // 1 step/minute

	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("first status = %d", resp.StatusCode)
	}
	resp = postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("second status = %d, want 429", resp.StatusCode)
	}
	if ra := resp.Header.Get("Retry-After"); ra != "1" {
		t.Errorf("Retry-After = %q, want 1 (per-minute)", ra)
	}
	var out map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out["error"] != "limit" {
		t.Errorf("error = %q", out["error"])
	}
}

func TestControl_DailyQuota(t *testing.T) {
	cb := &controlTestBackend{reply: `{"action":"done","note":"ok"}`}
	ts, key := newControlServerWithQuotas(t, cb, 1000, 2, 100000) // 2 steps/day

	for i := 0; i < 2; i++ {
		if resp := postControl(t, ts, key, `{"goal":"g","context":{}}`); resp.StatusCode != http.StatusOK {
			t.Fatalf("call %d status = %d", i, resp.StatusCode)
		}
	}
	resp := postControl(t, ts, key, `{"goal":"g","context":{}}`)
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", resp.StatusCode)
	}
	if ra := resp.Header.Get("Retry-After"); ra != "60" {
		t.Errorf("Retry-After = %q, want 60 (daily)", ra)
	}
}

func TestControl_NormalizedCoords(t *testing.T) {
	st, err := store.New(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, plaintext, hash, err := auth.IssueKey()
	if err != nil {
		t.Fatalf("issue key: %v", err)
	}
	if err := st.CreateKey(context.Background(), id, hash, "test", 1000, 100000); err != nil {
		t.Fatalf("create key: %v", err)
	}

	// The model answers in the 0-1000 normalized space (Gemini spatial dialect).
	cb := &controlTestBackend{reply: `{"action":"click","x":500,"y":250,"note":"center-ish"}`}
	srv := &Server{
		Backend: cb, Store: st, Logger: testLogger(),
		QuotaRPM: 1000, QuotaDaily: 100000,
		ControlModel: "test", ControlCoordSpace: "normalized",
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	controlLimiter := ratelimit.NewControl(st, 1000, 100000, 1000000, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, nil, nil, controlLimiter, "admin-secret", nil))
	t.Cleanup(ts.Close)

	// 1x1 PNG so an image rides (the coordinate rule is only emitted with one);
	// context reports the real 1600x1000 size the conversion uses.
	img := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
	body := `{"goal":"g","image":"` + img + `","context":{"image_width":1600,"image_height":1000}}`
	resp := postControl(t, ts, plaintext, body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// 500/1000*1600 = 800 ; 250/1000*1000 = 250. The client only ever sees pixels.
	if out["x"].(float64) != 800 || out["y"].(float64) != 250 {
		t.Errorf("denormalized coords = %v,%v want 800,250", out["x"], out["y"])
	}
	// The prompt asked for 0-1000, not pixels.
	if !strings.Contains(cb.calls[0], "from 0 to 1000") {
		t.Errorf("normalized prompt not used: %.200q", cb.calls[0])
	}
}

func TestControl_ToolMode(t *testing.T) {
	st, err := store.New(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, plaintext, hash, err := auth.IssueKey()
	if err != nil {
		t.Fatalf("issue key: %v", err)
	}
	if err := st.CreateKey(context.Background(), id, hash, "test", 1000, 100000); err != nil {
		t.Fatalf("create key: %v", err)
	}

	// The fake backend stands in for the real GeminiBackend's computer_use
	// mapping (unit-tested in the backend package): it returns the flat action
	// JSON the mapping would produce, with 0-999 coords.
	cb := &controlTestBackend{reply: `{"action":"click","x":500,"y":250,"note":"tap"}`}
	srv := &Server{
		Backend: cb, Store: st, Logger: testLogger(),
		QuotaRPM: 1000, QuotaDaily: 100000,
		ControlModel: "test", ControlUseTool: true, // tool mode implies normalized
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	controlLimiter := ratelimit.NewControl(st, 1000, 100000, 1000000, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, nil, nil, controlLimiter, "admin-secret", nil))
	t.Cleanup(ts.Close)

	img := "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
	body := `{"goal":"g","image":"` + img + `","context":{"image_width":1600,"image_height":1000}}`
	resp := postControl(t, ts, plaintext, body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// Tool mode forces normalized: 500/1000*1600 = 800, 250/1000*1000 = 250.
	if out["x"].(float64) != 800 || out["y"].(float64) != 250 {
		t.Errorf("coords = %v,%v want 800,250", out["x"], out["y"])
	}
	// The TOOL prompt must have been sent (no JSON schema, references the tool).
	if !strings.Contains(cb.calls[0], "computer tool") {
		t.Errorf("tool prompt not used: %.200q", cb.calls[0])
	}
	if strings.Contains(cb.calls[0], "EXACTLY one JSON object") {
		t.Errorf("JSON-schema prompt used in tool mode: %.200q", cb.calls[0])
	}
}

// newControlServerWithQuotas is newControlServer with explicit limiter
// quotas for the quota tests.
func newControlServerWithQuotas(t *testing.T, cb backend.Backend, rpm, daily, hard int) (*httptest.Server, string) {
	t.Helper()
	st, err := store.New(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	id, plaintext, hash, err := auth.IssueKey()
	if err != nil {
		t.Fatalf("issue key: %v", err)
	}
	if err := st.CreateKey(context.Background(), id, hash, "test", 1000, 100000); err != nil {
		t.Fatalf("create key: %v", err)
	}

	srv := &Server{
		Backend:    cb,
		Store:      st,
		Logger:     testLogger(),
		QuotaRPM:   1000,
		QuotaDaily: 100000,
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	controlLimiter := ratelimit.NewControl(st, rpm, daily, hard, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, nil, nil, controlLimiter, "admin-secret", nil))
	t.Cleanup(ts.Close)
	return ts, plaintext
}
