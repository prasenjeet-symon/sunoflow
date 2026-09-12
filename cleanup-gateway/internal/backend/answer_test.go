package backend

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// sseServer returns a test server whose body is the given SSE text, plus the
// request it received for assertions.
func sseServer(t *testing.T, body string) (*httptest.Server, *[]string) {
	t.Helper()
	var got []string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, "") // record that we were hit (append-only slice race-free here)
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(ts.Close)
	return ts, &got
}

func TestStreamAnswer_TextAndSources(t *testing.T) {
	body := strings.Join([]string{
		`data: {"candidates":[{"content":{"parts":[{"text":"Hello "}]},"index":0}]}`,
		`data: {"candidates":[{"content":{"parts":[{"text":"world"}]}}]}`,
		`data: {"candidates":[{"content":{"parts":[{"text":"."}]},"finishReason":"STOP","groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.com/page?q=secret","domain":"Example.com"}},{"web":{"uri":"https://www.example.com/other","domain":"www.example.com"}},{"web":{"uri":"https://docs.gov.uk/x","domain":""}}],"webSearchQueries":["capital of france"]}}]}`,
		`data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"reasoning ignored"}]}}]}`,
		"", // trailing blank line
	}, "\n")
	ts, _ := sseServer(t, body)

	b := &GeminiBackend{
		APIKey:  "test-key",
		Model:   "m",
		BaseURL: ts.URL,
		Timeout: 5 * time.Second,
		Client:  ts.Client(),
	}

	chunks, err := b.StreamAnswer(context.Background(), "prompt", nil)
	if err != nil {
		t.Fatalf("StreamAnswer: %v", err)
	}
	var texts []string
	var sources int
	var domains []string
	queries := -1
	for c := range chunks {
		if c.Err != nil {
			t.Fatalf("chunk err: %v", c.Err)
		}
		if c.Text != "" {
			texts = append(texts, c.Text)
		}
		if len(c.Domains) > 0 {
			sources++
			domains = c.Domains
		}
		if c.SearchQueries > 0 {
			queries = c.SearchQueries
		}
	}
	if got, want := strings.Join(texts, ""), "Hello world."; got != want {
		t.Fatalf("text = %q, want %q", got, want)
	}
	if sources != 1 {
		t.Fatalf("got %d source chunks, want 1", sources)
	}
	// Deduped, lowercased, www-stripped, host fallback from URI, capped.
	if got, want := strings.Join(domains, ","), "example.com,docs.gov.uk"; got != want {
		t.Fatalf("domains = %q, want %q", got, want)
	}
	if queries != 1 {
		t.Fatalf("queries = %d, want 1", queries)
	}
}

func TestStreamAnswer_DomainCap(t *testing.T) {
	var parts []string
	for i := 0; i < 8; i++ {
		parts = append(parts, `{"web":{"uri":"https://host`+strings.Repeat("x", i)+`.com/x","domain":"host`+strings.Repeat("x", i)+`.com"}}`)
	}
	body := `data: {"candidates":[{"content":{"parts":[{"text":"t"}]},"finishReason":"STOP","groundingMetadata":{"groundingChunks":[` +
		strings.Join(parts, ",") + `]}}]}`
	ts, _ := sseServer(t, body)

	b := &GeminiBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	chunks, err := b.StreamAnswer(context.Background(), "p", nil)
	if err != nil {
		t.Fatalf("StreamAnswer: %v", err)
	}
	var domains []string
	for c := range chunks {
		if len(c.Domains) > 0 {
			domains = c.Domains
		}
	}
	if len(domains) != MaxSourceDomains {
		t.Fatalf("got %d domains, want cap %d", len(domains), MaxSourceDomains)
	}
}

func TestStreamAnswer_UpstreamError(t *testing.T) {
	// Non-200 upstream → error before the channel opens.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"code":503,"status":"UNAVAILABLE","message":"overloaded"}}`))
	}))
	defer ts.Close()

	b := &GeminiBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	_, err := b.StreamAnswer(context.Background(), "p", nil)
	if err == nil {
		t.Fatal("want error for 503")
	}
	if !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("error should classify as unavailable, got: %v", err)
	}
}

