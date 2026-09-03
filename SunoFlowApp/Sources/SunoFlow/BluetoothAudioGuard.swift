import CoreAudio
import Foundation

/// Keeps a Bluetooth headset out of the system's default *input* slot, so it
/// stays in high-quality A2DP output mode.
///
/// macOS negotiates the Hands-Free Profile the moment a Bluetooth headset
/// becomes the default input device — nothing has to be recording. Measured on
/// a pair of OnePlus Nord Buds 3r: as soon as they are the default input, their
/// *output* stream drops from 44.1 kHz stereo to 16 kHz mono, and it stays
/// there for every app on the machine until the default input moves elsewhere.
/// That is the whole reason music and video sound muffled while a dictation app
/// is around — not the recording itself.
///
/// macOS re-selects the headset mic on its own each time the earbuds connect,
/// so correcting it once in Sound settings does not hold. This watches the
/// default-input property and steers capture back to the built-in mic.
///
/// It deliberately does not fight the user: if something already has the
/// headset mic open, that is a call in progress and we leave it alone.
final class BluetoothAudioGuard {
    static let shared = BluetoothAudioGuard()

    /// How long to wait before acting on a switch to a Bluetooth input.
    ///
    /// An app starting a call sets the default input and *then* opens the
    /// stream. Acting immediately would yank the mic out from under it, so we
    /// give the stream a moment to appear and back off if it does.
    private let graceSeconds: TimeInterval = 2.0

    private let queue = DispatchQueue(label: "com.sunoapp.sunoflow.bluetooth-guard")
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {}

    /// Begin watching the default input device. Safe to call more than once.
    func start() {
        guard listener == nil else { return }
        guard AudioDevices.builtInInputDeviceID() != nil else {
            AppLog.log("BluetoothAudioGuard: no built-in mic on this Mac — not watching the default input")
            return
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleEvaluation()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        guard status == noErr else {
            AppLog.log("BluetoothAudioGuard: could not watch the default input (status \(status))")
            return
        }
        listener = block
        AppLog.log("BluetoothAudioGuard: watching the default input device")

        // The earbuds may already own the input slot from before launch.
        scheduleEvaluation()
    }

    func stop() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
        )
        self.listener = nil
    }

    private func scheduleEvaluation() {
        queue.asyncAfter(deadline: .now() + graceSeconds) { [weak self] in
            self?.evaluate()
        }
    }

    private func evaluate() {
        guard Preferences.shared.protectBluetoothAudio else { return }
        guard let current = AudioDevices.defaultInputDeviceID(),
              AudioDevices.isBluetooth(current) else { return }

        // Someone is actively recording from the headset mic — a call, most
        // likely. Their choice; leave it.
        if AudioDevices.isRunningSomewhere(current) {
            AppLog.log("BluetoothAudioGuard: \(AudioDevices.name(of: current) ?? "Bluetooth mic") is in use — leaving the default input alone")
            return
        }

        guard let builtIn = AudioDevices.builtInInputDeviceID() else { return }
        let ok = AudioDevices.setDefaultInputDevice(builtIn)
        AppLog.log("BluetoothAudioGuard: macOS selected \(AudioDevices.name(of: current) ?? "a Bluetooth mic") as the input, which drops its output to call quality — moved capture back to the built-in mic (ok=\(ok))")
    }
}
