package server

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/sunoflow/cleanup-gateway/internal/analytics"
	"github.com/sunoflow/cleanup-gateway/internal/auth"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// serverWithAnalytics wires a real analytics client at a collector, so a test
// can read exactly what would have been posted for a real request.
func serverWithAnalytics(t *testing.T, fb *fakeBackend) (gw *httptest.Server, key string, bodies func() []string, flush func()) {
	t.Helper()

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
	srv := &Server{
		Backend:    fb,
		Store:      st,
		Logger:     testLogger(),
		QuotaRPM:   1000,
		QuotaDaily: 100000,
		Analytics:  stats,
	}
	limiter := ratelimit.New(st, 1000, 100000, nil)
	ts := httptest.NewServer(NewMux(srv, limiter, "admin-secret", nil))
	t.Cleanup(ts.Close)

	return ts, plaintext, func() []string {
			mu.Lock()
			defer mu.Unlock()
			return append([]string(nil), collected...)
		}, func() {
			stats.Close() // flushes
			time.Sleep(50 * time.Millisecond)
		}
}

// The one that matters. Analytics sits inside the handler that holds the
// transcript, the cleaned text, the screen OCR, the cursor context and the
// user's dictionary — every one of which is the sort of thing that ends up in
// an events pipeline by accident and is then very hard to get back out.
func TestAnalyticsNeverCarriesDictationContent(t *testing.T) {
	const (
		secretTranscript = "ZZTRANSCRIPTZZ my bank password is hunter2"
		secretContext    = "ZZCONTEXTZZ already written before the cursor"
		secretScreen     = "ZZSCREENZZ words visible on the user screen"
		secretTerm       = "ZZDICTIONARYZZ"
		secretCleaned    = "ZZCLEANEDZZ tidied up"
	)

	fb := &fakeBackend{resp: secretCleaned}
	gw, key, bodies, flush := serverWithAnalytics(t, fb)

	body, _ := json.Marshal(map[string]any{
		"text":    secretTranscript,
		"context": secretContext,
		"screen":  secretScreen,
		"dictionary": []map[string]string{
			{"from": secretTerm, "to": secretTerm + "-expanded", "kind": "correction"},
		},
	})
	req, _ := http.NewRequest(http.MethodPost, gw.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set(clientHeader, "windows/1.1.2")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	resp.Body.Close()

	flush()
	posted := strings.Join(bodies(), "\n")
	if posted == "" {
		t.Fatal("no analytics batch was posted, so this proves nothing")
	}

	for _, secret := range []string{
		secretTranscript, secretContext, secretScreen, secretTerm, secretCleaned,
		"hunter2", "ZZ",
	} {
		if strings.Contains(posted, secret) {
			t.Errorf("dictation content reached analytics: %q appears in the payload", secret)
		}
	}
}

func TestAnalyticsRecordsTheDimensionsWeActuallyWanted(t *testing.T) {
	fb := &fakeBackend{resp: "Cleaned."}
	gw, key, bodies, flush := serverWithAnalytics(t, fb)

	body, _ := json.Marshal(map[string]any{"text": "um so anyway", "screen": "some screen words"})
	req, _ := http.NewRequest(http.MethodPost, gw.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set(clientHeader, "windows/1.1.2")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	resp.Body.Close()
	flush()

	var batch struct {
		Batch []struct {
			Event      string         `json:"event"`
			DistinctID string         `json:"distinct_id"`
			Properties map[string]any `json:"properties"`
		} `json:"batch"`
	}
	all := bodies()
	if len(all) == 0 {
		t.Fatal("no analytics batch posted")
	}
	if err := json.Unmarshal([]byte(all[0]), &batch); err != nil {
		t.Fatalf("unparseable batch: %v", err)
	}
	if len(batch.Batch) == 0 {
		t.Fatal("batch carried no events")
	}
	e := batch.Batch[0]

	if e.Event != "dictation" {
		t.Errorf("event = %q, want dictation", e.Event)
	}
	if e.DistinctID == "" {
		t.Error("no distinct_id, so this dictation counts towards nobody")
	}
	if e.Properties["os"] != "windows" {
		t.Errorf("os = %v, want windows — the whole point is the platform split", e.Properties["os"])
	}
	if e.Properties["app_version"] != "1.1.2" {
		t.Errorf("app_version = %v", e.Properties["app_version"])
	}
	if e.Properties["transcript_chars"] != float64(len("um so anyway")) {
		t.Errorf("transcript_chars = %v", e.Properties["transcript_chars"])
	}
	if e.Properties["had_screen"] != true {
		t.Errorf("had_screen = %v", e.Properties["had_screen"])
	}
}

// A sidecar that predates the header still has to be counted — as an old
// install, not as no install.
func TestAnalyticsToleratesAClientThatSendsNoHeader(t *testing.T) {
	fb := &fakeBackend{resp: "Cleaned."}
	gw, key, bodies, flush := serverWithAnalytics(t, fb)

	body, _ := json.Marshal(map[string]any{"text": "hello world"})
	req, _ := http.NewRequest(http.MethodPost, gw.URL+"/cleanup", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	resp.Body.Close()
	flush()

	posted := strings.Join(bodies(), "\n")
	if !strings.Contains(posted, `"os":"unknown"`) {
		t.Errorf("a headerless client should report os=unknown; got %s", posted)
	}
}

func TestParseClient(t *testing.T) {
	cases := []struct{ in, wantOS, wantVer string }{
		{"mac/1.1.2", "mac", "1.1.2"},
		{"windows/1.1.2", "windows", "1.1.2"},
		{"", "unknown", "unknown"},
		{"mac", "mac", "unknown"},
		{"/1.1.2", "unknown", "1.1.2"},
		{"  mac / 1.1.2  ", "mac", "1.1.2"},
	}
	for _, c := range cases {
		gotOS, gotVer := parseClient(c.in)
		if gotOS != c.wantOS || gotVer != c.wantVer {
			t.Errorf("parseClient(%q) = %q,%q want %q,%q", c.in, gotOS, gotVer, c.wantOS, c.wantVer)
		}
	}

	// The header is attacker-controlled and becomes a property on every event.
	// An unbounded one would be an unbounded cardinality problem in PostHog.
	long := strings.Repeat("a", 500) + "/9"
	gotOS, _ := parseClient(long)
	if len(gotOS) > 64 {
		t.Errorf("parseClient did not bound a %d-char header; got %d chars", len(long), len(gotOS))
	}
}
