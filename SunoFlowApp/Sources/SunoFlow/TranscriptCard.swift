import Cocoa

/// The floating card shown when a finished dictation has nowhere to go.
///
/// Dictation normally ends with a simulated Cmd+V into whatever is focused.
/// When nothing editable is focused that keystroke lands nowhere and the
/// transcript is gone — the user spoke a paragraph and got silence. Rather than
/// paste blindly, `AppDelegate` asks `FocusInspector` first and, when there is
/// no target, hands the text to this card: a sheet of paper at the bottom-centre
/// of the screen holding the whole transcript with one button that copies it.
///
/// It is drawn in the dashboard's design language, not as a system HUD: paper,
/// ink, hairline rules, one filled action, and the light appearance pinned the
/// way `SettingsWindowController` pins it. Every colour, size and easing comes
/// from `Theme` (see the `NSColor` mirrors there) so the card and the settings
/// sheet stay the same product.
///
/// Like `DictationOverlay` it lives in a `NonActivatingPanel`, so showing it
/// never steals focus. Unlike the overlay it accepts clicks — which is why the
/// views below all return true from `acceptsFirstMouse`: without that, the first
/// click on a panel belonging to an inactive app is swallowed as an activation
/// click and the button appears dead.
final class TranscriptCard {

    /// Why the text could not be typed. Sets the card's kicker and its glyph.
    enum Reason {
        /// Nothing editable was focused when the transcript arrived.
        case noFocus
        /// Accessibility permission is missing, so we cannot press Cmd+V at all.
        case noAccessibility
    }

    private var panel: NonActivatingPanel?
    private var card: CardView?
    private var visible = false

    private var dismissTimer: Timer?
    private var dismissDeadline: Date?
    private var dismissRemaining: TimeInterval = 0

    /// Width of the paper itself. The panel is wider — see `CardView.margin`.
    private let paperWidth: CGFloat = 468
    private let bottomGap: CGFloat = 28

    // MARK: - Presenting

    /// Shows `text` and offers to copy it. Safe to call while already visible —
    /// the card re-sizes to the new transcript rather than stacking.
    func present(_ text: String, reason: Reason) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if panel == nil { build() }
        guard let panel = panel, let card = card else { return }

        card.onCopy = { [weak self] in self?.copyAndFinish(trimmed) }
        card.onClose = { [weak self] in self?.dismiss() }
        card.onHoverChange = { [weak self] hovering in
            hovering ? self?.holdDismissal() : self?.resumeDismissal()
        }
        card.configure(text: trimmed, reason: reason)

        let target = panelFrame(paperHeight: card.fittingHeight(forPaperWidth: paperWidth))
        let wasVisible = visible
        visible = true

        if wasVisible {
            // A second failed dictation while the first is still up: grow or
            // shrink into the new text instead of flashing a fresh card.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20 // Theme.gentle
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
            card.playContentEntrance()
        } else {
            panel.setFrame(target, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20 // Theme.gentle
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            card.playEntrance()
        }

        scheduleDismissal(after: lifetime(for: trimmed))
    }

