import Foundation
import ServiceManagement

/// Launch-at-login for the SunoFlow app, using the modern `SMAppService` API
/// (macOS 13+). This registers the app itself as a login item; it does NOT set
/// up the Python sidecar to auto-start — that lives in `install-autostart.sh`,
/// which also keeps the transcription engine alive.
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
