package backend

import (
	"encoding/json"
	"testing"
)

func iptr(i int) *int       { return &i }
func sptr(s string) *string { return &s }
func bptr(b bool) *bool     { return &b }

func TestMapComputerUseCall_Core(t *testing.T) {
	tests := []struct {
		name    string
		action  string
		args    computerUseArgs
		wantAct string
		check   func(t *testing.T, m map[string]any)
	}{
		{
			name:    "click carries coords and intent as note",
			action:  "click",
			args:    computerUseArgs{X: iptr(100), Y: iptr(50), Intent: "open the app"},
			wantAct: "click",
			check: func(t *testing.T, m map[string]any) {
				if m["x"] != 100 || m["y"] != 50 {
					t.Errorf("coords = %v,%v", m["x"], m["y"])
				}
				if m["note"] != "open the app" {
					t.Errorf("note = %v", m["note"])
				}
			},
		},
		{
			name:    "drag maps start/end to x,y,x2,y2",
			action:  "drag_and_drop",
			args:    computerUseArgs{StartX: iptr(1), StartY: iptr(2), EndX: iptr(3), EndY: iptr(4)},
			wantAct: "drag",
			check: func(t *testing.T, m map[string]any) {
				if m["x"] != 1 || m["y"] != 2 || m["x2"] != 3 || m["y2"] != 4 {
					t.Errorf("drag coords = %v", m)
				}
			},
		},
		{
			name:    "type carries press_enter",
			action:  "type",
			args:    computerUseArgs{Text: sptr("hello"), PressEnter: bptr(true)},
			wantAct: "type",
			check: func(t *testing.T, m map[string]any) {
				if m["text"] != "hello" {
					t.Errorf("text = %v", m["text"])
				}
				if m["press_enter"] != true {
					t.Errorf("press_enter = %v", m["press_enter"])
				}
			},
		},
		{
			name:    "hotkey splits modifiers from the key",
			action:  "hotkey",
			args:    computerUseArgs{Keys: []string{"cmd", "shift", "4"}},
			wantAct: "key",
			check: func(t *testing.T, m map[string]any) {
				if m["key"] != "4" {
					t.Errorf("key = %v", m["key"])
				}
				mods, _ := m["modifiers"].([]string)
				if len(mods) != 2 || mods[0] != "command" || mods[1] != "shift" {
					t.Errorf("modifiers = %v", m["modifiers"])
				}
			},
		},
		{
			name:    "scroll converts pixel magnitude to ticks",
			action:  "scroll",
			args:    computerUseArgs{Direction: sptr("DOWN"), MagnitudePixels: iptr(300)},
			wantAct: "scroll",
			check: func(t *testing.T, m map[string]any) {
				if m["direction"] != "down" {
					t.Errorf("direction = %v", m["direction"])
				}
				if m["amount"] != 3 {
					t.Errorf("amount = %v", m["amount"])
				}
			},
		},
		{
			name:    "take_screenshot becomes a short wait",
			action:  "take_screenshot",
			args:    computerUseArgs{},
			wantAct: "wait",
			check: func(t *testing.T, m map[string]any) {
				if m["seconds"] != 0.5 {
					t.Errorf("seconds = %v", m["seconds"])
				}
			},
		},
		{
			name:    "unknown/browser action fails honestly",
			action:  "navigate",
			args:    computerUseArgs{},
			wantAct: "failed",
			check:   func(t *testing.T, m map[string]any) {},
		},
		{
			name:    "coordinate action without coords fails",
			action:  "click",
			args:    computerUseArgs{},
			wantAct: "failed",
			check:   func(t *testing.T, m map[string]any) {},
		},
		{
			name:    "press_key maps to key",
			action:  "press_key",
			args:    computerUseArgs{Key: sptr("enter")},
			wantAct: "key",
			check: func(t *testing.T, m map[string]any) {
				if m["key"] != "enter" {
					t.Errorf("key = %v", m["key"])
				}
			},
		},
		{
			// Live failure 2026-09-08: ["super_l","space"] degraded to a bare
			// "space" press three times — the keysym must become the command
			// modifier.
			name:    "hotkey keysym super_l maps to command modifier",
			action:  "hotkey",
			args:    computerUseArgs{Keys: []string{"super_l", "space"}},
			wantAct: "key",
			check: func(t *testing.T, m map[string]any) {
				if m["key"] != "space" {
					t.Errorf("key = %v", m["key"])
				}
				mods, _ := m["modifiers"].([]string)
				if len(mods) != 1 || mods[0] != "command" {
					t.Errorf("modifiers = %v", m["modifiers"])
				}
			},
		},
		{
			// Live failure 2026-09-08: press_key("super_l") alone REFUSED in the
			// executor and killed the run. A lone modifier is a no-op — wait and
			// let the model re-judge on the next screenshot.
			name:    "lone modifier keysym becomes a wait",
			action:  "press_key",
			args:    computerUseArgs{Key: sptr("super_l")},
			wantAct: "wait",
			check: func(t *testing.T, m map[string]any) {
				if m["seconds"] != 0.5 {
					t.Errorf("seconds = %v", m["seconds"])
				}
			},
		},
		{
			name:    "keysym aliases normalize",
			action:  "press_key",
			args:    computerUseArgs{Key: sptr("BackSpace")},
			wantAct: "key",
			check: func(t *testing.T, m map[string]any) {
				if m["key"] != "delete" {
					t.Errorf("key = %v", m["key"])
				}
			},
		},
		{
			name:    "modifiers-only hotkey becomes a wait",
			action:  "hotkey",
			args:    computerUseArgs{Keys: []string{"cmd_l", "ctrl_l"}},
			wantAct: "wait",
			check:   func(t *testing.T, m map[string]any) {},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := mapComputerUseCall(tt.action, tt.args, false)
			if m["action"] != tt.wantAct {
				t.Fatalf("action = %v, want %v (%v)", m["action"], tt.wantAct, m)
			}
			tt.check(t, m)
		})
	}
}

