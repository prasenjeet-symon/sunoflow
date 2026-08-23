package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sunoflow/cleanup-gateway/internal/auth"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// fakeBackend is a controllable test backend implementing backend.Backend.
type fakeBackend struct {
	resp   string
	err    error
	health bool
	calls  []string
}

func (f *fakeBackend) Cleanup(_ context.Context, prompt string) (string, error) {
	f.calls = append(f.calls, prompt)
	if f.err != nil {
		return "", f.err
	}
	return f.resp, nil
}
func (f *fakeBackend) Name() string                   { return "fake" }
func (f *fakeBackend) Healthy(_ context.Context) bool { return f.health }

var errBackendDown = errors.New("backend down")

// newTestServer spins up an in-memory store + limiter + mux backed by fakeBackend.
func newTestServer(t *testing.T, fb *fakeBackend) (*httptest.Server, *store.Store, string) {
	t.Helper()
	st, err := store.New(":memory:")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	// Issue a real key so auth passes.
	id, plaintext, hash, err := auth.IssueKey()
	if err != nil {
		t.Fatalf("issue key: %v", err)
	}
	if err := st.CreateKey(context.Background(), id, hash, "test", 1000, 100000); err != nil {
		t.Fatalf("create key: %v", err)
	}

	srv := &Server{
		Backend:    fb,
		Store:      st,
		Logger:     testLogger(),
		QuotaRPM:   1000,
		QuotaDaily: 100000,
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	handler := NewMux(srv, limiter, "admin-secret", nil)
	ts := httptest.NewServer(handler)
	t.Cleanup(ts.Close)
	return ts, st, plaintext
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError + 1}))
}

func TestCleanup_EmptyText(t *testing.T) {
	fb := &fakeBackend{}
	ts, _, key := newTestServer(t, fb)
	body, _ := json.Marshal(map[string]string{"text": "   "})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var out cleanupResponse
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Cleaned != "" {
		t.Errorf("expected empty cleaned, got %q", out.Cleaned)
	}
	if len(fb.calls) != 0 {
		t.Errorf("backend should not be called for empty text, got %d calls", len(fb.calls))
	}
}

func TestCleanup_Success(t *testing.T) {
	fb := &fakeBackend{resp: "So I think we should ship this on Friday."}
	ts, _, key := newTestServer(t, fb)
	body, _ := json.Marshal(map[string]string{"text": "um so I think we should um ship this on friday"})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var out cleanupResponse
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Cleaned != "So I think we should ship this on Friday." {
		t.Errorf("unexpected cleaned: %q", out.Cleaned)
	}
}

func TestCleanup_FallbackOnBackendError(t *testing.T) {
	fb := &fakeBackend{err: errBackendDown}
	ts, _, key := newTestServer(t, fb)
	raw := "um so I think we should ship this on friday"
	body, _ := json.Marshal(map[string]string{"text": raw})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	// Must be 200 with the raw text — never an error status.
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 on backend failure, got %d", resp.StatusCode)
	}
	var out cleanupResponse
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Cleaned != raw {
		t.Errorf("expected raw fallback %q, got %q", raw, out.Cleaned)
	}
}

func TestCleanup_EchoRetry(t *testing.T) {
	// First call returns an echo of the context tail; second (context-free) call
	// returns a clean, length-ok result. Verifies the retry path.
	text := "the new transcript words here"
	context := strings.Repeat("x", 80) // long enough to trigger the context-tail echo rule
	echoed := "preamble " + context[len(context)-40:] + " trailing"
	clean := "The new transcript words here."

	fb := &seqBackend{responses: []string{echoed, clean}}
	ts, key := newTestServerWithBackend(t, fb)
	body, _ := json.Marshal(map[string]any{"text": text, "context": context})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var out cleanupResponse
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Cleaned != clean {
		t.Errorf("expected %q, got %q", clean, out.Cleaned)
	}
	if len(fb.calls) != 2 {
		t.Errorf("expected 2 backend calls (echo+retry), got %d", len(fb.calls))
	}
}

func TestCleanup_Unauthorized(t *testing.T) {
	fb := &fakeBackend{}
	ts, _, _ := newTestServer(t, fb)
	body, _ := json.Marshal(map[string]string{"text": "hello"})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

func TestHealth(t *testing.T) {
	fb := &fakeBackend{health: true}
	ts, _, _ := newTestServer(t, fb)
	resp, err := http.Get(ts.URL + "/health")
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	b, _ := io.ReadAll(resp.Body)
	if !bytes.Contains(b, []byte(`"status":"ok"`)) {
		t.Errorf("unexpected health body: %s", b)
	}
}

func TestReady_BackendDown(t *testing.T) {
	fb := &fakeBackend{health: false}
	ts, _, _ := newTestServer(t, fb)
	resp, err := http.Get(ts.URL + "/ready")
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	b, _ := io.ReadAll(resp.Body)
	if !bytes.Contains(b, []byte(`"backend_ok":false`)) {
		t.Errorf("expected backend_ok false: %s", b)
	}
}

func TestAdmin_CreateAndListKey(t *testing.T) {
	fb := &fakeBackend{}
	ts, _, _ := newTestServer(t, fb)
	// Create a key.
	body, _ := json.Marshal(map[string]string{"label": "laptop"})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/admin/keys", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var cr adminCreateKeyResponse
	_ = json.NewDecoder(resp.Body).Decode(&cr)
	if cr.Key == "" || cr.ID == "" {
		t.Errorf("expected non-empty key+id, got %+v", cr)
	}
	// List keys.
	req2, _ := http.NewRequest(http.MethodGet, ts.URL+"/admin/keys", nil)
	req2.Header.Set("Authorization", "Bearer admin-secret")
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp2.Body)
	if !bytes.Contains(b, []byte(cr.ID)) {
		t.Errorf("list should contain new key id: %s", b)
	}
}

