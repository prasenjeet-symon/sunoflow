package server

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/sunoflow/cleanup-gateway/internal/auth"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// sttStub is a controllable STTBackend for handler tests.
type sttStub struct {
	transcript string
	err        error
	calls      int
}

func (s *sttStub) Transcribe(_ context.Context, _ []byte, _ string) (string, error) {
	s.calls++
	if s.err != nil {
		return "", s.err
	}
	return s.transcript, nil
}
func (s *sttStub) STTName() string { return "stub" }

// newSTTServer wires a mux with the STT limiter enabled (5 rpm / 50 daily / 100
// hard) and the given STT backend. A nil stt leaves the route registered but
// unwired, so its handler answers 501 — and no limiter is attached, mirroring
// main.go (a disabled provider has no meter).
func newSTTServer(t *testing.T, stt backend.STTBackend) (*httptest.Server, string) {
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
		Backend:     &fakeBackend{}, // unused by /stt, but Server wants a Backend
		STT:         stt,
		STTProvider: "stub",
		Store:       st,
		Logger:      testLogger(),
		QuotaRPM:    1000,
		QuotaDaily:  100000,
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	var sttLimiter *ratelimit.STTLimiter
	if stt != nil {
		sttLimiter = ratelimit.NewSTT(st, 5, 50, 100, nil)
	}
	ts := httptest.NewServer(NewMux(srv, limiter, nil, sttLimiter, "admin-secret", nil))
	t.Cleanup(ts.Close)
	return ts, plaintext
}

func sttBody(audio []byte, format string) string {
	b := map[string]any{"audio": base64.StdEncoding.EncodeToString(audio)}
	if format != "" {
		b["format"] = format
	}
	j, _ := json.Marshal(b)
	return string(j)
}

func postSTT(t *testing.T, ts *httptest.Server, key, body string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/stt", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("X-SunoFlow-Client", "mac/1.0.0")
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("POST /stt: %v", err)
	}
	return resp
}

func TestSTT_Success(t *testing.T) {
	stub := &sttStub{transcript: "hello world"}
	ts, key := newSTTServer(t, stub)

	resp := postSTT(t, ts, key, sttBody([]byte("RIFFfakewavbytes"), "wav"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var out sttResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Transcript != "hello world" {
		t.Fatalf("transcript = %q", out.Transcript)
	}
	if stub.calls != 1 {
		t.Fatalf("backend calls = %d, want 1", stub.calls)
	}
}

func TestSTT_EmptyAudioRejected(t *testing.T) {
	stub := &sttStub{transcript: "x"}
	ts, key := newSTTServer(t, stub)

	resp := postSTT(t, ts, key, `{"audio":""}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
	if stub.calls != 0 {
		t.Fatalf("backend should not be called for empty audio, got %d", stub.calls)
	}
}

func TestSTT_MalformedJSON(t *testing.T) {
	ts, key := newSTTServer(t, &sttStub{})
	resp := postSTT(t, ts, key, `{not json`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
}

func TestSTT_BackendError(t *testing.T) {
	// A provider failure is a hard 502 with {"error":"unavailable"} — no raw
	// fallback, because there is no raw text to fall back to.
	stub := &sttStub{err: errors.New("provider exploded")}
	ts, key := newSTTServer(t, stub)

	resp := postSTT(t, ts, key, sttBody([]byte("audio"), "wav"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", resp.StatusCode)
	}
	var p map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&p)
	if p["error"] != "unavailable" {
		t.Fatalf("error = %q, want unavailable", p["error"])
	}
}

func TestSTT_NoBackend(t *testing.T) {
	// No provider configured → 501, so a client gets a structured error rather
	// than a 404 and can distinguish "not enabled" from "broken".
	ts, key := newSTTServer(t, nil)
	resp := postSTT(t, ts, key, sttBody([]byte("audio"), "wav"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("status = %d, want 501", resp.StatusCode)
	}
}

func TestSTT_LimitResponse(t *testing.T) {
	// Drive the per-minute bucket dry (rpm=5); the next call must be 429 with
	// exactly {"error":"limit"}.
	ts, key := newSTTServer(t, &sttStub{transcript: "ok"})
	for i := 0; i < 5; i++ {
		resp := postSTT(t, ts, key, sttBody([]byte("audio"), "wav"))
		resp.Body.Close()
	}
	resp := postSTT(t, ts, key, sttBody([]byte("audio"), "wav"))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", resp.StatusCode)
	}
	var p map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&p)
	if p["error"] != "limit" {
		t.Fatalf("error = %q, want limit", p["error"])
	}
}

func TestSTT_Unauthorized(t *testing.T) {
	ts, _ := newSTTServer(t, &sttStub{transcript: "ok"})
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/stt", strings.NewReader(sttBody([]byte("a"), "wav")))
	req.Header.Set("Authorization", "Bearer wrong-key")
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("POST /stt: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", resp.StatusCode)
	}
}

func TestDecodeAudio(t *testing.T) {
	if raw, err := decodeAudio(""); err != nil || raw != nil {
		t.Fatalf("empty should pass through, got %v %v", raw, err)
	}
	raw, err := decodeAudio("aGk=") // base64("hi")
	if err != nil || string(raw) != "hi" {
		t.Fatalf("decode: %v %q", err, raw)
	}
	if _, err := decodeAudio("!!!not base64!!!"); err == nil {
		t.Fatal("want error for bad base64")
	}
}

func TestMimeForFormat(t *testing.T) {
	cases := map[string]string{
		"":      "audio/wav",
		"wav":   "audio/wav",
		"WAV":   "audio/wav",
		"mp3":   "audio/mpeg",
		"ogg":   "audio/ogg",
		"weird": "audio/wav",
	}
	for in, want := range cases {
		if got := mimeForFormat(in); got != want {
			t.Errorf("mimeForFormat(%q) = %q, want %q", in, got, want)
		}
	}
}
