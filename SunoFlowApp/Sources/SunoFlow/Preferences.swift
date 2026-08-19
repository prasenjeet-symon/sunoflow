import Carbon
import Foundation

extension Notification.Name {
    /// Posted when the dictation hotkey changes so the AppDelegate can re-register it.
    static let sunoHotkeyChanged = Notification.Name("suno.hotkeyChanged")
    /// Posted by SettingsView when there are unsaved AI-config changes.
    static let sunoAIConfigDirty = Notification.Name("suno.aiConfigDirty")
    /// Posted when AI-config changes have been saved or discarded.
    static let sunoAIConfigClean = Notification.Name("suno.aiConfigClean")
    /// Posted by the window controller when the user chose "Save" in the close prompt.
    static let sunoSaveAndClose = Notification.Name("suno.saveAndClose")
}

/// Cross-process notifications (delivered via DistributedNotificationCenter).
enum AppNotifications {
    /// Sent by a second launch of the app to ask the running instance to open Settings.
    static let openSettings = Notification.Name("com.sunoapp.sunoflow.openSettings")
}

/// App-wide user settings, persisted in `UserDefaults` and observable from SwiftUI.
///
/// These back the values that used to be hardcoded across the app: the mic device,
/// the dictation hotkey, the auto-stop duration, and whether the AI cleanup pass
/// runs. The AI *instruction* and Ollama *model* live in the sidecar (see
/// `TranscriptionClient` `/config`), since that's where cleanup actually happens.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let micDeviceUID = "micDeviceUID"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let cleanupEnabled = "cleanupEnabled"
        static let screenContextEnabled = "screenContextEnabled"
    }

    /// Core Audio device UID to record from. Empty means "system default input".
    @Published var micDeviceUID: String {
        didSet { defaults.set(micDeviceUID, forKey: Key.micDeviceUID) }
    }

    /// Carbon virtual key code for the dictation toggle hotkey.
    @Published var hotkeyKeyCode: UInt32 {
        didSet { persistHotkey() }
    }

    /// Carbon modifier mask (cmdKey / optionKey / …) for the dictation hotkey.
    @Published var hotkeyModifiers: UInt32 {
        didSet { persistHotkey() }
    }

    /// Auto-stop a runaway recording after this many seconds.
    @Published var maxRecordingSeconds: Int {
        didSet { defaults.set(maxRecordingSeconds, forKey: Key.maxRecordingSeconds) }
    }

    /// Run the local LLM cleanup pass. When off, the raw transcript is pasted.
    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Key.cleanupEnabled) }
    }

    /// Capture the screen and run on-device OCR when dictation stops, so the
    /// cleanup LLM gets heuristic context about the app/field being typed
    /// into. Requires the Screen Recording permission. Off by default because
    /// it needs an extra permission the user must grant explicitly.
    @Published var screenContextEnabled: Bool {
        didSet { defaults.set(screenContextEnabled, forKey: Key.screenContextEnabled) }
    }

    private init() {
        defaults.register(defaults: [
            Key.micDeviceUID: "",
            Key.hotkeyKeyCode: Int(DefaultHotkey.keyCode),
            Key.hotkeyModifiers: Int(DefaultHotkey.modifiers),
            Key.maxRecordingSeconds: 60,
            Key.cleanupEnabled: true,
            Key.screenContextEnabled: false,
        ])
        // didSet does not fire for assignments inside init, so these load the
        // stored values without redundantly writing them back.
        micDeviceUID = defaults.string(forKey: Key.micDeviceUID) ?? ""
        hotkeyKeyCode = UInt32(defaults.integer(forKey: Key.hotkeyKeyCode))
        hotkeyModifiers = UInt32(defaults.integer(forKey: Key.hotkeyModifiers))
        maxRecordingSeconds = defaults.integer(forKey: Key.maxRecordingSeconds)
        cleanupEnabled = defaults.bool(forKey: Key.cleanupEnabled)
        screenContextEnabled = defaults.bool(forKey: Key.screenContextEnabled)
    }

    private func persistHotkey() {
        defaults.set(Int(hotkeyKeyCode), forKey: Key.hotkeyKeyCode)
        defaults.set(Int(hotkeyModifiers), forKey: Key.hotkeyModifiers)
        NotificationCenter.default.post(name: .sunoHotkeyChanged, object: nil)
    }

    /// Restore the built-in ⌥Space shortcut.
    func resetHotkeyToDefault() {
        hotkeyKeyCode = DefaultHotkey.keyCode
        hotkeyModifiers = DefaultHotkey.modifiers
    }
}
