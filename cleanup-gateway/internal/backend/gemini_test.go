package backend

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// newTestGemini points a GeminiBackend at a stub server so the request shaping
// and response parsing are exercised without a live API key.
func newTestGemini(t *testing.T, h http.HandlerFunc) (*GeminiBackend, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &GeminiBackend{
		APIKey:  "test-key",
		Model:   "gemini-3.5-flash-lite",
		BaseURL: srv.URL,
		Timeout: 5 * time.Second,
		Client:  srv.Client(),
	}, srv
}

func TestGeminiCleanupSendsPromptAndParsesText(t *testing.T) {
	var gotPath, gotKey string
	var gotReq geminiRequest

	be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotKey = r.Header.Get("x-goog-api-key")
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &gotReq)
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"candidates":[{"content":{"parts":[{"text":"cleaned text"}]},"finishReason":"STOP"}]}`)
	})

	out, err := be.Cleanup(context.Background(), "the raw prompt")
	if err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if out != "cleaned text" {
		t.Errorf("got %q, want %q", out, "cleaned text")
	}
	if !strings.HasSuffix(gotPath, "/models/gemini-3.5-flash-lite:generateContent") {
		t.Errorf("unexpected path %q", gotPath)
	}
	// The credential must travel as a header, never in the URL.
	if gotKey != "test-key" {
		t.Errorf("api key header = %q", gotKey)
	}
	if len(gotReq.Contents) != 1 || len(gotReq.Contents[0].Parts) != 1 ||
		gotReq.Contents[0].Parts[0].Text != "the raw prompt" {
		t.Errorf("prompt not sent verbatim: %+v", gotReq.Contents)
	}
	if gotReq.GenerationConfig.Temperature != 0 {
		t.Errorf("temperature = %v, want 0", gotReq.GenerationConfig.Temperature)
	}
}

func TestGeminiKeyNeverAppearsInURL(t *testing.T) {
	var rawURL string
	be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
		rawURL = r.URL.String()
		io.WriteString(w, `{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}`)
	})
	if _, err := be.Cleanup(context.Background(), "p"); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if strings.Contains(rawURL, "test-key") {
		t.Errorf("api key leaked into URL: %q", rawURL)
	}
}

func TestGeminiThinkingLevel(t *testing.T) {
	tests := []struct {
		name      string
		level     string
		wantSent  bool
		wantLevel string
	}{
		// Gemini 3.x takes a string level; the old integer thinkingBudget form
		// returns 400 INVALID_ARGUMENT, which is why this is not an int.
		{"low is sent through", "low", true, "low"},
		{"minimal is sent through", "minimal", true, "minimal"},
		{"empty omits the field entirely", "", false, ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var raw map[string]any
			be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				_ = json.Unmarshal(body, &raw)
				io.WriteString(w, `{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}`)
			})
			be.ThinkingLevel = tc.level
			if _, err := be.Cleanup(context.Background(), "p"); err != nil {
				t.Fatalf("Cleanup: %v", err)
			}
			gc, _ := raw["generationConfig"].(map[string]any)
			tcfg, present := gc["thinkingConfig"]
			if present != tc.wantSent {
				t.Fatalf("thinkingConfig present = %v, want %v", present, tc.wantSent)
			}
			if tc.wantSent {
				got, _ := tcfg.(map[string]any)["thinkingLevel"].(string)
				if got != tc.wantLevel {
					t.Errorf("thinkingLevel = %q, want %q", got, tc.wantLevel)
				}
				if _, bad := tcfg.(map[string]any)["thinkingBudget"]; bad {
					t.Error("sent thinkingBudget — Gemini 3.x rejects it with 400")
				}
			}
		})
	}
}

// Reasoning parts must never leak into the pasted transcript.
func TestGeminiSkipsThoughtParts(t *testing.T) {
	be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"candidates":[{"content":{"parts":[
			{"text":"let me think about this","thought":true},
			{"text":"internal note","metadata":{"isThinking":true}},
			{"text":"the real answer"}
		]}}]}`)
	})
	out, err := be.Cleanup(context.Background(), "p")
	if err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if out != "the real answer" {
		t.Errorf("got %q, want %q", out, "the real answer")
	}
}

func TestGeminiErrorPaths(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		body    string
		wantSub string
	}{
		{"http error", http.StatusTooManyRequests, `{"error":{"code":429}}`, "gemini returned 429"},
		{"safety block", http.StatusOK, `{"promptFeedback":{"blockReason":"SAFETY"}}`, "blocked"},
		{"no candidates", http.StatusOK, `{"candidates":[]}`, "no candidates"},
		{"empty text", http.StatusOK, `{"candidates":[{"content":{"parts":[{"text":"  "}]},"finishReason":"MAX_TOKENS"}]}`, "empty text"},
		{"inline error", http.StatusOK, `{"error":{"code":401,"status":"UNAUTHENTICATED"}}`, "gemini error 401"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				io.WriteString(w, tc.body)
			})
			_, err := be.Cleanup(context.Background(), "p")
			if err == nil {
				t.Fatal("expected an error so the caller can fall back to raw text")
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Errorf("error %q does not contain %q", err, tc.wantSub)
			}
		})
	}
}

