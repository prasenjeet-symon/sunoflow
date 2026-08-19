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

    /// The brand violet, matched to `Theme.violet` on the SwiftUI side.
    private static let accent = NSColor(calibratedRed: 0.545, green: 0.486, blue: 1.0, alpha: 1.0)

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

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
        let accent = Self.accent
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)

        if isRecording {
            accent.withAlphaComponent(0.14).setFill()
        } else if isHovered {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
        }
        path.fill()

        (isRecording ? accent : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 1.8 : 1
        path.stroke()

        let text = isRecording
            ? "Type shortcut…"
            : KeyCombo.display(keyCode: keyCode, modifiers: modifiers)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isRecording ? accent : NSColor.labelColor,
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
    @State private var hoveredKey: String?

    private var filtered: [Correction] {
        guard !searchText.isEmpty else { return corrections }
        let q = searchText.lowercased()
        return corrections.filter {
            $0.from.lowercased().contains(q) || $0.to.lowercased().contains(q)
        }
    }

    var body: some View {
        if !sidecarOnline {
            SunoNotice(text: "Engine offline — start the engine from Overview to manage corrections.")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                // Search + add
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField("Search corrections…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.sunoBody)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.sunoIcon())
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .sunoWell(radius: Theme.Radius.control)

                    Button {
                        withAnimation(Theme.spring) { addingNew.toggle() }
                    } label: {
                        Label(addingNew ? "Close" : "Add", systemImage: addingNew ? "xmark" : "plus")
                    }
                    .buttonStyle(.sunoSecondary)
                }

                if addingNew {
                    addRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if corrections.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(filtered) { correction in
                                if editingKey == correction.key {
                                    editRow(correction)
                                } else {
                                    displayRow(correction)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 260)

                    HStack {
                        Text("\(corrections.count) correction\(corrections.count == 1 ? "" : "s") learned")
                            .font(.sunoCaption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear all", action: clearAll)
                            .buttonStyle(.sunoGhost(Theme.danger))
                    }
                }
            }
            .animation(Theme.spring, value: addingNew)
            .animation(Theme.gentle, value: corrections.count)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            IconChip(systemImage: "text.badge.checkmark", size: 40)
                .opacity(0.85)
            Text("No corrections yet")
                .font(.sunoSubhead)
            Text("Edit the text SunoFlow pastes and it learns the fix automatically — or add one by hand.")
                .font(.sunoCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .sunoWell(radius: Theme.Radius.control)
    }

    // MARK: Rows

    private func displayRow(_ c: Correction) -> some View {
        let hovered = hoveredKey == c.key
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(c.from)
                        .font(.sunoMono)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.violet)
                    Text(c.to)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                if c.count > 1 {
                    Text("seen \(c.count)×")
                        .font(.sunoMicro)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                Button { startEdit(c) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.sunoIcon(Theme.violet))
                    .help("Edit")
                Button { delete(c) } label: { Image(systemName: "trash") }
                    .buttonStyle(.sunoIcon(Theme.danger))
                    .help("Delete")
            }
            .opacity(hovered ? 1 : 0.35)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .sunoWell(tint: hovered ? Theme.violet : nil)
        .animation(Theme.quick, value: hovered)
        .onHover { hoveredKey = $0 ? c.key : (hoveredKey == c.key ? nil : hoveredKey) }
    }

    private func editRow(_ c: Correction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                TextField("From", text: $editFrom)
                    .textFieldStyle(.roundedBorder)
                    .font(.sunoBody)
                TextField("To", text: $editTo)
                    .textFieldStyle(.roundedBorder)
                    .font(.sunoBody)
            }
            VStack(spacing: 6) {
                Button("Save") { saveEdit(c) }
                    .buttonStyle(.sunoPrimary)
                Button("Cancel") { editingKey = nil }
                    .buttonStyle(.sunoGhost)
            }
        }
        .padding(12)
        .sunoWell(tint: Theme.violet)
    }

    private var addRow: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                TextField("From — what the model mishears", text: $newFrom)
                    .textFieldStyle(.roundedBorder)
                    .font(.sunoBody)
                TextField("To — the correct text", text: $newTo)
                    .textFieldStyle(.roundedBorder)
                    .font(.sunoBody)
            }
            VStack(spacing: 6) {
                Button("Add") { addCorrection() }
                    .buttonStyle(.sunoPrimary)
                    .disabled(newFrom.isEmpty || newTo.isEmpty)
                Button("Cancel") {
                    withAnimation(Theme.spring) { addingNew = false }
                    newFrom = ""
                    newTo = ""
                }
                .buttonStyle(.sunoGhost)
            }
        }
        .padding(12)
        .sunoWell(tint: Theme.violet)
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
        case .model: return "Speech Model"
        case .corrections: return "Corrections"
        case .cleanup: return "AI Cleanup"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .general: return "gearshape.fill"
        case .microphone: return "mic.fill"
        case .model: return "waveform.badge.magnifyingglass"
        case .corrections: return "text.badge.checkmark"
        case .cleanup: return "sparkles"
        case .about: return "info.circle.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "System health and quick actions"
        case .general: return "Launch, hotkey, and recording behaviour"
        case .microphone: return "Choose which input SunoFlow listens to"
        case .model: return "The on-device speech-to-text model"
        case .corrections: return "Text substitutions SunoFlow has learned"
        case .cleanup: return "Hosted AI transcript polishing"
        case .about: return "Version, endpoints, and resources"
        }
    }
}