func TestMapComputerUseCall_SafetyDecisionStops(t *testing.T) {
	var args computerUseArgs
	if err := json.Unmarshal([]byte(`{"x":10,"y":20,"safety_decision":{"decision":"require_confirmation","explanation":"This will delete files."}}`), &args); err != nil {
		t.Fatal(err)
	}
	m := mapComputerUseCall("click", args, false)
	if m["action"] != "failed" {
		t.Fatalf("action = %v, want failed", m["action"])
	}
	if m["note"] != "This will delete files." {
		t.Errorf("note = %v", m["note"])
	}
}

func TestMapComputerUseCall_AutoProceed(t *testing.T) {
	// require_confirmation on a real action: with auto-proceed off it stops;
	// with it on, the underlying action is performed (the goal authorized it).
	mkArgs := func() computerUseArgs {
		var a computerUseArgs
		_ = json.Unmarshal([]byte(`{"x":10,"y":20,"safety_decision":{"decision":"require_confirmation","explanation":"About to send a message."}}`), &a)
		return a
	}
	if m := mapComputerUseCall("click", mkArgs(), false); m["action"] != "failed" {
		t.Errorf("auto-proceed off: action = %v, want failed", m["action"])
	}
	m := mapComputerUseCall("click", mkArgs(), true)
	if m["action"] != "click" {
		t.Fatalf("auto-proceed on: action = %v, want click", m["action"])
	}
	if m["x"] != 10 || m["y"] != 20 {
		t.Errorf("auto-proceed on: coords = %v,%v want 10,20", m["x"], m["y"])
	}

	// A non-confirmation decision (a hard block / injection) still stops even
	// with auto-proceed on — the goal never authorizes an on-screen hijack.
	var blocked computerUseArgs
	_ = json.Unmarshal([]byte(`{"x":1,"y":2,"safety_decision":{"decision":"block","explanation":"Suspicious page instruction."}}`), &blocked)
	if m := mapComputerUseCall("click", blocked, true); m["action"] != "failed" {
		t.Errorf("blocked decision with auto-proceed on: action = %v, want failed", m["action"])
	}
}

func TestActionJSONFromResponse_FunctionCall(t *testing.T) {
	// A reasoning part precedes the function_call; only the call becomes the action.
	raw := `{"candidates":[{"content":{"parts":[
		{"thought":true,"text":"reasoning..."},
		{"functionCall":{"name":"click","args":{"x":500,"y":250,"intent":"tap"}}}
	]}}]}`
	var out geminiResponse
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("setup: %v", err)
	}
	js, err := actionJSONFromResponse(&out, false)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(js), &got); err != nil {
		t.Fatalf("bad json %q: %v", js, err)
	}
	if got["action"] != "click" || got["x"].(float64) != 500 || got["y"].(float64) != 250 {
		t.Errorf("mapped = %v", got)
	}
	if got["note"] != "tap" {
		t.Errorf("note = %v", got["note"])
	}
}

func TestActionJSONFromResponse_NoCallIsDone(t *testing.T) {
	// No function_call is the tool's termination signal → done, text as note.
	raw := `{"candidates":[{"content":{"parts":[{"text":"The goal is complete."}]}}]}`
	var out geminiResponse
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("setup: %v", err)
	}
	js, err := actionJSONFromResponse(&out, false)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	var got map[string]any
	_ = json.Unmarshal([]byte(js), &got)
	if got["action"] != "done" {
		t.Errorf("action = %v, want done", got["action"])
	}
	if got["note"] != "The goal is complete." {
		t.Errorf("note = %v", got["note"])
	}
}

func TestUsageFromResponse(t *testing.T) {
	raw := `{"candidates":[{"content":{"parts":[{"text":"x"}]}}],
		"usageMetadata":{"promptTokenCount":1496,"candidatesTokenCount":42,"thoughtsTokenCount":210,"totalTokenCount":1748}}`
	var out geminiResponse
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatalf("setup: %v", err)
	}
	u := usageFromResponse(&out)
	if u.PromptTokens != 1496 || u.OutputTokens != 42 || u.ThinkingTokens != 210 || u.TotalTokens != 1748 {
		t.Errorf("usage = %+v", u)
	}
	// A response without usageMetadata reports zeros, never a panic.
	var empty geminiResponse
	if u := usageFromResponse(&empty); u != (Usage{}) {
		t.Errorf("empty usage = %+v, want zero", u)
	}
}

func TestScrollTicks(t *testing.T) {
	cases := []struct {
		px   int
		want int
	}{{0, 0}, {50, 1}, {100, 1}, {150, 2}, {300, 3}, {2000, 10}}
	for _, c := range cases {
		got := scrollTicks(computerUseArgs{MagnitudePixels: iptr(c.px)})
		if got != c.want {
			t.Errorf("scrollTicks(%d) = %d, want %d", c.px, got, c.want)
		}
	}
}
