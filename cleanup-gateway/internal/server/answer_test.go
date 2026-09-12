package server

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/analytics"
	"github.com/sunoflow/cleanup-gateway/internal/auth"
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// sseBackend implements backend.AnswerBackend over a scripted chunk list.
// sseBackend implements backend.Backend + backend.AnswerBackend over a
// scripted chunk list. fakeBackend is embedded by pointer so its pointer-
// receiver methods (Cleanup/Name/Healthy) promote to *sseBackend.
type sseBackend struct {
	*fakeBackend
	chunks []backend.AnswerChunk
}

func (s *sseBackend) StreamAnswer(_ context.Context, _ string, _ []byte) (<-chan backend.AnswerChunk, error) {
	out := make(chan backend.AnswerChunk, len(s.chunks)+1)
	for _, c := range s.chunks {
		out <- c
	}
	close(out)
	return out, nil
}

// newAnswerServer wires a mux with the answer limiter enabled (5 rpm / 50
// daily / 100 hard) and the scripted answer backend, using the same in-memory
// store + issued key setup as newTestServer. ab must satisfy both Backend and
// AnswerBackend (sseBackend does, via its embedded fakeBackend).
func newAnswerServer(t *testing.T, ab backend.Backend) (*httptest.Server, string) {
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
		Backend:     ab, // sseBackend embeds fakeBackend, so Backend is satisfied
		Store:       st,
		Logger:      testLogger(),
		QuotaRPM:    1000,
		QuotaDaily:  100000,
		AnswerModel: "test-answer-model",
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	answerLimiter := ratelimit.NewAnswer(st, 5, 50, 100, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, answerLimiter, nil, nil, nil, "admin-secret", nil))
	t.Cleanup(ts.Close)
	return ts, plaintext
}

// parseSSE reads an SSE body into ordered (event, data) pairs.
func parseSSE(t *testing.T, resp *http.Response) [][2]string {
	t.Helper()
	sc := bufio.NewScanner(resp.Body)
	var out [][2]string
	var event, data string
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "event: "):
			event = strings.TrimPrefix(line, "event: ")
		case strings.HasPrefix(line, "data: "):
			data = strings.TrimPrefix(line, "data: ")
		case line == "" && event != "":
			out = append(out, [2]string{event, data})
			event, data = "", ""
		}
	}
	return out
}

func answerBody(query string, history int, image bool) string {
	b := map[string]any{"query": query}
	if history > 0 {
		var h []map[string]string
		for i := 0; i < history; i++ {
			h = append(h, map[string]string{"q": fmt.Sprintf("q%d", i), "a": fmt.Sprintf("a%d", i)})
		}
		b["history"] = h
	}
	if image {
		b["image"] = "" // empty: present-but-empty is fine; a real test of the cap lives in decodeImage
	}
	j, _ := json.Marshal(b)
	return string(j)
}

func postAnswer(t *testing.T, ts *httptest.Server, key, body string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/answer", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("X-SunoFlow-Client", "mac/1.0.0")
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatalf("POST /answer: %v", err)
	}
	return resp
}

func TestAnswer_StreamsEvents(t *testing.T) {
	fb := &fakeBackend{}
	ab := &sseBackend{fakeBackend: fb, chunks: []backend.AnswerChunk{
		{Text: "Hello"},
		{Text: " world"},
		{Domains: []string{"example.com", "docs.example.org"}, SearchQueries: 2},
	}}
	ts, key := newAnswerServer(t, ab)

	resp := postAnswer(t, ts, key, answerBody("what is rust", 0, false))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("content-type = %q", ct)
	}
	events := parseSSE(t, resp)
	if len(events) == 0 {
		t.Fatal("no events")
	}
	if events[0][0] != "meta" {
		t.Fatalf("first event = %q, want meta", events[0][0])
	}
	var deltas strings.Builder
	var sawSources, sawDone bool
	var sourceDomains []string
	for _, ev := range events {
		switch ev[0] {
		case "delta":
			var p map[string]string
			if err := json.Unmarshal([]byte(ev[1]), &p); err != nil {
				t.Fatalf("delta payload: %v", err)
			}
			deltas.WriteString(p["text"])
		case "sources":
			sawSources = true
			var p struct {
				Domains []string `json:"domains"`
				Queries int      `json:"queries"`
			}
			_ = json.Unmarshal([]byte(ev[1]), &p)
			sourceDomains = p.Domains
		case "done":
			sawDone = true
		}
	}
	if deltas.String() != "Hello world" {
		t.Fatalf("deltas = %q", deltas.String())
	}
	if !sawSources || strings.Join(sourceDomains, ",") != "example.com,docs.example.org" {
		t.Fatalf("sources missing or wrong: %v", sourceDomains)
	}
	if !sawDone {
		t.Fatal("done event missing")
	}
}