func TestAdmin_WrongToken(t *testing.T) {
	fb := &fakeBackend{}
	ts, _, _ := newTestServer(t, fb)
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/admin/keys", nil)
	req.Header.Set("Authorization", "Bearer wrong-admin")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// seqBackend returns a sequence of responses, one per call.
type seqBackend struct {
	responses []string
	calls     []string
	idx       int
}

func (s *seqBackend) Cleanup(_ context.Context, prompt string) (string, error) {
	s.calls = append(s.calls, prompt)
	if s.idx >= len(s.responses) {
		return "", errors.New("no more responses")
	}
	r := s.responses[s.idx]
	s.idx++
	return r, nil
}
func (s *seqBackend) Name() string                   { return "seq" }
func (s *seqBackend) Healthy(_ context.Context) bool { return true }

// newTestServerWithBackend is like newTestServer but lets the caller supply the backend.
func newTestServerWithBackend(t *testing.T, be interface {
	Cleanup(context.Context, string) (string, error)
	Name() string
	Healthy(context.Context) bool
}) (*httptest.Server, string) {
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
	srv := &Server{Backend: be, Store: st, Logger: testLogger(), QuotaRPM: 1000, QuotaDaily: 100000}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	handler := NewMux(srv, limiter, "admin-secret", nil)
	ts := httptest.NewServer(handler)
	t.Cleanup(ts.Close)
	return ts, plaintext
}

// TestCleanup_DictionaryReachesPrompt checks the wire field actually lands in
// the prompt, split by kind — the whole feature is inert if it does not.
func TestCleanup_DictionaryReachesPrompt(t *testing.T) {
	fb := &fakeBackend{resp: "My LinkedIn: https://linkedin.example/me"}
	ts, _, key := newTestServer(t, fb)
	body, _ := json.Marshal(map[string]any{
		"text": "my linkedin",
		"dictionary": []map[string]string{
			{"from": "sunno flow", "to": "SunoFlow", "kind": "correction"},
			{"from": "my linkedin", "to": "https://linkedin.example/me", "kind": "expansion"},
		},
	})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if len(fb.calls) != 1 {
		t.Fatalf("expected 1 backend call, got %d", len(fb.calls))
	}
	prompt := fb.calls[0]
	for _, want := range []string{
		`"sunno flow" -> "SunoFlow"`,
		`"my linkedin" -> "https://linkedin.example/me"`,
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt missing dictionary entry %s", want)
		}
	}
	// An expanded URL is far longer than the words that triggered it; the echo
	// guard must let that through rather than falling back to the raw text.
	var out cleanupResponse
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out.Cleaned != "My LinkedIn: https://linkedin.example/me" {
		t.Errorf("expansion rejected by the echo guard, got %q", out.Cleaned)
	}
}

// TestCleanup_DictionarySurvivesEchoRetry pins the deliberate asymmetry in the
// retry: screen/context/recent are dropped because they are what gets echoed,
// but the dictionary is carried over so the retry can still apply it.
func TestCleanup_DictionarySurvivesEchoRetry(t *testing.T) {
	text := "the new transcript words here"
	context := strings.Repeat("x", 80)
	echoed := "preamble " + context[len(context)-40:] + " trailing"
	clean := "The new transcript words here."

	fb := &seqBackend{responses: []string{echoed, clean}}
	ts, key := newTestServerWithBackend(t, fb)
	body, _ := json.Marshal(map[string]any{
		"text":       text,
		"context":    context,
		"dictionary": []map[string]string{{"from": "sunno flow", "to": "SunoFlow", "kind": "correction"}},
	})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if len(fb.calls) != 2 {
		t.Fatalf("expected 2 backend calls (echo+retry), got %d", len(fb.calls))
	}
	retry := fb.calls[1]
	if !strings.Contains(retry, `"sunno flow" -> "SunoFlow"`) {
		t.Error("retry prompt dropped the dictionary")
	}
	if strings.Contains(retry, "[CONTEXT") {
		t.Error("retry prompt should not carry the context it just echoed")
	}
}
