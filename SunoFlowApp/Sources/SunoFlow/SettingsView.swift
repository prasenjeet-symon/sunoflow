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

    /// The brand accent, matched to `Theme.accent` on the SwiftUI side.
    private static let accent = NSColor(calibratedRed: 0.310, green: 0.286, blue: 0.710, alpha: 1.0)

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

/// A small pill naming which half of the dictionary an entry belongs to.
///
/// Worth the pixels because the two kinds behave differently at dictation time:
/// a spelling is swapped in on every dictation, while a shorthand value only
/// lands where the model judges you were actually giving it. Without the badge
/// that difference is invisible until it surprises someone.
private struct KindBadge: View {
    let kind: CorrectionKind

    var body: some View {
        Text(kind.label)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.2)
            .foregroundStyle(kind == .expansion ? Theme.accent : Theme.faint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(kind == .expansion ? Theme.accentSoft : Theme.wash)
            )
            .help(kind.blurb)
    }
}

/// Manages the dictionary inside Settings: search, edit, add, delete.
private struct CorrectionsManager: View {
    @Binding var corrections: [Correction]
    @Binding var sidecarOnline: Bool
    var onReload: () -> Void

    @State private var searchText = ""
    @State private var editingKey: String?
    @State private var editFrom = ""
    @State private var editTo = ""
    @State private var editKind: CorrectionKind = .correction
    @State private var addingNew = false
    @State private var newFrom = ""
    @State private var newTo = ""
    /// nil = let the sidecar classify it. The default, so the rule that decides
    /// lives in one place instead of being guessed at again here.
    @State private var newKind: CorrectionKind?
    @State private var hoveredKey: String?

    private var filtered: [Correction] {
        guard !searchText.isEmpty else { return corrections }
        let q = searchText.lowercased()
        return corrections.filter {
            $0.from.lowercased().contains(q) || $0.to.lowercased().contains(q)
                || $0.resolvedKind.label.lowercased().contains(q)
        }
    }

    private var spellingCount: Int { corrections.filter { $0.resolvedKind == .correction }.count }
    private var shorthandCount: Int { corrections.count - spellingCount }

