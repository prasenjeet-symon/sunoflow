import AVFoundation
import AppKit
import SwiftUI

/// First-run setup: a short wizard that takes a fresh install from "nothing
/// configured" to "you just dictated a sentence and watched it appear".
///
/// It exists because the dashboard was a poor first experience. Everything a new
/// install needs — an account, a microphone, permission to type into other apps,
/// a working shortcut, the speech model — lived on separate pages the user had
/// to know to visit. The wizard turns that into one ordered path with a single
/// next step at any moment.
///
/// Two deliberate choices, matching the Windows wizard:
///
///   * The model download does not block the flow. It is ~2.5 GB and can take an
///     hour on a bad connection, so it starts the moment an account exists and
///     streams in the background while the permission steps happen. Only the
///     final live test needs it, and that step can be left for later.
///   * The wording avoids jargon — nobody needs to hear "Parakeet TDT" — but the
///     size and the one-time nature stay on screen throughout. Those are the
///     facts that actually affect someone on a metered connection or a small
///     disk, and burying them would be the dishonest kind of simple.
///
/// The last step runs the real pipeline rather than a mock: the user's own
/// shortcut, their microphone, the sidecar, the entitlement check, the cleanup
/// gateway and the Cmd+V paste, landing in a text field on this window. If that
/// field fills in, the product works on this Mac.
///
/// Screen Recording is deliberately *not* asked for here. Screen context is off
/// by default and only sharpens cleanup; asking for a scary permission during
/// first run, for a feature the user has not switched on, trades trust for
/// nothing. It stays in Settings, where turning it on is what asks.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, account, microphone, accessibility, shortcut, setup, tryIt, done

        /// Welcome is scene-setting and done is a farewell; the numbered steps in
        /// between are the ones the user is actually asked to do.
        static let numbered: [Step] = [.account, .microphone, .accessibility, .shortcut, .setup, .tryIt]
    }

    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var account = AccountManager.shared

    @State private var step: Step = .welcome

    @State private var micPermission = false
    @State private var micLevel: Float = 0
    @State private var micHeard = false
    @State private var accessibility = false

    @State private var sidecarOnline = false
    @State private var modelStatus: ModelStatus?
    @State private var downloadRequested = false

    @State private var hotkeyProved = false
    @State private var tryText = ""
    @State private var trySucceeded = false

    @State private var poll: Timer?
    @State private var probe: AudioRecorder?

    private var modelLoaded: Bool { modelStatus?.model_loaded == true }

    private var hotkeyLabel: String {
        KeyCombo.display(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rule(strong: true)
                content
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, 32)
        }
        .background(Theme.paper)
        .frame(minWidth: 640, minHeight: 560)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: account.state) { _ in accountStateChanged() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let index = Step.numbered.firstIndex(of: step) {
                Text("STEP \(index + 1) OF \(Step.numbered.count)")
                    .font(.sunoKicker)
                    .tracking(0.8)
                    .foregroundStyle(Theme.faint)
                    .padding(.top, 34)
            } else {
                Color.clear.frame(height: 34)
            }
            Text(title)
                .font(.sunoDisplay)
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(.sunoBody)
                .foregroundStyle(Theme.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)
        }
    }

    private var title: String {
        switch step {
        case .welcome: return "Welcome to SunoFlow"
        case .account: return "Connect this Mac"
        case .microphone: return "Choose your microphone"
        case .accessibility: return "Let SunoFlow type for you"
        case .shortcut: return "Your dictation shortcut"
        case .setup: return "Setting up speech recognition"
        case .tryIt: return "Try it out"
        case .done: return "You're all set"
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome:
            return "Talk, and it types. A few short steps and you'll be dictating into any app on this Mac."
        case .account:
            return "Your subscription lives on your account, so this Mac needs to be linked to it before it can dictate."
        case .microphone:
            return "Pick the input you'll talk into, and check that SunoFlow can hear it."
        case .accessibility:
            return "macOS needs your permission before one app may type into another. Without it, SunoFlow can hear you but cannot put the words anywhere."
        case .shortcut:
            return "One key combination starts and stops dictation, anywhere on your Mac."
        case .setup:
            return "SunoFlow turns speech into text on this Mac rather than sending your voice anywhere. That needs a one-time download."
        case .tryIt:
            return "Last step. Read the line below out loud and watch it appear."
        case .done:
            return "SunoFlow lives in your menu bar from here on."
        }
    }

    // MARK: - Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .account: accountStep
        case .microphone: microphoneStep
        case .accessibility: accessibilityStep
        case .shortcut: shortcutStep
        case .setup: setupStep
        case .tryIt: tryItStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "What happens next")
            Rule(strong: true)
            SunoRow(title: "Connect this Mac to your account",
                    subtitle: "A code you approve in the browser. Nothing is typed in here.",
                    systemImage: "person.crop.circle") { EmptyView() }
            SunoRow(title: "Pick a microphone",
                    subtitle: "And check SunoFlow can hear you.",
                    systemImage: "mic.fill") { EmptyView() }
            SunoRow(title: "Allow SunoFlow to type",
                    subtitle: "The one macOS permission it genuinely cannot work without.",
                    systemImage: "hand.raised.fill") { EmptyView() }
            SunoRow(title: "Confirm your shortcut",
                    subtitle: "The key combination that starts dictation.",
                    systemImage: "keyboard") { EmptyView() }
            SunoRow(title: "Set up speech recognition",
                    subtitle: "A one-time download of about 2.5 GB, which runs in the background while you finish the steps above.",
                    systemImage: "arrow.down.circle") { EmptyView() }
            SunoRow(title: "Say something",
                    subtitle: "A quick end-to-end check that it all works on this Mac.",
                    systemImage: "checkmark.circle", divider: false) { EmptyView() }
            Rule(strong: true)
            footer(primary: "Get started", action: { go(.account) },
                   secondary: "Skip setup", secondaryAction: skipSetup)
        }
        .environment(\.sunoRowIconColumn, true)
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "This Mac")
            Rule(strong: true)
            switch account.state {
            case .connected:
                SunoRow(title: "This Mac is connected",
                        subtitle: "You're signed in and ready to dictate.",
                        systemImage: "checkmark.circle.fill", iconColor: Theme.success,
                        divider: false) {
                    StatusText(text: "Connected", color: Theme.success)
                }
                Rule(strong: true)
                footer(primary: "Continue", action: { go(.microphone) })

            case .waiting(let code):
                SunoRow(title: "Waiting for you to approve",
                        subtitle: "Enter this code in the browser window that just opened, then come back here. This page updates by itself.",
                        systemImage: "hourglass") {
                    Text(code)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(Theme.accent)
                }
                SunoRow(title: "Didn't the browser open?", divider: false) {
                    HStack(spacing: 12) {
                        Button("Cancel") { account.cancelPairing() }
                            .buttonStyle(.sunoGhost)
                        Button("Open browser") { account.openAccountPage() }
                            .buttonStyle(.sunoSecondary)
                    }
                }
                Rule(strong: true)

            case .failed(let message):
                SunoNotice(text: message.isEmpty ? "That didn't go through. Try connecting again." : message,
                           color: Theme.danger)
                    .padding(.vertical, 14)
                Rule(strong: true)
                footer(primary: "Try again", action: { account.connect() },
                       secondary: "Back", secondaryAction: { go(.welcome) })

            case .notConnected:
                SunoRow(title: "How this works",
                        subtitle: "SunoFlow opens your browser, you approve this Mac there, and the key it returns is stored in your keychain. Your password is never typed into this app.",
                        systemImage: "lock.fill", divider: false) { EmptyView() }
                Rule(strong: true)
                footer(primary: "Connect this Mac", action: { account.connect() },
                       secondary: "Back", secondaryAction: { go(.welcome) })
            }
        }
        .environment(\.sunoRowIconColumn, true)
    }

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Input")
            Rule(strong: true)

            if !micPermission {
                SunoRow(title: "SunoFlow needs the microphone",
                        subtitle: "macOS will ask once. If you've already said no, open System Settings → Privacy & Security → Microphone.",
                        systemImage: "mic.slash.fill", iconColor: Theme.warning, divider: false) {
                    Button("Allow microphone") { requestMic() }
                        .buttonStyle(.sunoPrimary)
                }
                Rule(strong: true)
                footer(primary: "Continue", action: { go(.accessibility) },
                       secondary: "Back", secondaryAction: { go(.account) },
                       primaryEnabled: false)
            } else {
                SunoRow(title: "Say something",
                        subtitle: micHeard
                            ? "Heard that — your microphone is working."
                            : "The bar below should move while you talk.",
                        systemImage: "waveform",
                        iconColor: micHeard ? Theme.success : Theme.faint,
                        divider: false) {
                    StatusText(text: micHeard ? "Working" : "Listening…",
                               color: micHeard ? Theme.success : Theme.faint)
                }
                SunoProgressBar(value: Double(micLevel), total: 1)
                    .padding(.vertical, 12)
                Rule(strong: true)
                footer(primary: "Continue", action: { go(.accessibility) },
                       secondary: "Back", secondaryAction: { go(.account) })
            }
        }
        .environment(\.sunoRowIconColumn, true)
    }

    private var accessibilityStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Permission")
            Rule(strong: true)
            SunoRow(title: accessibility ? "SunoFlow can type into other apps" : "Accessibility permission needed",
                    subtitle: accessibility
                        ? "Nothing else to do here."
                        : "Choose Open System Settings, switch SunoFlow on under Accessibility, then come back. This page notices by itself.",
                    systemImage: accessibility ? "checkmark.circle.fill" : "hand.raised.fill",
                    iconColor: accessibility ? Theme.success : Theme.warning,
                    divider: false) {
                if accessibility {
                    StatusText(text: "Allowed", color: Theme.success)
                } else {
                    Button("Open System Settings") { openAccessibilitySettings() }
                        .buttonStyle(.sunoPrimary)
                }
            }
            Rule(strong: true)
            footer(primary: "Continue", action: { go(.shortcut) },
                   secondary: "Back", secondaryAction: { go(.microphone) },
                   primaryEnabled: accessibility)
        }
        .environment(\.sunoRowIconColumn, true)
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Shortcut")
            Rule(strong: true)
            SunoRow(title: "Dictation shortcut",
                    subtitle: "Click the field and press the combination you want.",
                    systemImage: "keyboard") {
                HotkeyRecorder(keyCode: $prefs.hotkeyKeyCode, modifiers: $prefs.hotkeyModifiers)
                    .frame(width: 160, height: 32)
            }
            SunoRow(title: "Try it now",
                    subtitle: "Press your shortcut. Nothing will be recorded — this only proves macOS is passing the key to SunoFlow.",
                    systemImage: "checkmark.circle",
                    iconColor: hotkeyProved ? Theme.success : Theme.faint,
                    divider: false) {
                StatusText(text: hotkeyProved ? "Works" : "Press it to check",
                           color: hotkeyProved ? Theme.success : Theme.faint)
            }
            Rule(strong: true)
            footer(primary: "Continue", action: { go(.setup) },
                   secondary: "Back", secondaryAction: { go(.accessibility) })
        }
        .environment(\.sunoRowIconColumn, true)
    }

    private var setupStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Speech recognition")
            Rule(strong: true)
            SunoRow(title: "Runs on this Mac",
                    subtitle: "Your voice is turned into text by this machine. Recordings are never uploaded.",
                    systemImage: "desktopcomputer") { EmptyView() }
            SunoRow(title: "One-time download",
                    subtitle: "About 2.5 GB. It only happens once, and it keeps working afterwards with no internet connection.",
                    systemImage: "arrow.down.circle", divider: false) {
                StatusText(text: setupStatusText, color: setupStatusColor)
            }
            SunoProgressBar(value: Double(modelStatus?.downloaded ?? 0),
                            total: Double(max(modelStatus?.file_total ?? 1, 1)))
                .padding(.top, 14)
            Text(setupNote)
                .font(.sunoCaption)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 12)
            Rule(strong: true)
            footer(primary: "Continue", action: { go(.tryIt) },
                   secondary: "Finish later", secondaryAction: finishLater,
                   primaryEnabled: modelLoaded)
        }
        .environment(\.sunoRowIconColumn, true)
    }

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "One last check")
            Rule(strong: true)
            if !modelLoaded {
                SunoNotice(text: "Speech recognition is still being set up. This step needs it finished.",
                           systemImage: "hourglass", color: Theme.accent)
                    .padding(.vertical, 14)
                Rule(strong: true)
                footer(primary: "Back to setup", action: { go(.setup) },
                       secondary: "Finish later", secondaryAction: finishLater)
            } else {
                SunoRow(title: "Read this out loud",
                        subtitle: "“Hi, this is my first sentence with SunoFlow, and it seems to be working.”",
                        systemImage: "waveform") { EmptyView() }
                SunoRow(title: "Press \(hotkeyLabel) to start, then again when you're done",
                        subtitle: "The text will appear in the box below, exactly as it would in any other app.",
                        systemImage: "keyboard", divider: false) { EmptyView() }
                TextEditor(text: $tryText)
                    .font(.sunoBody)
                    .frame(height: 92)
                    .padding(8)
                    .background(Theme.wash)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.ruleStrong, lineWidth: 1))
                    .padding(.vertical, 14)
                    .onChange(of: tryText) { text in
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            trySucceeded = true
                        }
                    }
                SunoRow(title: "Result", systemImage: "checkmark.circle",
                        iconColor: trySucceeded ? Theme.success : Theme.faint,
                        divider: false) {
                    StatusText(text: trySucceeded ? "It works" : "Waiting for you to speak…",
                               color: trySucceeded ? Theme.success : Theme.faint)
                }
                Rule(strong: true)
                // Enabled either way: someone whose microphone is genuinely
                // broken must still be able to leave rather than be trapped.
                footer(primary: "Finish", action: { go(.done) },
                       secondary: "Skip this check", secondaryAction: { go(.done) })
            }
        }
        .environment(\.sunoRowIconColumn, true)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "From here")
            Rule(strong: true)
            SunoRow(title: "Press \(hotkeyLabel) anywhere",
                    subtitle: "In any app, any text field. Press once to start, once more to stop.",
                    systemImage: "keyboard") { EmptyView() }
            SunoRow(title: "SunoFlow is in your menu bar",
                    subtitle: "Click the menu bar icon for settings, your dictionary and the shortcut.",
                    systemImage: "menubar.arrow.up.rectangle") { EmptyView() }
            SunoRow(title: "It learns your words",
                    subtitle: "Correct a word after it's typed and SunoFlow remembers the spelling for next time.",
                    systemImage: "text.badge.checkmark", divider: false) { EmptyView() }
            Rule(strong: true)
            footer(primary: "Start dictating", action: finish,
                   secondary: "Open settings", secondaryAction: {
                       finish()
                       SettingsWindowController.shared.show()
                   })
        }
        .environment(\.sunoRowIconColumn, true)
        .onAppear {
            prefs.onboardingCompleted = true
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(primary: String, action: @escaping () -> Void,
                        secondary: String? = nil, secondaryAction: (() -> Void)? = nil,
                        primaryEnabled: Bool = true) -> some View {
        HStack(spacing: 12) {
            Button(primary, action: action)
                .buttonStyle(.sunoPrimary)
                .disabled(!primaryEnabled)
            if let secondary, let secondaryAction {
                Button(secondary, action: secondaryAction)
                    .buttonStyle(.sunoGhost)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }

    // MARK: - Setup step copy

    private var setupStatusText: String {
        if modelLoaded { return "Ready" }
        if !sidecarOnline { return "Waiting" }
        guard let st = modelStatus else { return "Checking…" }
        if st.active { return "\(st.overall_done) of \(st.overall_total)" }
        if st.phase == "error" || !st.error.isEmpty { return "Failed" }
        return "Starting…"
    }

    private var setupStatusColor: Color {
        if modelLoaded { return Theme.success }
        guard let st = modelStatus else { return Theme.faint }
        if st.phase == "error" || !st.error.isEmpty { return Theme.danger }
        return st.active ? Theme.accent : Theme.body
    }

    private var setupNote: String {
        if modelLoaded { return "Speech recognition is ready on this Mac." }
        if !sidecarOnline { return "Waiting for the speech engine to start…" }
        guard let st = modelStatus else { return "Checking…" }
        if st.phase == "loading" { return "Almost there — getting it ready to use…" }
        if st.active {
            return "Downloading… \(format(st.downloaded)) of \(format(st.file_total)). "
                + "You can leave this running and finish later."
        }
        if st.phase == "error" || !st.error.isEmpty {
            return st.error.isEmpty ? "The download failed. Check your connection and try again." : st.error
        }
        return "Starting the download…"
    }

    private func format(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
        if bytes >= 1_000_000 { return "\(bytes / 1_000_000) MB" }
        if bytes >= 1_000 { return "\(bytes / 1_000) KB" }
        return "\(bytes) B"
    }

    // MARK: - Lifecycle

    private func start() {
        refreshPermissions()
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            refreshPermissions()
            TranscriptionClient.health { ok in
                DispatchQueue.main.async { sidecarOnline = ok }
            }
            TranscriptionClient.fetchModelStatus { status in
                DispatchQueue.main.async {
                    modelStatus = status
                    startDownloadIfPossible()
                }
            }
        }
        poll?.fire()
    }

    private func stop() {
        poll?.invalidate()
        poll = nil
        stopMicProbe()
        AppDelegate.shared?.hotkeyInterceptor = nil
    }

    private func go(_ next: Step) {
        // Leaving a step must undo whatever it borrowed, or the shortcut stays
        // swallowed and the microphone stays open on the following page.
        stopMicProbe()
        AppDelegate.shared?.hotkeyInterceptor = nil

        step = next
        switch next {
        case .microphone:
            refreshPermissions()
            if micPermission { startMicProbe() }
        case .shortcut:
            hotkeyProved = false
            AppDelegate.shared?.hotkeyInterceptor = {
                DispatchQueue.main.async {
                    if !hotkeyProved {
                        hotkeyProved = true
                        NSSound.beep()
                    }
                }
                return true
            }
        case .setup:
            startDownloadIfPossible()
        default:
            break
        }
    }

    private func accountStateChanged() {
        guard step == .account else { return }
        if account.isConnected {
            startDownloadIfPossible()
            // Straight on: standing on a "connected" page the user cannot act on
            // any further is a click for its own sake.
            go(.microphone)
        }
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = TextInjector.hasAccessibilityPermission
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                micPermission = granted
                if granted { startMicProbe() }
            }
        }
    }

    private func openAccessibilitySettings() {
        // Prompting first means the app appears in the list already, so the user
        // has something to switch on rather than an empty pane.
        _ = TextInjector.promptForAccessibilityPermissionIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Microphone probe

    private func startMicProbe() {
        stopMicProbe()
        let recorder = AudioRecorder()
        recorder.onLevel = { level in
            DispatchQueue.main.async {
                micLevel = level
                if level > 0.04 { micHeard = true }
            }
        }
        do {
            _ = try recorder.startRecording()
            probe = recorder
        } catch {
            AppLog.log("Setup: microphone probe failed — \(error.localizedDescription)")
        }
    }

    private func stopMicProbe() {
        guard let recorder = probe else { return }
        probe = nil
        recorder.onLevel = nil
        recorder.stopRecording()
        micLevel = 0
    }

    // MARK: - Model

    /// Kick the download off as early as we are allowed to, which is as soon as
    /// there is an account. Idempotent — the sidecar refuses a second start.
    private func startDownloadIfPossible() {
        guard !downloadRequested, !modelLoaded, sidecarOnline, account.isConnected else { return }
        downloadRequested = true
        AppLog.log("Setup: starting the speech model download")
        TranscriptionClient.startModelDownload { started in
            if !started {
                AppLog.log("Setup: download did not start (already running, or already present)")
            }
        }
    }

    // MARK: - Exits

    private func skipSetup() {
        prefs.onboardingCompleted = true
        AppLog.log("Setup skipped by the user")
        close()
    }

    private func finishLater() {
        prefs.onboardingCompleted = true
        AppLog.log("Setup left to finish later — model download continues in the background")
        close()
    }

    private func finish() {
        prefs.onboardingCompleted = true
        close()
    }

    private func close() {
        stop()
        OnboardingWindowController.shared.dismiss()
    }
}