// An error must never carry the API key into logs.
func TestGeminiErrorDoesNotLeakKey(t *testing.T) {
	be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		io.WriteString(w, `{"error":{"code":401}}`)
	})
	_, err := be.Cleanup(context.Background(), "p")
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(err.Error(), "test-key") {
		t.Errorf("api key leaked into error: %v", err)
	}
}

func TestGeminiHealthy(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		want   bool
	}{
		{"model reachable", http.StatusOK, true},
		{"bad key", http.StatusUnauthorized, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var method, path string
			be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
				method, path = r.Method, r.URL.Path
				w.WriteHeader(tc.status)
			})
			if got := be.Healthy(context.Background()); got != tc.want {
				t.Errorf("Healthy() = %v, want %v", got, tc.want)
			}
			if method != http.MethodGet {
				t.Errorf("health probe used %s, want GET (must not spend generation quota)", method)
			}
			if strings.Contains(path, ":generateContent") {
				t.Errorf("health probe hit the generate endpoint: %q", path)
			}
		})
	}
}

func TestGeminiName(t *testing.T) {
	be := &GeminiBackend{}
	if be.Name() != "gemini" {
		t.Errorf("Name() = %q", be.Name())
	}
}

// TestGeminiPlanActionSafetySettings pins the control-only safety thresholds:
// PlanAction must attach BLOCK_ONLY_HIGH on all four harm categories (the
// default filter blocked ordinary desktop goals step 0 — live 2026-09-08),
// and Cleanup must keep sending none.
func TestGeminiPlanActionSafetySettings(t *testing.T) {
	var got map[string]any
	be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		io.WriteString(w, `{"candidates":[{"content":{"parts":[{"text":"{\"action\":\"done\",\"note\":\"ok\"}"}]}}]}`)
	})
	be.ControlUseTool = true
	be.ControlModel = ""
	if _, _, err := be.PlanAction(context.Background(), "the prompt", []byte("\xff\xd8jpeg")); err != nil {
		t.Fatalf("PlanAction: %v", err)
	}
	settings, ok := got["safetySettings"].([]any)
	if !ok || len(settings) != 4 {
		t.Fatalf("safetySettings = %v, want 4 entries", got["safetySettings"])
	}
	for _, s := range settings {
		m, _ := s.(map[string]any)
		if m["threshold"] != "BLOCK_ONLY_HIGH" {
			t.Errorf("category %v threshold = %v, want BLOCK_ONLY_HIGH", m["category"], m["threshold"])
		}
		switch m["category"] {
		case "HARM_CATEGORY_HARASSMENT", "HARM_CATEGORY_HATE_SPEECH",
			"HARM_CATEGORY_SEXUALLY_EXPLICIT", "HARM_CATEGORY_DANGEROUS_CONTENT":
		default:
			t.Errorf("unexpected category %v", m["category"])
		}
	}

	// Cleanup: the dictation prompt is the user's own words — no overrides.
	got = nil
	if _, err := be.Cleanup(context.Background(), "p"); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}
	if _, present := got["safetySettings"]; present {
		t.Errorf("Cleanup sent safetySettings: %v", got["safetySettings"])
	}
}

// TestGeminiPlanActionRetriesSafetyBlock pins the one planner retry on a
// prompt-level safety block: a blocked attempt is retried immediately (the
// filter is nondeterministic per screenshot and a blocked call produces
// nothing that could double-execute), then surfaces as ErrSafetyBlock. A
// non-safety failure is never retried.
func TestGeminiPlanActionRetriesSafetyBlock(t *testing.T) {
	tests := []struct {
		name      string
		bodies    []string
		wantCalls int
		wantErr   bool
	}{
		{
			name:      "block then block",
			bodies:    []string{`{"promptFeedback":{"blockReason":"SAFETY"}}`, `{"promptFeedback":{"blockReason":"SAFETY"}}`},
			wantCalls: 2,
			wantErr:   true,
		},
		{
			name:      "block then success",
			bodies:    []string{`{"promptFeedback":{"blockReason":"SAFETY"}}`, `{"candidates":[{"content":{"parts":[{"text":"{\"action\":\"click\",\"x\":1,\"y\":2}"}]}}]}`},
			wantCalls: 2,
		},
		{
			name:      "non-safety failure is NOT retried",
			bodies:    []string{`{"error":{"code":429}}`},
			wantCalls: 1,
			wantErr:   true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			be, _ := newTestGemini(t, func(w http.ResponseWriter, r *http.Request) {
				n := calls
				calls++
				if n >= len(tc.bodies) {
					t.Errorf("unexpected extra call %d", n)
					n = len(tc.bodies) - 1
				}
				io.WriteString(w, tc.bodies[n])
			})
			be.ControlUseTool = true
			_, _, err := be.PlanAction(context.Background(), "the prompt", []byte("\xff\xd8jpeg"))
			if calls != tc.wantCalls {
				t.Fatalf("calls = %d, want %d", calls, tc.wantCalls)
			}
			if tc.wantErr {
				if errors.Is(err, ErrSafetyBlock) != (len(tc.bodies) == 2) {
					t.Fatalf("err = %v, safety-wrapped = %v, want %v", err, errors.Is(err, ErrSafetyBlock), len(tc.bodies) == 2)
				}
				return
			}
			if err != nil {
				t.Fatalf("PlanAction: %v", err)
			}
		})
	}
}

// Compile-time proof the backend satisfies the interface the server depends on.
var _ Backend = (*GeminiBackend)(nil)
