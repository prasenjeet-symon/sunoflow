package backend

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestGroqTranscribe_Multipart(t *testing.T) {
	var gotModel, gotAuth, gotFile, gotContentType string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		gotContentType = r.Header.Get("Content-Type")
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Errorf("parse multipart: %v", err)
		}
		gotModel = r.FormValue("model")
		if fhs := r.MultipartForm.File["file"]; len(fhs) > 0 {
			gotFile = fhs[0].Filename
			f, _ := fhs[0].Open()
			defer f.Close()
			b, _ := io.ReadAll(f)
			if string(b) != "RIFFfakewav" {
				t.Errorf("uploaded audio = %q", string(b))
			}
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"text":"  hello world  "}`))
	}))
	defer ts.Close()

	b := &GroqSTTBackend{
		APIKey:  "test-key",
		Model:   "whisper-large-v3-turbo",
		BaseURL: ts.URL,
		Timeout: 5 * time.Second,
		Client:  ts.Client(),
	}
	got, err := b.Transcribe(context.Background(), []byte("RIFFfakewav"), "audio/wav")
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	if got != "hello world" {
		t.Fatalf("transcript = %q, want trimmed 'hello world'", got)
	}
	if gotModel != "whisper-large-v3-turbo" {
		t.Fatalf("model field = %q", gotModel)
	}
	if gotAuth != "Bearer test-key" {
		t.Fatalf("auth = %q", gotAuth)
	}
	if !strings.HasSuffix(gotFile, ".wav") {
		t.Fatalf("filename = %q, want .wav", gotFile)
	}
	if !strings.HasPrefix(gotContentType, "multipart/form-data") {
		t.Fatalf("content-type = %q", gotContentType)
	}
}

func TestGroqTranscribe_Non200(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"message":"overloaded","type":"server_error"}}`))
	}))
	defer ts.Close()

	b := &GroqSTTBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	if _, err := b.Transcribe(context.Background(), []byte("a"), "audio/wav"); err == nil {
		t.Fatal("want error for 503")
	}
}

func TestGroqTranscribe_ErrorBody(t *testing.T) {
	// 200 with an error object in the body must still be an error.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"error":{"message":"bad audio","type":"invalid_request_error"}}`))
	}))
	defer ts.Close()

	b := &GroqSTTBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	if _, err := b.Transcribe(context.Background(), []byte("a"), "audio/wav"); err == nil {
		t.Fatal("want error when body carries an error object")
	}
}

func TestGeminiTranscribe_InlineAudio(t *testing.T) {
	var body, gotPath, gotAuth string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("x-goog-api-key")
		buf := make([]byte, 8192)
		n, _ := r.Body.Read(buf)
		body = string(buf[:n])
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"candidates":[{"content":{"parts":[{"text":"the transcript"}]},"finishReason":"STOP"}]}`))
	}))
	defer ts.Close()

	b := &GeminiSTTBackend{APIKey: "test-key", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	got, err := b.Transcribe(context.Background(), []byte{0x52, 0x49, 0x46, 0x46}, "audio/wav")
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	if got != "the transcript" {
		t.Fatalf("transcript = %q", got)
	}
	if !strings.Contains(gotPath, ":generateContent") {
		t.Fatalf("path = %q, want generateContent", gotPath)
	}
	if gotAuth != "test-key" {
		t.Fatal("api key header missing")
	}
	if !strings.Contains(body, "inline_data") || !strings.Contains(body, "audio/wav") {
		t.Fatalf("inline audio part missing in body: %q", body)
	}
}

func TestGeminiTranscribe_SkipsThoughtParts(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"candidates":[{"content":{"parts":[{"thought":true,"text":"reasoning"},{"text":"real words"}]},"finishReason":"STOP"}]}`))
	}))
	defer ts.Close()

	b := &GeminiSTTBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	got, err := b.Transcribe(context.Background(), []byte("a"), "audio/wav")
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	if got != "real words" {
		t.Fatalf("transcript = %q, want reasoning stripped", got)
	}
}