    /// Slides the card away. A no-op when nothing is showing.
    func dismiss() {
        cancelDismissal()
        guard let panel = panel, visible else { return }
        visible = false

        let down = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y - 12)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13 // Theme.quick
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(down)
        } completionHandler: {
            // A present() during the fade-out puts the card back up; in that
            // case this stale completion must not tear it down again.
            guard !self.visible else { return }
            panel.orderOut(nil)
        }
    }

    // MARK: - Copy

    private func copyAndFinish(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        AppLog.log("Transcript card: copied \(text.count) chars to the clipboard")

        cancelDismissal()
        card?.showCopied()
        // Long enough to read the confirmation, short enough not to linger.
        scheduleDismissal(after: 1.0)
    }

    // MARK: - Auto-dismissal

    /// How long the card stays up. Longer transcripts take longer to read, so
    /// they get more time — but never so much that the card feels stuck.
    private func lifetime(for text: String) -> TimeInterval {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return min(26, 11 + Double(words) * 0.35)
    }

    private func scheduleDismissal(after seconds: TimeInterval) {
        dismissTimer?.invalidate()
        dismissDeadline = Date().addingTimeInterval(seconds)
        dismissRemaining = seconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        card?.startCountdown(duration: seconds)
    }

    private func cancelDismissal() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissDeadline = nil
        card?.stopCountdown()
    }

    /// Pointer is over the card: the user is reading, so stop the clock.
    private func holdDismissal() {
        guard let deadline = dismissDeadline else { return }
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissRemaining = max(1.5, deadline.timeIntervalSinceNow)
        card?.pauseCountdown()
    }

    private func resumeDismissal() {
        guard dismissDeadline != nil, dismissTimer == nil, visible else { return }
        dismissDeadline = Date().addingTimeInterval(dismissRemaining)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: dismissRemaining, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        card?.resumeCountdown()
    }

    // MARK: - Building

    private func build() {
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: paperWidth + CardView.margin * 2, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The paper draws its own lift, inside a panel deliberately larger than
        // the card so that shadow has somewhere to fall.
        panel.hasShadow = false
        panel.isMovable = false
        // Same reasoning as the settings window: this palette was drawn light,
        // so pin the appearance instead of letting macOS invent a dark variant.
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let card = CardView(frame: panel.contentLayoutRect)
        card.autoresizingMask = [.width, .height]
        panel.contentView = card

        self.panel = panel
        self.card = card
    }

    private func panelFrame(paperHeight: CGFloat) -> NSRect {
        let margin = CardView.margin
        let size = NSSize(width: paperWidth + margin * 2, height: paperHeight + margin * 2)
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return NSRect(origin: .zero, size: size) }
        // visibleFrame excludes the Dock, so the paper sits just above it.
        let vf = screen.visibleFrame
        return NSRect(
            x: (vf.midX - size.width / 2).rounded(),
            y: (vf.minY + bottomGap - margin).rounded(),
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - The card

/// The paper: a kicker, a hairline, the transcript, a hairline that doubles as
/// the auto-dismiss clock, and the single filled action. The dashboard's own
/// grammar, at the size of an overlay.
private final class CardView: NSView {
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    /// Transparent breathing room around the paper for its shadow to fall into.
    /// The panel is this much larger than the card on every side.
    static let margin: CGFloat = 24

    private let paper = NSView()
    private let headerRow = NSView()
    private let glyph = NSImageView()
    private let kicker = NSTextField(labelWithString: "")
    private let close = IconButton(symbol: "xmark", pointSize: 9)
    private let headerRule = NSView()
    private let scroll = NSScrollView()
    private let transcript = NSTextView()
    private let footerRow = NSView()
    private let countdownTrack = NSView()
    private let countdownFill = CALayer()
    private let meta = NSTextField(labelWithString: "")
    private let copyButton = PillButton()
    private let fade = CAGradientLayer()

    private var trackingArea: NSTrackingArea?
    private var hovering = false

    // Geometry, laid out bottom-up in unflipped view coordinates. The spacing
    // is the dashboard's: a generous margin, hairlines doing the structure.
    private let pad = Theme.Space.lg          // 24 — the paper's side margin
    private let topPad: CGFloat = 14
    private let bottomPad: CGFloat = 14
    private let kickerHeight: CGFloat = 13
    private let kickerToRule: CGFloat = 10
    private let ruleToText: CGFloat = 13
    private let buttonHeight: CGFloat = 28
    private let buttonToRule: CGFloat = 11
    private let buttonWidth: CGFloat = 104
    /// Five and a half lines of transcript. The half is deliberate: a longer
    /// transcript then shows a clipped line under the fade, which is what tells
    /// you there is more to scroll. A clean cut at five would just look short.
    private let maxTranscriptHeight: CGFloat = 104
    private let cornerRadius: CGFloat = 12

    /// `Font.sunoBody` and `Font.sunoKicker`, in AppKit.
    private let bodyFont = NSFont.systemFont(ofSize: 13)
    private let kickerFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private lazy var bodyParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3.5 // generous rhythm, same as the sheet's rows
        return style
    }()

    /// Header row = the rule plus the kicker line sitting above it.
    private var headerRowHeight: CGFloat { 1 + kickerToRule + kickerHeight }
    /// Footer row = the action line plus the countdown rule above it.
    private var footerRowHeight: CGFloat { buttonHeight + buttonToRule + 1 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setup()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Clicks in the margin are not ours — let them reach the app underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard paper.frame.contains(point) else { return nil }
        return super.hitTest(point)
    }

    private func setup() {
        paper.applySunoPaper(cornerRadius: cornerRadius, lift: 14)
        addSubview(paper)

        // Header: the kicker that says why the card is here, and a way out.
        headerRow.wantsLayer = true
        paper.addSubview(headerRow)

        glyph.imageScaling = .scaleNone
        headerRow.addSubview(glyph)

        kicker.font = kickerFont
        kicker.textColor = .sunoFaint
        kicker.lineBreakMode = .byTruncatingTail
        headerRow.addSubview(kicker)

        close.onClick = { [weak self] in self?.onClose?() }
        close.toolTip = "Dismiss"
        headerRow.addSubview(close)

        headerRule.wantsLayer = true
        headerRule.layer?.backgroundColor = NSColor.sunoRuleStrong.cgColor
        headerRow.addSubview(headerRule)

        // Transcript: readable and scrollable, never selectable — a panel that
        // cannot become key cannot host a text selection anyway, and the copy
        // button is the affordance that matters here.
        transcript.isEditable = false
        transcript.isSelectable = false
        transcript.drawsBackground = false
        transcript.textContainerInset = .zero
        transcript.textContainer?.lineFragmentPadding = 0
        transcript.textContainer?.widthTracksTextView = true
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false

        scroll.documentView = transcript
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.wantsLayer = true
        paper.addSubview(scroll)

        // Footer: how much was said, and the one filled action on this card.
        footerRow.wantsLayer = true
        paper.addSubview(footerRow)

        // The auto-dismiss clock. Rather than hang a progress bar off the card,
        // the hairline that closes the transcript *is* the clock: a rule that
        // empties rightward, the same way SunoProgressBar fills.
        countdownTrack.wantsLayer = true
        countdownTrack.layer?.backgroundColor = NSColor.sunoRule.cgColor
        countdownFill.backgroundColor = NSColor.sunoAccent.cgColor
        countdownFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        countdownTrack.layer?.addSublayer(countdownFill)
        footerRow.addSubview(countdownTrack)

        meta.font = .systemFont(ofSize: 12) // Font.sunoCaption
        meta.textColor = .sunoFaint
        meta.lineBreakMode = .byTruncatingTail
        footerRow.addSubview(meta)

        copyButton.onClick = { [weak self] in self?.onCopy?() }
        footerRow.addSubview(copyButton)

        fade.colors = [NSColor.white.cgColor, NSColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0.18)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
    }

    // MARK: - Content

    func configure(text: String, reason: TranscriptCard.Reason) {
        kicker.attributedStringValue = NSAttributedString(
            string: reason.kicker.uppercased(),
            attributes: [
                .font: kickerFont,
                .foregroundColor: NSColor.sunoFaint,
                .kern: 0.8, // SectionLabel's tracking
            ]
        )
        glyph.image = NSImage(
            systemSymbolName: reason.symbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        glyph.contentTintColor = reason.glyphColor

        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        meta.stringValue = reason.footnote ?? (words == 1 ? "1 word" : "\(words) words")
        meta.sizeToFit()

        transcript.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.sunoInk,
                .paragraphStyle: bodyParagraph,
            ])
        )
        transcript.scroll(NSPoint(x: 0, y: 0))
        copyButton.reset(title: "Copy text", symbol: nil, fill: .sunoInk)
        needsLayout = true
    }

    /// The paper height that fits the current transcript at `width`.
    func fittingHeight(forPaperWidth width: CGFloat) -> CGFloat {
        let chrome = topPad + headerRowHeight + ruleToText * 2 + footerRowHeight + bottomPad
        return (chrome + transcriptHeight(forPaperWidth: width)).rounded()
    }

    private func transcriptHeight(forPaperWidth width: CGFloat) -> CGFloat {
        let text = transcript.string
        guard !text.isEmpty else { return bodyFont.boundingRectForFont.height }
        let available = NSSize(width: width - pad * 2, height: .greatestFiniteMagnitude)
        let measured = (text as NSString).boundingRect(
            with: available,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: bodyFont, .paragraphStyle: bodyParagraph]
        ).height
        return min(max(ceil(measured), bodyFont.boundingRectForFont.height), maxTranscriptHeight)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        paper.frame = bounds.insetBy(dx: CardView.margin, dy: CardView.margin)

        let width = paper.bounds.width
        let height = paper.bounds.height
        let contentWidth = width - pad * 2

        // Footer: the action line, with the countdown rule closing the text above it.
        footerRow.frame = NSRect(x: pad, y: bottomPad, width: contentWidth, height: footerRowHeight)
        copyButton.frame = NSRect(
            x: contentWidth - buttonWidth, y: 0, width: buttonWidth, height: buttonHeight
        )
        meta.frame = NSRect(
            x: 0, y: ((buttonHeight - meta.frame.height) / 2).rounded(),
            width: max(0, contentWidth - buttonWidth - 12), height: meta.frame.height
        )
        countdownTrack.frame = NSRect(x: 0, y: footerRowHeight - 1, width: contentWidth, height: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        countdownFill.bounds = CGRect(x: 0, y: 0, width: contentWidth, height: 1)
        countdownFill.position = CGPoint(x: 0, y: 0.5)
        CATransaction.commit()

        // Header: the kicker, and the rule that opens the transcript.
        let headerY = height - topPad - headerRowHeight
        headerRow.frame = NSRect(x: pad, y: headerY, width: contentWidth, height: headerRowHeight)
        headerRule.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        let kickerY = headerRowHeight - kickerHeight
        if let size = glyph.image?.size {
            glyph.frame = NSRect(
                x: 0, y: (kickerY + (kickerHeight - size.height) / 2).rounded(),
                width: size.width, height: size.height
            )
        }
        // The glyph reserves a fixed column, the way SunoRow does, so the kicker
        // starts at the same x whichever symbol is showing.
        let kickerX: CGFloat = 19
        kicker.frame = NSRect(
            x: kickerX, y: kickerY,
            width: max(0, contentWidth - kickerX - 28), height: kickerHeight
        )
        close.frame = NSRect(
            x: contentWidth - 22, y: (kickerY + (kickerHeight - 22) / 2).rounded(),
            width: 22, height: 22
        )

        // Transcript fills what is left between the two rules.
        let textY = bottomPad + footerRowHeight + ruleToText
        let textHeight = headerY - ruleToText - textY
        scroll.frame = NSRect(x: pad, y: textY, width: contentWidth, height: max(0, textHeight))
        transcript.minSize = NSSize(width: 0, height: 0)
        transcript.maxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        transcript.frame.size.width = contentWidth
        transcript.textContainer?.containerSize = NSSize(
            width: contentWidth, height: .greatestFiniteMagnitude
        )

        updateFadeMask()
        updateTracking()
    }

    /// Fades the last line of the transcript only while there is more to scroll,
    /// so a clipped line reads as "keep going" rather than as a mistake.
    private func updateFadeMask() {
        if transcript.frame.height - scroll.contentSize.height > 1 {
            fade.frame = scroll.bounds
            scroll.layer?.mask = fade
        } else {
            scroll.layer?.mask = nil
        }
    }

    private func updateTracking() {
        if let existing = trackingArea { removeTrackingArea(existing) }
        // Tracked over the paper only, not the shadow margin. .activeAlways:
        // SunoFlow is not the active app while this is up, and without it the
        // card would never see the pointer arrive.
        let area = NSTrackingArea(
            rect: paper.frame,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !hovering else { return }
        hovering = true
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard hovering else { return }
        hovering = false
        onHoverChange?(false)
    }

    // MARK: - Animation

    /// The full arrival: the paper settles up into place while its rows rise in.
    /// `Theme.spring` is near-critically damped, so this lands rather than
    /// bounces — the sheet's restraint, in motion.
    func playEntrance() {
        guard let layer = paper.layer else { return }
        let settle = CASpringAnimation(keyPath: "transform")
        var from = CATransform3DMakeTranslation(0, -22, 0)
        from = CATransform3DScale(from, 0.985, 0.985, 1)
        settle.fromValue = NSValue(caTransform3D: from)
        settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        settle.mass = Theme.Spring.mass
        settle.stiffness = Theme.Spring.stiffness
        settle.damping = Theme.Spring.damping
        settle.duration = settle.settlingDuration
        layer.add(settle, forKey: "arrive")

        playContentEntrance()
    }

    /// The rows only, for when the card is already on screen.
    func playContentEntrance() {
        for (index, view) in [headerRow, scroll, footerRow].enumerated() {
            guard let layer = view.layer else { continue }
            let start = CACurrentMediaTime() + 0.035 * Double(index)

            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -7
            rise.toValue = 0
            rise.duration = 0.20 // Theme.gentle
            rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
            rise.beginTime = start
            rise.fillMode = .backwards
            layer.add(rise, forKey: "rise")

            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.20 // Theme.gentle
            appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
            appear.beginTime = start
            appear.fillMode = .backwards
            layer.add(appear, forKey: "appear")
        }
    }

    /// The copy button's confirmation state — success is one of the three
    /// semantic colours, used here for one second of exactly one thing.
    func showCopied() {
        copyButton.morph(title: "Copied", symbol: "checkmark", fill: .sunoSuccess)
    }

    // MARK: - Countdown

    func startCountdown(duration: TimeInterval) {
        countdownFill.removeAnimation(forKey: "drain")
        countdownFill.speed = 1
        countdownFill.timeOffset = 0
        countdownFill.beginTime = 0

        let drain = CABasicAnimation(keyPath: "transform.scale.x")
        drain.fromValue = 1
        drain.toValue = 0
        drain.duration = duration
        drain.timingFunction = CAMediaTimingFunction(name: .linear)
        drain.fillMode = .forwards
        drain.isRemovedOnCompletion = false
        countdownFill.add(drain, forKey: "drain")
    }

    func stopCountdown() {
        countdownFill.removeAnimation(forKey: "drain")
        countdownFill.speed = 1
        countdownFill.timeOffset = 0
        countdownFill.beginTime = 0
    }

    func pauseCountdown() {
        guard countdownFill.speed != 0 else { return }
        let paused = countdownFill.convertTime(CACurrentMediaTime(), from: nil)
        countdownFill.speed = 0
        countdownFill.timeOffset = paused
    }

    func resumeCountdown() {
        guard countdownFill.speed == 0 else { return }
        let paused = countdownFill.timeOffset
        countdownFill.speed = 1
        countdownFill.timeOffset = 0
        countdownFill.beginTime = 0
        countdownFill.beginTime = countdownFill.convertTime(CACurrentMediaTime(), from: nil) - paused
    }
}

