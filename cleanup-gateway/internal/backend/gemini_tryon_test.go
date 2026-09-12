package backend

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// newTestTryonGemini points a GeminiBackend with try-on fields set at a stub
// server, so the tryon request shaping and image parsing are exercised
// without a live API key.
func newTestTryonGemini(t *testing.T, h http.HandlerFunc, set func(*GeminiBackend)) (*GeminiBackend, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	be := &GeminiBackend{
		APIKey:           "test-key",
		Model:            "gemini-3.5-flash-lite",
		BaseURL:          srv.URL,
		Timeout:          5 * time.Second,
		TryonModel:       "gemini-3.1-flash-image-preview",
		TryonTimeout:     5 * time.Second,
		TryonImageSize:   "1K",
		TryonAspectRatio: "3:4",
		Client:           srv.Client(),
	}
	if set != nil {
		set(be)
	}
	return be, srv
}

func TestGeminiTryOnSendsPartsAndParsesImage(t *testing.T) {
	var gotPath string
	var raw map[string]any
	imageB64 := base64.StdEncoding.EncodeToString([]byte("fake png bytes"))

	be, _ := newTestTryonGemini(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &raw)
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"candidates":[{"content":{"parts":[
			{"text":"Here you are."},
			{"inlineData":{"mimeType":"image/png","data":"`+imageB64+`"}}
		]},"finishReason":"STOP"}],
		"usageMetadata":{"promptTokenCount":280,"candidatesTokenCount":1290,"totalTokenCount":1570}}`)
	}, nil)

	person := []byte("person jpeg bytes")
	garment := []byte("garment jpeg bytes")
	img, mime, usage, err := be.TryOn(context.Background(), "the prompt text", person, garment)
	if err != nil {
		t.Fatalf("TryOn: %v", err)
	}
	if string(img) != "fake png bytes" {
		t.Errorf("image = %q", img)
	}
	if mime != "image/png" {
		t.Errorf("mime = %q", mime)
	}
	if usage.PromptTokens != 280 || usage.TotalTokens != 1570 {
		t.Errorf("usage = %+v", usage)
	}
	if !strings.HasSuffix(gotPath, "/models/gemini-3.1-flash-image-preview:generateContent") {
		t.Errorf("unexpected path %q", gotPath)
	}

	// Wire shape: person → garment → text, responseModalities TEXT+IMAGE, and
	// the imageConfig from config.
	rawContents := raw["contents"].([]any)
	content := rawContents[0].(map[string]any)
	parts := content["parts"].([]any)
	if len(parts) != 3 {
		t.Fatalf("parts = %d, want 3 (person, garment, text)", len(parts))
	}
	// Request-side inline parts use the snake_case tag (geminiPart:
	// `inline_data`), which protobuf JSON accepts from the client.
	p0 := parts[0].(map[string]any)["inline_data"].(map[string]any)
	p1 := parts[1].(map[string]any)["inline_data"].(map[string]any)
	if p0["mime_type"] != "image/jpeg" || p1["mime_type"] != "image/jpeg" {
		t.Errorf("inline mime types = %v %v", p0["mime_type"], p1["mime_type"])
	}
	dec, err := base64.StdEncoding.DecodeString(p0["data"].(string))
	if err != nil || string(dec) != string(person) {
		t.Errorf("person bytes not sent verbatim: %v", err)
	}
	dec, err = base64.StdEncoding.DecodeString(p1["data"].(string))
	if err != nil || string(dec) != string(garment) {
		t.Errorf("garment bytes not sent verbatim: %v", err)
	}
	if parts[2].(map[string]any)["text"] != "the prompt text" {
		t.Errorf("prompt text not sent verbatim: %v", parts[2])
	}
	cfg := raw["generationConfig"].(map[string]any)
	mods := cfg["responseModalities"].([]any)
	if len(mods) != 2 || mods[0] != "TEXT" || mods[1] != "IMAGE" {
		t.Errorf("responseModalities = %v", mods)
	}
	if cfg["temperature"] != nil {
		t.Errorf("image generation must not carry temperature, got %v", cfg["temperature"])
	}
	imgCfg := cfg["imageConfig"].(map[string]any)
	if imgCfg["aspectRatio"] != "3:4" || imgCfg["imageSize"] != "1K" {
		t.Errorf("imageConfig = %v", imgCfg)
	}
}

func TestGeminiTryOnOmitsImageConfigWhenUnset(t *testing.T) {
	var raw map[string]any
	be, _ := newTestTryonGemini(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &raw)
		io.WriteString(w, `{"candidates":[{"content":{"parts":[{"inlineData":{"mimeType":"image/png","data":"aGk="}}]}}]}`)
	}, func(be *GeminiBackend) {
		be.TryonImageSize = ""
		be.TryonAspectRatio = ""
	})
	if _, _, _, err := be.TryOn(context.Background(), "p", []byte("a"), []byte("b")); err != nil {
		t.Fatalf("TryOn: %v", err)
	}
	cfg := raw["generationConfig"].(map[string]any)
	if _, present := cfg["imageConfig"]; present {
		t.Errorf("imageConfig must be omitted when unset, got %v", cfg["imageConfig"])
	}
}

func TestGeminiTryonModelFallback(t *testing.T) {
	// Empty TryonModel falls back to Model — only reachable from direct
	// backend use (main.go disables the route when TryonModel is unset).
	be := &GeminiBackend{Model: "fallback-model", TryonModel: ""}
	if got := be.tryonModel(); got != "fallback-model" {
		t.Errorf("tryonModel = %q", got)
	}
}

func TestGeminiTryOnErrors(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		wantErr string
	}{
		{"safety block", `{"promptFeedback":{"blockReason":"SAFETY"}}`, "safety filter"},
		{"no image part", `{"candidates":[{"content":{"parts":[{"text":"just text"}]}}]}`, "no image"},
		{"api error", `{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"bad"}}`, "gemini error"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			be, _ := newTestTryonGemini(t, func(w http.ResponseWriter, r *http.Request) {
				io.WriteString(w, tc.body)
			}, nil)
			_, _, _, err := be.TryOn(context.Background(), "p", []byte("a"), []byte("b"))
			if err == nil {
				t.Fatalf("want error, got nil")
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("err = %v, want it to contain %q", err, tc.wantErr)
			}
		})
	}
}

func TestGeminiTryOnSafetyBlockIsSentinel(t *testing.T) {
	be, _ := newTestTryonGemini(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"promptFeedback":{"blockReason":"SAFETY"}}`)
	}, nil)
	_, _, _, err := be.TryOn(context.Background(), "p", []byte("a"), []byte("b"))
	if !errors.Is(err, ErrSafetyBlock) {
		t.Errorf("err = %v, want ErrSafetyBlock", err)
	}
}

func TestGeminiTryOnRequiresBothImages(t *testing.T) {
	be, _ := newTestTryonGemini(t, func(w http.ResponseWriter, r *http.Request) {
		t.Error("request must not reach the provider without both images")
	}, nil)
	if _, _, _, err := be.TryOn(context.Background(), "p", nil, []byte("b")); err == nil {
		t.Error("nil person: want error")
	}
	if _, _, _, err := be.TryOn(context.Background(), "p", []byte("a"), nil); err == nil {
		t.Error("nil garment: want error")
	}
}
