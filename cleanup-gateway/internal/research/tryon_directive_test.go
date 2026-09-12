package research

import (
	"strings"
	"testing"
)

func TestBuildAnswerPrompt_TryonDirectiveArmedAndDormant(t *testing.T) {
	q := "how would I look in this hoodie?"
	// Armed: the directive appears before [SCREEN]/[QUESTION].
	with := BuildAnswerPrompt(AnswerPrompt{Query: q, Tryon: true, Image: true})
	joined := strings.Join(with, "\n")
	if !strings.Contains(joined, "[[TRYON]]") {
		t.Errorf("tryon directive missing when armed:\n%s", joined)
	}
	if !strings.Contains(joined, "Trying things on:") {
		t.Errorf("tryon directive text missing:\n%s", joined)
	}
	// Order: framing → directive → [SCREEN] → [QUESTION].
	if i := strings.Index(joined, "Trying things on:"); i < 0 ||
		strings.Index(joined, screenHeader) < i ||
		strings.Index(joined, queryHeader) < strings.Index(joined, screenHeader) {
		t.Errorf("section order wrong:\n%s", joined)
	}

	// Dormant: no directive, and the marker string must not leak into the
	// prompt at all (the model must never learn the marker exists unless the
	// client armed the feature).
	without := BuildAnswerPrompt(AnswerPrompt{Query: q, Image: true})
	if strings.Contains(strings.Join(without, "\n"), "TRYON") {
		t.Errorf("tryon directive present when disarmed:\n%s", strings.Join(without, "\n"))
	}
}

func TestTryonDirective_MarkerForm(t *testing.T) {
	// The directive must teach the exact uppercase two-bracket marker the
	// gateway's hold-back scans for, so the pair cannot drift apart silently.
	if !strings.Contains(tryonDirective, "[[TRYON]]") {
		t.Errorf("directive must name the exact marker %q", "[[TRYON]]")
	}
}