func TestAnswer_ErrorEvent(t *testing.T) {
	fb := &fakeBackend{}
	ab := &sseBackend{fakeBackend: fb, chunks: []backend.AnswerChunk{
		{Text: "partial"},
		{Err: fmt.Errorf("gemini error 500 (INTERNAL)")},
	}}
	ts, key := newAnswerServer(t, ab)

	resp := postAnswer(t, ts, key, answerBody("q", 0, false))
	defer resp.Body.Close()
	events := parseSSE(t, resp)
	var sawErr, sawDone bool
	var code string
	for _, ev := range events {
		if ev[0] == "error" {
			sawErr = true
			var p map[string]string
			_ = json.Unmarshal([]byte(ev[1]), &p)
			code = p["error"]
		}
		if ev[0] == "done" {
			sawDone = true
		}
	}
	if !sawErr || sawDone {
		t.Fatalf("want error without done, err=%v done=%v", sawErr, sawDone)
	}
	if code != "unavailable" {
		t.Fatalf("code = %q, want unavailable", code)
	}
}

func TestAnswer_EmptyQueryRejected(t *testing.T) {
	fb := &fakeBackend{}
	ts, key := newAnswerServer(t, &sseBackend{fakeBackend: fb})
	resp := postAnswer(t, ts, key, answerBody("   ", 0, false))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", resp.StatusCode)
	}
}

func TestAnswer_LimitResponse(t *testing.T) {
	// Exhaust the answer daily allowance; the limiter's body must be exactly
	// {"error":"limit"} so the client maps it to the limit card.
	fb := &fakeBackend{}
	ts, key := newAnswerServer(t, &sseBackend{fakeBackend: fb})

	// Drive the per-minute bucket dry (rpm=5 in newAnswerServer).
	for i := 0; i < 5; i++ {
		resp := postAnswer(t, ts, key, answerBody("q", 0, false))
		resp.Body.Close()
	}
	resp := postAnswer(t, ts, key, answerBody("q", 0, false))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", resp.StatusCode)
	}
	var p map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&p)
	if p["error"] != "limit" {
		t.Fatalf("body error = %q, want limit", p["error"])
	}
}

func TestDecodeImage(t *testing.T) {
	if raw, err := decodeImage(""); err != nil || raw != nil {
		t.Fatalf("empty should pass through, got %v %v", raw, err)
	}
	// "aGk=" is base64("hi").
	raw, err := decodeImage("aGk=")
	if err != nil || string(raw) != "hi" {
		t.Fatalf("decode: %v %q", err, raw)
	}
	if _, err := decodeImage("!!!not base64!!!"); err == nil {
		t.Fatal("want error for bad base64")
	}
}

