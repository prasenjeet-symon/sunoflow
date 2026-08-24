import Cocoa

// Standalone harness to visually verify DictationOverlay without needing the
// mic or the hotkey. Shows the pill, feeds it a simulated fluctuating level,
// and screencaptures each state. It lives in its own directory because Swift
// only allows top-level code in a file called main.swift.
//
//   swiftc -o /tmp/overlay-preview SunoFlowApp/tools/overlay-preview/main.swift \
//     SunoFlowApp/Sources/SunoFlow/{DictationOverlay,Theme}.swift
//   /tmp/overlay-preview /tmp/shots
//
// The pill is captured by window number, which grabs it properly and doesn't
// care which Space or app is in front.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let overlay = DictationOverlay()
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// Simulate speech-like level fluctuation.
var t: Double = 0
Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    t += 1.0 / 60.0
    let level = Float(0.35 + 0.35 * sin(t * 6) + 0.15 * sin(t * 17))
    overlay.updateLevel(max(0, min(1, level)))
}

func capture(_ name: String) {
    guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
        print("no visible window for \(name)")
        return
    }
    let task = Process()
    task.launchPath = "/usr/sbin/screencapture"
    task.arguments = ["-o", "-x", "-l\(window.windowNumber)", "\(outDir)/\(name).png"]
    try? task.run()
    task.waitUntilExit()
    print("captured \(name)")
}

var clock: TimeInterval = 0
func at(_ delay: TimeInterval, _ block: @escaping () -> Void) {
    clock += delay
    DispatchQueue.main.asyncAfter(deadline: .now() + clock, execute: block)
}

at(0.0) { overlay.show(mode: .recording) }
at(0.10) { capture("pill-entrance") }
at(0.9) { capture("pill-recording") }
at(0.4) { overlay.update(mode: .processing) }
at(0.6) { capture("pill-processing") }
at(0.3) { NSApp.terminate(nil) }

app.run()