    var body: some View {
        if !sidecarOnline {
            SunoNotice(text: "The engine is offline — start it from Overview to manage your dictionary.")
                .padding(.vertical, 16)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.faint)
                        TextField("Search your dictionary…", text: $searchText)
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
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.wash))

                    Button(addingNew ? "Cancel" : "Add entry") {
                        withAnimation(Theme.spring) { addingNew.toggle() }
                    }
                    .buttonStyle(.sunoSecondary)
                }
                .padding(.vertical, 14)

                if addingNew {
                    addRow
                }

                Rule()

                if corrections.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(filtered) { correction in
                            if editingKey == correction.key {
                                editRow(correction)
                            } else {
                                displayRow(correction)
                            }
                        }
                    }

                    Rule(strong: true)

                    HStack {
                        Text(summary)
                            .font(.sunoCaption)
                            .foregroundStyle(Theme.faint)
                        Spacer()
                        Button("Clear all", action: clearAll)
                            .buttonStyle(.sunoGhost(Theme.danger))
                    }
                    .padding(.top, 14)
                }
            }
            .animation(Theme.spring, value: addingNew)
            .animation(Theme.gentle, value: corrections.count)
        }
    }

    /// "3 spellings · 1 shorthand", dropping whichever half is empty.
    private var summary: String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if spellingCount > 0 { parts.append(plural(spellingCount, "spelling")) }
        if shorthandCount > 0 { parts.append(plural(shorthandCount, "shorthand entry")) }
        return parts.isEmpty ? "Nothing saved yet" : parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Nothing saved yet")
                .font(.sunoRowTitle)
                .foregroundStyle(Theme.ink)
            Text("Edit the text SunoFlow pastes and it remembers the fix — or add a spelling or a shorthand by hand.")
                .font(.sunoCaption)
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
    }

    // MARK: Rows

    private func displayRow(_ c: Correction) -> some View {
        let hovered = hoveredKey == c.key
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(c.from)
                    .font(.sunoMono)
                    .foregroundStyle(Theme.faint)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.faint.opacity(0.7))
                Text(c.to)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                KindBadge(kind: c.resolvedKind)

                if c.count > 1 {
                    Text("seen \(c.count)×")
                        .font(.sunoCaption)
                        .foregroundStyle(Theme.faint)
                        .padding(.leading, 4)
                }

                Spacer(minLength: 12)

                HStack(spacing: 2) {
                    Button { startEdit(c) } label: { Image(systemName: "pencil") }
                        .buttonStyle(.sunoIcon(Theme.accent))
                        .help("Edit")
                    Button { delete(c) } label: { Image(systemName: "trash") }
                        .buttonStyle(.sunoIcon(Theme.danger))
                        .help("Delete")
                }
                .opacity(hovered ? 1 : 0)
            }
            .padding(.vertical, 11)
            .background(hovered ? Theme.wash : Color.clear)
            .animation(Theme.quick, value: hovered)
            .onHover { hoveredKey = $0 ? c.key : (hoveredKey == c.key ? nil : hoveredKey) }

            Rule()
        }
    }

    private func editRow(_ c: Correction) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TextField(editKind.fromPlaceholder, text: $editFrom)
                        .textFieldStyle(SunoFieldStyle())
                    TextField(editKind.toPlaceholder, text: $editTo)
                        .textFieldStyle(SunoFieldStyle())
                    Button("Save") { saveEdit(c) }
                        .buttonStyle(.sunoPrimary)
                    Button("Cancel") { editingKey = nil }
                        .buttonStyle(.sunoGhost)
                }
                HStack(spacing: 8) {
                    // Prefilled with the entry's current kind, never re-inferred:
                    // fixing a typo in a URL should not silently reclassify it.
                    Picker("", selection: $editKind) {
                        ForEach(CorrectionKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 132)

                    Text(editKind.blurb)
                        .font(.sunoCaption)
                        .foregroundStyle(Theme.faint)
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 10)
            Rule()
        }
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(newKind?.fromPlaceholder ?? "What you say", text: $newFrom)
                    .textFieldStyle(SunoFieldStyle())
                TextField(newKind?.toPlaceholder ?? "What should be written instead", text: $newTo)
                    .textFieldStyle(SunoFieldStyle())
                Button("Add") { addCorrection() }
                    .buttonStyle(.sunoPrimary)
                    .disabled(newFrom.isEmpty || newTo.isEmpty)
            }
            HStack(spacing: 8) {
                Picker("", selection: $newKind) {
                    Text("Detect automatically").tag(CorrectionKind?.none)
                    ForEach(CorrectionKind.allCases) { kind in
                        Text(kind.label).tag(CorrectionKind?.some(kind))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 175)

                Text(newKind?.blurb
                     ?? "Paste a link or handle and it becomes a shorthand; a respelling stays a spelling.")
                    .font(.sunoCaption)
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: Actions

    private func startEdit(_ c: Correction) {
        editingKey = c.key
        editFrom = c.from
        editTo = c.to
        editKind = c.resolvedKind
    }

    private func saveEdit(_ c: Correction) {
        let from = editFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = editTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty else { editingKey = nil; return }
        TranscriptionClient.updateCorrection(key: c.key, from: from, to: to, kind: editKind) { updated in
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
        TranscriptionClient.addCorrection(from: from, to: to, kind: newKind) { updated in
            DispatchQueue.main.async {
                corrections = updated
                addingNew = false
                newFrom = ""
                newTo = ""
                newKind = nil
            }
        }
    }
}

// MARK: - Dashboard navigation

/// Sidebar tabs for the dashboard.
private enum Tab: String, CaseIterable, Identifiable {
    case overview, account, general, microphone, model, corrections, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .account: return "Account"
        case .general: return "General"
        case .microphone: return "Microphone"
        case .model: return "Speech Model"
        case .corrections: return "Dictionary"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .account: return "person.crop.circle"
        case .general: return "gearshape.fill"
        case .microphone: return "mic.fill"
        case .model: return "waveform.badge.magnifyingglass"
        case .corrections: return "text.badge.checkmark"
        case .about: return "info.circle.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "System health and quick actions"
        case .account: return "Your subscription and this device"
        case .general: return "Launch, hotkey, and recording behaviour"
        case .microphone: return "Choose which input SunoFlow listens to"
        case .model: return "The speech-to-text model"
        case .corrections: return "Spellings it has learned, and shorthand you add"
        case .about: return "Version and resources"
        }
    }
}

