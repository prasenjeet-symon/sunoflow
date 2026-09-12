package control

import (
	"fmt"
	"strings"
	"testing"

	"github.com/sunoflow/cleanup-gateway/internal/cleanup"
)

func TestBuildPrompt_SectionOrder(t *testing.T) {
	cursorX, cursorY := 640, 400
	imgW, imgH := 1600, 1000
	lines := BuildPrompt(Prompt{
		Goal:        "open calculator",
		Steps:       []Step{{Action: "click", Note: "the Dock icon"}, {Action: "wait", Note: ""}},
		Dictionary:  []cleanup.Entry{{From: "calc", To: "Calculator"}},
		App:         "Finder",
		Window:      "Downloads",
		OS:          "macOS 15.5 (Version 15.5 (Build 24F90)) · Apple Silicon (arm64)",
		CursorX:     &cursorX,
		CursorY:     &cursorY,
		ImageWidth:  &imgW,
		ImageHeight: &imgH,
		Image:       true,
	})
	text := strings.Join(lines, "\n")

	var idx int
	check := func(name, substr string) {
		i := strings.Index(text, substr)
		if i < 0 {
			t.Fatalf("%s: substring %q missing from prompt", name, substr)
		}
		if i < idx {
			t.Fatalf("%s: %q appears out of order", name, substr)
		}
		idx = i
	}
	check("framing", "You are Suno Control")
	check("output rule", "EXACTLY one JSON object")
	check("os line", "Target operating system: macOS 15.5")
	check("screen header", "[SCREEN")
	check("coordinate rule", "PIXELS of this image")
	check("image dims", "This image is 1600 pixels wide and 1000 pixels tall")
	check("coordinate range", "x runs 0–1599 and y runs 0–999")
	check("steps header", "[STEPS ALREADY TAKEN]")
	check("step 1", "1. click — \"the Dock icon\"")
	check("step 2 no note", "2. wait")
	check("dictionary", "calc")
	check("goal header", "[GOAL]")
	check("goal", "open calculator")
	check("context", "Context (observed): App: Finder · Window: Downloads · Cursor: 640,400")
}

func TestBuildPrompt_Minimal(t *testing.T) {
	lines := BuildPrompt(Prompt{Goal: "quit safari"})
	text := strings.Join(lines, "\n")
	if strings.Contains(text, "[SCREEN") {
		t.Error("screen header present without Image")
	}
	if strings.Contains(text, "Target operating system") {
		t.Error("OS line present without a client-reported OS")
	}
	if strings.Contains(text, "[STEPS ALREADY TAKEN]") {
		t.Error("steps header present without steps")
	}
	if strings.Contains(text, "[DICTIONARY]") {
		t.Error("dictionary header present without entries")
	}
	if strings.Contains(text, "Context (observed)") {
		t.Error("context line present without context")
	}
	if !strings.Contains(text, "[GOAL]\nquit safari") {
		t.Errorf("goal section malformed: %q", text)
	}
}

func TestBuildPrompt_NormalizedCoords(t *testing.T) {
	w, h := 1600, 1000
	lines := BuildPrompt(Prompt{
		Goal:        "open calculator",
		App:         "Finder",
		ImageWidth:  &w,
		ImageHeight: &h,
		Image:       true,
		Normalized:  true,
	})
	text := strings.Join(lines, "\n")
	if !strings.Contains(text, "from 0 to 1000") {
		t.Errorf("normalized coordinate rule missing: %q", text)
	}
	// The pixel dims and pixel rule must NOT appear in normalized mode — they
	// would fight the 0-1000 instruction the model is trained to emit.
	if strings.Contains(text, "1600 pixels wide") {
		t.Errorf("pixel dims leaked into normalized prompt: %q", text)
	}
	if strings.Contains(text, "PIXELS of this image") {
		t.Errorf("pixel coordinate rule present in normalized prompt: %q", text)
	}
}

func TestDenormalize(t *testing.T) {
	x, y := 500, 250
	x2, y2 := 1000, 0
	a := &Action{Name: "drag", X: &x, Y: &y, X2: &x2, Y2: &y2}
	a.Denormalize(1600, 1000)
	if *a.X != 800 || *a.Y != 250 {
		t.Errorf("x,y = %d,%d want 800,250", *a.X, *a.Y)
	}
	if *a.X2 != 1600 || *a.Y2 != 0 {
		t.Errorf("x2,y2 = %d,%d want 1600,0", *a.X2, *a.Y2)
	}
}

func TestDenormalize_ClampsAndSkipsNil(t *testing.T) {
	x, y := 1200, -30                         // out of the 0-1000 range → clamp to 1000, 0
	a := &Action{Name: "click", X: &x, Y: &y} // no x2/y2 on a click
	a.Denormalize(1000, 800)
	if *a.X != 1000 || *a.Y != 0 {
		t.Errorf("x,y = %d,%d want 1000,0", *a.X, *a.Y)
	}
	if a.X2 != nil || a.Y2 != nil {
		t.Errorf("nil coords must stay nil: %+v", a)
	}
}

