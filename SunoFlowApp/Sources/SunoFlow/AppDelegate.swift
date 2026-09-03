import AVFoundation
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The running delegate. First-run setup reaches it to borrow the shortcut
    /// and to ask whether that shortcut registered at all.
    static private(set) var shared: AppDelegate?

    /// Set by first-run setup while it is asking the user to press the shortcut.
    /// Returning true swallows the press, so proving the key works does not also
    /// start a dictation the user did not ask for.
    var hotkeyInterceptor: (() -> Bool)?

    /// Whether the configured shortcut is actually ours. False means another app
    /// owns the combination and the key will silently do nothing.
    var hotkeyRegistered: Bool { hotkeyManager.isRegistered }
    private enum State {
        case sidecarOffline
        case idle
        case recording
        case processing
    }

    private var statusItem: NSStatusItem!
    private let hotkeyManager = HotkeyManager(id: 1)
    /// Second Carbon hotkey: cycles the tone. `HotkeyManager` instances need
    /// distinct ids so their events can be told apart in the shared handler.
    private let toneHotkeyManager = HotkeyManager(id: 2)
    private let audioRecorder = AudioRecorder()
    private let overlay = DictationOverlay()
    private let transcriptCard = TranscriptCard()
    private let editLearner = EditLearner()
    private var state: State = .sidecarOffline {
        didSet {
            updateIcon()
            updateStatusText()
        }
    }
    private var healthCheckTimer: Timer?
    private var maxRecordingTimer: Timer?
    /// Screen OCR for the dictation currently being recorded, started the
    /// moment recording began. See `beginScreenContextCapture`. Nil when this
    /// dictation is not collecting screen context.
    private var screenContextCapture: ScreenContextCapture?

    /// The frontmost-app reading started when recording began. See
    /// `ForegroundApp.Capture` for why it starts there and never waits.
    private var appContextCapture: ForegroundApp.Capture?
    private var statusMenuItem: NSMenuItem!
    private var lastTranscriptMenuItem: NSMenuItem!
    private var correctionsMenuItem: NSMenuItem!
    private let correctionsMenu = NSMenu()
    private var toneMenuItem: NSMenuItem!
    private let toneMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

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

        // Earbuds that macOS has parked in the input slot play everything back
        // at call quality until something moves it. Watch for that and steer
        // capture to the built-in mic.
        BluetoothAudioGuard.shared.start()

        audioRecorder.onLevel = { [weak self] level in
            self?.overlay.updateLevel(level)
        }

        hotkeyManager.onHotkey = { [weak self] in
            if self?.hotkeyInterceptor?() == true { return }
            self?.toggleRecording()
        }
        let prefs = Preferences.shared
        hotkeyManager.register(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)

        NotificationCenter.default.addObserver(
            forName: .sunoHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            let prefs = Preferences.shared
            self?.hotkeyManager.reregister(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
            AppLog.log("Hotkey re-registered: \(KeyCombo.display(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers))")
        }

        toneHotkeyManager.onHotkey = { [weak self] in self?.cycleTone() }
        syncToneHotkey()
        NotificationCenter.default.addObserver(
            forName: .sunoToneHotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncToneHotkey()
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

        // A first run gets the setup wizard rather than a menu-bar icon and no
        // idea what to do next. Everything above has already registered the
        // hotkey and started the sidecar, so setup can report on both.
        if !Preferences.shared.onboardingCompleted {
            AppLog.log("First run — showing setup")
            OnboardingWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthCheckTimer?.invalidate()
        hotkeyManager.unregister()
        toneHotkeyManager.unregister()
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
        // The current voice always has somewhere to be read. A colour on the
        // pill says a tone changed; it cannot say which one is in force now,
        // and the pill is only on screen for a moment.
        toneMenuItem = NSMenuItem(title: "Tone", action: nil, keyEquivalent: "")
        toneMenuItem.submenu = toneMenu
        menu.addItem(toneMenuItem)

        menu.addItem(NSMenuItem.separator())
        correctionsMenuItem = NSMenuItem(title: "Learned Corrections", action: nil, keyEquivalent: "")
        correctionsMenuItem.submenu = correctionsMenu
        menu.addItem(correctionsMenuItem)

        let setupItem = NSMenuItem(title: "Run setup again…", action: #selector(openOnboarding), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit SunoFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
        rebuildCorrectionsMenu([])
        refreshToneMenu()
        updateStatusText()
    }

    // MARK: - Tone

    /// Register or re-register the tone hotkey to match the setting. Unlike the
    /// old Fn event tap, a Carbon hotkey registers first try — there is no
    /// permission to wait for, so this only needs to run when the setting or
    /// the combination changes.
    private func syncToneHotkey() {
        let prefs = Preferences.shared
        guard prefs.toneHotkeyEnabled else {
            toneHotkeyManager.unregister()
            return
        }
        toneHotkeyManager.reregister(
            keyCode: prefs.toneHotkeyKeyCode,
            modifiers: prefs.toneHotkeyModifiers
        )
        AppLog.log("Tone hotkey \(toneHotkeyManager.isRegistered ? "registered" : "FAILED to register"): \(KeyCombo.display(keyCode: prefs.toneHotkeyKeyCode, modifiers: prefs.toneHotkeyModifiers))")
    }

    /// Advance to the next voice and show it. The tone hotkey calls exactly
    /// this; the menu is the same action by another route, so the two can never
    /// disagree about what "next" means.
    @objc func cycleTone() {
        announce(Preferences.shared.cycleTone())
    }

    @objc private func selectToneItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let tone = Tone.from(raw)
        Preferences.shared.tone = tone
        announce(tone)
    }

    private func announce(_ tone: Tone) {
        overlay.announceTone(tone)
        refreshToneMenu()
        AppLog.log("Tone set to \(tone.label)")
    }

    private func refreshToneMenu() {
        let current = Preferences.shared.tone
        toneMenuItem?.title = "Tone: \(current.label)"

        toneMenu.removeAllItems()
        // A voice is applied by the cleanup model, so with cleanup off there is
        // no pass to apply it in. Saying so beats a menu that looks live and
        // changes nothing about the pasted text.
        if !Preferences.shared.cleanupEnabled {
            let off = NSMenuItem(title: "Cleanup is off — tone has no effect", action: nil, keyEquivalent: "")
            off.isEnabled = false
            toneMenu.addItem(off)
            toneMenu.addItem(NSMenuItem.separator())
        }
        for tone in Tone.allCases {
            let item = NSMenuItem(title: tone.label, action: #selector(selectToneItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tone.rawValue
            item.state = tone == current ? .on : .off
            toneMenu.addItem(item)
        }
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

    /// Kept reachable from the menu so someone who skipped setup, or who is
    /// setting up a second Mac, can walk the same path again rather than
    /// hunting through settings pages for the pieces.
    @objc private func openOnboarding() {
        OnboardingWindowController.shared.show()
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

        // A card left over from the last dictation is about to be answered by
        // this one — take it down before the overlay comes up.
        transcriptCard.dismiss()

        // Before recording the next utterance, learn from any edits the user made
        // to the previously pasted text.
        editLearner.captureIfNeeded()
        do {
            _ = try audioRecorder.startRecording()
            // Kicked off before the overlay goes up, so the overlay's own words
            // are less likely to end up in the OCR.
            beginScreenContextCapture()
            beginForegroundAppCapture()
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
            screenContextCapture = nil
            appContextCapture = nil
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

        // Whatever the reading started at record time has produced. It is not
        // waited on: see ForegroundApp.Capture.
        let app = appContextCapture?.result() ?? ForegroundApp.Snapshot()
        appContextCapture = nil
        if !app.isEmpty {
            AppLog.log("Dictating into \(app.id.isEmpty ? "?" : app.id)"
                + (app.site.isEmpty ? "" : " (\(app.site))"))
        }

        // The screen OCR was started back when recording began, so by now it has
        // almost always finished; `collect` hands it over immediately when it
        // has, and waits out the remainder when the dictation was too short for
        // it to land. Best-effort throughout: no capture means we proceed with
        // cursor context only.
        guard let capture = screenContextCapture else {
            sendForTranscription(fileURL: fileURL, context: context, screenContext: "", app: app)
            return
        }
        screenContextCapture = nil
        capture.collect { [weak self] screenText in
            guard let self = self else { return }
            if !screenText.isEmpty {
                AppLog.log("Captured \(screenText.count) chars of screen OCR context")
            }
            self.sendForTranscription(
                fileURL: fileURL, context: context, screenContext: screenText, app: app
            )
        }
    }

    /// Starts the screen capture + OCR for the dictation just beginning.
    ///
    /// Screen context costs a screenshot, a downscale and a Vision pass. Run
    /// when the user *stops* speaking, all of that sits between their last word
    /// and the pasted text; run when they *start*, it happens while they are
    /// still talking and is free by the time it is needed. The screen someone
    /// is dictating into barely changes across the utterance, which is what
    /// makes the earlier snapshot just as good a reference for the cleanup
    /// model.
    ///
    /// Needs the Screen Recording permission and is gated by a user toggle;
    /// leaving `screenContextCapture` nil means this dictation carries cursor
    /// context only.
    /// Starts the frontmost-app reading for the dictation just beginning.
    ///
    /// Gated on cleanup alone. Unlike the screen capture this needs no Screen
    /// Recording permission and takes no pixels — the identity comes from
    /// NSWorkspace and the title from Accessibility, which the app already holds
    /// for pasting — so there is no second toggle to hide it behind. With
    /// cleanup off there is no request for it to travel on.
    private func beginForegroundAppCapture() {
        appContextCapture = Preferences.shared.cleanupEnabled ? ForegroundApp.beginCapture() : nil
    }

    private func beginScreenContextCapture() {
        screenContextCapture = nil
        guard Preferences.shared.cleanupEnabled,
              Preferences.shared.screenContextEnabled else { return }
        guard ScreenContext.hasPermission else {
            AppLog.log("Screen context enabled but Screen Recording permission missing — skipping")
            return
        }
        let capture = ScreenContextCapture()
        screenContextCapture = capture
        ScreenContext.captureAndRecognize { capture.finish($0) }
    }

    private func sendForTranscription(
        fileURL: URL, context: String, screenContext: String, app: ForegroundApp.Snapshot
    ) {
        // Read once, here, rather than anywhere downstream: the tone key can
        // fire while this dictation is in flight, and the voice that applies is
        // the one that was chosen when the user stopped speaking.
        TranscriptionClient.transcribe(
            fileURL: fileURL,
            context: context,
            screenContext: screenContext,
            app: app,
            cleanup: Preferences.shared.cleanupEnabled,
            tone: Preferences.shared.tone.rawValue
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
        let offerCopy = Preferences.shared.offerCopyWhenUnfocused

        guard trusted else {
            // We can't simulate Cmd+V without Accessibility. Hand the transcript
            // to the card so it is one click from the clipboard; without the
            // card, fall back to copying it and saying so in the menu.
            NSSound.beep()
            if offerCopy {
                lastTranscriptMenuItem?.title = "Last (not pasted — grant Accessibility): \(preview)"
                AppLog.log("Accessibility NOT granted — offering the transcript to copy")
                transcriptCard.present(cleaned, reason: .noAccessibility)
            } else {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(cleaned, forType: .string)
                lastTranscriptMenuItem?.title = "Last (copied — grant Accessibility): \(preview)"
                AppLog.log("Accessibility NOT granted — copied to clipboard instead of auto-pasting")
            }
            return
        }

        // Pasting into something that can't take text loses the transcript
        // silently, which reads as dictation having failed. Ask what has focus
        // first, and when there is no target, offer the text instead.
        let target = offerCopy ? FocusInspector.currentTarget() : .unknown
        guard target != .notEditable else {
            lastTranscriptMenuItem?.title = "Last (nothing focused — copy it): \(preview)"
            AppLog.log("No editable target — offering the transcript to copy")
            transcriptCard.present(cleaned, reason: .noFocus)
            return
        }

        TextInjector.insert(cleaned)
        AppLog.log("Inserted via paste (\(cleaned.count) chars)")
        // Snapshot the field so we can learn from any edits the user makes.
        editLearner.noteInsertion()
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
        // The tone can change from the key while the menu is shut, and the
        // cleanup toggle can change from Settings, so both are re-read here
        // rather than only when something in this file moved them.
        refreshToneMenu()
    }
}

/// One screen-OCR pass, started when a dictation begins and collected when it
/// ends — the two rarely line up, and either can come first.
///
/// Main-queue confined: `ScreenContext.captureAndRecognize` completes there and
/// both ends of the dictation run there, so the state needs no lock. Delivery
/// happens exactly once, whichever way round the race falls: a collector that
/// arrives late is answered on the spot, one that arrives early is answered as
/// soon as the OCR lands.
private final class ScreenContextCapture {
    private var text: String?
    private var finished = false
    private var collector: ((String) -> Void)?

    /// Called by the OCR when it finishes. Nil (no permission, capture or OCR
    /// failure, nothing legible on screen) is simply no context.
    func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        text = value
        guard let collector = collector else { return }
        self.collector = nil
        collector(value ?? "")
    }

    /// Hands over the recognized words, immediately if the OCR has already
    /// finished, otherwise as soon as it does.
    func collect(_ completion: @escaping (String) -> Void) {
        if finished {
            completion(text ?? "")
        } else {
            collector = completion
        }
    }
}