func TestGeminiTranscribe_Blocked(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"promptFeedback":{"blockReason":"SAFETY"}}`))
	}))
	defer ts.Close()

	b := &GeminiSTTBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	if _, err := b.Transcribe(context.Background(), []byte("a"), "audio/wav"); err == nil {
		t.Fatal("want error when the prompt is blocked")
	}
}

func TestOpenRouterTranscribe_ChatAudio(t *testing.T) {
	var body, gotPath, gotAuth string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		b, _ := io.ReadAll(r.Body)
		body = string(b)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"the transcript"}}]}`))
	}))
	defer ts.Close()

	b := &OpenRouterSTTBackend{APIKey: "test-key", Model: "mistralai/voxtral-small-24b-2507", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	got, err := b.Transcribe(context.Background(), []byte("RIFFwav"), "audio/wav")
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	if got != "the transcript" {
		t.Fatalf("transcript = %q", got)
	}
	if !strings.HasSuffix(gotPath, "/chat/completions") {
		t.Fatalf("path = %q, want chat/completions", gotPath)
	}
	if gotAuth != "Bearer test-key" {
		t.Fatalf("auth = %q", gotAuth)
	}
	// The audio must ride as an input_audio part with the model and top_p:1
	// (Voxtral rejects greedy sampling otherwise), and never contain the raw key.
	for _, want := range []string{`"input_audio"`, `"format":"wav"`, `"model":"mistralai/voxtral-small-24b-2507"`, `"top_p":1`} {
		if !strings.Contains(body, want) {
			t.Fatalf("request body missing %s: %s", want, body)
		}
	}
}

func TestOpenRouterTranscribe_ContentArray(t *testing.T) {
	// OpenRouter may return content as an array of parts; both shapes decode.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}]}}]}`))
	}))
	defer ts.Close()
	b := &OpenRouterSTTBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	got, err := b.Transcribe(context.Background(), []byte("a"), "audio/wav")
	if err != nil {
		t.Fatalf("Transcribe: %v", err)
	}
	if got != "hello world" {
		t.Fatalf("transcript = %q", got)
	}
}

func TestOpenRouterTranscribe_Errors(t *testing.T) {
	// Non-200.
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"bad audio","code":400}}`))
	}))
	defer ts.Close()
	b := &OpenRouterSTTBackend{APIKey: "k", Model: "m", BaseURL: ts.URL, Timeout: 5 * time.Second, Client: ts.Client()}
	if _, err := b.Transcribe(context.Background(), []byte("a"), "audio/wav"); err == nil {
		t.Fatal("want error for 400")
	}

	// 200 with an error object.
	ts2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"error":{"message":"rate limited"}}`))
	}))
	defer ts2.Close()
	b2 := &OpenRouterSTTBackend{APIKey: "k", Model: "m", BaseURL: ts2.URL, Timeout: 5 * time.Second, Client: ts2.Client()}
	if _, err := b2.Transcribe(context.Background(), []byte("a"), "audio/wav"); err == nil {
		t.Fatal("want error when body carries an error object")
	}
}

func TestFormatFromMime(t *testing.T) {
	cases := map[string]string{"audio/wav": "wav", "audio/mpeg": "mp3", "audio/ogg": "ogg", "": "wav"}
	for mime, want := range cases {
		if got := formatFromMime(mime); got != want {
			t.Errorf("formatFromMime(%q) = %q, want %q", mime, got, want)
		}
	}
}

func TestAudioFilename(t *testing.T) {
	cases := map[string]string{
		"audio/wav":  "audio.wav",
		"audio/mpeg": "audio.mp3",
		"audio/ogg":  "audio.ogg",
		"":           "audio.wav",
	}
	for mime, want := range cases {
		if got := audioFilename(mime); got != want {
			t.Errorf("audioFilename(%q) = %q, want %q", mime, got, want)
		}
	}
}
