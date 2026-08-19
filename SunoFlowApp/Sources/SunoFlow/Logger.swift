import Foundation

/// Minimal append-only file logger so we can inspect app behavior directly,
/// without digging through the noisy unified system log.
enum AppLog {
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/work/sunoapp")
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
