// PROTOTYPE — throwaway. The focusable answer popup + recording bubble for the
// Suno Answer G2 questions (docs/SUNO_ANSWER_RESEARCH.md §G2):
//   - A4: this panel CAN become key (unlike the dictation pill); PROTO_FOCUS
//     picks focus-on-appear vs click-to-focus.
//   - A10: dismissal = Esc / ✕ / click-outside / hotkey re-press, aborting work.
//   - A5: Insert hides the popup and pastes into the previously focused app.
//   - C6: source chips under the answer; D4: inline error card + Try again.
// This never ships — production draws its own panel informed by what we learn.

import AppKit

// MARK: - Focusable popup panel (deliberately NOT .nonactivatingPanel)

final class AnswerPopupWindow: NSPanel {
    static let size = NSSize(width: 400, height: 480)

    var onBecameKey: (() -> Void)?

    init(view: AnswerPanelView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: AnswerPopupWindow.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        contentView = view
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false              // the sheet's own layer carries the lift
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        onBecameKey?()
    }

    var panelView: AnswerPanelView? { contentView as? AnswerPanelView }

    func show(at anchor: NSPoint, clickToFocus: Bool) {
        place(near: anchor)
        alphaValue = 0
        orderFrontRegardless()
        if !clickToFocus {
            // Focus-on-appear: the panel is key the moment it exists, so typing
            // a follow-up works immediately.
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
            panelView?.focusInput()
        }
        // Click-to-focus: just order front; the click promotes it (see panelClicked).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
        })
    }

    private func place(near anchor: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = AnswerPopupWindow.size
        var x = anchor.x - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        var y = anchor.y + 20
        if y + size.height > visible.maxY - 8 {
            y = anchor.y - size.height - 20   // flip below the cursor near the top
        }
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Popup content: header, chat transcript, action row, follow-up input

final class AnswerPanelView: NSView {
    var onSend: ((String) -> Void)?
    var onRetry: (() -> Void)?
    var onInsert: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onPanelClicked: (() -> Void)?

    private let titleField = NSTextField(labelWithString: "Suno")
    private let statusLabel = NSTextField(labelWithString: "")
    private let chatScroll = NSScrollView()
    private let chatView = NSTextView()
    private let actionRow = NSStackView(views: [])
    private let input = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)

    private var thinkingRange: NSRange?
    private var errorRange: NSRange?
    private var retryAction: (() -> Void)?
    private var chipURLs: [URL] = []

    private var answerAttrs: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.sunoInk,
            .paragraphStyle: Self.para(spacing: 0, line: 2),
        ]
    }

    /// `Theme.accentSoft` has no NSColor mirror in Theme.swift (AppKit panels
    /// never needed it) — derived here, same trick as the suno* mirrors: from
    /// the SwiftUI token, not re-typed hex, so it can't drift.
    private static let accentSoftNS = NSColor(Theme.accentSoft)

    init() {
        super.init(frame: NSRect(origin: .zero, size: AnswerPopupWindow.size))
        applySunoPaper(cornerRadius: 14, lift: 10)

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .sunoInk
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .sunoFaint

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        glyph.contentTintColor = .sunoAccent

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = .sunoFaint
        close.toolTip = "Dismiss (Esc)"

        let header = NSStackView(views: [glyph, titleField, statusLabel, close])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        buildChat()
        buildActionRow()
        buildInputRow()

        let hint = NSTextField(labelWithString: "Esc dismiss · hotkey again · Insert pastes into your app")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .sunoFaint
        hint.alignment = .center

        for sub in [header, chatScroll, actionRow, input, sendButton, hint] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            chatScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            chatScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chatScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chatScroll.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -4),

            actionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            actionRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            actionRow.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -10),

            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            input.heightAnchor.constraint(equalToConstant: 30),
            input.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            sendButton.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            sendButton.centerYAnchor.constraint(equalTo: input.centerYAnchor),

            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    private func buildChat() {
        chatScroll.hasVerticalScroller = true
        chatScroll.drawsBackground = false
        chatScroll.borderType = .noBorder
        chatView.isEditable = false
        chatView.drawsBackground = false
        chatView.isVerticallyResizable = true
        chatView.isHorizontallyResizable = false
        chatView.autoresizingMask = [.width]
        chatView.textContainer?.widthTracksTextView = true
        chatView.textContainerInset = NSSize(width: 8, height: 6)
        chatView.minSize = .zero
        chatView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        chatScroll.documentView = chatView
    }

    private func buildActionRow() {
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 6
        actionRow.edgeInsets = NSEdgeInsets()
    }

    private func buildInputRow() {
        input.font = .systemFont(ofSize: 13)
        input.placeholderString = "Ask a follow-up…"
        input.target = self
        input.action = #selector(sendTapped)
        input.wantsLayer = true
        input.layer?.backgroundColor = NSColor.sunoWash.cgColor
        input.layer?.cornerRadius = 8

        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .small
        sendButton.font = .systemFont(ofSize: 11, weight: .semibold)
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
    }

    // MARK: actions

    override func mouseDown(with event: NSEvent) {
        onPanelClicked?()
        super.mouseDown(with: event)
    }

    @objc private func sendTapped() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.stringValue = ""
        onSend?(text)
    }

    @objc private func closeTapped() { onDismiss?() }

    @objc private func insertTapped() { onInsert?() }

    @objc private func copyTapped() { onCopy?() }

    @objc private func retryTapped() { retryAction?() }

    @objc private func chipTapped(_ sender: NSButton) {
        let index = sender.tag
        guard index >= 0, index < chipURLs.count else { return }
        NSWorkspace.shared.open(chipURLs[index])
    }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    // MARK: transcript

    private static func para(spacing: CGFloat, line: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacing
        p.lineSpacing = line
        return p
    }

    func reset() {
        chatView.string = ""
        thinkingRange = nil
        errorRange = nil
        retryAction = nil
        chipURLs = []
        setActions(.none)
        setStatus("")
    }

    func setStatus(_ text: String) { statusLabel.stringValue = text }

    /// The transient "Thinking…" line (also reused by the error card). Cleared
    /// by the next real content so history never keeps a stale placeholder.
    func showThinking() {
        clearTransient()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12).withItalic(),
            .foregroundColor: NSColor.sunoFaint,
            .paragraphStyle: Self.para(spacing: 14, line: 2),
        ]
        let text = NSAttributedString(string: "Thinking…", attributes: attrs)
        if let storage = chatView.textStorage {
            thinkingRange = NSRange(location: storage.length, length: text.length)
            storage.append(text)
        }
    }

    func addUserTurn(text: String, thumbnail: CGImage?) {
        clearTransient()
        let s = NSMutableAttributedString()
        if let cg = thumbnail {
            let attach = NSTextAttachment()
            attach.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let height: CGFloat = 92
            let aspect = CGFloat(cg.width) / max(1, CGFloat(cg.height))
            attach.bounds = CGRect(x: 0, y: 2, width: height * aspect, height: height)
            s.append(NSAttributedString(attachment: attach))
            s.append(NSAttributedString(string: "\n", attributes: [:]))
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.sunoInk,
            .backgroundColor: Self.accentSoftNS,
            .paragraphStyle: Self.para(spacing: 14, line: 2),
        ]
        s.append(NSAttributedString(string: text + "\n", attributes: attrs))
        chatView.textStorage?.append(s)
    }

    /// Deletes the transient marker right before the first answer token lands.
    func beginAnswer() {
        clearTransient()
    }

    func appendAnswer(_ chunk: String) {
        chatView.textStorage?.append(NSAttributedString(string: chunk, attributes: answerAttrs))
    }

    func endAnswer(sources: [String]) {
        chatView.textStorage?.append(NSAttributedString(string: "\n", attributes: answerAttrs))
        setActions(.answer(sources))
        scrollToBottom()
    }

    func showErrorCard(message: String, onRetry: @escaping () -> Void) {
        clearTransient()
        retryAction = onRetry
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.sunoInk,
            .backgroundColor: NSColor.sunoWash,
            .paragraphStyle: Self.para(spacing: 14, line: 2),
        ]
        let text = NSAttributedString(string: "⚠︎  " + message + "\n", attributes: attrs)
        if let storage = chatView.textStorage {
            errorRange = NSRange(location: storage.length, length: text.length)
            storage.append(text)
        }
        setActions(.error)
    }

    private func clearTransient() {
        guard let storage = chatView.textStorage else { return }
        if let r = thinkingRange { storage.deleteCharacters(in: r); thinkingRange = nil }
        if let r = errorRange { storage.deleteCharacters(in: r); errorRange = nil }
    }

    /// Keeps the newest content visible while tokens land.
    func scrollToBottom() {
        guard let layoutManager = chatView.layoutManager,
              let container = chatView.textContainer else { return }
        let used = layoutManager.usedRect(for: container)
        let bottom = NSRect(
            x: 0,
            y: max(0, used.maxY - chatView.frame.height + chatView.textContainerInset.height * 2),
            width: 1,
            height: chatView.frame.height
        )
        chatScroll.contentView.scrollToVisible(bottom)
    }

    // MARK: action row

    private enum ActionSet { case none, answer([String]), error }

    private func setActions(_ set: ActionSet) {
        actionRow.views.forEach { $0.removeFromSuperview() }
        chipURLs = []
        switch set {
        case .none:
            break
        case .error:
            actionRow.addArrangedSubview(actionButton("Try again", #selector(retryTapped)))
        case .answer(let sources):
            actionRow.addArrangedSubview(actionButton("Insert", #selector(insertTapped)))
            actionRow.addArrangedSubview(actionButton("Copy", #selector(copyTapped)))
            for (i, domain) in sources.enumerated() {
                let chip = actionButton("▸ " + domain, #selector(chipTapped(_:)))
                chip.tag = i
                chipURLs.append(URL(string: "https://" + domain)!)
                actionRow.addArrangedSubview(chip)
            }
        }
    }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 10.5, weight: .semibold)
        return b
    }
}

extension NSFont {
    func withItalic() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}

// MARK: - Recording bubble ("magic bubble" chrome, A7 — deliberately NOT the pill)

final class RecordingBubbleWindow: NSPanel {
    private let bubbleView: RecordingBubbleView

    init() {
        bubbleView = RecordingBubbleView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        contentView = bubbleView
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }

    func show(at anchor: NSPoint) {
        let x = anchor.x - 48
        let y = anchor.y + 28
        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
    }

    func update(level: Float) { bubbleView.update(level: level) }

    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
        })
    }
}

final class RecordingBubbleView: NSView {
    private let pulseA = CALayer()
    private let pulseB = CALayer()
    private let levelRing = CALayer()
    private var displayedLevel: Float = 0
    private var pulsesAttached = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer = layer else { return }
        layer.backgroundColor = NSColor.sunoInk.withAlphaComponent(0.94).cgColor
        layer.cornerRadius = frame.width / 2
        layer.borderWidth = 1
        layer.borderColor = NSColor.sunoRuleStrong.cgColor
        layer.shadowColor = NSColor.sunoInk.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: -3)

        for (sub, delay) in [(pulseA, 0.0), (pulseB, 0.7)] {
            sub.frame = bounds.insetBy(dx: 2, dy: 2)
            sub.cornerRadius = sub.bounds.width / 2
            sub.backgroundColor = NSColor.sunoAccent.cgColor
            sub.opacity = 0
            layer.addSublayer(sub)
            attachPulses(to: sub, delay: delay)
        }

        levelRing.frame = bounds.insetBy(dx: 2, dy: 2)
        levelRing.cornerRadius = levelRing.bounds.width / 2
        levelRing.borderColor = NSColor.sunoAccent.cgColor
        levelRing.borderWidth = 2
        levelRing.backgroundColor = NSColor.clear.cgColor
        layer.addSublayer(levelRing)

        let mic = NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!)
        mic.contentTintColor = NSColor.white
        mic.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        mic.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mic)
        NSLayoutConstraint.activate([
            mic.centerXAnchor.constraint(equalTo: centerXAnchor),
            mic.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// Two expanding accent rings, phase-offset — the "alive" tell that is
    /// clearly not the dictation pill's horizontal waveform.
    private func attachPulses(to sublayer: CALayer, delay: TimeInterval) {
        let t0 = CACurrentMediaTime() + delay
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.26
        scale.duration = 1.4
        scale.repeatCount = .infinity
        scale.beginTime = t0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.4
        fade.toValue = 0.0
        fade.duration = 1.4
        fade.repeatCount = .infinity
        fade.beginTime = t0
        sublayer.add(scale, forKey: "pulse.scale")
        sublayer.add(fade, forKey: "pulse.fade")
    }

    func update(level: Float) {
        // Light smoothing so the ring breathes instead of jittering.
        displayedLevel = displayedLevel * 0.7 + level * 0.3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelRing.borderWidth = 2 + CGFloat(displayedLevel) * 5
        layer?.setAffineTransform(CGAffineTransform(
            scaleX: 1 + CGFloat(displayedLevel) * 0.05,
            y: 1 + CGFloat(displayedLevel) * 0.05
        ))
        CATransaction.commit()
    }
}