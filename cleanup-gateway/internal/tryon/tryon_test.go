package tryon

import (
	"strings"
	"testing"
)

func TestBuildPrompt_Order(t *testing.T) {
	out := BuildPrompt(Prompt{
		Item:   "the grey hoodie on this page",
		Query:  "how would I look in this?",
		App:    "Safari",
		Window: "Hoodie — Streetwear",
	})
	if len(out) == 0 {
		t.Fatal("BuildPrompt returned no sections")
	}
	joined := strings.Join(out, "\n")
	first := out[0]
	if !strings.Contains(first, "SunoFlow") {
		t.Errorf("framing must carry identity, got %q", first)
	}
	if !strings.Contains(first, "The first image shows a person") {
		t.Errorf("framing must state the person/garment contract, got %q", first)
	}
	var itemAt, queryAt, ctxAt int
	for i, s := range out {
		if s == itemHeader {
			itemAt = i
		}
		if s == queryHeader {
			queryAt = i
		}
		if strings.Contains(s, "Context (observed)") {
			ctxAt = i
		}
	}
	if itemAt == 0 {
		t.Errorf("[ITEM] header missing: %q", joined)
	}
	if queryAt == 0 {
		t.Errorf("[REQUEST] header missing: %q", joined)
	}
	if itemAt > queryAt {
		t.Errorf("[ITEM] must precede [REQUEST]: item at %d, request at %d", itemAt, queryAt)
	}
	if ctxAt != 0 && ctxAt < queryAt {
		t.Errorf("context line must follow [REQUEST], got %d < %d", ctxAt, queryAt)
	}
	// The item and query must appear verbatim after their headers.
	if !strings.Contains(joined, "the grey hoodie on this page") {
		t.Errorf("item missing from prompt: %q", joined)
	}
	if !strings.Contains(joined, "how would I look in this?") {
		t.Errorf("query missing from prompt: %q", joined)
	}
	if !strings.Contains(joined, "Safari") || !strings.Contains(joined, "Hoodie — Streetwear") {
		t.Errorf("context line missing app/window: %q", joined)
	}
}

func TestBuildPrompt_NoContextWhenClientReportsNone(t *testing.T) {
	out := BuildPrompt(Prompt{Item: "a hat", Query: "try it on"})
	joined := strings.Join(out, "\n")
	if strings.Contains(joined, "Context (observed)") {
		t.Errorf("context line must be absent when app/window empty: %q", joined)
	}
}

func TestBuildPrompt_Caps(t *testing.T) {
	// V and Z appear nowhere in the framing or headers, so counting them
	// measures only the clipped fields.
	long := strings.Repeat("V", MaxItemLen+500)
	out := BuildPrompt(Prompt{Item: long, Query: strings.Repeat("Z", MaxQueryLen+500)})
	joined := strings.Join(out, "\n")
	if c := strings.Count(joined, "V"); c > MaxItemLen {
		t.Errorf("item not clipped: %d > %d", c, MaxItemLen)
	}
	if c := strings.Count(joined, "Z"); c > MaxQueryLen {
		t.Errorf("query not clipped: %d > %d", c, MaxQueryLen)
	}
}