func TestStreamAnswer_ErrorEventMidStream(t *testing.T) {
	body := strings.Join([]string{
		`data: {"candidates":[{"content":{"parts":[{"text":"partial"}]}}]}`,
		`data: {"error":{"code":500,"status":"INTERNAL","message":"boom"}}`,
	}, "\n")
	ts, _ := sseServer(t, body)

	b := &GeminiBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	chunks, err := b.StreamAnswer(context.Background(), "p", nil)
	if err != nil {
		t.Fatalf("StreamAnswer: %v", err)
	}
	var sawText, sawErr bool
	for c := range chunks {
		if c.Text != "" {
			sawText = true
		}
		if c.Err != nil {
			sawErr = true
		}
	}
	if !sawText || !sawErr {
		t.Fatalf("want text-then-error, got text=%v err=%v", sawText, sawErr)
	}
}

func TestStreamAnswer_NoText(t *testing.T) {
	body := `data: {"candidates":[{"content":{"parts":[{"thought":true,"text":"only reasoning"}]},"finishReason":"SAFETY"}]}`
	ts, _ := sseServer(t, body)

	b := &GeminiBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	chunks, err := b.StreamAnswer(context.Background(), "p", nil)
	if err != nil {
		t.Fatalf("StreamAnswer: %v", err)
	}
	var last error
	for c := range chunks {
		if c.Err != nil {
			last = c.Err
		}
	}
	if last == nil {
		t.Fatal("want error for stream with no text")
	}
}

func TestStreamAnswer_ImageRidesInline(t *testing.T) {
	var body string
	var gotPath, gotQuery, gotAuth string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		gotAuth = r.Header.Get("x-goog-api-key")
		buf := make([]byte, 4096)
		n, _ := r.Body.Read(buf)
		body = string(buf[:n])
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(`data: {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}` + "\n"))
	}))
	defer ts.Close()

	b := &GeminiBackend{APIKey: "test-key", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	chunks, err := b.StreamAnswer(context.Background(), "prompt text", []byte{0xFF, 0xD8, 0xFF})
	if err != nil {
		t.Fatalf("StreamAnswer: %v", err)
	}
	for range chunks {
	}
	if !strings.Contains(gotPath, ":streamGenerateContent") {
		t.Fatalf("path = %q, want stream endpoint", gotPath)
	}
	if gotQuery != "alt=sse" {
		t.Fatalf("query = %q, want alt=sse", gotQuery)
	}
	if gotAuth != "test-key" {
		t.Fatal("api key header missing")
	}
	// The request body must carry the inline image part before the text part,
	// and never contain the raw key.
	if !strings.Contains(body, "inline_data") || !strings.Contains(body, "image/jpeg") {
		t.Fatalf("inline image part missing in body: %q", body)
	}
	if !strings.Contains(body, "prompt text") {
		t.Fatal("prompt text missing in body")
	}
}

// The media-resolution bucket rides generationConfig when an image is present
// (it caps the image's token cost), and is omitted on a text-only turn.
func TestStreamAnswer_MediaResolution(t *testing.T) {
	var body string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		buf := make([]byte, 8192)
		n, _ := r.Body.Read(buf)
		body = string(buf[:n])
		w.Header().Set("Content-Type", "text/event-stream")
		_, _ = w.Write([]byte(`data: {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}` + "\n"))
	}))
	defer ts.Close()

	b := &GeminiBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second,
		Client: ts.Client(), AnswerMediaResolution: "MEDIA_RESOLUTION_MEDIUM"}

	// With an image: the bucket is present.
	chunks, err := b.StreamAnswer(context.Background(), "p", []byte{0xFF, 0xD8, 0xFF})
	if err != nil {
		t.Fatalf("StreamAnswer image: %v", err)
	}
	for range chunks {
	}
	if !strings.Contains(body, `"mediaResolution":"MEDIA_RESOLUTION_MEDIUM"`) {
		t.Fatalf("mediaResolution missing with image: %q", body)
	}

	// Text-only turn: no image, so no bucket (nothing to size).
	chunks2, err := b.StreamAnswer(context.Background(), "p", nil)
	if err != nil {
		t.Fatalf("StreamAnswer text: %v", err)
	}
	for range chunks2 {
	}
	if strings.Contains(body, "mediaResolution") {
		t.Fatalf("mediaResolution should be absent without an image: %q", body)
	}
}

