package server

import (
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
	"github.com/sunoflow/cleanup-gateway/internal/backend"
	"github.com/sunoflow/cleanup-gateway/internal/ratelimit"
	"github.com/sunoflow/cleanup-gateway/internal/store"
)

// tryonEvents extracts (event, data) pairs named "tryon" and joins the delta
// text of an answer SSE stream.
func tryonEvents(t *testing.T, events [][2]string) (item string, deltas string, found bool) {
	t.Helper()
	for _, ev := range events {
		switch ev[0] {
		case "tryon":
			var p map[string]string
			if err := json.Unmarshal([]byte(ev[1]), &p); err != nil {
				t.Fatalf("tryon payload: %v", err)
			}
			item = p["item"]
			found = true
		case "delta":
			var p map[string]string
			_ = json.Unmarshal([]byte(ev[1]), &p)
			deltas += p["text"]
		}
	}
	return
}

func TestAnswer_TryonMarkerHeldBack(t *testing.T) {
	// The marker arrives split across chunks, with the item label bolded —
	// the shapes the real stream produces.
	ab := &sseBackend{fakeBackend: &fakeBackend{}, chunks: []backend.AnswerChunk{
		{Text: "[[TRY"},
		{Text: "ON]] **the grey hoodie**\nYou'd look"},
		{Text: " great in it."},
	}}
	ts, key := newAnswerServer(t, ab)
	resp := postAnswer(t, ts, key, answerBody("how would I look in this hoodie?", 0, false))
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	events := parseSSE(t, resp)

	// Order: meta first, then tryon, then deltas.
	if events[0][0] != "meta" {
		t.Fatalf("first event = %q", events[0][0])
	}
	item, deltas, found := tryonEvents(t, events)
	if !found {
		t.Fatal("tryon event missing")
	}
	if item != "the grey hoodie" {
		t.Fatalf("item = %q", item)
	}
	if deltas != "You'd look great in it." {
		t.Fatalf("deltas = %q", deltas)
	}
	// The raw marker must never reach the client.
	if strings.Contains(deltas, "TRYON") {
		t.Fatalf("marker leaked into deltas: %q", deltas)
	}
	// done still terminates the stream.
	if events[len(events)-1][0] != "done" {
		t.Fatalf("last event = %q", events[len(events)-1][0])
	}
}

func TestAnswer_TryonMarkerWholeFirstChunk(t *testing.T) {
	ab := &sseBackend{fakeBackend: &fakeBackend{}, chunks: []backend.AnswerChunk{
		{Text: "[[TRYON]] a leather jacket\nNice choice —"},
		{Text: " it suits you."},
	}}
	ts, key := newAnswerServer(t, ab)
	resp := postAnswer(t, ts, key, answerBody("try on a leather jacket", 0, false))
	defer resp.Body.Close()
	events := parseSSE(t, resp)
	item, deltas, found := tryonEvents(t, events)
	if !found || item != "a leather jacket" {
		t.Fatalf("item = %q found=%v", item, found)
	}
	if deltas != "Nice choice — it suits you." {
		t.Fatalf("deltas = %q", deltas)
	}
}

func TestAnswer_NoMarkerWhenFirstLineIsNotMarker(t *testing.T) {
	// An ordinary reply must pass through byte-identical, including a first
	// line that merely contains brackets.
	ab := &sseBackend{fakeBackend: &fakeBackend{}, chunks: []backend.AnswerChunk{
		{Text: "[see section 2]\nThe docs say"},
		{Text: " otherwise."},
	}}
	ts, key := newAnswerServer(t, ab)
	resp := postAnswer(t, ts, key, answerBody("what does section 2 say?", 0, false))
	defer resp.Body.Close()
	events := parseSSE(t, resp)
	item, deltas, found := tryonEvents(t, events)
	if found {
		t.Fatalf("unexpected tryon event (item %q)", item)
	}
	if deltas != "[see section 2]\nThe docs say otherwise." {
		t.Fatalf("deltas = %q", deltas)
	}
}

func TestAnswer_StreamEndsWithoutNewlineFlushesBuffer(t *testing.T) {
	// No newline anywhere: the hold-back must flush at stream end, not eat
	// the whole reply.
	ab := &sseBackend{fakeBackend: &fakeBackend{}, chunks: []backend.AnswerChunk{
		{Text: "Short reply, no newline"},
	}}
	ts, key := newAnswerServer(t, ab)
	resp := postAnswer(t, ts, key, answerBody("quick?", 0, false))
	defer resp.Body.Close()
	events := parseSSE(t, resp)
	_, deltas, found := tryonEvents(t, events)
	if found {
		t.Fatal("unexpected tryon event")
	}
	if deltas != "Short reply, no newline" {
		t.Fatalf("deltas = %q", deltas)
	}
}

func TestAnswer_AnalyticsRecordsTryon(t *testing.T) {
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
			{Text: "[[TRYON]] the denim jacket\nLooking good."},
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

	resp := postAnswer(t, ts, plaintext, answerBody("how does this look on me?", 0, false))
	resp.Body.Close()

	stats.Close() // flush
	time.Sleep(50 * time.Millisecond)

	mu.Lock()
	posted := strings.Join(collected, "\n")
	mu.Unlock()

	var batch struct {
		Batch []struct {
			Event      string         `json:"event"`
			Properties map[string]any `json:"properties"`
		} `json:"batch"`
	}
	if err := json.Unmarshal([]byte(posted), &batch); err != nil {
		t.Fatalf("unparseable batch: %v", err)
	}
	var ev map[string]any
	for _, b := range batch.Batch {
		if b.Event == "answer" {
			ev = b.Properties
		}
	}
	if ev == nil {
		t.Fatal("no answer event captured")
	}
	if ev["had_tryon"] != true {
		t.Errorf("had_tryon = %v", ev["had_tryon"])
	}
	if n, _ := ev["tryon_item_length"].(float64); n != float64(len("the denim jacket")) {
		t.Errorf("tryon_item_length = %v", ev["tryon_item_length"])
	}
}
