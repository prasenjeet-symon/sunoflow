import Cocoa

// Standalone harness to visually verify DictationOverlay without needing the
// mic/hotkey. Shows the overlay and feeds it a simulated fluctuating level.
// Compiled together with DictationOverlay.swift.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let overlay = DictationOverlay()
overlay.show(mode: .recording)

var t: Double = 0
Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    t += 1.0 / 60.0
    // Simulate speech-like level fluctuation.
    let level = Float(0.35 + 0.35 * sin(t * 6) + 0.15 * sin(t * 17))
    overlay.updateLevel(max(0, min(1, level)))
}

// Give it a moment to render, then the external script will screencapture.
app.run()