private extension TranscriptCard.Reason {
    /// The small capitalised label that opens the card, as `SectionLabel` does
    /// on the sheet.
    var kicker: String {
        switch self {
        case .noFocus: return "Nowhere to paste"
        case .noAccessibility: return "Couldn't paste"
        }
    }

    var symbol: String {
        switch self {
        case .noFocus: return "waveform"
        case .noAccessibility: return "lock"
        }
    }

    var glyphColor: NSColor {
        switch self {
        // The accent marks this as SunoFlow's own; warning marks a thing the
        // user has to go and fix.
        case .noFocus: return .sunoAccent
        case .noAccessibility: return .sunoWarning
        }
    }

    /// Replaces the word count when there is something more useful to say.
    var footnote: String? {
        switch self {
        case .noFocus: return nil
        case .noAccessibility: return "Grant Accessibility to paste automatically"
        }
    }
}

// MARK: - Controls

/// The one filled action on the card — `SunoPrimaryButtonStyle` in AppKit.
/// Hand-rolled rather than an `NSButton` so it can be clicked while the app is
/// inactive, hover without a key window, and morph into its confirmed state.
private final class PillButton: NSView {
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var fill: NSColor = .sunoInk
    private var hovering = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        addSubview(icon)
        addSubview(label)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init() { self.init(frame: .zero) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Sets the button's look with no animation — used when a new transcript
    /// reuses the card and the button must start over as "Copy text".
    func reset(title: String, symbol: String?, fill: NSColor) {
        self.fill = fill
        label.stringValue = title
        setAccessibilityLabel(title)
        icon.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
        }
        icon.contentTintColor = .white
        label.alphaValue = 1
        icon.alphaValue = 1
        applyFill(animated: false)
        needsLayout = true
    }