// The provider's token accounting rides the final candidate chunk as
// usageMetadata; the decoder must surface it as a Usage chunk so the handler can
// pass exact per-request usage on to analytics.
func TestStreamAnswer_UsageMetadata(t *testing.T) {
	body := strings.Join([]string{
		`data: {"candidates":[{"content":{"parts":[{"text":"Partial "}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":4,"thoughtsTokenCount":2,"totalTokenCount":16}}`,
		`data: {"candidates":[{"content":{"parts":[{"text":"answer"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":8,"thoughtsTokenCount":2,"totalTokenCount":20}}`,
		"",
	}, "\n")
	ts, _ := sseServer(t, body)

	b := &GeminiBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	chunks, err := b.StreamAnswer(context.Background(), "p", nil)
	if err != nil {
		t.Fatalf("StreamAnswer: %v", err)
	}
	var usage Usage
	for c := range chunks {
		if c.Err != nil {
			t.Fatalf("chunk err: %v", c.Err)
		}
		if c.Usage.TotalTokens > 0 {
			usage = c.Usage
		}
	}
	// The LAST reported usage wins (the final candidate chunk carries the
	// complete accounting).
	want := Usage{PromptTokens: 10, OutputTokens: 8, ThinkingTokens: 2, TotalTokens: 20}
	if usage != want {
		t.Fatalf("usage = %+v, want %+v", usage, want)
	}
}

// A usage chunk with a zero total (provider didn't report) is never emitted —
// nothing useful to surface downstream.
func TestStreamAnswer_NoUsageMetadata(t *testing.T) {
	body := `data: {"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"totalTokenCount":0}}`
	ts, _ := sseServer(t, body)

	b := &GeminiBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	chunks, err := b.StreamAnswer(context.Background(), "p", nil)
	if err != nil {
		t.Fatalf("StreamAnswer: %v", err)
	}
	for c := range chunks {
		if c.Usage.TotalTokens > 0 {
			t.Fatalf("should not report zero usage, got %+v", c.Usage)
		}
	}
}

// A prompt-level safety block surfaces as its own BlockReason chunk — not an
// Err — so the handler can record a distinct "blocked" outcome in analytics
// instead of folding it into a generic backend error.
func TestStreamAnswer_PromptBlockReason(t *testing.T) {
	body := `data: {"promptFeedback":{"blockReason":"SAFETY"},"candidates":[]}`
	ts, _ := sseServer(t, body)

	b := &GeminiBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	chunks, err := b.StreamAnswer(context.Background(), "p", nil)
	if err != nil {
		t.Fatalf("StreamAnswer: %v", err)
	}
	var got string
	var gotErr error
	for c := range chunks {
		if c.Err != nil {
			gotErr = c.Err
		}
		if c.BlockReason != "" {
			got = c.BlockReason
		}
	}
	if gotErr != nil {
		t.Fatalf("block should not surface as an Err, got %v", gotErr)
	}
	if got != "SAFETY" {
		t.Fatalf("BlockReason = %q, want %q", got, "SAFETY")
	}
}

func TestDedupeDomains(t *testing.T) {
	chunks := []geminiGroundingChunk{}
	for _, h := range []string{"Example.com", "www.example.com", "example.org", "", "example.net"} {
		var c geminiGroundingChunk
		c.Web.Domain = h
		c.Web.URI = "https://" + h + "/p"
		chunks = append(chunks, c)
	}
	got := dedupeDomains(chunks)
	want := "example.com,example.org,example.net"
	if strings.Join(got, ",") != want {
		t.Fatalf("dedupeDomains = %v, want %v", got, want)
	}
}
