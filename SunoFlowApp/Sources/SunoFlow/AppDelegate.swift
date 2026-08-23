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
        // The stored device key may have been written by a copy of the app at a
        // different path (a build directory, before it was installed). Rewrite
        // it from here so macOS stops treating every read as untrusted.
        Keychain.repairAccessIfNeeded()

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

        // In a distributed app the app itself supervises the bundled frozen
        // sidecar (no external launchd KeepAlive). In dev this is a no-op.
        SidecarSupervisor.shared.ensureRunning()

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
            ? "Dictionary"
            : "Dictionary (\(corrections.count))"

        guard !corrections.isEmpty else {
            let none = NSMenuItem(title: "Empty — edit pasted text to teach it a spelling", action: nil, keyEquivalent: "")
            none.isEnabled = false
            correctionsMenu.addItem(none)
            return
        }

        let header = NSMenuItem(title: "Click an item to remove it:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        correctionsMenu.addItem(header)

        for correction in corrections {
            // Only shorthand is tagged. Spellings are the default and the bulk of
            // the list, so labelling them too would be noise in a menu this size.
            let kindTag = correction.resolvedKind == .expansion ? "  · Shorthand" : ""
            let suffix = correction.count > 1 ? "  (×\(correction.count))" : ""
            let item = NSMenuItem(
                title: "“\(correction.from)” → “\(correction.to)”\(suffix)\(kindTag)",
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
        case .sidecarOffline: text = "Status: speech engine offline"
        case .idle: text = "Status: idle — press ⌥Space to dictate"
        case .recording: text = "Status: recording… press ⌥Space to stop"
        case .processing: text = "Status: transcribing…"
        }
        statusMenuItem?.title = text
    }

    private func updateIcon() {
        let variant: BrandMark.Variant
        switch state {
        case .sidecarOffline: variant = .offline
        case .idle: variant = .idle
        case .recording: variant = .recording
        case .processing: variant = .processing
        }
        statusItem.button?.image = BrandMark.image(variant)
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
                    if !ok {
                        // Respawn a dead bundled sidecar (installed mode only).
                        // In dev this is a no-op.
                        SidecarSupervisor.shared.ensureRunning()
                    }
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
        // SunoFlow is a subscription product: without a connected account there
        // is no device key, nothing would authenticate to the cleanup service,
        // and dictation would quietly degrade to raw text. Say so up front
        // rather than recording something we cannot finish.
        guard Keychain.deviceKey() != nil else {
            NSSound.beep()
            AppLog.log("Dictation blocked — no account connected on this Mac")
            lastTranscriptMenuItem?.title = "Connect your account to dictate"
            SettingsWindowController.shared.show()
            return
        }

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

        // Optionally capture the screen and run on-device OCR for heuristic
        // context (window titles, labels, nearby text). This needs the Screen
        // Recording permission and is gated by a user toggle. Best-effort:
        // nil means we skip it and proceed with cursor context only.
        let captureScreen = Preferences.shared.cleanupEnabled
            && Preferences.shared.screenContextEnabled
        if captureScreen {
            guard ScreenContext.hasPermission else {
                AppLog.log("Screen context enabled but Screen Recording permission missing — skipping")
                sendForTranscription(fileURL: fileURL, context: context, screenContext: "")
                return
            }
            ScreenContext.captureAndRecognize { [weak self] screenText in
                guard let self = self else { return }
                if let screenText = screenText, !screenText.isEmpty {
                    AppLog.log("Captured \(screenText.count) chars of screen OCR context")
                }
                self.sendForTranscription(
                    fileURL: fileURL, context: context, screenContext: screenText ?? ""
                )
            }
        } else {
            sendForTranscription(fileURL: fileURL, context: context, screenContext: "")
        }
    }

    private func sendForTranscription(fileURL: URL, context: String, screenContext: String) {
        TranscriptionClient.transcribe(
            fileURL: fileURL,
            context: context,
            screenContext: screenContext,
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
                    // Served, so the account is in good standing: clear any
                    // stale lapse notice and re-arm it for a future one.
                    AccountManager.shared.clearEntitlementNotice()
                    self.hasShownLapseNotice = false
                    self.handleTranscript(transcription)
                case .failure(let error):
                    NSSound.beep()
                    if case TranscriptionError.notEntitled(let code, let message) = error {
                        // Nothing is pasted. This is a stop, not a degraded
                        // result — say so and point at the place it can be fixed.
                        AppLog.log("Dictation refused — \(code)")
                        AccountManager.shared.noteEntitlementProblem(message)
                        self.showDictationBlocked(code: code, message: message)
                    } else {
                        AppLog.log("Transcription request failed: \(error)")
                    }
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    /// Tells the user why nothing was typed.
    ///
    /// Deliberately not a user notification: that API is deprecated and the
    /// replacement needs an authorisation prompt, which is a poor thing to ask
    /// for at the exact moment dictation has just failed. Opening Settings on
    /// the Account tab explains it and puts the fix one click away.
    private func showDictationBlocked(code: String, message: String) {
        // An outage and a lapsed subscription both stop dictation, but they are
        // not the same news and must not read the same in the menu bar.
        let summary = code == "unreachable"
            ? "Paused — can't reach SunoFlow"
            : "Paused — subscription inactive"
        lastTranscriptMenuItem?.title = summary
        let paused = BrandMark.image(.offline)
        paused.accessibilityDescription = "SunoFlow \(summary)"
        statusItem.button?.image = paused

        // Only surface the window once per lapse, so repeated hotkey presses
        // do not keep yanking Settings to the front.
        guard !hasShownLapseNotice else { return }
        hasShownLapseNotice = true
        SettingsWindowController.shared.show()
    }

    private var hasShownLapseNotice = false

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
