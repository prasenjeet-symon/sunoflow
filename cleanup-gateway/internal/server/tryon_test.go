package server

import (
	"context"
	"encoding/base64"
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

// 1x1 PNG bytes, base64 — decodeImage only checks base64 + size.
const tryonTestImage = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

// tryonTestBackend implements backend.Backend + backend.TryonBackend over a
// scripted image.
type tryonTestBackend struct {
	fakeBackend
	image    []byte
	mimeType string
	usage    backend.Usage
	err      error
}

func (t *tryonTestBackend) TryOn(_ context.Context, prompt string, person, garment []byte) ([]byte, string, backend.Usage, error) {
	t.calls = append(t.calls, fmt.Sprintf("%s|person=%d|garment=%d", prompt, len(person), len(garment)))
	if t.err != nil {
		return nil, "", backend.Usage{}, t.err
	}
	return t.image, t.mimeType, t.usage, nil
}

func (t *tryonTestBackend) TryonName() string { return "gemini" }

// newTryonServer wires a mux with the tryon limiter enabled (3 rpm / 20 daily
// / 40 hard) and the scripted tryon backend, using the same in-memory store +
// issued key setup as newTestServer.
func newTryonServer(t *testing.T, tb backend.Backend) (*httptest.Server, string) {
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
		Backend:    tb,
		Store:      st,
		Logger:     testLogger(),
		QuotaRPM:   1000,
		QuotaDaily: 100000,
		TryonModel: "test-tryon-model",
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	tryonLimiter := ratelimit.NewTryon(st, 3, 20, 40, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, nil, nil, nil, tryonLimiter, "admin-secret", nil))
	t.Cleanup(ts.Close)
	return ts, plaintext
}

// newTryonServerWithQuotas is newTryonServer with explicit tryon limiter
// quotas, for the limit tests.
func newTryonServerWithQuotas(t *testing.T, tb backend.Backend, rpm, daily, hard int) (*httptest.Server, string) {
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
		Backend:    tb,
		Store:      st,
		Logger:     testLogger(),
		QuotaRPM:   1000,
		QuotaDaily: 100000,
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	tryonLimiter := ratelimit.NewTryon(st, rpm, daily, hard, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, nil, nil, nil, tryonLimiter, "admin-secret", nil))
	t.Cleanup(ts.Close)
	return ts, plaintext
}

func postTryon(t *testing.T, ts *httptest.Server, key, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/tryon", strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("post /tryon: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func TestTryon_OK(t *testing.T) {
	out := []byte{0x89, 'P', 'N', 'G'}
	tb := &tryonTestBackend{image: out, mimeType: "image/png"}
	ts, key := newTryonServer(t, tb)

	body := `{"person":"` + tryonTestImage + `","garment":"` + tryonTestImage + `","item":"the grey hoodie","query":"how would I look?","context":{"app":"Safari","window":"Hoodie"}}`
	resp := postTryon(t, ts, key, body)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var outBody map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&outBody); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if outBody["mime_type"] != "image/png" {
		t.Errorf("mime_type = %v", outBody["mime_type"])
	}
	img, _ := outBody["image"].(string)
	if got, err := base64.StdEncoding.DecodeString(img); err != nil || string(got) != string(out) {
		t.Errorf("image round-trip failed: %v", err)
	}
	// The lease rides the 200 only when the account middleware put one in
	// context (the local-store test path has none) — same shape as /control.

	// The prompt reached the backend with both images, under the framing.
	if len(tb.calls) != 1 {
		t.Fatalf("calls = %d", len(tb.calls))
	}
	if !strings.Contains(tb.calls[0], "The first image shows a person") {
		t.Errorf("prompt framing missing: %q", tb.calls[0][:80])
	}
	if !strings.Contains(tb.calls[0], "the grey hoodie") {
		t.Errorf("item missing from prompt")
	}
	if !strings.Contains(tb.calls[0], "how would I look?") {
		t.Errorf("query missing from prompt")
	}
	if !strings.Contains(tb.calls[0], "App: Safari") {
		t.Errorf("context missing from prompt")
	}
	if !strings.Contains(tb.calls[0], "person=70|garment=70") {
		t.Errorf("both images must ride as parts: %q", tb.calls[0][len(tb.calls[0])-60:])
	}
}

