import Foundation

/// Owns the sidecar process lifecycle: locates the bundled frozen sidecar
/// binary and (re)spawns it when the health probe fails. This is the macOS
/// counterpart of the Windows `SidecarSupervisor.cs` — for a distributed app
/// there is no external launchd `KeepAlive` plist, so the app itself supervises
/// the bundled sidecar and keeps it alive.
///
/// Behaviour:
/// - **Dev mode** (no frozen binary inside the `.app` bundle): a no-op. The
///   user runs the sidecar manually (`run.sh` / `.venv`), exactly as today.
/// - **Installed mode** (`Contents/Resources/sidecar/SunoFlowSidecar` present):
///   `ensureRunning()` spawns the binary as a detached `Process` when it isn't
///   already running. A 10-second respawn cooldown prevents a crashing sidecar
///   from spinning a respawn loop.
/// - The sidecar's stdout/stderr are teed into
///   `~/Library/Logs/SunoFlow/sidecar.log` so a frozen-bundle startup failure
///   is diagnosable (the binary has no console when launched by the app).
/// - On app quit the sidecar is intentionally **left running**. It is an
///   independent service; killing it would force a slow model reload on the
///   next launch. The health loop restarts it if it ever dies.
final class SidecarSupervisor {
    static let shared = SidecarSupervisor()
    private init() {}

    /// Minimum gap between spawn attempts so a sidecar that dies on startup
    /// doesn't get relaunched in a tight loop.
    private static let respawnCooldown: TimeInterval = 10

    private let logURL: URL = {
        let fm = FileManager.default
        let dir = fm
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/SunoFlow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sidecar.log")
    }()

    /// The process we spawned ourselves. If the user launched the sidecar
    /// manually (dev), we never touch it.
    private var process: Process?
    private var lastSpawn: Date = .distantPast

    /// `true` when a frozen sidecar binary was found inside the app bundle.
    /// When `false` the supervisor is a no-op (dev mode).
    var isAvailable: Bool {
        binaryURL != nil
    }

    /// The bundled frozen sidecar executable, if present inside the app bundle.
    /// In a distributed `.app` this is
    /// `Contents/Resources/sidecar/SunoFlowSidecar`. Returns `nil` in dev.
    private var binaryURL: URL? {
        let exe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/sidecar/SunoFlowSidecar")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { return nil }
        return exe
    }

    /// (Re)spawn the sidecar if we own a dead process or none yet. Called from
    /// the health-poll loop when `/health` fails, and at app launch. No-op in
    /// dev mode or within the respawn cooldown.
    func ensureRunning() {
        guard let exe = binaryURL else { return }
        if let p = process, p.isRunning { return }
        if Date().timeIntervalSince(lastSpawn) < SidecarSupervisor.respawnCooldown {
            return
        }
        spawn(at: exe)
    }

    private func spawn(at exe: URL) {
        let task = Process()
        task.launchPath = exe.path
        task.currentDirectoryURL = exe.deletingLastPathComponent()

        // Tee stdout/stderr into sidecar.log so a frozen-bundle startup failure
        // is diagnosable (the binary has no console when launched here).
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let logURL = self.logURL
        // Truncate per line and append — runs off the main thread.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty,
                  let text = String(data: chunk, encoding: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let data = text.data(using: .utf8) {
                    handle.write(data)
                }
            }
        }

        do {
            try task.run()
            process = task
            lastSpawn = Date()
            AppLog.log("Sidecar spawned (pid=\(task.processIdentifier)) from \(exe.path)")
        } catch {
            AppLog.log("Failed to spawn sidecar: \(error.localizedDescription)")
        }
    }
}