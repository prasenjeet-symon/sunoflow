// Package analytics reports product counters — how many people use SunoFlow,
// how much they dictate, and on which OS — to PostHog.
//
// It lives in the gateway rather than in the two client apps for three reasons.
// Every dictation already passes through here, so the numbers are available
// without asking anyone; the account uid is already resolved here, so "how many
// users" is a real answer rather than a guess from install counts; and changing
// what is measured is then a gateway restart instead of a Mac release, a Windows
// release, and a wait for everyone to update.
//
// WHAT IS NEVER SENT: no transcript, no cleaned text, no screen OCR, no cursor
// context, no dictionary entry, no audio, no IP address. The product's promise
// is that speech stays on the user's machine, and analytics is exactly the kind
// of well-meaning addition that quietly breaks such a promise. Only counts,
// durations, and the platform string travel. Everything in this file that
// touches a request body handles lengths, never contents.
package analytics

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
	"time"
)

// Event is one thing worth counting.
type Event struct {
	// Name is the PostHog event name, e.g. "dictation".
	Name string
	// DistinctID identifies the person. The account uid, so one customer with
	// three machines counts as one user rather than three.
	DistinctID string
	// Properties are the event's dimensions. Numbers and short enums only —
	// see the package comment for what must never appear here.
	Properties map[string]any
	// PersonProperties are set on the person rather than the event, so a
	// breakdown by OS or version reflects the user's current state.
	PersonProperties map[string]any
}

// Client batches events and posts them to PostHog.
//
// A nil or disabled Client is safe to call: Capture is a no-op. That is the
// configured state when POSTHOG_API_KEY is empty, which is how a local or
// self-hosted deployment runs with no analytics at all.
type Client struct {
	apiKey string
	host   string
	http   *http.Client
	log    *slog.Logger

	queue chan Event
	done  chan struct{}
	wg    sync.WaitGroup

	// dropped counts events thrown away because the queue was full, reported
	// once on shutdown. A silent drop would make a dip in the numbers look like
	// a dip in usage.
	mu      sync.Mutex
	dropped int
}

const (
	// queueSize is the backlog tolerated before events are dropped. Sized for a
	// flush stall, not for retention: losing a count is an acceptable outcome,
	// blocking a dictation is not.
	queueSize = 1024
	// batchMax is how many events go in one request.
	batchMax = 100
	// flushEvery bounds how stale the numbers get when traffic is light.
	flushEvery = 10 * time.Second
)

// New returns a running client, or a disabled one when apiKey is empty.
func New(apiKey, host string, log *slog.Logger) *Client {
	c := &Client{
		apiKey: apiKey,
		host:   host,
		log:    log,
		http:   &http.Client{Timeout: 10 * time.Second},
		queue:  make(chan Event, queueSize),
		done:   make(chan struct{}),
	}
	if !c.Enabled() {
		return c
	}
	c.wg.Add(1)
	go c.run()
	return c
}

// Enabled reports whether events actually go anywhere.
func (c *Client) Enabled() bool { return c != nil && c.apiKey != "" }

// Capture queues an event. It never blocks and never fails: this is called from
// the dictation path, where the user is waiting, and a counter is not worth one
// millisecond of that. A full queue drops.
func (c *Client) Capture(e Event) {
	if !c.Enabled() || e.DistinctID == "" {
		return
	}
	select {
	case c.queue <- e:
	default:
		c.mu.Lock()
		c.dropped++
		c.mu.Unlock()
	}
}

// Close flushes what is queued and stops the worker.
func (c *Client) Close() {
	if !c.Enabled() {
		return
	}
	close(c.done)
	c.wg.Wait()
	c.mu.Lock()
	dropped := c.dropped
	c.mu.Unlock()
	if dropped > 0 {
		c.log.Warn("analytics events dropped; counts under-report", "dropped", dropped)
	}
}

func (c *Client) run() {
	defer c.wg.Done()
	ticker := time.NewTicker(flushEvery)
	defer ticker.Stop()

	batch := make([]Event, 0, batchMax)
	flush := func() {
		if len(batch) == 0 {
			return
		}
		c.send(batch)
		batch = batch[:0]
	}

	for {
		select {
		case e := <-c.queue:
			batch = append(batch, e)
			if len(batch) >= batchMax {
				flush()
			}
		case <-ticker.C:
			flush()
		case <-c.done:
			// Drain whatever arrived before the stop, then go.
			for {
				select {
				case e := <-c.queue:
					batch = append(batch, e)
					if len(batch) >= batchMax {
						flush()
					}
					continue
				default:
				}
				break
			}
			flush()
			return
		}
	}
}

type wireEvent struct {
	Event      string         `json:"event"`
	DistinctID string         `json:"distinct_id"`
	Properties map[string]any `json:"properties"`
	Timestamp  string         `json:"timestamp"`
}

type wireBatch struct {
	APIKey string      `json:"api_key"`
	Batch  []wireEvent `json:"batch"`
}

// send posts one batch. Failures are logged and discarded — there is no retry,
// because a retry queue is a way to turn an outage at the analytics vendor into
// memory pressure on the thing that serves dictations.
func (c *Client) send(batch []Event) {
	wire := wireBatch{APIKey: c.apiKey, Batch: make([]wireEvent, 0, len(batch))}
	now := time.Now().UTC().Format(time.RFC3339)
	for _, e := range batch {
		props := map[string]any{}
		for k, v := range e.Properties {
			props[k] = v
		}
		if len(e.PersonProperties) > 0 {
			props["$set"] = e.PersonProperties
		}
		// Explicitly null so PostHog does not geo-locate anyone. Server-side, the
		// only IP it could see is the gateway's, which would place every user in
		// one datacentre — wrong, and not ours to collect either way.
		props["$ip"] = nil
		wire.Batch = append(wire.Batch, wireEvent{
			Event:      e.Name,
			DistinctID: e.DistinctID,
			Properties: props,
			Timestamp:  now,
		})
	}

	body, err := json.Marshal(wire)
	if err != nil {
		c.log.Warn("analytics: could not encode batch", "err", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.host+"/batch/", bytes.NewReader(body))
	if err != nil {
		c.log.Warn("analytics: could not build request", "err", err)
		return
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		c.log.Warn("analytics: batch not delivered", "err", err, "events", len(batch))
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		c.log.Warn("analytics: batch refused", "status", resp.StatusCode, "events", len(batch))
	}
}

// Host normalizes a configured host into an API root, so both
// "us.i.posthog.com" and "https://us.i.posthog.com/" work.
func Host(raw string) string {
	if raw == "" {
		return ""
	}
	h := raw
	if len(h) > 0 && h[len(h)-1] == '/' {
		h = h[:len(h)-1]
	}
	if len(h) < 8 || (h[:7] != "http://" && h[:8] != "https://") {
		h = "https://" + h
	}
	return fmt.Sprintf("%s", h)
}