// MARK: - Status card (overview dashboard)

/// A card showing the health of one subsystem, with a live status dot and an
/// optional inline recovery action.
private struct StatusCard: View {
    let title: String
    let systemImage: String
    let ok: Bool
    let okText: String
    let failText: String
    var hint: String? = nil
    var action: (() -> Void)? = nil
    var actionLabel: String? = nil
    var actionBusy: Bool = false

    @State private var hovering = false

    private var tint: Color { Theme.status(ok) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconChip(
                    systemImage: systemImage,
                    gradient: Theme.gradient(for: tint),
                    size: 38,
                    glowColor: tint
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.sunoSubhead)
                    HStack(spacing: 2) {
                        PulseDot(color: tint, active: ok, size: 5)
                        Text(ok ? okText : failText)
                            .font(.sunoCaption)
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }

            if let hint {
                Text(hint)
                    .font(.sunoCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let action, let actionLabel {
                Button(action: action) {
                    HStack(spacing: 6) {
                        if actionBusy {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold))
                        }
                        Text(actionLabel)
                    }
                }
                .buttonStyle(.sunoPrimary)
                .disabled(actionBusy)
            }
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .sunoSurface(hovering: hovering, interactive: true)
        .scaleEffect(hovering ? 1.01 : 1)
        .animation(Theme.spring, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Dashboard window content

struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    @State private var selectedTab: Tab = .overview
    @State private var hoveredTab: Tab?
    @Namespace private var navPill

    @State private var inputDevices: [AudioInputDevice] = []
    @State private var micIsBluetooth = false

    // Hosted cleanup gateway reachability (replaces local-Ollama status).
    @State private var sidecarOnline = false
    @State private var cleanupGatewayOnline = false

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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// Number of subsystems that are healthy (for the overview header).
    private var healthyCount: Int {
        [sidecarOnline, cleanupGatewayOnline, micPermission, accessibilityPermission].filter { $0 }.count
    }

    private var allReady: Bool { healthyCount == 4 }

    private var heroSubtitle: String {
        guard !allReady else {
            let combo = KeyCombo.display(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
            return "Press \(combo) anywhere to dictate."
        }
        let pending = 4 - healthyCount
        return pending == 1
            ? "1 item still needs attention before dictation works everywhere."
            : "\(pending) items still need attention before dictation works everywhere."
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .frame(minWidth: 880, minHeight: 620)
        .background(Theme.canvas)
        .onAppear(perform: load)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand mark. The top padding clears the (hidden) title bar so the
            // traffic lights float over the sidebar instead of over content.
            HStack(spacing: 11) {
                IconChip(systemImage: "waveform", size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SunoFlow")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Voice dictation")
                        .font(.sunoMicro)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 42)
            .padding(.bottom, Theme.Space.lg)

            // Navigation
            VStack(spacing: 3) {
                ForEach(Tab.allCases) { tab in
                    navButton(tab)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: Theme.Space.lg)

            // Footer: live engine status
            VStack(alignment: .leading, spacing: 0) {
                Divider().opacity(0.5)
                HStack(spacing: 4) {
                    PulseDot(
                        color: sidecarOnline ? Theme.success : Theme.warning,
                        active: sidecarOnline,
                        size: 6
                    )
                    Text(sidecarOnline ? "Engine online" : "Engine offline")
                        .font(.sunoCaption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 232, alignment: .top)
        .background(GlassBackground(material: .sidebar))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    private func navButton(_ tab: Tab) -> some View {
        let selected = selectedTab == tab
        let hovered = hoveredTab == tab

        return Button {
            withAnimation(Theme.spring) { selectedTab = tab }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(selected
                        ? AnyShapeStyle(Theme.brand)
                        : AnyShapeStyle(Color.secondary))
                Text(tab.title)
                    .font(.system(size: 12.5,
                                  weight: selected ? .semibold : .medium,
                                  design: .rounded))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 11)
            .background {
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Theme.brandWash)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(Theme.violet.opacity(0.28), lineWidth: 1)
                            )
                            .matchedGeometryEffect(id: "navPill", in: navPill)
                    } else if hovered {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Theme.quick) {
                if inside { hoveredTab = tab }
                else if hoveredTab == tab { hoveredTab = nil }
            }
        }
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header

                Group {
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
                .id(selectedTab)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 12)),
                    removal: .opacity
                ))
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, 38)
            .padding(.bottom, Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Theme.gentle, value: selectedTab)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedTab.title)
                    .font(.sunoDisplay)
                Text(selectedTab.subtitle)
                    .font(.sunoCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selectedTab == .overview {
                SunoBadge(
                    text: allReady ? "All systems ready" : "\(healthyCount) of 4 ready",
                    color: allReady ? Theme.success : Theme.warning,
                    systemImage: allReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
            }
        }
    }

