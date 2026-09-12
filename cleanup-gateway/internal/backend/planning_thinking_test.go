package backend

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

// TestGeminiPlanActionThinkingLevel pins the planner's thinking-level override:
// CONTROL_THINKING_LEVEL (ControlThinkingLevel) wins for PlanAction when set,
// otherwise the shared cleanup level applies. Cleanup itself always sends the
// shared level and never the override — the override is planner-only.
func TestGeminiPlanActionThinkingLevel(t *testing.T) {
	tests := []struct {
		name      string
		shared    string
		override  string
		wantPlan  string // thinkingLevel a PlanAction call sends; "" = field omitted
		wantClean string // thinkingLevel a Cleanup call sends
	}{
		{"override wins on the planner", "low", "minimal", "minimal", "low"},
		{"override empty falls back to shared", "low", "", "low", "low"},
		{"override set, no shared level", "", "medium", "medium", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Two separate stubs so each records exactly its own path's
			// thinkingLevel: an absent thinkingConfig reads as "".
			planLevel := "?"
			cleanLevel := "?"
			capture := func(dst *string) http.HandlerFunc {
				return func(w http.ResponseWriter, r *http.Request) {
					var raw map[string]any
					body, _ := io.ReadAll(r.Body)
					_ = json.Unmarshal(body, &raw)
					gc, _ := raw["generationConfig"].(map[string]any)
					tcfg, _ := gc["thinkingConfig"].(map[string]any)
					level, _ := tcfg["thinkingLevel"].(string)
					*dst = level
					io.WriteString(w, `{"candidates":[{"content":{"parts":[{"text":"{\"action\":\"done\",\"note\":\"ok\"}"}]}}]}`)
				}
			}
			be, _ := newTestGemini(t, capture(&planLevel))
			be.ThinkingLevel = tc.shared
			be.ControlThinkingLevel = tc.override
			be.ControlUseTool = true
			if _, _, err := be.PlanAction(context.Background(), "the prompt", []byte("\xff\xd8jpeg")); err != nil {
				t.Fatalf("PlanAction: %v", err)
			}

			clean, _ := newTestGemini(t, capture(&cleanLevel))
			clean.ThinkingLevel = tc.shared
			if _, err := clean.Cleanup(context.Background(), "p"); err != nil {
				t.Fatalf("Cleanup: %v", err)
			}

			if planLevel != tc.wantPlan {
				t.Errorf("PlanAction thinkingLevel = %q, want %q", planLevel, tc.wantPlan)
			}
			if cleanLevel != tc.wantClean {
				t.Errorf("Cleanup thinkingLevel = %q, want %q", cleanLevel, tc.wantClean)
			}
		})
	}
}
