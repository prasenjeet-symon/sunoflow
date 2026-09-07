import Carbon
import Foundation

extension Notification.Name {
    /// Posted when the dictation hotkey changes so the AppDelegate can re-register it.
    static let sunoHotkeyChanged = Notification.Name("suno.hotkeyChanged")
    /// Posted when the tone hotkey or its combination changes, so the
    /// AppDelegate can register or re-register it.
    static let sunoToneHotkeyChanged = Notification.Name("suno.toneHotkeyChanged")
    /// Posted when the Suno Answer hotkey or its combination changes, so the
    /// AppDelegate can register or re-register it.
    static let sunoAnswerHotkeyChanged = Notification.Name("suno.answerHotkeyChanged")
    /// Posted when the gateway refuses Suno Answer (not entitled). The
    /// AppDelegate opens the account sheet — the same surface a dictation 402
    /// lands on — carrying `message` and `code` in userInfo.
    static let sunoAnswerNotEntitled = Notification.Name("suno.answerNotEntitled")
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
/// runs. The cleanup instruction and LLM model are owned by the hosted cleanup
/// gateway (see `TranscriptionClient.checkCleanupGateway`); the app only toggles
/// whether the cleanup pass runs and probes the gateway's reachability.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let micDeviceUID = "micDeviceUID"
        static let protectBluetoothAudio = "protectBluetoothAudio"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let cleanupEnabled = "cleanupEnabled"
        static let tone = "tone"
        static let toneHotkeyEnabled = "toneHotkeyEnabled"
        static let toneHotkeyKeyCode = "toneHotkeyKeyCode"
        static let toneHotkeyModifiers = "toneHotkeyModifiers"
        static let answerHotkeyEnabled = "answerHotkeyEnabled"
        static let answerHotkeyKeyCode = "answerHotkeyKeyCode"
        static let answerHotkeyModifiers = "answerHotkeyModifiers"
        static let screenContextEnabled = "screenContextEnabled"
        static let offerCopyWhenUnfocused = "offerCopyWhenUnfocused"
        static let onboardingCompleted = "onboardingCompleted"
        static let cloudWarmStartEnabled = "cloudWarmStartEnabled"
        static let cloudWarmStartDisclosed = "cloudWarmStartDisclosed"
    }

    /// Core Audio device UID to record from. Empty means "system default input".
    @Published var micDeviceUID: String {
        didSet { defaults.set(micDeviceUID, forKey: Key.micDeviceUID) }
    }

    /// Keep Bluetooth headsets out of the system's default *input* slot.
    ///
    /// macOS hands the input slot to earbuds the moment they connect, which
    /// switches them into call mode and drops their playback to 16 kHz mono in
    /// every app. On means SunoFlow moves capture back to the built-in mic —
    /// unless a call already has the headset mic open. See `BluetoothAudioGuard`.
    @Published var protectBluetoothAudio: Bool {
        didSet { defaults.set(protectBluetoothAudio, forKey: Key.protectBluetoothAudio) }
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

    /// The writing voice the cleanup pass writes in. Sticky by design — it is
    /// cycled from a key while dictating, so resetting it every dictation would
    /// make the key feel like it had not registered. `Tone.faithful`, the
    /// default, sends nothing and leaves the user's own wording alone.
    ///
    /// Stored as the raw ID rather than an index: an index would silently mean
    /// a different voice the moment the list gains or loses an entry.
    @Published var tone: Tone {
        didSet { defaults.set(tone.rawValue, forKey: Key.tone) }
    }

    /// Cycle the tone with a second system-wide hotkey (⌥⇧Space by default).
    ///
    /// Off by default: the dictation hotkey already does something with every
    /// press, and a second global shortcut should be an opt-in. On, it is an
    /// ordinary Carbon hotkey — reliable system-wide, unlike the old Fn tap.
    @Published var toneHotkeyEnabled: Bool {
        didSet {
            defaults.set(toneHotkeyEnabled, forKey: Key.toneHotkeyEnabled)
            NotificationCenter.default.post(name: .sunoToneHotkeyChanged, object: nil)
        }
    }

    /// Carbon virtual key code for the tone-cycle hotkey.
    @Published var toneHotkeyKeyCode: UInt32 {
        didSet { persistToneHotkey() }
    }

    /// Carbon modifier mask (cmdKey / optionKey / …) for the tone-cycle hotkey.
    @Published var toneHotkeyModifiers: UInt32 {
        didSet { persistToneHotkey() }
    }

    /// Show the Suno Answer popup (⌃⌥Space by default). Off by default because
    /// turning it on is the consent step (E1/E2): the toggle's description says
    /// exactly what leaves the Mac — a screen snapshot attached to each
    /// question — and nothing is captured while the feature is off.
    @Published var answerHotkeyEnabled: Bool {
        didSet {
            defaults.set(answerHotkeyEnabled, forKey: Key.answerHotkeyEnabled)
            NotificationCenter.default.post(name: .sunoAnswerHotkeyChanged, object: nil)
        }
    }

    /// Carbon virtual key code for the Suno Answer hotkey.
    @Published var answerHotkeyKeyCode: UInt32 {
        didSet { persistAnswerHotkey() }
    }

    /// Carbon modifier mask (cmdKey / optionKey / …) for the Suno Answer hotkey.
    @Published var answerHotkeyModifiers: UInt32 {
        didSet { persistAnswerHotkey() }
    }

    /// Capture the screen and run on-device OCR when dictation stops, so the
    /// cleanup LLM gets heuristic context about the app/field being typed
    /// into. Requires the Screen Recording permission. Off by default because
    /// it needs an extra permission the user must grant explicitly.
    @Published var screenContextEnabled: Bool {
        didSet { defaults.set(screenContextEnabled, forKey: Key.screenContextEnabled) }
    }

    /// When a finished dictation has nowhere to paste — no text field focused,
    /// or no Accessibility permission to press Cmd+V — show the transcript at the
    /// bottom of the screen with a button that copies it, instead of typing into
    /// nothing. Off returns to pasting blindly and hoping something catches it.
    @Published var offerCopyWhenUnfocused: Bool {
        didSet { defaults.set(offerCopyWhenUnfocused, forKey: Key.offerCopyWhenUnfocused) }
    }

    /// False until first-run setup has been completed (or explicitly skipped).
    /// Stored rather than inferred from "is everything configured", so someone
    /// who deletes their model later gets the model page, not the whole wizard.
    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    /// Let a new install dictate immediately over the cloud while the on-device
    /// model (~2 GB) downloads in the background, then hand transcription back to
    /// the local model once it is ready and proven. Sent to the sidecar as
    /// `allow_cloud` on every `/transcribe`.
    ///
    /// On by default — the whole point is that a new user can dictate on first
    /// launch instead of waiting for a multi-gigabyte download. When it is on,
    /// the raw audio of a dictation is processed in the cloud *only* until the
    /// device cuts over to on-device; the first-run disclosure (see
    /// `cloudWarmStartDisclosed`) says so before the first word is captured, and
    /// this switch turns it off — dictation then waits for the local model, the
    /// on-device-only behaviour SunoFlow otherwise ships with.
    @Published var cloudWarmStartEnabled: Bool {
        didSet { defaults.set(cloudWarmStartEnabled, forKey: Key.cloudWarmStartEnabled) }
    }

    /// Whether the one-time cloud warm-start disclosure has been shown. Gates the
    /// first-run notice so it appears once (not the whole reversal of the setting
    /// — a user who turns cloud STT back on later has already seen it).
    @Published var cloudWarmStartDisclosed: Bool {
        didSet { defaults.set(cloudWarmStartDisclosed, forKey: Key.cloudWarmStartDisclosed) }
    }

    private init() {
        defaults.register(defaults: [
            Key.micDeviceUID: "",
            Key.protectBluetoothAudio: true,
            Key.hotkeyKeyCode: Int(DefaultHotkey.keyCode),
            Key.hotkeyModifiers: Int(DefaultHotkey.modifiers),
            Key.maxRecordingSeconds: 60,
            Key.cleanupEnabled: true,
            Key.tone: Tone.faithful.rawValue,
            Key.toneHotkeyEnabled: false,
            Key.toneHotkeyKeyCode: Int(DefaultToneHotkey.keyCode),
            Key.toneHotkeyModifiers: Int(DefaultToneHotkey.modifiers),
            Key.answerHotkeyEnabled: false,
            Key.answerHotkeyKeyCode: Int(DefaultAnswerHotkey.keyCode),
            Key.answerHotkeyModifiers: Int(DefaultAnswerHotkey.modifiers),
            Key.screenContextEnabled: false,
            Key.offerCopyWhenUnfocused: true,
            Key.onboardingCompleted: false,
            Key.cloudWarmStartEnabled: true,
            Key.cloudWarmStartDisclosed: false,
        ])
        // didSet does not fire for assignments inside init, so these load the
        // stored values without redundantly writing them back.
        micDeviceUID = defaults.string(forKey: Key.micDeviceUID) ?? ""
        protectBluetoothAudio = defaults.bool(forKey: Key.protectBluetoothAudio)
        hotkeyKeyCode = UInt32(defaults.integer(forKey: Key.hotkeyKeyCode))
        hotkeyModifiers = UInt32(defaults.integer(forKey: Key.hotkeyModifiers))
        maxRecordingSeconds = defaults.integer(forKey: Key.maxRecordingSeconds)
        cleanupEnabled = defaults.bool(forKey: Key.cleanupEnabled)
        tone = Tone.from(defaults.string(forKey: Key.tone))
        toneHotkeyEnabled = defaults.bool(forKey: Key.toneHotkeyEnabled)
        toneHotkeyKeyCode = UInt32(defaults.integer(forKey: Key.toneHotkeyKeyCode))
        toneHotkeyModifiers = UInt32(defaults.integer(forKey: Key.toneHotkeyModifiers))
        answerHotkeyEnabled = defaults.bool(forKey: Key.answerHotkeyEnabled)
        answerHotkeyKeyCode = UInt32(defaults.integer(forKey: Key.answerHotkeyKeyCode))
        answerHotkeyModifiers = UInt32(defaults.integer(forKey: Key.answerHotkeyModifiers))
        screenContextEnabled = defaults.bool(forKey: Key.screenContextEnabled)
        offerCopyWhenUnfocused = defaults.bool(forKey: Key.offerCopyWhenUnfocused)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        cloudWarmStartEnabled = defaults.bool(forKey: Key.cloudWarmStartEnabled)
        cloudWarmStartDisclosed = defaults.bool(forKey: Key.cloudWarmStartDisclosed)
    }

    private func persistHotkey() {
        defaults.set(Int(hotkeyKeyCode), forKey: Key.hotkeyKeyCode)
        defaults.set(Int(hotkeyModifiers), forKey: Key.hotkeyModifiers)
        NotificationCenter.default.post(name: .sunoHotkeyChanged, object: nil)
    }

    private func persistToneHotkey() {
        defaults.set(Int(toneHotkeyKeyCode), forKey: Key.toneHotkeyKeyCode)
        defaults.set(Int(toneHotkeyModifiers), forKey: Key.toneHotkeyModifiers)
        NotificationCenter.default.post(name: .sunoToneHotkeyChanged, object: nil)
    }

    private func persistAnswerHotkey() {
        defaults.set(Int(answerHotkeyKeyCode), forKey: Key.answerHotkeyKeyCode)
        defaults.set(Int(answerHotkeyModifiers), forKey: Key.answerHotkeyModifiers)
        NotificationCenter.default.post(name: .sunoAnswerHotkeyChanged, object: nil)
    }

    /// Restore the built-in ⌥Space shortcut.
    func resetHotkeyToDefault() {
        hotkeyKeyCode = DefaultHotkey.keyCode
        hotkeyModifiers = DefaultHotkey.modifiers
    }

    /// Restore the built-in ⌥⇧Space tone shortcut.
    func resetToneHotkeyToDefault() {
        toneHotkeyKeyCode = DefaultToneHotkey.keyCode
        toneHotkeyModifiers = DefaultToneHotkey.modifiers
    }

    /// Restore the built-in ⌃⌥Space Suno Answer shortcut.
    func resetAnswerHotkeyToDefault() {
        answerHotkeyKeyCode = DefaultAnswerHotkey.keyCode
        answerHotkeyModifiers = DefaultAnswerHotkey.modifiers
    }
}

extension Preferences {
    /// Advance to the next voice and hand back what it landed on, so the caller
    /// can announce it. One place for the cycle, whether it was driven from the
    /// key or from the menu.
    @discardableResult
    func cycleTone() -> Tone {
        tone = tone.next
        return tone
    }
}