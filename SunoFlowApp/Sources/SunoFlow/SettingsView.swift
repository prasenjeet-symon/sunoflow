import AVFoundation
import AppKit
import SwiftUI

// MARK: - Hotkey recorder

/// A click-to-record shortcut field. Clicking arms it; the next key combo with a
/// modifier (or a function key) becomes the new hotkey. Esc cancels.
final class HotkeyRecorderNSView: NSView {
    var keyCode: UInt32 = DefaultHotkey.keyCode
    var modifiers: UInt32 = DefaultHotkey.modifiers
    var onCapture: ((UInt32, UInt32) -> Void)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        isRecording = false
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        let code = UInt32(event.keyCode)
        let significant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let mods = KeyCombo.carbonModifiers(from: event.modifierFlags)

        // Esc with no modifiers cancels the capture.
        if code == 53, event.modifierFlags.intersection(significant).isEmpty {
            stopRecording()
            return
        }
        // Require a modifier unless it's a function key, so the shortcut doesn't
        // hijack ordinary typing.
        if mods == 0, !KeyCombo.isStandaloneKey(code) {
            NSSound.beep()
            return
        }
        keyCode = code
        modifiers = mods
        onCapture?(code, mods)
        stopRecording()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text = isRecording
            ? "Type shortcut…"
            : KeyCombo.display(keyCode: keyCode, modifiers: modifiers)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textRect = NSRect(
            x: 0, y: (bounds.height - textSize.height) / 2,
            width: bounds.width, height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }
}

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.keyCode = keyCode
        view.modifiers = modifiers
        view.onCapture = { code, mods in
            keyCode = code
            modifiers = mods
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        guard !nsView.isRecording else { return }
        nsView.keyCode = keyCode
        nsView.modifiers = modifiers
        nsView.needsDisplay = true
    }
}

// MARK: - Status row helper

/// A single line in the status banner: icon + label + colored badge.
private struct StatusRow: View {
    let label: String
    let ok: Bool
    let okText: String
    let failText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
                .font(.caption)
            Spacer(minLength: 0)
            Text(ok ? okText : failText)
                .font(.caption2)
                .foregroundStyle(ok ? .green : .red)
        }
    }
}

// MARK: - Corrections manager

/// Manages the learned-corrections list inside Settings: search, edit, add, delete.
private struct CorrectionsManager: View {
    @Binding var corrections: [Correction]
    @Binding var sidecarOnline: Bool
    var onReload: () -> Void

    @State private var searchText = ""
    @State private var editingKey: String?
    @State private var editFrom = ""
    @State private var editTo = ""
    @State private var addingNew = false
    @State private var newFrom = ""
    @State private var newTo = ""

    private var filtered: [Correction] {
        guard !searchText.isEmpty else { return corrections }
        let q = searchText.lowercased()
        return corrections.filter {
            $0.from.lowercased().contains(q) || $0.to.lowercased().contains(q)
        }
    }

