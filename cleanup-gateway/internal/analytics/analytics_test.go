package analytics

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError + 1}))
}

// collector stands in for PostHog and records the raw bodies it is posted, so a
// test can assert on exactly what would have crossed the network.
type collector struct {
	mu     sync.Mutex
	bodies []string
	got    chan struct{}
}

func newCollector() (*collector, *httptest.Server) {
	c := &collector{got: make(chan struct{}, 16)}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		c.mu.Lock()
		c.bodies = append(c.bodies, string(b))
		c.mu.Unlock()
		w.WriteHeader(http.StatusOK)
		c.got <- struct{}{}
	}))
	return c, ts
}

func (c *collector) wait(t *testing.T) {
	t.Helper()
	select {
	case <-c.got:
	case <-time.After(5 * time.Second):
		t.Fatal("no batch delivered")
	}
}

func (c *collector) all() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.bodies...)
}

// The privacy default. No key configured must mean no client, no goroutine and
// no network call — not a client that quietly posts to a default endpoint.
func TestNoKeyMeansNothingIsSent(t *testing.T) {
	c, ts := newCollector()
	defer ts.Close()

	client := New("", ts.URL, quietLogger())
	if client.Enabled() {
		t.Fatal("client with no API key reports itself enabled")
	}
	client.Capture(Event{Name: "dictation", DistinctID: "u1"})
	client.Close()

	if len(c.all()) != 0 {
		t.Errorf("a disabled client posted %d batches", len(c.all()))
	}
}

// Server.Analytics is nil wherever analytics is not wired up, including every
// existing test. Capturing on that must be a no-op, not a panic on the
// dictation path.
func TestNilClientIsSafe(t *testing.T) {
	var client *Client
	if client.Enabled() {
		t.Error("nil client reports itself enabled")
	}
	client.Capture(Event{Name: "dictation", DistinctID: "u1"})
	client.Close()
}

func TestEventsAreBatchedAndShaped(t *testing.T) {
	c, ts := newCollector()
	defer ts.Close()

	client := New("phc_test", ts.URL, quietLogger())
	client.Capture(Event{
		Name:             "dictation",
		DistinctID:       "user-1",
		Properties:       map[string]any{"os": "mac", "transcript_chars": 42},
		PersonProperties: map[string]any{"os": "mac"},
	})
	client.Close()
	c.wait(t)

	var batch struct {
		APIKey string `json:"api_key"`
		Batch  []struct {
			Event      string         `json:"event"`
			DistinctID string         `json:"distinct_id"`
			Properties map[string]any `json:"properties"`
		} `json:"batch"`
	}
	if err := json.Unmarshal([]byte(c.all()[0]), &batch); err != nil {
		t.Fatalf("body is not the batch shape: %v", err)
	}
	if batch.APIKey != "phc_test" {
		t.Errorf("api_key = %q", batch.APIKey)
	}
	if len(batch.Batch) != 1 {
		t.Fatalf("expected 1 event, got %d", len(batch.Batch))
	}
	e := batch.Batch[0]
	if e.Event != "dictation" || e.DistinctID != "user-1" {
		t.Errorf("event = %q, distinct_id = %q", e.Event, e.DistinctID)
	}
	if e.Properties["os"] != "mac" {
		t.Errorf("os property = %v", e.Properties["os"])
	}
	if _, ok := e.Properties["$set"]; !ok {
		t.Error("person properties did not travel as $set")
	}
}

// Server-side, the only IP PostHog could see is the gateway's, which would put
// every user in one datacentre. Explicitly null keeps it from guessing.
func TestGeoIPIsDisabled(t *testing.T) {
	c, ts := newCollector()
	defer ts.Close()

	client := New("phc_test", ts.URL, quietLogger())
	client.Capture(Event{Name: "dictation", DistinctID: "user-1"})
	client.Close()
	c.wait(t)

	var batch struct {
		Batch []struct {
			Properties map[string]any `json:"properties"`
		} `json:"batch"`
	}
	_ = json.Unmarshal([]byte(c.all()[0]), &batch)
	ip, present := batch.Batch[0].Properties["$ip"]
	if !present || ip != nil {
		t.Errorf("$ip = %v (present=%v), want an explicit null", ip, present)
	}
}

// An event with nobody attached is not worth a network call, and would show up
// in PostHog as a phantom user.
func TestEventWithoutAnIdentityIsDropped(t *testing.T) {
	c, ts := newCollector()
	defer ts.Close()

	client := New("phc_test", ts.URL, quietLogger())
	client.Capture(Event{Name: "dictation", DistinctID: ""})
	client.Close()

	if len(c.all()) != 0 {
		t.Errorf("an event with no distinct_id was sent: %v", c.all())
	}
}

// A dead or slow analytics vendor must not become a dead dictation path.
// Capture is called with the user waiting, so it has to return regardless.
func TestCaptureNeverBlocks(t *testing.T) {
	// A server that never answers, so every flush is stuck in-flight.
	block := make(chan struct{})
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-block
	}))
	defer ts.Close()
	defer close(block)

	client := New("phc_test", ts.URL, quietLogger())

	done := make(chan struct{})
	go func() {
		// Comfortably more than the queue holds, so the drop path is exercised
		// too rather than just the buffered one.
		for i := 0; i < queueSize*3; i++ {
			client.Capture(Event{Name: "dictation", DistinctID: "user-1"})
		}
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Capture blocked when the analytics endpoint stopped answering")
	}
}

func TestHostNormalization(t *testing.T) {
	cases := map[string]string{
		"":                          "",
		"us.i.posthog.com":          "https://us.i.posthog.com",
		"https://us.i.posthog.com":  "https://us.i.posthog.com",
		"https://us.i.posthog.com/": "https://us.i.posthog.com",
		"http://localhost:8000":     "http://localhost:8000",
	}
	for in, want := range cases {
		if got := Host(in); got != want {
			t.Errorf("Host(%q) = %q, want %q", in, got, want)
		}
	}
}
