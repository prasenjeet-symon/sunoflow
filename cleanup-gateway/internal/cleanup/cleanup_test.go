package cleanup

import (
	"strings"
	"testing"
)

// TestBuildPrompt_NoExtras matches the sidecar: no screen/context/recent.
func TestBuildPrompt_NoExtras(t *testing.T) {
	got := BuildPrompt("hello world", "", nil, "")
	// Must end with the new-transcript block exactly like server.py.
	wantTail := strings.Join([]string{
		"[NEW TRANSCRIPT — output ONLY the cleaned version of this]",
		"hello world",
		"",
		"Cleaned transcript:",
	}, "\n")
	if !strings.HasSuffix(got, wantTail) {
		t.Errorf("prompt tail mismatch:\n%q", got)
	}
	// Must NOT contain any reference sections.
	for _, bad := range []string{"[SCREEN", "[CONTEXT", "[RECENT"} {
		if strings.Contains(got, bad) {
			t.Errorf("prompt should not contain %q", bad)
		}
	}
}

// TestBuildPrompt_AllSections matches the sidecar ordering: screen, context, recent, new.
func TestBuildPrompt_AllSections(t *testing.T) {
	got := BuildPrompt("the text", "the context", []string{"recent one", "recent two"}, "screen words")
	parts := strings.Split(got, "\n")
	// Find section header indices.
	screenIdx, contextIdx, recentIdx, newIdx := -1, -1, -1, -1
	for i, p := range parts {
		switch p {
		case "[SCREEN — words visible on screen near the input field; reference only, do NOT repeat or edit]":
			screenIdx = i
		case "[CONTEXT — already written before the cursor; reference only, do NOT repeat or edit]":
			contextIdx = i
		case "[RECENT DICTATION — the user's last few dictations; reference only]":
			recentIdx = i
		case "[NEW TRANSCRIPT — output ONLY the cleaned version of this]":
			newIdx = i
		}
	}
	if !(screenIdx < contextIdx && contextIdx < recentIdx && recentIdx < newIdx) {
		t.Errorf("section order wrong: screen=%d context=%d recent=%d new=%d", screenIdx, contextIdx, recentIdx, newIdx)
	}
	// Recent entries must be "- " prefixed.
	if parts[recentIdx+1] != "- recent one" || parts[recentIdx+2] != "- recent two" {
		t.Errorf("recent entries malformed: %q", parts[recentIdx+1:recentIdx+3])
	}
}

// TestLooksLikeEcho_LengthGrowth mirrors _looks_like_echo's first rule.
func TestLooksLikeEcho_LengthGrowth(t *testing.T) {
	text := "short text here"
	long := strings.Repeat("x", len(text)*2+100)
	if !LooksLikeEcho(long, text, "", nil, "") {
		t.Error("expected echo for overly long output")
	}
}

// TestLooksLikeEcho_RecentVerbatim mirrors the recent-entry rule.
func TestLooksLikeEcho_RecentVerbatim(t *testing.T) {
	recent := []string{"this is a long recent dictation entry"}
	cleaned := "some output this is a long recent dictation entry more output"
	if !LooksLikeEcho(cleaned, "some output more output", "", recent, "") {
		t.Error("expected echo when recent entry appears verbatim")
	}
}

// TestLooksLikeEcho_ContextTail mirrors the context last-40-chars rule.
func TestLooksLikeEcho_ContextTail(t *testing.T) {
	context := strings.Repeat("a", 30) + "tail-of-context-here-!!"
	cleaned := "cleaned text " + context[len(context)-40:]
	if !LooksLikeEcho(cleaned, "cleaned text", context, nil, "") {
		t.Error("expected echo when context tail appears in output")
	}
}

// TestLooksLikeEcho_ScreenTail mirrors the screen last-40-chars rule.
func TestLooksLikeEcho_ScreenTail(t *testing.T) {
	screen := strings.Repeat("b", 40) + "screen-tail-content-here-!!"
	cleaned := "x " + screen[len(screen)-40:]
	if !LooksLikeEcho(cleaned, "x", "", nil, screen) {
		t.Error("expected echo when screen tail appears in output")
	}
}

// TestLooksLikeEcho_CleanOutput passes for a normal, slightly-edited cleanup.
func TestLooksLikeEcho_CleanOutput(t *testing.T) {
	text := "um so I think we should ship this on friday"
	cleaned := "So I think we should ship this on Friday."
	if LooksLikeEcho(cleaned, text, "", nil, "") {
		t.Error("did not expect echo for a normal cleanup")
	}
}

// TestTooLong matches the retry length guard.
func TestTooLong(t *testing.T) {
	text := "ten chars"
	if TooLong("short", text) {
		t.Error("short output should not be too long")
	}
	long := strings.Repeat("x", len(text)*2+100)
	if !TooLong(long, text) {
		t.Error("long output should be too long")
	}
}

// TestCleanupRules_Unchanged guards against accidental edits to the system prompt.
func TestCleanupRules_Unchanged(t *testing.T) {
	if !strings.Contains(CleanupRules, "mechanical transcript cleanup tool") {
		t.Error("CleanupRules preamble missing")
	}
	if !strings.Contains(CleanupRules, "delete my wallet") {
		t.Error("anti-injection example missing")
	}
	if !strings.Contains(CleanupRules, "bullet point") {
		t.Error("formatting cue missing")
	}
}