func TestTryon_MissingImagesRejected(t *testing.T) {
	tb := &tryonTestBackend{image: []byte("x"), mimeType: "image/png"}
	// Generous quotas: these tests exercise validation, not limiting (several
	// requests would otherwise trip the 3-rpm default bucket).
	ts, key := newTryonServerWithQuotas(t, tb, 1000, 100000, 100000)

	// Empty person → 400.
	resp := postTryon(t, ts, key, `{"person":"","garment":"`+tryonTestImage+`","item":"a hat"}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("empty person: status = %d", resp.StatusCode)
	}
	// Empty garment → 400.
	resp = postTryon(t, ts, key, `{"person":"`+tryonTestImage+`","garment":"","item":"a hat"}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("empty garment: status = %d", resp.StatusCode)
	}
	// Bad base64 → 400.
	resp = postTryon(t, ts, key, `{"person":"!!!not base64","garment":"`+tryonTestImage+`","item":"a hat"}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad base64: status = %d", resp.StatusCode)
	}
	// Empty item → 400.
	resp = postTryon(t, ts, key, `{"person":"`+tryonTestImage+`","garment":"`+tryonTestImage+`","item":"  "}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("empty item: status = %d", resp.StatusCode)
	}
	// Malformed JSON → 400.
	resp = postTryon(t, ts, key, `{not json`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("malformed json: status = %d", resp.StatusCode)
	}
	// The backend must never have been called.
	if len(tb.calls) != 0 {
		t.Fatalf("backend called %d times on rejected requests", len(tb.calls))
	}
}

func TestTryon_NoBackend501(t *testing.T) {
	// fakeBackend alone does not implement TryonBackend → 501.
	ts, key := newTryonServer(t, &fakeBackend{})
	resp := postTryon(t, ts, key, `{"person":"`+tryonTestImage+`","garment":"`+tryonTestImage+`","item":"a hat"}`)
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("status = %d, want 501", resp.StatusCode)
	}
}

func TestTryon_BackendFailure502(t *testing.T) {
	tb := &tryonTestBackend{err: errBackendDown}
	ts, key := newTryonServer(t, tb)
	resp := postTryon(t, ts, key, `{"person":"`+tryonTestImage+`","garment":"`+tryonTestImage+`","item":"a hat"}`)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
	var out map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out["error"] != "unavailable" {
		t.Errorf("error = %q", out["error"])
	}
}

func TestTryon_SafetyBlock502(t *testing.T) {
	tb := &tryonTestBackend{err: backend.ErrSafetyBlock}
	ts, key := newTryonServer(t, tb)
	resp := postTryon(t, ts, key, `{"person":"`+tryonTestImage+`","garment":"`+tryonTestImage+`","item":"a hat"}`)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
	var out map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out["error"] != "safety_block" {
		t.Errorf("error = %q, want safety_block", out["error"])
	}
}

func TestTryon_DailyLimit429(t *testing.T) {
	// daily=2: the third request hits the limit.
	tb := &tryonTestBackend{image: []byte("x"), mimeType: "image/png"}
	ts, key := newTryonServerWithQuotas(t, tb, 1000, 2, 100000)

	for i := 0; i < 2; i++ {
		resp := postTryon(t, ts, key, `{"person":"`+tryonTestImage+`","garment":"`+tryonTestImage+`","item":"a hat"}`)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("request %d: status = %d", i, resp.StatusCode)
		}
	}
	resp := postTryon(t, ts, key, `{"person":"`+tryonTestImage+`","garment":"`+tryonTestImage+`","item":"a hat"}`)
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", resp.StatusCode)
	}
	if ra := resp.Header.Get("Retry-After"); ra != "60" {
		t.Errorf("Retry-After = %q, want 60 (daily)", ra)
	}
	var out map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out["error"] != "limit" {
		t.Errorf("error = %q", out["error"])
	}
}

func TestTryon_RequiresAuth(t *testing.T) {
	tb := &tryonTestBackend{image: []byte("x"), mimeType: "image/png"}
	ts, _ := newTryonServer(t, tb)
	resp := postTryon(t, ts, "not-a-real-key", `{"person":"`+tryonTestImage+`","garment":"`+tryonTestImage+`","item":"a hat"}`)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
}
