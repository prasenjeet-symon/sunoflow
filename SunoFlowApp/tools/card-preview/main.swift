import Cocoa

// Standalone harness to visually verify TranscriptCard without needing a
// dictation to fail. Shows the card, drives it through every state, and
// screencaptures each one. It lives in its own directory because Swift only
// allows top-level code in a file called main.swift.
//
//   swiftc -o /tmp/card-preview SunoFlowApp/tools/card-preview/main.swift \
//     SunoFlowApp/Sources/SunoFlow/{TranscriptCard,DictationOverlay,Logger}.swift
//   APPEARANCE=light /tmp/card-preview /tmp/shots
//
// APPEARANCE is light/dark (default: follow the system). The card is captured
// by window number, which grabs the frosted material properly and doesn't care
// which Space or app is in front.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if let name = ProcessInfo.processInfo.environment["APPEARANCE"] {
    app.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
}

let card = TranscriptCard()
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let short = "Let's ship the Windows build behind a flag and see what the runner says."
let long = """
Let's ship the Windows build behind a flag first and see what the runner says, \
then decide whether the sidecar needs its own installer step. If it does, I'd \
rather do that before the release notes go out than after, because the download \
page will be wrong for a day and people will file issues about it. Also remind \
me to check the code signing certificate expiry — it bit us last spring and I \
have no memory of where the renewal instructions live.
"""

func capture(_ name: String) {
    guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
        print("no visible window for \(name)")
        return
    }
    let task = Process()
    task.launchPath = "/usr/sbin/screencapture"
    task.arguments = ["-o", "-x", "-l\(window.windowNumber)", "\(outDir)/\(ProcessInfo.processInfo.environment["APPEARANCE"] ?? "system")-\(name).png"]
    try? task.run()
    task.waitUntilExit()
    print("captured \(name)")
}

/// Clicks the copy button in-process, so we see the real confirmed state.
func clickCopy() {
    guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
    // Centre of the copy button: in from the panel's shadow margin, the paper's
    // own padding, then half the button.
    let point = NSPoint(x: window.frame.width - 24 - 24 - 52, y: 24 + 14 + 14)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) {
            window.sendEvent(event)
        }
    }
}

var step = 0
let steps: [(TimeInterval, () -> Void)] = [
    (0.0, { card.present(short, reason: .noFocus) }),
    (0.12, { capture("card-entrance") }),
    (0.9, { capture("card-rest") }),
    (0.3, { clickCopy() }),
    (0.5, { capture("card-copied") }),
    (0.8, { card.dismiss() }),
    (0.4, { card.present(long, reason: .noAccessibility) }),
    (1.2, { capture("card-long") }),
    (0.3, { NSApp.terminate(nil) }),
]

var clock: TimeInterval = 0
for (delay, action) in steps {
    clock += delay
    DispatchQueue.main.asyncAfter(deadline: .now() + clock, execute: action)
}

app.run()