    /// Crossfades into a new state, so the copy reads as done.
    func morph(title: String, symbol: String?, fill: NSColor) {
        self.fill = fill
        applyFill(animated: true)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.09
            label.animator().alphaValue = 0
            icon.animator().alphaValue = 0
        } completionHandler: {
            self.label.stringValue = title
            self.setAccessibilityLabel(title)
            self.icon.image = symbol.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10.5, weight: .semibold))
            }
            self.layoutContents()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.13 // Theme.quick
                self.label.animator().alphaValue = 1
                self.icon.animator().alphaValue = 1
            }
        }
    }

    private func applyFill(animated: Bool) {
        // Ink, raised on hover, dimmed on press — SunoPrimaryButtonStyle exactly.
        let base = hovering && fill == .sunoInk ? NSColor.sunoInkRaised : fill
        let target = base.withAlphaComponent(pressed ? 0.9 : 1).cgColor
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.backgroundColor = target
            CATransaction.commit()
            return
        }
        let change = CABasicAnimation(keyPath: "backgroundColor")
        change.fromValue = layer?.backgroundColor
        change.toValue = target
        change.duration = 0.13 // Theme.quick
        layer?.add(change, forKey: "tint")
        layer?.backgroundColor = target
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layoutContents()
        updateTracking()
    }

    private func layoutContents() {
        label.sizeToFit()
        let iconSize = icon.image?.size ?? .zero
        let gap: CGFloat = iconSize.width > 0 ? 6 : 0
        let total = iconSize.width + gap + label.frame.width
        let startX = ((bounds.width - total) / 2).rounded()
        icon.frame = NSRect(
            x: startX, y: ((bounds.height - iconSize.height) / 2).rounded(),
            width: iconSize.width, height: iconSize.height
        )
        label.frame = NSRect(
            x: startX + iconSize.width + gap,
            y: ((bounds.height - label.frame.height) / 2).rounded(),
            width: label.frame.width, height: label.frame.height
        )
    }

    private func updateTracking() {
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyFill(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressed = false
        applyFill(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        applyFill(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        applyFill(animated: true)
        if inside { onClick?() }
    }
}

/// A small glyph button — the card's dismiss control, styled like the sheet's
/// row-level icon buttons: faint until you reach for it.
private final class IconButton: NSView {
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(symbol: String, pointSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Dismiss")?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        icon.contentTintColor = .sunoFaint
        icon.imageScaling = .scaleNone
        addSubview(icon)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Dismiss")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        if let size = icon.image?.size {
            icon.frame = NSRect(
                x: ((bounds.width - size.width) / 2).rounded(),
                y: ((bounds.height - size.height) / 2).rounded(),
                width: size.width, height: size.height
            )
        }
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyHover()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyHover()
    }

    private func applyHover() {
        icon.contentTintColor = hovering ? .sunoInk : .sunoFaint
        layer?.backgroundColor = hovering ? NSColor.sunoWash.cgColor : NSColor.clear.cgColor
    }

    /// Claims the click so the matching mouseUp is delivered here.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
