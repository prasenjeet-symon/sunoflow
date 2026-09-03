import AVFoundation
import AudioToolbox

enum AudioRecorderError: Error {
    case converterCreationFailed
    case notRecording
}

/// Captures microphone audio and writes it to a temp WAV file as
/// 16 kHz mono 16-bit PCM, the format Parakeet expects.
final class AudioRecorder {
    // Recreated per recording so the input node binds to the current default
    // device (see startRecording).
    private var engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private(set) var isRecording = false
    private(set) var currentFileURL: URL?

    // When we temporarily switch the system default input to the user's chosen
    // mic, remember the previous default so we can restore it on stop.
    private var savedDefaultInputID: AudioDeviceID?

    /// Emits a normalized 0...1 audio level for each captured buffer, on the
    /// main queue, so a UI (the dictation overlay) can react to the voice.
    var onLevel: ((Float) -> Void)?

    // Diagnostics: how much audio we captured and how loud it was.
    private var capturedFrames: Int = 0
    private var peakAmplitude: Int16 = 0

    func startRecording() throws -> URL {
        capturedFrames = 0
        peakAmplitude = 0

        selectPreferredInputDevice()
        // A fresh engine so its input node binds to the (possibly just-changed)
        // default input device. Reusing an engine keeps the node bound to whatever
        // device it first saw — which is why a Bluetooth default left the tap on a
        // dead 16 kHz HFP stream that delivered 0 frames.
        engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        AppLog.log("startRecording: input format \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioRecorderError.converterCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sunoflow-\(UUID().uuidString).wav")

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file = try AVAudioFile(
            forWriting: tempURL,
            settings: fileSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        audioFile = file
        currentFileURL = tempURL

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

            var providedData = false
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if providedData {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                providedData = true
                outStatus.pointee = .haveData
                return buffer
            }

            var conversionError: NSError?
            converter.convert(to: outBuffer, error: &conversionError, withInputFrom: inputBlock)

            if conversionError == nil, outBuffer.frameLength > 0 {
                self.updateStats(from: outBuffer)
                try? self.audioFile?.write(from: outBuffer)
            }
        }

        engine.prepare()
        try engine.start()
        isRecording = true
        return tempURL
    }

    /// If the user picked a specific mic, make it the system default input for the
    /// duration of the recording (AVAudioEngine records from the default input).
    /// The previous default is restored in stopRecording. No-op for "system
    /// default" or when the saved device is no longer connected.
    ///
    /// Bluetooth fallback: recording from a Bluetooth headset mic forces it into
    /// low-quality HFP call mode, which degrades audio *output* in every app for
    /// the whole recording (and often lingers afterward). When the effective input
    /// is Bluetooth and a built-in mic is available, we silently steer capture to
    /// the built-in mic instead — preserving high-quality A2DP output on the
    /// headset. The user's Settings selection is left untouched.
    private func selectPreferredInputDevice() {
        savedDefaultInputID = nil
        let current = AudioDevices.defaultInputDeviceID()

        // Resolve the device we *would* record from: the saved choice, or the
        // system default if none was set.
        let savedUID = Preferences.shared.micDeviceUID
        let targetUID = savedUID.isEmpty ? (AudioDevices.defaultInputUID() ?? "") : savedUID
        let targetDevice = targetUID.isEmpty ? current : AudioDevices.deviceID(forUID: targetUID)

        // If that device is Bluetooth and a built-in mic exists, fall back to it
        // so the headset stays in A2DP output mode.
        if targetDevice != nil, AudioDevices.effectiveInputIsBluetooth(savedUID: savedUID),
           let builtInUID = AudioDevices.builtInInputUID(),
           let builtInID = AudioDevices.deviceID(forUID: builtInUID) {
            AppLog.log("startRecording: effective input is Bluetooth (\(targetUID)) — falling back to built-in mic to preserve audio output quality")
            if current != builtInID {
                savedDefaultInputID = current
                let ok = AudioDevices.setDefaultInputDevice(builtInID)
                AppLog.log("startRecording: set default input to built-in (\(builtInUID)) (ok=\(ok))")
            }
            return
        }

        guard !savedUID.isEmpty, let deviceID = AudioDevices.deviceID(forUID: savedUID) else {
            if !savedUID.isEmpty {
                AppLog.log("Preferred mic \(savedUID) not found — using system default")
            }
            return
        }
        // Only override (and remember to restore) if it isn't already the default.
        if current != deviceID {
            savedDefaultInputID = current
            let ok = AudioDevices.setDefaultInputDevice(deviceID)
            AppLog.log("startRecording: set default input to \(savedUID) (ok=\(ok))")
        }
    }

    private func updateStats(from buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        capturedFrames += frames
        guard frames > 0, let channel = buffer.int16ChannelData?[0] else { return }

        var localPeak = peakAmplitude
        var bufferPeak: Int16 = 0
        var sumSquares: Double = 0
        for i in 0..<frames {
            let sample = channel[i]
            let magnitude = sample == Int16.min ? Int16.max : abs(sample)
            if magnitude > localPeak { localPeak = magnitude }
            if magnitude > bufferPeak { bufferPeak = magnitude }
            let normalized = Double(sample) / Double(Int16.max)
            sumSquares += normalized * normalized
        }
        peakAmplitude = localPeak

        // RMS gives a smoother, more voice-like level than raw peak.
        let rms = sqrt(sumSquares / Double(frames))
        let level = Float(min(1.0, rms * 3.2)) // gentle gain so normal speech fills the meter
        if let onLevel = onLevel {
            DispatchQueue.main.async { onLevel(level) }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false

        // Restore the user's previous default input device — unless it was the
        // Bluetooth headset we steered away from. Handing that slot back
        // re-negotiates HFP, and the headset's *output* drops to 16 kHz mono for
        // every app on the machine until something moves the default input
        // again. Protecting output only for the duration of the recording and
        // then re-arming the downgrade is worse than not restoring at all; the
        // guard keeps the built-in mic selected from here.
        if let saved = savedDefaultInputID {
            if AudioDevices.isBluetooth(saved) {
                AppLog.log("stopRecording: not restoring \(AudioDevices.name(of: saved) ?? "the Bluetooth mic") as the default input — that would drop its output to call quality")
            } else {
                AudioDevices.setDefaultInputDevice(saved)
            }
            savedDefaultInputID = nil
        }

        let seconds = Double(capturedFrames) / 16000.0
        let peakRatio = Double(peakAmplitude) / Double(Int16.max)
        AppLog.log(String(
            format: "stopRecording: captured %d frames (%.2fs), peak amplitude %d (%.1f%% of full scale)%@",
            capturedFrames, seconds, peakAmplitude, peakRatio * 100,
            peakAmplitude < 100 ? "  <-- NEAR SILENCE (mic likely muted or permission denied)" : ""
        ))
    }
}