    // MARK: Overview / Dashboard

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            heroBanner

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.Space.md)],
                spacing: Theme.Space.md
            ) {
                StatusCard(
                    title: "Transcription Engine",
                    systemImage: "cpu.fill",
                    ok: sidecarOnline,
                    okText: "Online — Parakeet TDT v2",
                    failText: "Offline",
                    hint: sidecarOnline
                        ? "Speech runs entirely on this Mac."
                        : "Start the sidecar to enable dictation.",
                    action: sidecarOnline ? nil : startEngine,
                    actionLabel: startingEngine ? "Starting…" : "Start engine",
                    actionBusy: startingEngine
                )
                StatusCard(
                    title: "AI Cleanup",
                    systemImage: "sparkles",
                    ok: cleanupGatewayOnline,
                    okText: "Cleanup service reachable",
                    failText: "Cleanup service offline",
                    hint: "Transcript polishing runs on a hosted service — no local setup needed."
                )
                StatusCard(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    ok: micPermission,
                    okText: "Permission granted",
                    failText: "Permission needed",
                    hint: micPermission
                        ? micDisplayName
                        : "Grant access in System Settings → Privacy & Security."
                )
                StatusCard(
                    title: "Accessibility",
                    systemImage: "keyboard.fill",
                    ok: accessibilityPermission,
                    okText: "Permission granted",
                    failText: "Permission needed",
                    hint: "Required to insert text into other apps."
                )
            }

            // Model download banner — surfaces on the overview when the STT
            // model isn't ready, with a one-click jump to the Model tab.
            if sidecarOnline, let st = modelStatus, !st.model_loaded {
                modelBanner(st)
            }

            currentSetupCard

            // Permission warnings
            if !micPermission || !accessibilityPermission
                || (prefs.screenContextEnabled && !screenRecordingPermission) {
                SunoSection(
                    title: "Action needed",
                    systemImage: "exclamationmark.triangle.fill",
                    subtitle: "SunoFlow can't do everything until these are granted",
                    tint: Theme.gradient(for: Theme.warning)
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !micPermission {
                            SunoNotice(text: "Grant microphone permission in System Settings → Privacy & Security → Microphone.")
                        }
                        if !accessibilityPermission {
                            SunoNotice(text: "Grant Accessibility permission in System Settings → Privacy & Security → Accessibility for text insertion to work.")
                        }
                        if prefs.screenContextEnabled, !screenRecordingPermission {
                            SunoNotice(text: "Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording for screen context to work.")
                        }
                    }
                }
            }
        }
    }

    /// The big "how are we doing" strip at the top of the overview.
    private var heroBanner: some View {
        HStack(spacing: 18) {
            healthRing

            VStack(alignment: .leading, spacing: 5) {
                Text(allReady ? "Everything's ready" : "Almost there")
                    .font(.sunoTitle)
                Text(heroSubtitle)
                    .font(.sunoCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.brandWash.opacity(0.6))
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.violet.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: Theme.violet.opacity(0.14), radius: 16, y: 6)
        )
    }

    /// Circular gauge of healthy subsystems, animated as services come up.
    private var healthRing: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(healthyCount) / 4)
                .stroke(Theme.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.violet.opacity(0.4), radius: 5)
            VStack(spacing: -1) {
                Text("\(healthyCount)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("of 4")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .animation(Theme.gentle, value: healthyCount)
    }

    private func modelBanner(_ st: ModelStatus) -> some View {
        Button {
            withAnimation(Theme.spring) { selectedTab = .model }
        } label: {
            HStack(spacing: 13) {
                IconChip(
                    systemImage: st.active ? "arrow.down.circle.fill" : "exclamationmark.circle.fill",
                    gradient: Theme.gradient(for: Theme.warning),
                    size: 34,
                    glowColor: Theme.warning
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(st.active ? "Downloading speech model…" : "Speech model not downloaded")
                        .font(.sunoSubhead)
                    Text(st.active
                         ? "\(st.overall_done)/\(st.overall_total) files — open for details"
                         : "Download the ~2.4 GB on-device model to start dictating")
                        .font(.sunoCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sunoWell(radius: Theme.Radius.control, tint: Theme.warning)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var currentSetupCard: some View {
        SunoSection(
            title: "Current setup",
            systemImage: "slider.horizontal.3",
            subtitle: "Everything SunoFlow is configured to do right now"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: 8)],
                spacing: 8
            ) {
                SunoInfoRow(
                    label: "Dictation hotkey",
                    value: KeyCombo.display(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers),
                    systemImage: "command"
                )
                SunoInfoRow(label: "Microphone", value: micDisplayName, systemImage: "mic")
                SunoInfoRow(label: "Auto-stop", value: "\(prefs.maxRecordingSeconds) s", systemImage: "timer")
                SunoInfoRow(
                    label: "AI cleanup",
                    value: prefs.cleanupEnabled ? "On" : "Off",
                    systemImage: "sparkles",
                    valueColor: prefs.cleanupEnabled ? Theme.success : .secondary
                )
                SunoInfoRow(
                    label: "Screen context",
                    value: prefs.screenContextEnabled ? "On" : "Off",
                    systemImage: "rectangle.on.rectangle",
                    valueColor: prefs.screenContextEnabled ? Theme.success : .secondary
                )
                SunoInfoRow(
                    label: "Launch at login",
                    value: launchAtLogin ? "Enabled" : "Disabled",
                    systemImage: "power",
                    valueColor: launchAtLogin ? Theme.success : .secondary
                )
                SunoInfoRow(
                    label: "Learned corrections",
                    value: "\(corrections.count)",
                    systemImage: "text.badge.checkmark"
                )
            }
        }
    }

    private var micDisplayName: String {
        if prefs.micDeviceUID.isEmpty { return "System Default" }
        if let dev = inputDevices.first(where: { $0.uid == prefs.micDeviceUID }) {
            return dev.name
        }
        return "Selected device (disconnected)"
    }

    // MARK: Reusable form row

    /// A label + description on the left, its control on the right.
    private func settingRow<C: View>(
        _ title: String,
        _ description: String? = nil,
        @ViewBuilder control: () -> C
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.sunoBodyMedium)
                if let description {
                    Text(description)
                        .font(.sunoCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }

    private func brandToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.violet)
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            SunoSection(
                title: "Startup",
                systemImage: "power",
                subtitle: "What happens when you log in"
            ) {
                settingRow(
                    "Launch SunoFlow at login",
                    "To also auto-start the transcription engine, run ./install-autostart.sh once."
                ) {
                    brandToggle($launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            if let error = LoginItem.setEnabled(newValue) {
                                loginError = error
                                launchAtLogin = LoginItem.isEnabled
                            } else {
                                loginError = nil
                            }
                        }
                }
                if let loginError {
                    SunoNotice(text: loginError, systemImage: "xmark.octagon.fill", color: Theme.danger)
                }
            }

            SunoSection(
                title: "Dictation hotkey",
                systemImage: "command",
                subtitle: "Press this combo anywhere to start and stop dictation"
            ) {
                HStack(spacing: 10) {
                    HotkeyRecorder(keyCode: $prefs.hotkeyKeyCode, modifiers: $prefs.hotkeyModifiers)
                        .frame(width: 168, height: 34)
                    Button("Reset") { prefs.resetHotkeyToDefault() }
                        .buttonStyle(.sunoGhost)
                    Spacer(minLength: 0)
                }
            }

            SunoSection(
                title: "Recording",
                systemImage: "timer",
                subtitle: "Stops a runaway recording automatically so you don't have to"
            ) {
                settingRow("Auto-stop recording after") {
                    HStack(spacing: 10) {
                        Text("\(prefs.maxRecordingSeconds) s")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 46, alignment: .trailing)
                        Stepper("", value: $prefs.maxRecordingSeconds, in: 10...600, step: 5)
                            .labelsHidden()
                    }
                }
            }

            SunoSection(
                title: "Screen context",
                systemImage: "rectangle.on.rectangle",
                subtitle: "Give the cleanup AI a sense of what's on screen"
            ) {
                settingRow(
                    "Use screen context for cleanup",
                    "When on, a screenshot is taken and OCR'd on-device when dictation stops. The recognized words give the cleanup AI rough context about the app you're typing into — better names, terms, and phrasing. Accuracy is not the goal; only the on-screen vocabulary is extracted."
                ) {
                    brandToggle($prefs.screenContextEnabled)
                        .onChange(of: prefs.screenContextEnabled) { newValue in
                            if newValue, !ScreenContext.hasPermission {
                                ScreenContext.openSystemSettings()
                            }
                        }
                }

                if prefs.screenContextEnabled, !screenRecordingPermission {
                    SunoNotice(text: "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then restart SunoFlow.")
                    Button("Open System Settings") { ScreenContext.openSystemSettings() }
                        .buttonStyle(.sunoSecondary)
                }
            }
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            SunoSection(
                title: "Input device",
                systemImage: "mic.fill",
                subtitle: "Which microphone SunoFlow records from"
            ) {
                Picker("", selection: $prefs.micDeviceUID) {
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
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: prefs.micDeviceUID) { _ in refreshMicWarning() }

                if micIsBluetooth {
                    VStack(alignment: .leading, spacing: 10) {
                        SunoNotice(text: "This is a Bluetooth microphone. Recording from it forces your earbuds or headphones into low-quality call mode — degrading audio in every app while you dictate.")
                        if AudioDevices.builtInInputUID() != nil {
                            Button("Switch to built-in microphone") {
                                if let builtIn = AudioDevices.builtInInputUID() {
                                    prefs.micDeviceUID = builtIn
                                    refreshMicWarning()
                                }
                            }
                            .buttonStyle(.sunoPrimary)
                        }
                    }
                }

                HStack {
                    Spacer(minLength: 0)
                    Button {
                        inputDevices = AudioDevices.inputDevices()
                        refreshMicWarning()
                    } label: {
                        Label("Refresh devices", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.sunoGhost)
                }
            }
        }
    }

    private func refreshMicWarning() {
        micIsBluetooth = AudioDevices.effectiveInputIsBluetooth(savedUID: prefs.micDeviceUID)
    }

    // MARK: Model download

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            if !sidecarOnline {
                SunoNotice(text: "Engine offline — start it from the Overview tab to download the model.")
            }

            SunoSection(
                title: "Parakeet TDT 0.6B v2",
                systemImage: "waveform",
                subtitle: "Runs entirely on your Mac — no audio ever leaves this machine"
            ) {
                Text("The model is about 2.4 GB; the download takes a few minutes on a typical connection.")
                    .font(.sunoCaption)
                    .foregroundStyle(.secondary)

                Divider().opacity(0.5)

                if let st = modelStatus {
                    modelStatusBody(st)
                } else if sidecarOnline {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking model status…")
                            .font(.sunoCaption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Model status unavailable while the engine is offline.")
                        .font(.sunoCaption).foregroundStyle(.secondary)
                }
            }

            if let st = modelStatus, !st.model_dir.isEmpty {
                SunoSection(
                    title: "Storage",
                    systemImage: "internaldrive.fill",
                    subtitle: "Where the weights live on disk"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        monoRow(st.model_dir)
                        monoRow(st.model_id)
                    }
                }
            }
        }
        .onAppear { startModelPolling() }
        .onDisappear { stopModelPolling() }
    }

    private func monoRow(_ text: String) -> some View {
        Text(text)
            .font(.sunoMono)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sunoWell()
    }

    @ViewBuilder
    private func modelStatusBody(_ st: ModelStatus) -> some View {
        if st.model_loaded {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text("Model ready — dictation is available.")
                    .font(.sunoBodyMedium)
                Spacer(minLength: 0)
            }
            .padding(12)
            .sunoWell(radius: Theme.Radius.control, tint: Theme.success)
        } else if st.active {
            // Download / load in progress.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    if st.phase == "loading" {
                        ProgressView().controlSize(.small)
                        Text("Loading model into memory…").font(.sunoBodyMedium)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Theme.violet)
                        Text("Downloading model…").font(.sunoBodyMedium)
                    }
                    Spacer(minLength: 0)
                    SunoBadge(text: "\(st.overall_done)/\(st.overall_total) files")
                }

                if st.phase != "loading", !st.current_file.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(st.current_file)
                            .font(.sunoMono)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        SunoProgressBar(
                            value: Double(st.downloaded),
                            total: Double(max(st.file_total, 1))
                        )
                        HStack {
                            Text(byteString(st.downloaded))
                            Spacer()
                            if st.file_total > 0 { Text(byteString(st.file_total)) }
                        }
                        .font(.sunoMicro)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }
            .padding(12)
            .sunoWell(radius: Theme.Radius.control, tint: Theme.violet)
        } else if st.model_present {
            // Files are on disk but the model isn't loaded in-process yet.
            VStack(alignment: .leading, spacing: 12) {
                SunoNotice(text: "Model downloaded but not loaded. Restart the engine to activate it.")
                Button("Start engine") { startEngine() }
                    .buttonStyle(.sunoPrimary)
                    .disabled(startingEngine)
            }
        } else if st.phase == "error" {
            VStack(alignment: .leading, spacing: 12) {
                SunoNotice(text: st.error.isEmpty ? "Download failed." : "Download failed — \(st.error)",
                           systemImage: "xmark.octagon.fill",
                           color: Theme.danger)
                Button("Retry download") { startDownload() }
                    .buttonStyle(.sunoPrimary)
            }
        } else {
            // Idle, nothing present.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                    Text("Model not downloaded yet.")
                        .font(.sunoBodyMedium)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Button {
                    startDownload()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(modelDownloadStarting ? "Starting…" : "Download model (2.4 GB)")
                    }
                }
                .buttonStyle(.sunoPrimary)
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
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            SunoSection(
                title: "Learned corrections",
                systemImage: "text.badge.checkmark",
                subtitle: "SunoFlow learns from the edits you make to pasted text"
            ) {
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
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            SunoSection(
                title: "Transcript polishing",
                systemImage: "sparkles",
                subtitle: "A hosted AI rewrites the raw transcript before it's pasted"
            ) {
                settingRow(
                    "Polish transcript with AI",
                    "When off, the raw transcript is pasted with no cleanup pass. On-device speech recognition and your learned corrections still apply."
                ) {
                    brandToggle($prefs.cleanupEnabled)
                }
            }

            SunoSection(
                title: "Cleanup service",
                systemImage: "cloud.fill",
                subtitle: "Transcript polishing runs on a hosted gateway, not on this Mac"
            ) {
                HStack(spacing: 12) {
                    PulseDot(
                        color: cleanupGatewayOnline ? Theme.success : Theme.warning,
                        active: cleanupGatewayOnline,
                        size: 7
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cleanupGatewayOnline ? "Service reachable" : "Service unreachable")
                            .font(.sunoBodyMedium)
                        Text(cleanupGatewayOnline
                             ? "Transcripts are sent for polishing when AI cleanup is on."
                             : "Dictation still works — raw transcripts are pasted unchanged while the service is down.")
                            .font(.sunoCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .sunoWell(radius: Theme.Radius.control, tint: cleanupGatewayOnline ? Theme.success : Theme.warning)

                monoRow("https://cleanup.mirrorli.art")
            }

            if prefs.screenContextEnabled {
                SunoSection(
                    title: "Screen context",
                    systemImage: "rectangle.on.rectangle",
                    subtitle: "On-screen words sent to the cleanup AI as reference"
                ) {
                    Text("When enabled, a screenshot is OCR'd on-device when dictation stops and the recognized words are sent to the cleanup service as context. This helps the AI match names, terminology, and phrasing to what's visible on screen. Managed in the General tab.")
                        .font(.sunoCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.cardGap) {
            // App identity strip
            HStack(spacing: 16) {
                IconChip(systemImage: "waveform", size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SunoFlow")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Version \(appVersion) (build \(appBuild))")
                        .font(.sunoCaption)
                        .foregroundStyle(.secondary)
                    Text("On-device dictation for macOS")
                        .font(.sunoCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.surface)
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.brandWash.opacity(0.6))
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.violet.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: Theme.violet.opacity(0.14), radius: 16, y: 6)
            )

            SunoSection(
                title: "Components",
                systemImage: "square.stack.3d.up.fill",
                subtitle: "What's running under the hood"
            ) {
                VStack(spacing: 8) {
                    SunoInfoRow(label: "Speech engine", value: "Parakeet TDT 0.6B v2 (MLX)", systemImage: "waveform")
                    SunoInfoRow(
                        label: "Speech model",
                        value: modelStatus?.model_loaded == true
                            ? "Downloaded & loaded"
                            : (modelStatus?.model_present == true ? "Downloaded (not loaded)" : "Not downloaded"),
                        systemImage: "arrow.down.circle",
                        valueColor: modelStatus?.model_loaded == true ? Theme.success : Theme.warning
                    )
                    SunoInfoRow(
                        label: "Cleanup service",
                        value: cleanupGatewayOnline ? "Hosted gateway reachable" : "Hosted gateway offline",
                        systemImage: "sparkles",
                        valueColor: cleanupGatewayOnline ? Theme.success : Theme.warning
                    )
                    SunoInfoRow(label: "Sidecar endpoint", value: "http://127.0.0.1:8765", systemImage: "network")
                }
            }

            SunoSection(
                title: "Resources",
                systemImage: "folder.fill",
                subtitle: "Files, logs, and upstream projects"
            ) {
                HStack(spacing: 8) {
                    Button {
                        openProjectFolder()
                    } label: {
                        Label("Project folder", systemImage: "folder")
                    }
                    .buttonStyle(.sunoSecondary)

                    Button {
                        revealLogs()
                    } label: {
                        Label("View logs", systemImage: "doc.text")
                    }
                    .buttonStyle(.sunoSecondary)

                    Link(destination: URL(string: "https://github.com/senstella/parakeet-mlx")!) {
                        Label("Parakeet MLX", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.sunoGhost)

                    Spacer(minLength: 0)
                }
            }
        }
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
                    loadCorrections()
                    fetchModelStatus()
                }
            }
        }
        TranscriptionClient.checkCleanupGateway { ok in
            DispatchQueue.main.async { cleanupGatewayOnline = ok }
        }
    }

    private func loadCorrections() {
        TranscriptionClient.fetchCorrections { items in
            DispatchQueue.main.async { corrections = items }
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

    private func openProjectFolder() {
        guard let root = projectRoot() else { return }
        NSWorkspace.shared.open(root)
    }
}
