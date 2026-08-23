import Foundation
import ServiceManagement

/// Launch-at-login for the SunoFlow app, using the modern `SMAppService` API
/// (macOS 13+). This registers the app itself as a login item only. The
/// transcription sidecar's lifecycle is owned by `SidecarSupervisor`, which
/// spawns/respawns the bundled frozen sidecar binary directly — there is no
/// external launchd plist or `install-autostart.sh` dependency in a
/// distributed app.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns `nil` on success, or a human-readable error message on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
