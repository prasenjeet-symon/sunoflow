package research

import (
	"strings"
	"testing"

	"github.com/sunoflow/cleanup-gateway/internal/cleanup"
)

func TestBuildAnswerPrompt_Basic(t *testing.T) {
	lines := BuildAnswerPrompt(AnswerPrompt{Query: "what is the capital of France"})
	joined := strings.Join(lines, "\n")
	if !strings.Contains(joined, answerFraming) {
		t.Fatal("framing missing")
	}
	if !strings.Contains(joined, queryHeader) {
		t.Fatal("query header missing")
	}
	if !strings.Contains(joined, "what is the capital of France") {
		t.Fatal("query missing")
	}
	if strings.Contains(joined, screenHeader) {
		t.Fatal("screen header present without image")
	}
	if strings.Contains(joined, historyHeader) {
		t.Fatal("history header present without history")
	}
	if !strings.HasSuffix(strings.TrimSpace(joined), "what is the capital of France") {
		t.Fatal("query must be the last thing in the prompt")
	}
}

func TestBuildAnswerPrompt_ImageAndHistory(t *testing.T) {
	p := AnswerPrompt{
		Query: "second question",
		History: []Turn{
			{Question: "first question", Answer: "first answer"},
			{Question: "", Answer: "orphan answer"},
		},
		Image: true,
	}
	joined := strings.Join(BuildAnswerPrompt(p), "\n")
	if !strings.Contains(joined, screenHeader) {
		t.Fatal("screen header missing with image")
	}
	if !strings.Contains(joined, historyHeader) {
		t.Fatal("history header missing")
	}
	if !strings.Contains(joined, "User: first question") || !strings.Contains(joined, "Assistant: first answer") {
		t.Fatal("history lines missing")
	}
	// The orphan turn (empty question AND empty answer after clipping) is dropped
	// — an answer-only line is kept, so this one must survive.
	if !strings.Contains(joined, "orphan answer") {
		t.Fatal("answer-only turn was dropped")
	}
}

func TestBuildAnswerPrompt_HistoryOrderAndCap(t *testing.T) {
	var hist []Turn
	for i := 0; i < 12; i++ {
		hist = append(hist, Turn{Question: "q", Answer: "a"})
	}
	joined := strings.Join(BuildAnswerPrompt(AnswerPrompt{Query: "x", History: hist}), "\n")
	// MaxTurns=8 pairs → 16 "User:"/"Assistant:" lines.
	if got := strings.Count(joined, "User: "); got != MaxTurns {
		t.Fatalf("got %d user lines, want %d (oldest dropped)", got, MaxTurns)
	}
}

func TestBuildAnswerPrompt_QueryClipped(t *testing.T) {
	long := strings.Repeat("a", MaxQueryLen+500) // no other letter 'a' appears uniquely; count via suffix check
	joined := strings.Join(BuildAnswerPrompt(AnswerPrompt{Query: long}), "\n")
	if !strings.Contains(joined, strings.Repeat("a", MaxQueryLen)) {
		t.Fatal("clipped query lost its prefix")
	}
	if strings.Contains(joined, strings.Repeat("a", MaxQueryLen+1)) {
		t.Fatal("query not clipped at MaxQueryLen")
	}
}

func TestBuildAnswerPrompt_DictionaryRenders(t *testing.T) {
	p := AnswerPrompt{
		Query: "email my linkedin",
		Dictionary: []cleanup.Entry{
			{From: "my linkedin", To: "https://linkedin.com/in/prasenjeet", Kind: cleanup.KindExpansion},
		},
	}
	joined := strings.Join(BuildAnswerPrompt(p), "\n")
	if !strings.Contains(joined, `"my linkedin" -> "https://linkedin.com/in/prasenjeet"`) {
		t.Fatal("dictionary entry missing from answer prompt")
	}
}

// The framing must tell the model the question is dictated and may contain
// transcription errors, repaired via the dictionary and what is on screen.
func TestBuildAnswerPrompt_FramingCoversQueryInterpretation(t *testing.T) {
	joined := strings.Join(BuildAnswerPrompt(AnswerPrompt{Query: "q"}), "\n")
	for _, want := range []string{
		"transcription errors",
		"dictionary entries",
		"what is visible on screen",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("framing missing query-interpretation rule fragment %q", want)
		}
	}
}

// The answer panel renders Markdown with KaTeX math, so the framing must ask
// for that formatting — and must NOT ask for plain text (the old rule).
func TestBuildAnswerPrompt_FramingCoversMarkdownAndMath(t *testing.T) {
	joined := strings.Join(BuildAnswerPrompt(AnswerPrompt{Query: "q"}), "\n")
	for _, want := range []string{
		"Format with Markdown",
		"Math in LaTeX",
		"$...$",
		"$$...$$",
		"aligned environment",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("framing missing markdown/math rule fragment %q", want)
		}
	}
	if strings.Contains(joined, "Plain text only") {
		t.Fatal("stale plain-text rule still present in framing")
	}
}