// The answer event must carry the exact per-request provider token usage, so
// cost per answer is measured — the same contract control already records.
// Mirrors serverWithAnalytics but wired for the answer route with the scripted
// streaming backend carrying a usage chunk.
func TestAnswer_AnalyticsRecordsTokenUsage(t *testing.T) {
	var mu sync.Mutex
	var collected []string
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		collected = append(collected, string(b))
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(sink.Close)

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

	stats := analytics.New("phc_test", sink.URL, testLogger())
	ab := &sseBackend{
		fakeBackend: &fakeBackend{},
		chunks: []backend.AnswerChunk{
			{Text: "An answer."},
			{Domains: []string{"example.com"}, SearchQueries: 1},
			{Usage: backend.Usage{PromptTokens: 31, OutputTokens: 12, ThinkingTokens: 3, TotalTokens: 46}},
		},
	}
	srv := &Server{
		Backend:     ab,
		Store:       st,
		Logger:      testLogger(),
		QuotaRPM:    1000,
		QuotaDaily:  100000,
		AnswerModel: "test-answer-model",
		Analytics:   stats,
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	answerLimiter := ratelimit.NewAnswer(st, 5, 50, 100, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, answerLimiter, nil, nil, nil, "admin-secret", nil))
	t.Cleanup(ts.Close)

	resp := postAnswer(t, ts, plaintext, answerBody("q", 0, false))
	resp.Body.Close()

	stats.Close() // flush
	time.Sleep(50 * time.Millisecond)

	mu.Lock()
	posted := strings.Join(collected, "\n")
	mu.Unlock()
	if posted == "" {
		t.Fatal("no analytics batch posted")
	}

	var batch struct {
		Batch []struct {
			Event      string         `json:"event"`
			Properties map[string]any `json:"properties"`
		} `json:"batch"`
	}
	if err := json.Unmarshal([]byte(collected[0]), &batch); err != nil {
		t.Fatalf("unparseable batch: %v", err)
	}
	var answer *struct {
		Event      string         `json:"event"`
		Properties map[string]any `json:"properties"`
	}
	for i := range batch.Batch {
		if batch.Batch[i].Event == "answer" {
			answer = &batch.Batch[i]
		}
	}
	if answer == nil {
		t.Fatal("no answer event captured")
	}
	pr := answer.Properties
	if got, want := pr["prompt_tokens"], float64(31); got != want {
		t.Errorf("prompt_tokens = %v, want %v", got, want)
	}
	if got, want := pr["output_tokens"], float64(12); got != want {
		t.Errorf("output_tokens = %v, want %v", got, want)
	}
	if got, want := pr["thinking_tokens"], float64(3); got != want {
		t.Errorf("thinking_tokens = %v, want %v", got, want)
	}
	if got, want := pr["total_tokens"], float64(46); got != want {
		t.Errorf("total_tokens = %v, want %v", got, want)
	}
	if got, want := pr["answer_chars"], float64(len("An answer.")); got != want {
		t.Errorf("answer_chars = %v, want %v", got, want)
	}
	if pr["model"] != "test-answer-model" {
		t.Errorf("model = %v", pr["model"])
	}
}

