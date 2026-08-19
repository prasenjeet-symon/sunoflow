import AVFoundation
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum State {
        case sidecarOffline
        case idle
        case recording
        case processing
    }

    private var statusItem: NSStatusItem!
    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let overlay = DictationOverlay()
    private let editLearner = EditLearner()
    private var state: State = .sidecarOffline {
        didSet {
            updateIcon()
            updateStatusText()
        }
    }
    private var healthCheckTimer: Timer?
    private var maxRecordingTimer: Timer?
    private var statusMenuItem: NSMenuItem!
    private var lastTranscriptMenuItem: NSMenuItem!
    private var correctionsMenuItem: NSMenuItem!
    private let correctionsMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.log("=== SunoFlow launched ===")
        logMicPermission()
        setupStatusItem()
        requestMicPermissionIfNeeded()

        let trusted = TextInjector.promptForAccessibilityPermissionIfNeeded()
        AppLog.log("Accessibility trusted at launch: \(trusted)")

        audioRecorder.onLevel = { [weak self] level in
            self?.overlay.updateLevel(level)
        }

        hotkeyManager.onHotkey = { [weak self] in self?.toggleRecording() }
        let prefs = Preferences.shared
        hotkeyManager.register(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)

        NotificationCenter.default.addObserver(
            forName: .sunoHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            let prefs = Preferences.shared
            self?.hotkeyManager.reregister(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
            AppLog.log("Hotkey re-registered: \(KeyCombo.display(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers))")
        }

        // A second launch of the app asks us to surface the Settings window.
        DistributedNotificationCenter.default().addObserver(
            forName: AppNotifications.openSettings, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openSettings()
        }

        startHealthPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthCheckTimer?.invalidate()
        hotkeyManager.unregister()
        if audioRecorder.isRecording {
            audioRecorder.stopRecording()
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "SunoFlow", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        statusMenuItem = NSMenuItem(title: "Status: starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        lastTranscriptMenuItem = NSMenuItem(title: "Last: (nothing yet)", action: nil, keyEquivalent: "")
        lastTranscriptMenuItem.isEnabled = false
        menu.addItem(lastTranscriptMenuItem)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(
            title: "Toggle Dictation (⌥Space)",
            action: #selector(menuToggle),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())
        correctionsMenuItem = NSMenuItem(title: "Learned Corrections", action: nil, keyEquivalent: "")
        correctionsMenuItem.submenu = correctionsMenu
        menu.addItem(correctionsMenuItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit SunoFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        rebuildCorrectionsMenu([])
        updateStatusText()
    }

    // MARK: - Learned corrections menu

    private func refreshCorrectionsMenu() {
        TranscriptionClient.fetchCorrections { [weak self] corrections in
            DispatchQueue.main.async {
                self?.rebuildCorrectionsMenu(corrections)
            }
        }
    }

    private func rebuildCorrectionsMenu(_ corrections: [Correction]) {
        correctionsMenu.removeAllItems()
        correctionsMenuItem.title = corrections.isEmpty
            ? "Learned Corrections"
            : "Learned Corrections (\(corrections.count))"

        guard !corrections.isEmpty else {
            let none = NSMenuItem(title: "None yet — edit pasted text to teach it", action: nil, keyEquivalent: "")
            none.isEnabled = false
            correctionsMenu.addItem(none)
            return
        }

        let header = NSMenuItem(title: "Click an item to remove it:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        correctionsMenu.addItem(header)

        for correction in corrections {
            let suffix = correction.count > 1 ? "  (×\(correction.count))" : ""
            let item = NSMenuItem(
                title: "“\(correction.from)” → “\(correction.to)”\(suffix)",
                action: #selector(deleteCorrectionItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = correction.key
            correctionsMenu.addItem(item)
        }

        correctionsMenu.addItem(NSMenuItem.separator())
        let clear = NSMenuItem(title: "Clear All", action: #selector(clearCorrectionsItem), keyEquivalent: "")
        clear.target = self
        correctionsMenu.addItem(clear)
    }

    @objc private func deleteCorrectionItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        TranscriptionClient.deleteCorrection(key: key) { [weak self] in
            DispatchQueue.main.async { self?.refreshCorrectionsMenu() }
        }
    }

    @objc private func clearCorrectionsItem() {
        TranscriptionClient.clearCorrections { [weak self] in
            DispatchQueue.main.async { self?.refreshCorrectionsMenu() }
        }
    }

    @objc private func menuToggle() {
        toggleRecording()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    private func updateStatusText() {
        let text: String
        switch state {
        case .sidecarOffline: text = "Status: sidecar offline (run ./run.sh)"
        case .idle: text = "Status: idle — press ⌥Space to dictate"
        case .recording: text = "Status: recording… press ⌥Space to stop"
        case .processing: text = "Status: transcribing…"
        }
        statusMenuItem?.title = text
    }

    private func updateIcon() {
        let symbolName: String
        switch state {
        case .sidecarOffline: symbolName = "exclamationmark.triangle"
        case .idle: symbolName = "mic"
        case .recording: symbolName = "mic.fill"
        case .processing: symbolName = "hourglass"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SunoFlow")
    }

    // MARK: - Sidecar health

    private func startHealthPolling() {
        checkHealth()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func checkHealth() {
        TranscriptionClient.health { [weak self] ok in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch self.state {
                case .recording, .processing:
                    return
                default:
                    self.state = ok ? .idle : .sidecarOffline
                }
            }
        }
    }

    // MARK: - Recording flow

    private func toggleRecording() {
        AppLog.log("toggleRecording called, current state=\(state)")
        switch state {
        case .sidecarOffline:
            NSSound.beep()
        case .processing:
            // Never leave the user stuck: a press while processing cancels back to idle.
            AppLog.log("Press during processing — cancelling back to idle")
            overlay.hide()
            state = .idle
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        }
    }

    private func startRecording() {
        // Before recording the next utterance, learn from any edits the user made
        // to the previously pasted text.
        editLearner.captureIfNeeded()
        do {
            _ = try audioRecorder.startRecording()
            state = .recording
            overlay.show(mode: .recording)
            maxRecordingTimer?.invalidate()
            maxRecordingTimer = Timer.scheduledTimer(
                withTimeInterval: TimeInterval(Preferences.shared.maxRecordingSeconds), repeats: false
            ) { [weak self] _ in
                guard let self = self, self.state == .recording else { return }
                AppLog.log("Max recording duration reached — auto-stopping")
                self.stopAndTranscribe()
            }
        } catch {
            NSSound.beep()
            AppLog.log("Failed to start recording: \(error)")
        }
    }

    private func stopAndTranscribe() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        guard let fileURL = audioRecorder.currentFileURL else {
            overlay.hide()
            state = .idle
            return
        }
        audioRecorder.stopRecording()
        state = .processing
        overlay.update(mode: .processing)

        // Read the text just before the cursor (while the field is still focused
        // and unmodified) to give the cleanup model context. Best-effort.
        let context = AccessibilityContext.textBeforeCursor() ?? ""
        if !context.isEmpty {
            AppLog.log("Captured \(context.count) chars of cursor context")
        }

        TranscriptionClient.transcribe(
            fileURL: fileURL,
            context: context,
            cleanup: Preferences.shared.cleanupEnabled
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // If the user cancelled while we were transcribing, drop the result.
                guard self.state == .processing else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                self.overlay.hide()
                self.state = .idle
                switch result {
                case .success(let transcription):
                    self.handleTranscript(transcription)
                case .failure(let error):
                    NSSound.beep()
                    AppLog.log("Transcription request failed: \(error)")
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func handleTranscript(_ transcription: TranscriptionResult) {
        let cleaned = transcription.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Log lengths only, not the dictated text itself (privacy).
        AppLog.log("Transcript received — raw \(transcription.raw.count) chars, cleaned \(cleaned.count) chars")

        guard !cleaned.isEmpty else {
            AppLog.log("Transcript is EMPTY — nothing to insert (silent audio or no speech detected)")
            NSSound.beep()
            lastTranscriptMenuItem?.title = "Last: (empty — no speech detected)"
            return
        }

        let previewLimit = 60
        let preview = cleaned.count > previewLimit
            ? String(cleaned.prefix(previewLimit)) + "…"
            : cleaned
        lastTranscriptMenuItem?.title = "Last: \(preview)"

        let trusted = TextInjector.hasAccessibilityPermission
        AppLog.log("Accessibility trusted before insert: \(trusted)")

        if trusted {
            TextInjector.insert(cleaned)
            AppLog.log("Inserted via paste (\(cleaned.count) chars)")
            // Snapshot the field so we can learn from any edits the user makes.
            editLearner.noteInsertion()
        } else {
            // Fallback: we can't simulate Cmd+V without Accessibility, but we can
            // still put the text on the clipboard so the user can paste manually.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(cleaned, forType: .string)
            NSSound.beep()
            lastTranscriptMenuItem?.title = "Last (copied — grant Accessibility): \(preview)"
            AppLog.log("Accessibility NOT granted — copied to clipboard instead of auto-pasting")
        }
    }

    // MARK: - Permissions

    private func requestMicPermissionIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                AppLog.log("Mic permission request result: granted=\(granted)")
            }
        default:
            break
        }
    }

    private func logMicPermission() {
        let status: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: status = "authorized"
        case .denied: status = "denied"
        case .restricted: status = "restricted"
        case .notDetermined: status = "notDetermined"
        @unknown default: status = "unknown"
        }
        AppLog.log("Mic permission at launch: \(status)")
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh the learned-corrections list each time the menu opens.
        refreshCorrectionsMenu()
    }
}