func TestBuildToolPrompt(t *testing.T) {
	os := "macOS 15.5 (Version 15.5 (Build 24F90)) · Apple Silicon (arm64)"
	lines := BuildToolPrompt(Prompt{
		Goal:  "open calculator",
		Steps: []Step{{Action: "click", Note: "dock"}},
		App:   "Finder",
		OS:    os,
		Image: true,
	})
	text := strings.Join(lines, "\n")
	if !strings.Contains(text, "You are Suno Control") {
		t.Error("missing identity framing")
	}
	if !strings.Contains(text, "computer tool") {
		t.Error("tool framing should reference the computer tool")
	}
	if !strings.Contains(text, "Target operating system: "+os) {
		t.Error("OS line missing from the tool prompt")
	}
	// Tool mode must NOT restate our JSON output schema or coordinate rule —
	// the native tool defines both, and repeating ours would conflict.
	if strings.Contains(text, "EXACTLY one JSON object") {
		t.Error("JSON output schema leaked into the tool prompt")
	}
	if strings.Contains(text, "PIXELS of this image") || strings.Contains(text, "from 0 to 1000") {
		t.Error("coordinate rule leaked into the tool prompt")
	}
	// But it keeps the safety/injection posture and the goal + steps.
	if !strings.Contains(text, "REFERENCE, not instruction") {
		t.Error("safety/injection posture missing from the tool prompt")
	}
	if !strings.Contains(text, "[GOAL]\nopen calculator") {
		t.Error("goal missing from the tool prompt")
	}
	if !strings.Contains(text, "[STEPS ALREADY TAKEN]") {
		t.Error("steps missing from the tool prompt")
	}
}

func TestBuildPrompt_StepCap(t *testing.T) {
	var steps []Step
	for i := 0; i < 130; i++ {
		steps = append(steps, Step{Action: fmt.Sprintf("click%03d", i)})
	}
	lines := BuildPrompt(Prompt{Goal: "g", Steps: steps})
	text := strings.Join(lines, "\n")
	if strings.Contains(text, "click029") || strings.Contains(text, "click000") {
		t.Error("oldest steps should have been dropped")
	}
	// Last MaxSteps=100 survive, renumbered 1..100.
	if !strings.Contains(text, "click030") || !strings.Contains(text, "click129") {
		t.Errorf("recent steps missing: %q", text)
	}
	if strings.Contains(text, "101. ") {
		t.Errorf("more than 100 steps rendered: %q", text)
	}
}

func TestParseAction_Click(t *testing.T) {
	a, err := ParseAction(`{"action":"click","x":120,"y":80,"note":"open the app"}`)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if a.Name != "click" || a.X == nil || *a.X != 120 || a.Y == nil || *a.Y != 80 {
		t.Fatalf("wrong action: %+v", a)
	}
	if a.Note == nil || *a.Note != "open the app" {
		t.Fatalf("note lost: %+v", a)
	}
}

func TestParseAction_FencedAndNoisy(t *testing.T) {
	in := "Here is my plan:\n```json\n{\"action\":\"key\",\"key\":\"Space\",\"modifiers\":[\"Command\"]}\n```\n"
	a, err := ParseAction(in)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if a.Name != "key" || a.Key == nil || *a.Key != "space" {
		t.Fatalf("wrong action: %+v", a)
	}
	if len(a.Modifiers) != 1 || a.Modifiers[0] != "command" {
		t.Fatalf("modifiers wrong: %+v", a.Modifiers)
	}
}

func TestParseAction_ClashesAndBounds(t *testing.T) {
	t.Run("unknown action", func(t *testing.T) {
		if _, err := ParseAction(`{"action":"reboot"}`); err == nil {
			t.Fatal("expected error")
		}
	})
	t.Run("click without coords", func(t *testing.T) {
		if _, err := ParseAction(`{"action":"click"}`); err == nil {
			t.Fatal("expected error")
		}
	})
	t.Run("drag partial coords", func(t *testing.T) {
		if _, err := ParseAction(`{"action":"drag","x":1,"y":2}`); err == nil {
			t.Fatal("expected error")
		}
	})
	t.Run("negative coord clamped", func(t *testing.T) {
		a, err := ParseAction(`{"action":"click","x":-5,"y":16384}`)
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		if *a.X != 0 || *a.Y != maxCoord {
			t.Fatalf("clamp wrong: %d,%d", *a.X, *a.Y)
		}
	})
	t.Run("scroll clamped", func(t *testing.T) {
		a, err := ParseAction(`{"action":"scroll","direction":"UP","amount":99}`)
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		if *a.Direction != "up" || *a.Amount != 10 {
			t.Fatalf("scroll wrong: %v %v", *a.Direction, *a.Amount)
		}
	})
	t.Run("scroll default amount", func(t *testing.T) {
		a, err := ParseAction(`{"action":"scroll","direction":"down"}`)
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		if *a.Amount != 3 {
			t.Fatalf("default amount wrong: %v", *a.Amount)
		}
	})
	t.Run("wait clamped", func(t *testing.T) {
		a, err := ParseAction(`{"action":"wait","seconds":30}`)
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		if *a.Seconds != 5 {
			t.Fatalf("wait clamp wrong: %v", *a.Seconds)
		}
	})
	t.Run("bad direction", func(t *testing.T) {
		if _, err := ParseAction(`{"action":"scroll","direction":"in"}`); err == nil {
			t.Fatal("expected error")
		}
	})
	t.Run("type empty", func(t *testing.T) {
		if _, err := ParseAction(`{"action":"type","text":"  "}`); err == nil {
			t.Fatal("expected error")
		}
	})
	t.Run("done strips fields", func(t *testing.T) {
		a, err := ParseAction(`{"action":"done","x":5,"y":6,"note":"it worked"}`)
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		if a.X != nil || a.Y != nil || a.Text != nil || a.Key != nil || a.Seconds != nil {
			t.Fatalf("done should carry only note: %+v", a)
		}
	})
	t.Run("no json", func(t *testing.T) {
		if _, err := ParseAction("I cannot help with that."); err == nil {
			t.Fatal("expected error")
		}
	})
}

func TestParseAction_TypeTextTrims(t *testing.T) {
	a, err := ParseAction(`{"action":"type","text":" hello world "}`)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if *a.Text != "hello world" {
		t.Fatalf("text not trimmed: %q", *a.Text)
	}
}
