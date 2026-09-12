import Foundation

/// Dedicated, append-only record of everything Suno Control does on this Mac:
/// each run's goal, every action the planner chose and whether the executor
/// actually performed it, and why the run stopped. Kept separate from
/// `app-debug.log` (AppLog) so the account of what the agent did to the machine
/// — the one log a user or reviewer most wants for a feature that moves the
/// mouse and types — is easy to find and read on its own.
///
/// Lives at `~/Library/Logs/SunoFlow/suno-control.log`, the same TCC-safe
/// location AppLog uses; never under the dev source tree, which a distributed
/// app has no access to. Writes are serialized on a private queue and every
/// line is timestamped and tagged with a short run id, so one run's lines can
/// be grepped out of an interleaved file.
enum ControlLog {
    static let fileURL: URL = {
        let fm = FileManager.default
        let dir = fm
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/SunoFlow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("suno-control.log")
    }()

    private static let queue = DispatchQueue(label: "com.sunoapp.sunoflow.controllog")

    /// A fresh short id correlating one run's lines. The flow holds it from the
    /// moment recording starts until the run stops.
    static func newRunID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased()
    }

    /// The goal take is being recorded — the first line of a run.
    static func recording(_ runID: String) {
        write(runID, "RECORDING goal…")
    }

    /// The goal was heard; the loop is about to run. Logged once per run.
    static func runStarted(_ runID: String, goal: String, maxSteps: Int, wallClock: TimeInterval) {
        write(runID, "START goal=\(quote(goal)) (max \(maxSteps) steps, \(Int(wallClock))s cap)")
    }

    /// Per-step token usage from the gateway (the planning call's cost). Logged
    /// next to the step so the control log shows real per-step cost, not an
    /// estimate. All-zero (the provider reported nothing) prints nothing.
    struct TokenUsage {
        var prompt = 0, output = 0, thinking = 0, total = 0
        var isEmpty: Bool { prompt == 0 && output == 0 && thinking == 0 && total == 0 }
    }

    private static func tokenSuffix(_ t: TokenUsage?) -> String {
        guard let t = t, !t.isEmpty else { return "" }
        return "tok in=\(t.prompt) out=\(t.output) think=\(t.thinking) total=\(t.total)"
    }

    /// One executed action: its number, the observed context (frontmost app and
    /// focused window), the action with its parameters, the planner's note,
    /// whether the executor performed it or refused, and the call's token usage.
    static func step(_ runID: String, n: Int, maxSteps: Int, app: String, window: String,
                     action: String, detail: String, note: String, performed: Bool,
                     tokens: TokenUsage? = nil) {
        var parts = ["STEP \(n)/\(maxSteps)"]
        if !app.isEmpty { parts.append("app=\(app)") }
        if !window.isEmpty { parts.append("win=\(quote(window))") }
        let d = detail.trimmingCharacters(in: .whitespaces)
        parts.append(d.isEmpty ? action : "\(action) \(d)")
        if !note.isEmpty { parts.append("note=\(quote(note))") }
        parts.append(performed ? "-> ok" : "-> REFUSED")
        let ts = tokenSuffix(tokens)
        if !ts.isEmpty { parts.append(ts) }
        write(runID, parts.joined(separator: "  "))
    }

    /// A terminal decision from the planner (done / failed): nothing is executed,
    /// but the decision, its reason, and the call's token usage are recorded
    /// before the run stops.
    static func decision(_ runID: String, n: Int, action: String, note: String,
                         tokens: TokenUsage? = nil) {
        var line = "PLAN \(action.uppercased()) at step \(n)"
        if !note.isEmpty { line += "  note=\(quote(note))" }
        let ts = tokenSuffix(tokens)
        if !ts.isEmpty { line += "  " + ts }
        write(runID, line)
    }

    /// A non-step event worth recording: an STT failure, a plan failure, a
    /// permission gap — anything that explains why a run did little or nothing.
    static func event(_ runID: String, _ message: String) {
        write(runID, message)
    }

    /// The run ended: the reason shown to the user, how many actions ran, and
    /// how long the whole run took.
    static func stopped(_ runID: String, reason: String, steps: Int, duration: TimeInterval) {
        let secs = String(format: "%.1f", max(duration, 0))
        let r = reason.isEmpty ? "(no reason)" : quote(reason)
        write(runID, "STOP reason=\(r) steps=\(steps) \(secs)s")
    }

    // MARK: - internals

    /// One-line, greppable rendering of an untrusted string: newlines flattened,
    /// quotes neutralised, and hard-capped so a pathological note or window
    /// title cannot bloat the log.
    private static func quote(_ s: String) -> String {
        let clean = s
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
        return "\"\(clean.prefix(300))\""
    }

    private static func write(_ runID: String, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  run=\(runID)  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                // First write of the file's life: create it with this line.
                try? data.write(to: fileURL)
            }
        }
    }
}