// The answer analytics event carries the dictionary size and the full prompt
// context length (framing + history + dictionary + screen), not just the query
// — so dashboard users can see how much context each answer consumed.
func TestAnswer_AnalyticsRecordsContextProps(t *testing.T) {
	var mu sync.Mutex
	var collected []string
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		collected = append(collected, string(b))
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(sink.Close)

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

	stats := analytics.New("phc_test", sink.URL, testLogger())
	ab := &sseBackend{
		fakeBackend: &fakeBackend{},
		chunks:      []backend.AnswerChunk{{Text: "An answer."}},
	}
	srv := &Server{
		Backend:     ab,
		Store:       st,
		Logger:      testLogger(),
		QuotaRPM:    1000,
		QuotaDaily:  100000,
		AnswerModel: "test-answer-model",
		Analytics:   stats,
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	answerLimiter := ratelimit.NewAnswer(st, 5, 50, 100, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, answerLimiter, nil, nil, nil, "admin-secret", nil))
	t.Cleanup(ts.Close)

	// Carry one prior turn and a one-entry dictionary.
	body := `{"query":"what is rust","history":[{"q":"hi","a":"hello"}],"dictionary":[{"from":"rust","to":"Rust"}],"image":""}`
	resp := postAnswer(t, ts, plaintext, body)
	resp.Body.Close()

	stats.Close() // flush
	time.Sleep(50 * time.Millisecond)

	mu.Lock()
	posted := strings.Join(collected, "\n")
	mu.Unlock()
	if posted == "" {
		t.Fatal("no analytics batch posted")
	}

	var batch struct {
		Batch []struct {
			Event      string         `json:"event"`
			Properties map[string]any `json:"properties"`
		} `json:"batch"`
	}
	if err := json.Unmarshal([]byte(collected[0]), &batch); err != nil {
		t.Fatalf("unparseable batch: %v", err)
	}
	var pr map[string]any
	for i := range batch.Batch {
		if batch.Batch[i].Event == "answer" {
			pr = batch.Batch[i].Properties
		}
	}
	if pr == nil {
		t.Fatal("no answer event captured")
	}
	if got, want := pr["dict_entries"], float64(1); got != want {
		t.Errorf("dict_entries = %v, want %v", got, want)
	}
	if got, want := pr["turn_index"], float64(1); got != want {
		t.Errorf("turn_index = %v, want %v", got, want)
	}
	// context_chars must exceed the bare query — framing + history + dict are
	// part of the prompt bytes.
	ctxChars, _ := pr["context_chars"].(float64)
	queryLen := float64(len("what is rust"))
	if ctxChars <= queryLen {
		t.Errorf("context_chars = %v, want > query_length %v", ctxChars, queryLen)
	}
}

// A prompt-level safety block surfaces as a distinct "blocked" outcome (and
// error_code + block_reason), not a generic error — so safety blocks are
// countable in analytics.
func TestAnswer_AnalyticsBlockedOutcome(t *testing.T) {
	var mu sync.Mutex
	var collected []string
	sink := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		collected = append(collected, string(b))
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(sink.Close)

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

	stats := analytics.New("phc_test", sink.URL, testLogger())
	ab := &sseBackend{
		fakeBackend: &fakeBackend{},
		chunks:      []backend.AnswerChunk{{BlockReason: "SAFETY"}},
	}
	srv := &Server{
		Backend:     ab,
		Store:       st,
		Logger:      testLogger(),
		QuotaRPM:    1000,
		QuotaDaily:  100000,
		AnswerModel: "test-answer-model",
		Analytics:   stats,
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	answerLimiter := ratelimit.NewAnswer(st, 5, 50, 100, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, answerLimiter, nil, nil, nil, "admin-secret", nil))
	t.Cleanup(ts.Close)

	resp := postAnswer(t, ts, plaintext, answerBody("bad thing", 0, false))
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (SSE even for a block)", resp.StatusCode)
	}
	resp.Body.Close()

	stats.Close() // flush
	time.Sleep(50 * time.Millisecond)

	mu.Lock()
	posted := strings.Join(collected, "\n")
	mu.Unlock()
	if posted == "" {
		t.Fatal("no analytics batch posted")
	}

	var batch struct {
		Batch []struct {
			Event      string         `json:"event"`
			Properties map[string]any `json:"properties"`
		} `json:"batch"`
	}
	if err := json.Unmarshal([]byte(collected[0]), &batch); err != nil {
		t.Fatalf("unparseable batch: %v", err)
	}
	var pr map[string]any
	for i := range batch.Batch {
		if batch.Batch[i].Event == "answer" {
			pr = batch.Batch[i].Properties
		}
	}
	if pr == nil {
		t.Fatal("no answer event captured")
	}
	if pr["outcome"] != "blocked" {
		t.Errorf("outcome = %v, want blocked", pr["outcome"])
	}
	if pr["error_code"] != "blocked" {
		t.Errorf("error_code = %v, want blocked", pr["error_code"])
	}
	if pr["block_reason"] != "SAFETY" {
		t.Errorf("block_reason = %v, want SAFETY", pr["block_reason"])
	}
	// A block emits no text, so answer_chars stays zero.
	if got, want := pr["answer_chars"], float64(0); got != want {
		t.Errorf("answer_chars = %v, want %v", got, want)
	}
}