    var body: some View {
        if !sidecarOnline {
            Label("Engine offline — start the engine to manage corrections.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Search + add button
                HStack {
                    TextField("Search corrections…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button(action: { addingNew.toggle() }) {
                        Label("Add", systemImage: "plus")
                    }
                    .controlSize(.small)
                }

                if addingNew {
                    addRow
                }

                if corrections.isEmpty {
                    Text("No learned corrections yet. Edit pasted text to teach SunoFlow, or use Add.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(filtered) { correction in
                                if editingKey == correction.key {
                                    editRow(correction)
                                } else {
                                    displayRow(correction)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)

                    HStack {
                        Text("\(corrections.count) correction\(corrections.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear All", role: .destructive, action: clearAll)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func displayRow(_ c: Correction) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("“\(c.from)”  →  “\(c.to)”")
                    .font(.system(size: 12))
                if c.count > 1 {
                    Text("seen \(c.count)×")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(action: { startEdit(c) }) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button(action: { delete(c) }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private func editRow(_ c: Correction) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("From", text: $editFrom)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("To", text: $editTo)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Button("OK") { saveEdit(c) }
                    .controlSize(.small)
                Button("Cancel") { editingKey = nil }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("From (what the model mishears)", text: $newFrom)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("To (the correct text)", text: $newTo)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Button("Add") { addCorrection() }
                    .controlSize(.small)
                    .disabled(newFrom.isEmpty || newTo.isEmpty)
                Button("Cancel") { addingNew = false; newFrom = ""; newTo = "" }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: Actions

    private func startEdit(_ c: Correction) {
        editingKey = c.key
        editFrom = c.from
        editTo = c.to
    }

    private func saveEdit(_ c: Correction) {
        let from = editFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = editTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { editingKey = nil; return }
        TranscriptionClient.updateCorrection(key: c.key, from: from, to: to) { updated in
            DispatchQueue.main.async {
                corrections = updated
                editingKey = nil
            }
        }
    }

    private func delete(_ c: Correction) {
        TranscriptionClient.deleteCorrection(key: c.key) {
            DispatchQueue.main.async { onReload() }
        }
    }

    private func clearAll() {
        TranscriptionClient.clearCorrections {
            DispatchQueue.main.async { onReload() }
        }
    }

    private func addCorrection() {
        let from = newFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = newTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { return }
        TranscriptionClient.addCorrection(from: from, to: to) { updated in
            DispatchQueue.main.async {
                corrections = updated
                addingNew = false
                newFrom = ""
                newTo = ""
            }
        }
    }
}

// MARK: - Dashboard navigation

/// Sidebar tabs for the dashboard.
private enum Tab: String, CaseIterable, Identifiable {
    case overview, general, microphone, model, corrections, cleanup, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .general: return "General"
        case .microphone: return "Microphone"
        case .model: return "Model"
        case .corrections: return "Corrections"
        case .cleanup: return "AI Cleanup"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .general: return "gearshape.fill"
        case .microphone: return "microphone.fill"
        case .model: return "arrow.down.circle.fill"
        case .corrections: return "text.badge.checkmark"
        case .cleanup: return "sparkles"
        case .about: return "info.circle.fill"
        }
    }
}

// MARK: - Status card (overview dashboard)

/// A large tappable card showing the health of one subsystem.
private struct StatusCard: View {
    let title: String
    let systemImage: String
    let ok: Bool
    let okText: String
    let failText: String
    var hint: String? = nil
    var action: (() -> Void)? = nil
    var actionLabel: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill((ok ? Color.green : Color.red).opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ok ? .green : .red)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                    Text(ok ? okText : failText)
                        .font(.caption)
                        .foregroundStyle(ok ? .green : .red)
                }
                Spacer()
            }
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let action, let actionLabel {
                Button(action: action) {
                    Label(actionLabel, systemImage: "play.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
        )
    }
}

// MARK: - Dashboard window content

struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    @State private var selectedTab: Tab = .overview

    @State private var inputDevices: [AudioInputDevice] = []
    @State private var micIsBluetooth = false

    // AI-cleanup settings that live in the sidecar.
    @State private var sidecarOnline = false
    @State private var ollamaOnline = false
    @State private var configLoaded = false
    @State private var model = ""
    @State private var instruction = ""
    // The last loaded/saved values — the baseline "dirty" is measured against, so
    // programmatically filling the fields on load doesn't count as an edit.
    @State private var savedModel = ""
    @State private var savedInstruction = ""
    @State private var defaultInstruction = ""
    @State private var defaultModel = ""
    @State private var availableModels: [String] = []
    @State private var saveState: SaveState = .idle

    // Permission status.
    @State private var micPermission: Bool = false
    @State private var accessibilityPermission: Bool = false
    @State private var screenRecordingPermission: Bool = false

    // Corrections list.
    @State private var corrections: [Correction] = []

    // Launch at login.
    @State private var launchAtLogin = false
    @State private var loginError: String?

    // Whether the sidecar process is starting (button pressed).
    @State private var startingEngine = false

    // STT model download state.
    @State private var modelStatus: ModelStatus?
    @State private var modelDownloadStarting = false
    @State private var modelPollTimer: Timer?

    private enum SaveState { case idle, dirty, saving, saved, failed }

    private var aiEditable: Bool { sidecarOnline && configLoaded }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Number of subsystems that are healthy (for the overview header).
    private var healthyCount: Int {
        [sidecarOnline, ollamaOnline, micPermission, accessibilityPermission].filter { $0 }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .frame(width: 920, height: 620)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .sunoSaveAndClose)) { _ in
            saveConfig(thenClose: true)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Header: app icon + name
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                Text("SunoFlow")
                    .font(.title3.bold())
                Text("Voice dictation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 22)
            .padding(.bottom, 18)

            // Navigation
            VStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    navButton(tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            // Footer: engine status pill
            VStack(spacing: 6) {
                Divider()
                HStack(spacing: 6) {
                    Circle()
                        .fill(sidecarOnline ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(sidecarOnline ? "Engine online" : "Engine offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 224, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func navButton(_ tab: Tab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                Text(tab.title)
                    .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                Spacer()
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                switch selectedTab {
                case .overview: overviewSection
                case .general: generalSection
                case .microphone: microphoneSection
                case .model: modelSection
                case .corrections: correctionsSection
                case .cleanup: cleanupSection
                case .about: aboutSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedTab.title)
                    .font(.title2.bold())
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedTab == .overview {
                Text("\(healthyCount)/4 ready")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(healthyCount == 4 ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                    )
            }
        }
    }

    private var headerSubtitle: String {
        switch selectedTab {
        case .overview: return "System health and quick actions"
        case .general: return "Launch, hotkey, and recording behaviour"
        case .microphone: return "Input device selection"
        case .model: return "Download the speech-to-text model"
        case .corrections: return "Manage learned text substitutions"
        case .cleanup: return "Local AI transcript polishing"
        case .about: return "Version and resources"
        }
    }

    // MARK: Overview / Dashboard

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Status cards grid
            HStack(spacing: 12) {
                StatusCard(
                    title: "Transcription Engine",
                    systemImage: "cpu.fill",
                    ok: sidecarOnline,
                    okText: "Online — Parakeet TDT v2",
                    failText: "Offline",
                    hint: sidecarOnline ? nil : "Start the sidecar to enable dictation.",
                    action: sidecarOnline ? nil : startEngine,
                    actionLabel: startingEngine ? "Starting…" : "Start engine"
                )
                StatusCard(
                    title: "AI Cleanup",
                    systemImage: "sparkles",
                    ok: ollamaOnline,
                    okText: model.isEmpty ? "Ollama reachable" : "Ollama — \(model)",
                    failText: "Ollama not running",
                    hint: "Local LLM that polishes raw transcripts."
                )
            }
            HStack(spacing: 12) {
                StatusCard(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    ok: micPermission,
                    okText: "Permission granted",
                    failText: "Permission not granted",
                    hint: micPermission ? nil : "Grant access in System Settings → Privacy & Security."
                )
                StatusCard(
                    title: "Accessibility",
                    systemImage: "keyboard.fill",
                    ok: accessibilityPermission,
                    okText: "Permission granted",
                    failText: "Permission not granted",
                    hint: accessibilityPermission ? nil : "Required to insert text into other apps."
                )
            }

            // Current configuration summary
            VStack(alignment: .leading, spacing: 10) {
                Text("Current Setup")
                    .font(.headline)
                VStack(spacing: 6) {
                    summaryRow("Dictation hotkey", value: KeyCombo.display(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers))
                    summaryRow("Microphone", value: micDisplayName)
                    summaryRow("Auto-stop", value: "\(prefs.maxRecordingSeconds) s")
                    summaryRow("AI cleanup", value: prefs.cleanupEnabled ? "On" : "Off")
                    summaryRow("Screen context", value: prefs.screenContextEnabled ? "On" : "Off")
                    summaryRow("Launch at login", value: launchAtLogin ? "Enabled" : "Disabled")
                    summaryRow("Learned corrections", value: "\(corrections.count)")
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.2))
                )
            }

            // Model download banner — surfaces on the overview when the STT
            // model isn't ready, with a one-click jump to the Model tab.
            if sidecarOnline, let st = modelStatus, !st.model_loaded {
                Button {
                    selectedTab = .model
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(st.active ? "Downloading speech model…" : "Speech model not downloaded")
                                .font(.callout)
                            Text(st.active
                                 ? "\(st.overall_done)/\(st.overall_total) files — tap for details"
                                 : "Tap to download the ~2.4 GB on-device model")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: st.active ? "arrow.down.circle" : "arrow.down.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            // Permission warnings
            if !micPermission || !accessibilityPermission || (prefs.screenContextEnabled && !screenRecordingPermission) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action needed")
                        .font(.headline)
                    if !micPermission {
                        permissionWarning(
                            "Grant microphone permission in System Settings → Privacy & Security → Microphone."
                        )
                    }
                    if !accessibilityPermission {
                        permissionWarning(
                            "Grant Accessibility permission in System Settings → Privacy & Security → Accessibility for text insertion to work."
                        )
                    }
                    if prefs.screenContextEnabled, !screenRecordingPermission {
                        permissionWarning(
                            "Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording for screen context to work."
                        )
                    }
                }
            }
        }
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium))
        }
        .font(.caption)
    }

    private func permissionWarning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var micDisplayName: String {
        if prefs.micDeviceUID.isEmpty { return "System Default" }
        if let dev = inputDevices.first(where: { $0.uid == prefs.micDeviceUID }) {
            return dev.name
        }
        return "Selected device (disconnected)"
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard {
                Toggle("Launch SunoFlow at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        if let error = LoginItem.setEnabled(newValue) {
                            loginError = error
                            launchAtLogin = LoginItem.isEnabled
                        } else {
                            loginError = nil
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("Starts the app at login. To also auto-start the transcription engine, run ./install-autostart.sh once.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            settingsCard {
                LabeledContent("Dictation hotkey") {
                    HStack(spacing: 8) {
                        HotkeyRecorder(keyCode: $prefs.hotkeyKeyCode, modifiers: $prefs.hotkeyModifiers)
                            .frame(width: 150, height: 26)
                        Button("Reset") { prefs.resetHotkeyToDefault() }
                    }
                }
                Text("Press this combo anywhere to start and stop dictation.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            settingsCard {
                LabeledContent("Auto-stop recording after") {
                    Stepper(value: $prefs.maxRecordingSeconds, in: 10...600, step: 5) {
                        Text("\(prefs.maxRecordingSeconds) s").monospacedDigit()
                    }
                }
                Text("Stops a runaway recording automatically so you don't have to.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            settingsCard {
                Toggle("Use screen context for cleanup", isOn: $prefs.screenContextEnabled)
                    .onChange(of: prefs.screenContextEnabled) { newValue in
                        if newValue, !ScreenContext.hasPermission {
                            ScreenContext.openSystemSettings()
                        }
                    }
                Text("When on, a screenshot is taken and OCR'd on-device when dictation stops. The recognized words give the cleanup AI rough context about the app you're typing into (better names, terms, and phrasing). Accuracy is not the goal — only the on-screen vocabulary is extracted.")
                    .font(.caption).foregroundStyle(.secondary)

                if prefs.screenContextEnabled, !screenRecordingPermission {
                    Label(
                        "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then restart SunoFlow.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Button("Open System Settings") {
                        ScreenContext.openSystemSettings()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard {
                Picker("Input device", selection: $prefs.micDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.isBluetooth ? "\(device.name) — Bluetooth" : device.name)
                            .tag(device.uid)
                    }
                    if !prefs.micDeviceUID.isEmpty,
                       !inputDevices.contains(where: { $0.uid == prefs.micDeviceUID }) {
                        Text("Selected device (disconnected)").tag(prefs.micDeviceUID)
                    }
                }
                .onChange(of: prefs.micDeviceUID) { _ in refreshMicWarning() }

                if micIsBluetooth {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "This is a Bluetooth microphone. Recording from it forces your earbuds/headphones into low-quality call mode — degrading audio in every app while you dictate.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        if AudioDevices.builtInInputUID() != nil {
                            Button("Switch to built-in microphone") {
                                if let builtIn = AudioDevices.builtInInputUID() {
                                    prefs.micDeviceUID = builtIn
                                    refreshMicWarning()
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }

                Button("Refresh devices") {
                    inputDevices = AudioDevices.inputDevices()
                    refreshMicWarning()
                }
                .font(.caption)
            }
        }
    }

    private func refreshMicWarning() {
        micIsBluetooth = AudioDevices.effectiveInputIsBluetooth(savedUID: prefs.micDeviceUID)
    }

    // MARK: Model download

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !sidecarOnline {
                Label("Engine offline — start it from the Overview tab to download the model.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Parakeet TDT 0.6B v2")
                        .font(.headline)
                    Text("The on-device speech-to-text model. It runs entirely on your Mac — no audio leaves your machine. The model is ~2.4 GB; the download takes a few minutes on a typical connection.")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()

                    if let st = modelStatus {
                        modelStatusBody(st)
                    } else if sidecarOnline {
                        Text("Checking model status…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Model status unavailable while the engine is offline.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let st = modelStatus, !st.model_dir.isEmpty {
                settingsCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Storage location")
                            .font(.caption.bold())
                        Text(st.model_dir)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(st.model_id)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onAppear { startModelPolling() }
        .onDisappear { stopModelPolling() }
    }

    @ViewBuilder
    private func modelStatusBody(_ st: ModelStatus) -> some View {
        if st.model_loaded {
            Label("Model ready — dictation is available.", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        } else if st.active {
            // Download / load in progress.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if st.phase == "loading" {
                        ProgressView().controlSize(.small)
                        Text("Loading model into memory…")
                            .font(.callout)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(Color.accentColor)
                        Text("Downloading model…")
                            .font(.callout)
                    }
                    Spacer()
                    Text("\(st.overall_done)/\(st.overall_total) files")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if st.phase != "loading", !st.current_file.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(st.current_file)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ProgressView(
                            value: Double(st.downloaded),
                            total: Double(max(st.file_total, 1))
                        )
                        HStack {
                            Text(byteString(st.downloaded))
                            Spacer()
                            if st.file_total > 0 {
                                Text(byteString(st.file_total))
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } else if st.model_present {
            // Files are on disk but the model isn't loaded in-process yet.
            VStack(alignment: .leading, spacing: 8) {
                Label("Model downloaded but not loaded. Restart the engine to activate it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                Button("Start engine") { startEngine() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(startingEngine)
            }
        } else if st.phase == "error" {
            VStack(alignment: .leading, spacing: 8) {
                Label("Download failed.", systemImage: "xmark.octagon.fill")
                    .font(.callout).foregroundStyle(.red)
                if !st.error.isEmpty {
                    Text(st.error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Button("Retry download") { startDownload() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            // Idle, nothing present.
            VStack(alignment: .leading, spacing: 8) {
                Label("Model not downloaded yet.", systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Button {
                    startDownload()
                } label: {
                    Label(modelDownloadStarting ? "Starting…" : "Download model",
                          systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(modelDownloadStarting)
            }
        }
    }

    private func startDownload() {
        guard !modelDownloadStarting else { return }
        modelDownloadStarting = true
        TranscriptionClient.startModelDownload { started in
            DispatchQueue.main.async {
                modelDownloadStarting = false
                if started { startModelPolling() }
            }
        }
    }

    /// Poll /model/status every second while the Model tab is visible and a
    /// download might be running. Stops when the model is loaded or an error
    /// is reported with no active download.
    private func startModelPolling() {
        stopModelPolling()
        fetchModelStatus()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            fetchModelStatus()
        }
        RunLoop.main.add(timer, forMode: .common)
        modelPollTimer = timer
    }

    private func stopModelPolling() {
        modelPollTimer?.invalidate()
        modelPollTimer = nil
    }

    private func fetchModelStatus() {
        TranscriptionClient.fetchModelStatus { status in
            DispatchQueue.main.async {
                modelStatus = status
            }
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    // MARK: Learned corrections

    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SunoFlow learns from edits you make to pasted text. Manage them here.")
                .font(.caption).foregroundStyle(.secondary)
            settingsCard {
                CorrectionsManager(
                    corrections: $corrections,
                    sidecarOnline: $sidecarOnline,
                    onReload: loadCorrections
                )
            }
        }
    }

    // MARK: AI cleanup

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard {
                Toggle("Polish transcript with local AI", isOn: $prefs.cleanupEnabled)
                Text("When off, the raw transcript is pasted with no LLM pass.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !sidecarOnline {
                Label("Engine offline — start it from the Overview tab to edit the AI settings below.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            settingsCard {
                Group {
                    if availableModels.isEmpty {
                        TextField("Ollama model", text: $model)
                    } else {
                        Picker("Ollama model", selection: $model) {
                            ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                            if !model.isEmpty, !availableModels.contains(model) {
                                Text(model).tag(model)
                            }
                        }
                    }
                    if !defaultModel.isEmpty {
                        if model == defaultModel {
                            Text("\(defaultModel) is the built-in default model.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Button("Reset to default model") { model = defaultModel }
                                .font(.caption)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cleanup instruction")
                            .font(.caption.bold())
                        TextEditor(text: $instruction)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 170)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                        Text("The steering prompt sent to the cleanup model before your transcript.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Restore default") { instruction = defaultInstruction }
                            .font(.caption)
                            .disabled(defaultInstruction.isEmpty)
                        Spacer()
                        dirtyBadge
                        saveStatusLabel
                        Button("Save AI settings", action: { saveConfig() })
                            .disabled(saveState == .saving || saveState == .idle)
                    }
                }
                .disabled(!aiEditable)
                .onChange(of: model) { _ in recomputeDirty() }
                .onChange(of: instruction) { _ in recomputeDirty() }
            }
        }
    }

    @ViewBuilder
    private var dirtyBadge: some View {
        if saveState == .dirty {
            Label("Unsaved changes", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var saveStatusLabel: some View {
        switch saveState {
        case .idle, .dirty:
            EmptyView()
        case .saving:
            Text("Saving…").font(.caption).foregroundStyle(.secondary)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed:
            Label("Save failed", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard {
                LabeledContent("App version", value: "SunoFlow \(appVersion) (\(appBuild))")
                LabeledContent("Speech engine", value: "Parakeet TDT 0.6B v2 (MLX)")
                LabeledContent("Speech model", value: modelStatus?.model_loaded == true
                    ? "Downloaded & loaded"
                    : (modelStatus?.model_present == true ? "Downloaded (not loaded)" : "Not downloaded"))
                LabeledContent("Cleanup model", value: ollamaOnline ? model : "Ollama offline")
                LabeledContent("Sidecar endpoint", value: "http://127.0.0.1:8765")
            }

            settingsCard {
                HStack {
                    Button("Open project folder") { openProjectFolder() }
                        .font(.caption)
                    Button("View logs") { revealLogs() }
                        .font(.caption)
                    Link("Parakeet MLX", destination: URL(string: "https://github.com/senstella/parakeet-mlx")!)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: Reusable card wrapper

    private func settingsCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
        )
    }

    // MARK: Loading & saving

    private func load() {
        inputDevices = AudioDevices.inputDevices()
        refreshMicWarning()
        launchAtLogin = LoginItem.isEnabled
        checkPermissions()
        refreshStatus()
    }

    private func checkPermissions() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityPermission = TextInjector.hasAccessibilityPermission
        screenRecordingPermission = ScreenContext.hasPermission
    }

    private func refreshStatus() {
        TranscriptionClient.health { ok in
            DispatchQueue.main.async {
                sidecarOnline = ok
                if ok {
                    loadSidecarConfig()
                    loadCorrections()
                    fetchModelStatus()
                }
            }
        }
        TranscriptionClient.checkOllama { ok in
            DispatchQueue.main.async { ollamaOnline = ok }
        }
    }

    private func loadSidecarConfig() {
        TranscriptionClient.fetchConfig { config in
            DispatchQueue.main.async {
                guard let config else { return }
                model = config.ollama_model
                instruction = config.cleanup_instruction
                // Capture the baseline so the onChange fired by these very
                // assignments doesn't register as an unsaved edit.
                savedModel = config.ollama_model
                savedInstruction = config.cleanup_instruction
                defaultInstruction = config.default_instruction
                defaultModel = config.default_model
                configLoaded = true
                saveState = .idle
                SettingsWindowController.shared.hasUnsavedAIChanges = false
            }
        }
        TranscriptionClient.fetchModels { models in
            DispatchQueue.main.async { availableModels = models }
        }
    }

    private func loadCorrections() {
        TranscriptionClient.fetchCorrections { items in
            DispatchQueue.main.async { corrections = items }
        }
    }

    /// Recompute whether the AI settings differ from the last loaded/saved state.
    /// Driven by the fields' onChange, so it reflects only genuine user edits —
    /// not the programmatic fill on load — which is what gates the close prompt.
    private func recomputeDirty() {
        guard saveState != .saving else { return }
        let dirty = model != savedModel || instruction != savedInstruction
        saveState = dirty ? .dirty : .idle
        SettingsWindowController.shared.hasUnsavedAIChanges = dirty
        NotificationCenter.default.post(
            name: dirty ? .sunoAIConfigDirty : .sunoAIConfigClean, object: nil
        )
    }

    private func saveConfig(thenClose: Bool = false) {
        saveState = .saving
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        TranscriptionClient.saveConfig(model: trimmedModel, instruction: instruction) { ok in
            DispatchQueue.main.async {
                if ok {
                    // New baseline — nothing is unsaved anymore.
                    savedModel = model
                    savedInstruction = instruction
                    saveState = .saved
                    SettingsWindowController.shared.hasUnsavedAIChanges = false
                    NotificationCenter.default.post(name: .sunoAIConfigClean, object: nil)
                    if thenClose {
                        SettingsWindowController.shared.close()
                    }
                } else {
                    // Keep the changes marked unsaved so the user can retry or
                    // discard; never silently close on a failed save.
                    saveState = .failed
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: Engine actions

    /// Find the project root (the directory containing run.sh) relative to the
    /// app's own location. Works whether running from the built app bundle
    /// (`<root>/SunoFlowApp/SunoFlow.app/Contents/MacOS/SunoFlow`) or from the
    /// SwiftPM debug binary (`<root>/SunoFlowApp/.build/debug/SunoFlow`).
    private func projectRoot() -> URL? {
        let bundle = Bundle.main.bundleURL
        // Bundle.main.bundleURL is the .app for a bundled app, or the executable's
        // directory for a bare SwiftPM binary. In both cases, walking up a few
        // levels should find run.sh.
        var url = bundle
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("run.sh")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
        }
        return nil
    }

    private func startEngine() {
        guard let root = projectRoot() else { return }
        startingEngine = true
        // Launch run.sh as a detached process. It starts the sidecar and waits
        // for health, then opens the app — which is already running, so the
        // single-instance guard in main.swift just bumps our Settings window.
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = [root.appendingPathComponent("run.sh").path]
        try? task.run()

        // Poll for sidecar health, then refresh the UI.
        DispatchQueue.global().async {
            var becameHealthy = false
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 1)
                let semaphore = DispatchSemaphore(value: 0)
                var healthy = false
                TranscriptionClient.health { ok in
                    healthy = ok
                    semaphore.signal()
                }
                semaphore.wait()
                if healthy {
                    becameHealthy = true
                    break
                }
            }
            DispatchQueue.main.async {
                startingEngine = false
                if becameHealthy { refreshStatus() }
            }
        }
    }

    private func revealLogs() {
        let logURL = AppLog.fileURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            // Reveal the directory at least.
            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
        }
    }

    private func openInTerminal() {
        guard let root = projectRoot() else { return }
        let script = "cd \(root.path) && ./run.sh"
        // Use osascript to open a Terminal window and run the script.
        let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        if let scriptObj = NSAppleScript(source: appleScript) {
            var error: NSDictionary?
            scriptObj.executeAndReturnError(&error)
        }
    }

    private func openProjectFolder() {
        guard let root = projectRoot() else { return }
        NSWorkspace.shared.open(root)
    }
}