// MARK: - Status card (overview dashboard)

/// A card showing the health of one subsystem, with a live status dot and an
/// optional inline recovery action.


// MARK: - Dashboard window content

struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    @State private var selectedTab: Tab = .overview
    @StateObject private var account = AccountManager.shared
    @State private var hoveredTab: Tab?
    @Namespace private var navPill

    @State private var inputDevices: [AudioInputDevice] = []
    @State private var micIsBluetooth = false

    // Sidecar (transcription engine) reachability.
    @State private var sidecarOnline = false

    // Hosted text-polishing pass reachability. Named for what the user sees it
    // do, not for the gateway/backend behind it.
    @State private var polishOnline = false

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

    /// Total subsystems tracked in the overview status list.
    private let subsystemCount = 4

    /// Number of subsystems that are healthy (for the overview header).
    private var healthyCount: Int {
        [sidecarOnline, micPermission, accessibilityPermission, polishOnline].filter { $0 }.count
    }

    private var allReady: Bool { healthyCount == subsystemCount }

    private var heroSubtitle: String {
        guard !allReady else {
            let combo = KeyCombo.display(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
            return "Press \(combo) anywhere to dictate."
        }
        let pending = subsystemCount - healthyCount
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
        .background(Theme.paper)
        // Toggles, pickers and sliders are system controls; tinting them here
        // stops macOS colouring them its own accent blue mid-page.
        .tint(Theme.accent)
        .onAppear(perform: load)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand. The top padding clears the hidden title bar so the traffic
            // lights float over the navigation column.
            HStack(spacing: 9) {
                Image(nsImage: BrandMark.image(size: 17))
                    .renderingMode(.template)
                    .foregroundStyle(Theme.accent)
                Text("SunoFlow")
                    .font(.system(size: 14.5, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 46)
            .padding(.bottom, 20)

            VStack(spacing: 0) {
                ForEach(Tab.allCases) { tab in
                    navButton(tab)
                }
            }

            Spacer(minLength: 20)

            Rule()
            HStack(spacing: 7) {
                Circle()
                    .fill(sidecarOnline ? Theme.success : Theme.warning)
                    .frame(width: 6, height: 6)
                Text(sidecarOnline ? "Engine online" : "Engine offline")
                    .font(.sunoCaption)
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 210, alignment: .top)
        .background(Theme.shell)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.ruleStrong).frame(width: 1)
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
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.accent : Theme.faint)
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.body)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                ZStack(alignment: .leading) {
                    if selected {
                        Theme.accentSoft
                        Rectangle().fill(Theme.accent).frame(width: 2)
                    } else if hovered {
                        Theme.rule.opacity(0.55)
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
            VStack(alignment: .leading, spacing: 0) {
                header

                Group {
                    switch selectedTab {
                    case .overview: overviewSection
                    case .account: accountSection
                    case .general: generalSection
                    case .microphone: microphoneSection
                    case .model: modelSection
                    case .corrections: correctionsSection
                    case .about: aboutSection
                    }
                }
                .id(selectedTab)
                .transition(.opacity)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.paper)
        .animation(Theme.gentle, value: selectedTab)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTab.title)
                        .font(.sunoDisplay)
                        .tracking(-0.7)
                        .foregroundStyle(Theme.ink)
                    Text(selectedTab.subtitle)
                        .font(.sunoCaption)
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 12)
                StatusText(
                    text: allReady ? "All systems ready" : "\(subsystemCount - healthyCount) need attention",
                    color: allReady ? Theme.success : Theme.warning
                )
            }
            .padding(.top, 46)
            .padding(.bottom, 22)

            Rule(strong: true)
        }
    }

    // MARK: Overview / Dashboard

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            overviewLead
            statusGroup
            setupGroup
            actionNeededGroup
        }
    }

    /// The one sentence that answers "is this thing working?".
    private var overviewLead: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(allReady ? "Everything's ready" : "Almost there")
                .font(.sunoLead)
                .tracking(-0.3)
                .foregroundStyle(Theme.ink)
            Text(heroSubtitle)
                .font(.sunoBody)
                .foregroundStyle(Theme.body)
                .fixedSize(horizontal: false, vertical: true)

            if sidecarOnline, let st = modelStatus, !st.model_loaded {
                modelBanner(st)
                    .padding(.top, 14)
            }
        }
        .padding(.top, 28)
    }

    private var statusGroup: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Status", trailing: "\(healthyCount) of \(subsystemCount) ready")
            Rule(strong: true)
            statusRow(
                title: "Transcription engine",
                systemImage: "cpu",
                ok: sidecarOnline,
                okText: "Online",
                failText: "Offline",
                hint: sidecarOnline
                    ? "Speech is transcribed entirely on this Mac."
                    : "Start the engine to enable dictation.",
                action: sidecarOnline ? nil : startEngine,
                actionLabel: startingEngine ? "Starting…" : "Start engine"
            )
            statusRow(
                title: "Microphone",
                systemImage: "mic",
                ok: micPermission,
                okText: "Allowed",
                failText: "Not allowed",
                hint: micPermission
                    ? micDisplayName
                    : "Grant access in System Settings → Privacy & Security."
            )
            statusRow(
                title: "Accessibility",
                systemImage: "keyboard",
                ok: accessibilityPermission,
                okText: "Allowed",
                failText: "Not allowed",
                hint: "Required so SunoFlow can type into other apps."
            )
            statusRow(
                title: "Text polish",
                systemImage: "sparkles",
                ok: polishOnline,
                okText: "Online",
                failText: "Offline",
                hint: polishOnline
                    ? "Dictation is tidied up before it's typed out."
                    : "Dictation still works, but arrives unpolished until this reconnects.",
                divider: false
            )
            Rule(strong: true)
        }
    }

    private func statusRow(
        title: String,
        systemImage: String,
        ok: Bool,
        okText: String,
        failText: String,
        hint: String,
        action: (() -> Void)? = nil,
        actionLabel: String = "",
        divider: Bool = true
    ) -> some View {
        SunoRow(
            title: title,
            subtitle: hint,
            systemImage: systemImage,
            iconColor: ok ? Theme.success : Theme.warning,
            divider: divider
        ) {
            HStack(spacing: 14) {
                if let action, !ok {
                    Button(action: action) {
                        Text(actionLabel)
                    }
                    .buttonStyle(.sunoPrimary)
                    .disabled(startingEngine)
                }
                StatusText(
                    text: ok ? okText : failText,
                    color: ok ? Theme.success : Theme.warning
                )
            }
        }
    }

    private var setupGroup: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Current setup")
            Rule(strong: true)
            ValueRow(
                label: "Dictation hotkey",
                value: KeyCombo.display(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers),
                systemImage: "command"
            )
            ValueRow(label: "Microphone", value: micDisplayName, systemImage: "mic")
            ValueRow(label: "Auto-stop recording", value: "\(prefs.maxRecordingSeconds) seconds", systemImage: "timer")
            ValueRow(
                label: "Screen context",
                value: prefs.screenContextEnabled ? "On" : "Off",
                systemImage: "rectangle.on.rectangle",
                valueColor: prefs.screenContextEnabled ? Theme.success : Theme.faint
            )
            ValueRow(
                label: "Launch at login",
                value: launchAtLogin ? "Enabled" : "Disabled",
                systemImage: "power",
                valueColor: launchAtLogin ? Theme.success : Theme.faint
            )
            ValueRow(
                label: "Dictionary entries",
                value: "\(corrections.count)",
                systemImage: "text.badge.checkmark",
                divider: false
            )
            Rule(strong: true)
        }
    }

    @ViewBuilder
    private var actionNeededGroup: some View {
        let needsMic = !micPermission
        let needsAX = !accessibilityPermission
        let needsScreen = prefs.screenContextEnabled && !screenRecordingPermission

        if needsMic || needsAX || needsScreen {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Action needed")
                Rule(strong: true)
                VStack(alignment: .leading, spacing: 12) {
                    if needsMic {
                        SunoNotice(text: "Grant microphone access in System Settings → Privacy & Security → Microphone.")
                    }
                    if needsAX {
                        SunoNotice(text: "Grant Accessibility access in System Settings → Privacy & Security → Accessibility so SunoFlow can insert text.")
                    }
                    if needsScreen {
                        SunoNotice(text: "Grant Screen Recording access in System Settings → Privacy & Security → Screen Recording for screen context to work.")
                    }
                }
                .padding(.vertical, 16)
                Rule(strong: true)
            }
        }
    }

    /// The big "how are we doing" strip at the top of the overview.


    /// Circular gauge of healthy subsystems, animated as services come up.


    private func modelBanner(_ st: ModelStatus) -> some View {
        Button {
            withAnimation(Theme.spring) { selectedTab = .model }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: st.active ? "arrow.down.circle" : "exclamationmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.warning)
                Text(st.active
                     ? "Downloading the speech model — \(st.overall_done) of \(st.overall_total) files"
                     : "The speech model hasn't been downloaded yet")
                    .font(.sunoValue)
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        divider: Bool = true,
        @ViewBuilder control: @escaping () -> C
    ) -> some View {
        SunoRow(title: title, subtitle: description, divider: divider, trailing: control)
    }

    private func brandToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.accent)
    }

    // MARK: Account

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "This Mac")
            Rule(strong: true)

            switch account.state {
            case .notConnected:
                SunoRow(
                    title: "Not connected",
                    subtitle: "Connect this Mac to your SunoFlow account to dictate. We'll open your browser to confirm it's you — there's nothing to type.",
                    systemImage: "personalhotspot",
                    divider: false
                ) {
                    Button("Connect account") { account.connect() }
                        .buttonStyle(.sunoPrimary)
                }

            case .waiting(let code):
                SunoRow(
                    title: "Waiting for you to approve",
                    subtitle: "Check your browser shows this same code, then choose Connect.",
                    systemImage: "hourglass"
                ) {
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

            case .connected:
                SunoRow(
                    title: "Connected",
                    subtitle: "This Mac is linked to your account and can dictate.",
                    systemImage: "checkmark.circle",
                    iconColor: Theme.success
                ) {
                    StatusText(text: "Linked", color: Theme.success)
                }
                SunoRow(
                    title: "Sign out of this Mac",
                    subtitle: "Removes the key stored here. To stop it working everywhere, disconnect the device from your account page instead.",
                    systemImage: "xmark.circle",
                    divider: false
                ) {
                    Button("Sign out") { account.signOutThisMac() }
                        .buttonStyle(.sunoSecondary)
                }

            case .failed(let message):
                SunoRow(
                    title: "Couldn't connect",
                    subtitle: message,
                    systemImage: "exclamationmark.triangle",
                    iconColor: Theme.warning,
                    divider: false
                ) {
                    Button("Try again") { account.connect() }
                        .buttonStyle(.sunoPrimary)
                }
            }

            Rule(strong: true)

            if let notice = account.entitlementNotice {
                SectionLabel(text: "Subscription")
                Rule(strong: true)
                SunoRow(
                    title: "Dictation is paused",
                    subtitle: notice,
                    systemImage: "creditcard",
                    iconColor: Theme.warning,
                    divider: false
                ) {
                    Button("Open account") { account.openAccountPage() }
                        .buttonStyle(.sunoPrimary)
                }
                Rule(strong: true)
            }

            SectionLabel(text: "Your account")
            Rule(strong: true)
            SunoRow(
                title: "Subscription and devices",
                subtitle: "Your plan, billing and every connected Mac live on your account page.",
                systemImage: "safari",
                divider: false
            ) {
                Button("Open account page") { account.openAccountPage() }
                    .buttonStyle(.sunoSecondary)
            }
            Rule(strong: true)
        }
        .rowIconColumn()
    }

    // MARK: General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            startupGroup
            hotkeyGroup
            recordingGroup
            unfocusedGroup
            screenContextGroup
        }
    }

    private var startupGroup: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Startup")
            Rule(strong: true)
            settingRow(
                "Launch SunoFlow at login",
                "SunoFlow starts automatically and waits in the menu bar.",
                divider: loginError != nil
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
                    .padding(.vertical, 14)
            }
            Rule(strong: true)
        }
    }

    private var hotkeyGroup: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Dictation hotkey")
            Rule(strong: true)
            settingRow(
                "Shortcut",
                "Press this combination anywhere to start and stop dictation.",
                divider: false
            ) {
                HStack(spacing: 12) {
                    Button("Reset") { prefs.resetHotkeyToDefault() }
                        .buttonStyle(.sunoGhost)
                    HotkeyRecorder(keyCode: $prefs.hotkeyKeyCode, modifiers: $prefs.hotkeyModifiers)
                        .frame(width: 150, height: 30)
                }
            }
            Rule(strong: true)
        }
    }

    private var recordingGroup: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Recording")
            Rule(strong: true)
            settingRow(
                "Stop automatically after",
                "Ends a recording you forgot about, so it can't run all day.",
                divider: false
            ) {
                HStack(spacing: 8) {
                    Text("\(prefs.maxRecordingSeconds) s")
                        .font(.sunoValue)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .frame(minWidth: 42, alignment: .trailing)
                    Stepper("", value: $prefs.maxRecordingSeconds, in: 10...600, step: 5)
                        .labelsHidden()
                }
            }
            Rule(strong: true)
        }
    }

    private var unfocusedGroup: some View {
        VStack(spacing: 0) {
            SectionLabel(text: "Nowhere to paste")
            Rule(strong: true)
            settingRow(
                "Offer the text instead",
                "When a dictation finishes and no text field is focused, SunoFlow shows what you said at the bottom of the screen with a button to copy it — rather than typing into nothing and losing it.",
                divider: false
            ) {
                brandToggle($prefs.offerCopyWhenUnfocused)
            }
            Rule(strong: true)
        }
    }

    private var screenContextGroup: some View {
        let needsPermission = prefs.screenContextEnabled && !screenRecordingPermission
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Screen context")
            Rule(strong: true)
            settingRow(
                "Read what's on screen",
                "When dictation stops, SunoFlow reads the words visible on screen so it can match names, terminology and phrasing. Nothing is stored, and only the vocabulary is used.",
                divider: needsPermission
            ) {
                brandToggle($prefs.screenContextEnabled)
                    .onChange(of: prefs.screenContextEnabled) { newValue in
                        if newValue, !ScreenContext.hasPermission {
                            ScreenContext.openSystemSettings()
                        }
                    }
            }
            if needsPermission {
                VStack(alignment: .leading, spacing: 12) {
                    SunoNotice(text: "Screen Recording access is required. Grant it in System Settings, then restart SunoFlow.")
                    Button("Open System Settings") { ScreenContext.openSystemSettings() }
                        .buttonStyle(.sunoSecondary)
                }
                .padding(.vertical, 14)
            }
            Rule(strong: true)
        }
    }

    // MARK: Microphone

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Input device")
            Rule(strong: true)
            settingRow(
                "Microphone",
                "Which input SunoFlow records from.",
                divider: micIsBluetooth
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
                .frame(maxWidth: 240)
                .onChange(of: prefs.micDeviceUID) { _ in refreshMicWarning() }
            }

            if micIsBluetooth {
                VStack(alignment: .leading, spacing: 12) {
                    SunoNotice(text: "Recording from a Bluetooth microphone forces your earbuds into low-quality call mode, degrading audio in every app while you dictate.")
                    if AudioDevices.builtInInputUID() != nil {
                        Button("Switch to the built-in microphone") {
                            if let builtIn = AudioDevices.builtInInputUID() {
                                prefs.micDeviceUID = builtIn
                                refreshMicWarning()
                            }
                        }
                        .buttonStyle(.sunoSecondary)
                    }
                }
                .padding(.vertical, 14)
            }

            SunoRow(
                title: "Devices out of date?",
                subtitle: "SunoFlow reads the input list when Settings opens. Rescan if you have just plugged something in.",
                systemImage: "arrow.clockwise",
                divider: false
            ) {
                Button("Rescan") {
                    inputDevices = AudioDevices.inputDevices()
                    refreshMicWarning()
                }
                .buttonStyle(.sunoSecondary)
            }
            Rule(strong: true)

            SectionLabel(text: "Getting a clean recording")
            Rule(strong: true)
            SunoRow(
                title: "The built-in microphone is usually best",
                subtitle: "It stays in high-quality mode while you dictate, and it is what the speech model hears most often.",
                systemImage: "checkmark.circle"
            )
            SunoRow(
                title: "Wired beats wireless",
                subtitle: "Any wired headset avoids the call-mode downgrade that Bluetooth microphones force on the whole system.",
                systemImage: "cable.connector",
                divider: false
            )
            Rule(strong: true)
        }
        .rowIconColumn()
    }

    private func refreshMicWarning() {
        micIsBluetooth = AudioDevices.effectiveInputIsBluetooth(savedUID: prefs.micDeviceUID)
    }

    // MARK: Model download

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sidecarOnline {
                SunoNotice(text: "The engine is offline — start it from Overview before downloading the model.")
                    .padding(.top, 26)
            }

            SectionLabel(text: "On-device model")
            Rule(strong: true)

            SunoRow(
                title: "SunoFlow speech model v1",
                subtitle: "Roughly 2.4 GB. The download takes a few minutes on a typical connection.",
                systemImage: "waveform"
            )

            Group {
                if let st = modelStatus {
                    modelStatusBody(st)
                } else if sidecarOnline {
                    SunoRow(title: "Checking model status…", divider: false) {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    }
                } else {
                    SunoRow(
                        title: "Status unavailable",
                        subtitle: "Start the engine to see whether the model is installed.",
                        divider: false
                    )
                }
            }

            Rule(strong: true)

            SectionLabel(text: "Where it runs")
            Rule(strong: true)
            SunoRow(
                title: "On this Mac",
                subtitle: "Speech is turned into text by your own machine. The recording is never uploaded.",
                systemImage: "desktopcomputer"
            )
            SunoRow(
                title: "Downloaded once",
                subtitle: "The model is stored locally and reused. After the first download it works without an internet connection.",
                systemImage: "arrow.down.circle",
                divider: false
            )
            Rule(strong: true)
        }
        .rowIconColumn()
        .onAppear { startModelPolling() }
        .onDisappear { stopModelPolling() }
    }

    @ViewBuilder
    private func modelStatusBody(_ st: ModelStatus) -> some View {
        if st.model_loaded {
            SunoRow(title: "Model ready", subtitle: "Dictation is available.", divider: false) {
                StatusText(text: "Ready", color: Theme.success)
            }
        } else if st.active {
            VStack(alignment: .leading, spacing: 0) {
                SunoRow(
                    title: st.phase == "loading" ? "Loading model into memory…" : "Downloading model…",
                    subtitle: st.phase == "loading" ? nil : "File \(st.overall_done + 1) of \(st.overall_total)",
                    divider: false
                ) {
                    if st.phase == "loading" {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    } else {
                        Text("\(st.overall_done)/\(st.overall_total)")
                            .font(.sunoValue).monospacedDigit()
                            .foregroundStyle(Theme.body)
                    }
                }
                if st.phase != "loading", !st.current_file.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        SunoProgressBar(
                            value: Double(st.downloaded),
                            total: Double(max(st.file_total, 1))
                        )
                        HStack {
                            Text(byteString(st.downloaded))
                            Spacer()
                            if st.file_total > 0 { Text(byteString(st.file_total)) }
                        }
                        .font(.sunoCaption)
                        .foregroundStyle(Theme.faint)
                        .monospacedDigit()
                    }
                    .padding(.bottom, 16)
                }
            }
        } else if st.model_present {
            SunoRow(
                title: "Downloaded, but not loaded",
                subtitle: "Restart the engine to activate the model.",
                divider: false
            ) {
                Button("Start engine") { startEngine() }
                    .buttonStyle(.sunoPrimary)
                    .disabled(startingEngine)
            }
        } else if st.phase == "error" {
            SunoRow(
                title: "Download failed",
                subtitle: st.error.isEmpty ? "Something went wrong during the download." : st.error,
                iconColor: Theme.danger,
                divider: false
            ) {
                Button("Retry") { startDownload() }
                    .buttonStyle(.sunoPrimary)
            }
        } else {
            SunoRow(
                title: "Not downloaded yet",
                subtitle: "Dictation stays unavailable until the model is on this Mac.",
                divider: false
            ) {
                Button(modelDownloadStarting ? "Starting…" : "Download model") { startDownload() }
                    .buttonStyle(.sunoPrimary)
                    .disabled(modelDownloadStarting || !sidecarOnline)
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

    // MARK: Dictionary

    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Your dictionary", trailing: "Spellings it learns, and shorthand you add")
            Rule(strong: true)
            CorrectionsManager(
                corrections: $corrections,
                sidecarOnline: $sidecarOnline,
                onReload: loadCorrections
            )

            SectionLabel(text: "How this works")
            Rule(strong: true)
            SunoRow(
                title: "Spellings are learned for you",
                subtitle: "After SunoFlow pastes, it notices small edits you make — a name respelled, an acronym capitalised — and remembers them. Rephrasing a whole sentence is you changing your mind, not a mistake, so only short, name-like fixes are picked up.",
                systemImage: "eye"
            )
            SunoRow(
                title: "Spellings always win",
                subtitle: "They are applied as the last step of every dictation, so they override whatever the model heard.",
                systemImage: "checkmark.seal"
            )
            SunoRow(
                title: "Shorthand saves you spelling things out",
                subtitle: "Save your Instagram or LinkedIn link once, then just say “here's my Instagram” and the link is written instead. Add these by hand — SunoFlow never invents one.",
                systemImage: "link"
            )
            SunoRow(
                title: "Shorthand reads the sentence first",
                subtitle: "The value is only substituted where you were actually giving it out. Say “I don't have an Instagram” and the words stay exactly as you said them.",
                systemImage: "text.magnifyingglass"
            )
            SunoRow(
                title: "The list stays on this Mac",
                subtitle: "It lives in a local file. Only the few entries that match what you just said travel with a dictation, so cleanup can apply them. Remove any entry above, or clear the lot.",
                systemImage: "lock",
                divider: false
            )
            Rule(strong: true)
        }
    }

    // MARK: About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "ear")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("SunoFlow")
                        .font(.system(size: 19, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Theme.ink)
                    Text("On-device dictation for macOS")
                        .font(.sunoCaption)
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 28)
            .padding(.bottom, 4)

            SectionLabel(text: "Version")
            Rule(strong: true)
            ValueRow(label: "Version", value: appVersion, mono: true)
            ValueRow(label: "Build", value: appBuild, mono: true, divider: false)
            Rule(strong: true)

            SectionLabel(text: "Resources")
            Rule(strong: true)
            SunoRow(
                title: "Diagnostic logs",
                subtitle: "Records audio levels and permission status. Never transcript contents.",
                divider: false
            ) {
                Button("View logs") { revealLogs() }
                    .buttonStyle(.sunoSecondary)
            }
            Rule(strong: true)
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
            DispatchQueue.main.async {
                polishOnline = ok
            }
        }
    }

    private func loadCorrections() {
        TranscriptionClient.fetchCorrections { items in
            DispatchQueue.main.async { corrections = items }
        }
    }

    // MARK: Engine actions

    private func startEngine() {
        // In a distributed app the supervisor owns the sidecar process. In dev
        // (no frozen binary) it's a no-op and the user runs the sidecar
        // manually — there's nothing for the button to do.
        startingEngine = true
        SidecarSupervisor.shared.ensureRunning()

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
}
