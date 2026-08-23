import Foundation

/// Minimal append-only file logger so we can inspect app behavior directly,
/// without digging through the noisy unified system log.
///
/// The log lives at `~/Library/Logs/SunoFlow/app-debug.log` — the conventional,
/// TCC-safe location. It must NOT live under the dev source tree
/// (`~/Downloads/work/sunoapp`), because a distributed app has no such
/// directory and writing there would fail silently for end users.
enum AppLog {
    static let fileURL: URL = {
        let fm = FileManager.default
        let dir = fm
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/SunoFlow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app-debug.log")
    }()

    private static let queue = DispatchQueue(label: "com.sunoapp.sunoflow.applog")

    static func log(_ message: String) {
        NSLog("[SunoFlow] \(message)")
        queue.async {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
