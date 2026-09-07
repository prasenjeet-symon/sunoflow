// PROTOTYPE — Suno Answer G2 popup harness. Throwaway: answers the G2
// questions in docs/SUNO_ANSWER_RESEARCH.md, then gets deleted.
//
//   What it exercises (batch-1/2/3 decisions, marked by their ledger IDs):
//     ⌃⌥Space, HotkeyManager(id: 3), default OFF in production (A6)
//     → magic-bubble recording anchored at the mouse cursor (A3/A7)
//     → press again → screen capture (F3/A9) + real STT via the sidecar
//     → focusable popup (A4) streams a STUBBED answer (C3) with source chips (C6)
//     → dismissal: Esc / ✕ / click-outside / hotkey re-press, aborting work (A10)
//     → Insert hides the popup and pastes into the previously focused app (A5)
//     → D4 error card + "Try again" (no raw fallback)
//     → typed follow-ups in the popup (A4), ephemerally (A2)
//
//   The G2 residuals it exists to settle:
//     - focus-on-appear vs click-to-focus (PROTO_FOCUS)
//     - does insert-at-cursor work when the popup held key focus?
//     - does the Esc/click-outside/hotkey dismissal set feel right?
//     - does the stub stream (TTFB + speed) feel like a grounded answer?
//
//   Env knobs (all optional):
//     PROTO_FOCUS=on-appear|click    popup focus behaviour (default on-appear)
//     PROTO_TTFB=1.5                 seconds before the first token
//     PROTO_SPEED=220                stub characters per second
//     PROTO_FAIL=unavailable|timeout|limit|unable   force the D4 error card
//     PROTO_SIDECAR=0                skip real STT; use a canned query
//     PROTO_KEY=...                  device key for /transcribe (else Keychain)
//
//   Run: tools/answer-proto/run.sh
//   Needs: sidecar running + model loaded (real STT), mic + Accessibility +
//   Screen Recording TCC for the full flow (each degrades gracefully).

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Read the device key once, off the main thread. A read whose ACL doesn't
// trust this binary (the normal case — the item was written by the installed
// app) shows a one-time system prompt, and SecItemCopyMatching BLOCKS until
// it is answered, so it must never run on the main thread. Deliberately NOT
// calling Keychain.repairAccessIfNeeded(): that rewrites the item's ACL to
// name the running binary, and the running binary here is a throwaway — the
// ACL must keep naming /Applications/SunoFlow.app.
DispatchQueue.global(qos: .userInitiated).async {
    _ = Keychain.deviceKey()
}

let flow = AnswerFlow()
flow.install()

// Insert-at-cursor (A5) needs Accessibility; ask once up front.
if !TextInjector.hasAccessibilityPermission {
    AppLog.log("answer proto: prompting for Accessibility (needed by Insert)")
    TextInjector.promptForAccessibilityPermissionIfNeeded()
}

print(
    """
    Suno Answer — G2 popup prototype (throwaway)

      hotkey    ⌃⌥Space  — press to record, press again to ask
      focus     \(ProtoKnobs.focusMode)
      stt       \(ProtoKnobs.sidecarStubbed ? "stubbed (PROTO_SIDECAR=0)" : "real — sidecar http://127.0.0.1:8765")
      stub      ttfb \(ProtoKnobs.ttfb)s · \(ProtoKnobs.speed) chars/s\(ProtoKnobs.failMode.map { " · forced failure: " + $0 } ?? "")
      dismiss   Esc · ✕ · click outside · hotkey again   (aborts in-flight work)
      insert    pastes the last answer into the previously focused app

    Log: \(AppLog.fileURL.path)
    """
)

app.run()