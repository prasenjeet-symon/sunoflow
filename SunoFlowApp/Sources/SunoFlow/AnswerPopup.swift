// The Suno Answer popup: a focusable chat panel anchored at the cursor, plus
// the "magic bubble" recording indicator (docs/SUNO_ANSWER_RESEARCH.md):
//   - A4: this panel CAN become key (unlike the dictation pill) — it takes
//     focus the moment it appears, so a typed follow-up works immediately.
//   - A10: dismissal = Esc / ✕ / click-outside / hotkey re-press, aborting work.
//   - A5: Insert hides the popup and pastes into the previously focused app.
//   - C6: source chips under the answer; D4: inline error card + Try again.

import AppKit
import WebKit

// MARK: - Focusable popup panel (deliberately NOT .nonactivatingPanel)

final class AnswerPopupWindow: NSPanel {
    static let size = NSSize(width: 400, height: 480)
    /// The minimized peek: same width, cropped to a few lines of the latest
    /// answer plus the header (which keeps the drag handle and the restore
    /// control).
    static let minimizedSize = NSSize(width: 400, height: 208)

    private(set) var isMinimized = false

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

    var panelView: AnswerPanelView? { contentView as? AnswerPanelView }

    /// Focus-on-appear — the panel is key the moment it exists, so typing a
    /// follow-up works immediately. (A click that lands while it is not yet
    /// key still promotes it; see `AnswerFlow.panelClicked`.)
    ///
    /// Entrance: the same near-critically-damped spring settle the dictation
    /// pill uses — the sheet drops the last few points into place while it
    /// fades up. One motion idea, shared across every floating surface.
    func show(at anchor: NSPoint) {
        // A new session always opens expanded, whatever state the last one left.
        if isMinimized {
            isMinimized = false
            panelView?.setMinimized(false)
        }
        setContentSize(AnswerPopupWindow.size)
        place(near: anchor)
        alphaValue = 0
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        panelView?.focusInput()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Timing.gentle
            animator().alphaValue = 1
        }
        if let layer = panelView?.layer {
            let settle = CASpringAnimation(keyPath: "transform")
            settle.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 12, 0))
            settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            settle.mass = Theme.Spring.mass
            settle.stiffness = Theme.Spring.stiffness
            settle.damping = Theme.Spring.damping
            settle.duration = settle.settlingDuration
            layer.add(settle, forKey: "arrive")
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

    // MARK: minimize / restore

    @objc func toggleMinimize() { setMinimized(!isMinimized) }

    /// Collapse to the latest-answer peek, or restore the full sheet. The top
    /// edge is held fixed so the header stays put and the body grows/shrinks
    /// beneath it.
    ///
    /// On collapse the window is NOT snapped to a fixed size: once the page
    /// reports the compact answer's height, `fitMinimizedHeight` sizes the
    /// window to exactly fit it (so a short answer gets a short card, a long one
    /// a taller card — never a cropped, scrolling one). Restoring goes straight
    /// back to the full sheet.
    func setMinimized(_ minimized: Bool) {
        guard minimized != isMinimized else { return }
        isMinimized = minimized
        panelView?.setMinimized(minimized)
        if !minimized {
            setFrameKeepingTop(AnswerPopupWindow.size, animated: true)
        }
        // Collapse: the fit is driven by the measured content height, arriving
        // via panelView.onHeightChanged → fitMinimizedHeight, so the collapse is
        // a single animation straight to the answer's size.
    }

    /// Size the minimized window to fit `contentDrivenHeight`, clamped so it
    /// never exceeds the full sheet (or runs off screen); beyond that the peek
    /// scrolls. A large change (the initial collapse) animates; the small
    /// growth of a streaming answer snaps, so the card grows smoothly without a
    /// stutter of overlapping animations.
    func fitMinimizedHeight(_ contentDrivenHeight: CGFloat) {
        guard isMinimized else { return }
        let ceiling = min(AnswerPopupWindow.size.height,
                          ((screen ?? NSScreen.main)?.visibleFrame.height ?? 800) - 40)
        let h = min(max(contentDrivenHeight, 110), ceiling)
        guard abs(h - frame.height) > 0.5 else { return }
        setFrameKeepingTop(NSSize(width: AnswerPopupWindow.minimizedSize.width, height: h),
                           animated: abs(h - frame.height) > 40)
    }

    /// Resize the window while holding its top edge fixed, then clamp back onto
    /// the screen.
    private func setFrameKeepingTop(_ size: NSSize, animated: Bool) {
        var f = frame
        let topEdge = f.maxY
        f.size = size
        f.origin.y = topEdge - size.height
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            f.origin.y = min(max(f.origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Theme.Timing.gentle
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                animator().setFrame(f, display: true)
            }, completionHandler: { [weak self] in
                self?.panelView?.repaintTranscript()
            })
        } else {
            setFrame(f, display: true)
            panelView?.repaintTranscript()
        }
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
    /// The input row's mic button was clicked (start / stop a dictated follow-up).
    var onMicToggle: (() -> Void)?

    private let titleField = NSTextField(labelWithString: "Suno")
    private let statusLabel = NSTextField(labelWithString: "")
    private let chatScroll = NSScrollView()
    /// The transcript itself: a local WKWebView page (AnswerWebBridge) that
    /// renders voice bubbles, Markdown and KaTeX. Native chrome — header,
    /// action row, input — stays AppKit around it.
    private let web = AnswerWebBridge()
    private let actionRow = NSStackView(views: [])
    /// The follow-up mic, built into the input row (2026-09-05): quiet glyph
    /// at rest, accent capsule + pulse rings while recording.
    private let micBadge = MicBadgeView()
    /// Padded so the text and caret clear the well's rounded corner instead of
    /// touching it — the AppKit twin of `SunoFieldStyle`'s horizontal inset.
    private let input = PaddedTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    /// The affordances line under the input. A field so `setMinimized` can hide
    /// it with the rest of the input chrome.
    private let hint = NSTextField(labelWithString: "Esc to dismiss   ·   mic or hotkey for a follow-up   ·   Insert to paste")
    /// The hairline that closes the transcript zone and anchors the input row
    /// — the dashboard's structural device, one rule doing the work.
    private let hairline = NSView()
    /// The rule under the header: it brackets the transcript with the input's
    /// hairline so the header reads as a compact titlebar — structure from
    /// hairlines, not boxes, the way the dashboard frames a section.
    private let headerRule = NSView()
    /// A status dot ahead of the status word — accent while working, success at
    /// rest, warning once stopped. Colour and a dot, never a capsule; the
    /// AppKit twin of the sheet's `StatusText`.
    private let statusDot = NSView()
    /// Collapse to / expand from the latest-answer peek. Its glyph flips with
    /// the state.
    private let minimizeButton = NSButton()
    /// The header doubles as a title bar: dragging it moves the whole window.
    private let dragHandle = HeaderDragView()

    /// The transcript's bottom edge in each state — full pins above the action
    /// row, minimized pins near the window's bottom (the action row, input and
    /// hint are hidden). Exactly one is active at a time.
    private var fullBottomConstraint: NSLayoutConstraint!
    private var minimizedBottomConstraint: NSLayoutConstraint!

    private var retryAction: (() -> Void)?
    private var chipURLs: [URL] = []
    private var sendHovering = false

    /// The height the page currently wants (set by the bridge as the DOM
    /// grows). The chat area is at least one bubble tall and grows with the
    /// page until the fixed panel size is reached; beyond that the scroll
    /// takes over.
    private var webHeight: NSLayoutConstraint!

    init() {
        super.init(frame: NSRect(origin: .zero, size: AnswerPopupWindow.size))
        applySunoPaper(cornerRadius: 14, lift: 10)
        micBadge.onToggle = { [weak self] in self?.onMicToggle?() }

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .sunoInk
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .sunoFaint

        // A 6pt dot, hidden until there is a status to colour. It rides in the
        // header stack right before the word, so the two move together.
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = NSColor.sunoAccent.cgColor
        statusDot.isHidden = true
        statusDot.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),
        ])

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        glyph.contentTintColor = .sunoAccent

        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = .sunoFaint
        close.toolTip = "Dismiss (Esc)"

        minimizeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Minimize")
        minimizeButton.isBordered = false
        minimizeButton.imagePosition = .imageOnly
        minimizeButton.contentTintColor = .sunoFaint
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizeTapped)
        minimizeButton.toolTip = "Minimize to the latest answer"
        minimizeButton.setAccessibilityLabel("Minimize")

        // The ✕ is a sibling pinned to the far edge, not a stack member: the
        // status label's width swings ("Ready", "Answering…", "Listening…")
        // and used to drag the button along with it.
        let header = NSStackView(views: [glyph, titleField, statusDot, statusLabel])
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        // The dot hugs its word; the word group sits a touch clear of the title.
        header.setCustomSpacing(9, after: titleField)
        header.setCustomSpacing(5, after: statusDot)

        buildChat()
        buildActionRow()
        buildInputRow()

        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .sunoFaint
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail

        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.sunoRule.cgColor
        hairline.setContentHuggingPriority(.defaultLow, for: .horizontal)

        headerRule.wantsLayer = true
        headerRule.layer?.backgroundColor = NSColor.sunoRule.cgColor
        headerRule.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Order matters: the drag handle sits above the header labels (so the
        // title band grabs the window) but below the buttons (so ✕ / minimize
        // still take their clicks).
        for sub in [header, dragHandle, close, minimizeButton, headerRule, chatScroll, hairline, actionRow, micBadge, input, sendButton, hint] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }

        // One page margin governs every full-width edge (header, rules, action
        // row, input); the transcript sits a hair inside it so the bubbles'
        // own gutters line the prose up with the chrome.
        let margin: CGFloat = 16

        // The transcript's bottom differs by state; build both, activate full.
        fullBottomConstraint = chatScroll.bottomAnchor.constraint(equalTo: actionRow.topAnchor, constant: -6)
        minimizedBottomConstraint = chatScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),

            // The drag handle covers the whole title band, behind the buttons.
            dragHandle.topAnchor.constraint(equalTo: topAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHandle.bottomAnchor.constraint(equalTo: headerRule.topAnchor),

            // ✕ pinned to the far right; minimize just inside it. The header
            // labels stay clear of the minimize button whatever the status
            // word's width. All three share the header's vertical centre.
            minimizeButton.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 8),
            minimizeButton.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            minimizeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(margin - 4)),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            // The header's closing rule — the transcript's top edge.
            headerRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            headerRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            headerRule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            headerRule.heightAnchor.constraint(equalToConstant: 1),

            chatScroll.topAnchor.constraint(equalTo: headerRule.bottomAnchor, constant: 10),
            chatScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin - 6),
            chatScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(margin - 6)),
            fullBottomConstraint,

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            hairline.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -12),

            actionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            actionRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margin),
            actionRow.bottomAnchor.constraint(equalTo: hairline.topAnchor, constant: -12),

            micBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: margin),
            micBadge.centerYAnchor.constraint(equalTo: input.centerYAnchor),
            input.leadingAnchor.constraint(equalTo: micBadge.trailingAnchor, constant: 10),
            input.heightAnchor.constraint(equalToConstant: 34),
            input.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -11),
            sendButton.leadingAnchor.constraint(equalTo: input.trailingAnchor, constant: 10),
            sendButton.widthAnchor.constraint(equalToConstant: 60),
            sendButton.heightAnchor.constraint(equalToConstant: 28),
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -margin),
            sendButton.centerYAnchor.constraint(equalTo: input.centerYAnchor),

            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: margin),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -margin),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    private func buildChat() {
        chatScroll.hasVerticalScroller = true
        chatScroll.drawsBackground = false
        chatScroll.borderType = .noBorder
        // Overlay + auto-hide: the scroller only appears while actively
        // scrolling, so the minimized peek (sized to fit its answer) shows no
        // scroll bar at all.
        chatScroll.scrollerStyle = .overlay
        chatScroll.autohidesScrollers = true

        // Watch the clip so a manual scroll can release (or re-pin) the
        // follow-the-bottom behaviour; see `clipBoundsChanged`.
        chatScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: chatScroll.contentView)

        // The bridge reports the page's height as it grows; this constraint is
        // that height, clamped so the document never collapses below one
        // bubble (which would anchor the first bubble against the clip's
        // bottom). The document (below) is exactly as tall as the web view,
        // so driving this one constant drives the whole scroll content.
        webHeight = web.view.heightAnchor.constraint(equalToConstant: 40)
        web.onHeightChanged = { [weak self] h in
            guard let self else { return }
            self.webHeight.constant = max(h, 44)
            if let win = self.window as? AnswerPopupWindow, win.isMinimized {
                // Minimized: the window grows/shrinks to fit the latest answer,
                // so it shows in full with no scroll bar. No follow-to-bottom —
                // the peek reads from the top.
                win.fitMinimizedHeight(self.minimizedPanelHeight(forContentHeight: max(h, 44)))
            } else {
                // Full: apply the new height, then follow it to the bottom if we
                // are still pinned there. The scroll forces a layout pass first,
                // so it lands on the just-grown height rather than the stale one
                // — the race that used to strand streaming answers.
                self.scrollToBottomIfNeeded(force: false)
            }
        }
        web.view.translatesAutoresizingMaskIntoConstraints = false

        // The document is a flipped wrapper exactly as tall as the page; the
        // scroll view takes over when the content outgrows the fixed panel.
        // Width: the document matches the clip view's width — the transcript
        // always fills the visible width at any scroll offset.
        let doc = FlippedDocumentView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(web.view)
        chatScroll.documentView = doc

        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: chatScroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: chatScroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: chatScroll.contentView.widthAnchor),
            doc.heightAnchor.constraint(equalTo: web.view.heightAnchor),

            web.view.topAnchor.constraint(equalTo: doc.topAnchor),
            web.view.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            web.view.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            web.view.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            webHeight,
        ])
    }

    /// Whether the transcript is pinned to the bottom and should follow new
    /// content. It starts pinned; a manual scroll up releases it and scrolling
    /// back to the bottom re-pins. Content growth alone never changes it — that
    /// is the point: a streaming answer keeps following unless the user chooses
    /// to scroll away to read an earlier turn.
    private var stickToBottom = true
    /// Set around our own `scroll(to:)` so the bounds change it triggers is not
    /// mistaken for a user scroll.
    private var programmaticScroll = false
    private var scrollScheduled = false

    /// A user scroll decides whether to keep following: release when they move
    /// up, re-pin when they return to the bottom. Guarded against our own
    /// programmatic scrolls.
    @objc private func clipBoundsChanged() {
        guard !programmaticScroll else { return }
        stickToBottom = atScrollBottom
    }

    /// Keep the newest turn on screen. `force` re-pins first (a turn the user
    /// just authored should always come into view); otherwise it follows only
    /// while pinned. Debounced to one scroll per runloop tick — answer deltas
    /// arrive faster than the height round-trips — and it forces a layout pass
    /// before measuring so it lands on the just-grown height, not the stale one.
    private func scrollToBottomIfNeeded(force: Bool) {
        if force { stickToBottom = true }
        guard stickToBottom, !scrollScheduled else { return }
        scrollScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollScheduled = false
            guard self.stickToBottom, self.chatScroll.superview != nil else { return }
            self.layoutSubtreeIfNeeded()      // apply the pending webHeight first
            let clip = self.chatScroll.contentView
            guard let doc = self.chatScroll.documentView,
                  doc.frame.height > clip.bounds.height else { return }
            self.programmaticScroll = true
            clip.scroll(to: NSPoint(x: 0, y: doc.frame.height - clip.bounds.height))
            self.chatScroll.reflectScrolledClipView(clip)
            self.programmaticScroll = false
        }
    }

    /// Bring the top of the transcript into view — used when the panel shrinks
    /// to its minimized peek, so the latest answer reads from its first line.
    private func scrollToTop() {
        stickToBottom = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.chatScroll.superview != nil else { return }
            self.layoutSubtreeIfNeeded()
            let clip = self.chatScroll.contentView
            self.programmaticScroll = true
            clip.scroll(to: NSPoint(x: 0, y: 0))
            self.chatScroll.reflectScrolledClipView(clip)
            self.programmaticScroll = false
        }
    }

    /// True when the clip shows the last of the document (within a few points,
    /// so "close enough to the bottom" still counts as pinned).
    private var atScrollBottom: Bool {
        guard let doc = chatScroll.documentView else { return true }
        let clip = chatScroll.contentView.bounds
        return clip.maxY >= doc.frame.height - 8
    }

    private func buildActionRow() {
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 6
        actionRow.edgeInsets = NSEdgeInsets()
    }

    private func buildInputRow() {
        // The follow-up field as the dashboard styles a text field: a soft
        // wash well with no border and no focus ring — focus is announced by
        // the well darkening one step (Theme.quick), never by a ring.
        input.font = .systemFont(ofSize: 13)
        input.placeholderString = "Ask a follow-up…"
        input.textColor = .sunoInk
        input.backgroundColor = .clear
        input.drawsBackground = false
        input.isBordered = false
        input.focusRingType = .none
        input.target = self
        input.action = #selector(sendTapped)
        input.wantsLayer = true
        input.layer?.backgroundColor = NSColor.sunoWash.cgColor
        input.layer?.cornerRadius = 9
        if let cell = input.cell as? NSTextFieldCell {
            cell.placeholderAttributedString = NSAttributedString(
                string: "Ask a follow-up…",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.sunoFaint,
                ])
        }

        // The single filled action on the sheet: solid ink capsule, white
        // label — SunoPrimaryButtonStyle's AppKit twin. Hover deepens to
        // inkRaised; empty input holds it at the disabled opacity.
        sendButton.title = "Send"
        sendButton.isBordered = false
        sendButton.wantsLayer = true
        sendButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        sendButton.contentTintColor = .white
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        styleSend(active: false, hover: false)
        sendButton.layer?.cornerRadius = 14
        sendButton.setAccessibilityLabel("Send follow-up")
        sendButton.setAccessibilityRole(.button)

        // Empty field = resting CTA; typing lights it up (Theme.quick).
        sendHoverPad = NSHoverPad(area: NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: ["send": true]))
        sendButton.addSubview(sendHoverPad)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fieldEdited),
            name: NSControl.textDidChangeNotification, object: input)
        setSendEnabled(false)
    }

    private var sendHoverPad: NSHoverPad!

    @objc private func fieldEdited(_ note: Notification) {
        let has = !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        setSendEnabled(has)
    }

    // MARK: actions

    override func mouseDown(with event: NSEvent) {
        onPanelClicked?()
        super.mouseDown(with: event)
    }

    /// Dragging on the sheet's own background (the paper around the controls,
    /// not the transcript, field or buttons — those consume their own drags)
    /// moves the window, so the whole dialog can be repositioned, not just its
    /// title band. The header has its own drag handle for the obvious grab.
    override func mouseDragged(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// One hover entry point for every capsule on the sheet: the send CTA
    /// (keyed "send" in the pad's tracking user info) deepens to inkRaised;
    /// PaperButton handles its own wash-deepening hover.
    override func mouseEntered(with event: NSEvent) {
        hover(from: event, entered: true)
    }

    override func mouseExited(with event: NSEvent) {
        hover(from: event, entered: false)
    }

    private func hover(from event: NSEvent, entered: Bool) {
        if event.trackingArea?.owner is NSHoverPad, (event.trackingArea?.userInfo?["send"] as? Bool) == true {
            sendHovering = entered
            let has = !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            styleSend(active: has, hover: entered)
        }
    }

    /// The send CTA's three states, painted directly on its layer so the
    /// capsule never falls back to a stock bezel: enabled ink (hover raises
    /// it a step), or faint ink when the field is empty.
    private func styleSend(active: Bool, hover: Bool) {
        guard let layer = sendButton.layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Timing.gentle)
        if active {
            layer.backgroundColor = (hover ? NSColor.sunoInkRaised : NSColor.sunoInk).cgColor
            sendButton.contentTintColor = .white
        } else {
            layer.backgroundColor = NSColor.sunoInk.withAlphaComponent(0.32).cgColor
            sendButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        }
        CATransaction.commit()
    }

    /// Empty field → CTA rests at the disabled opacity, mirroring
    /// SunoPrimaryButtonStyle's `isEnabled` treatment.
    func setSendEnabled(_ enabled: Bool) {
        styleSend(active: enabled, hover: sendHovering)
    }

    @objc private func sendTapped() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input.stringValue = ""
        onSend?(text)
    }

    @objc private func closeTapped() { onDismiss?() }

    @objc private func minimizeTapped() {
        (window as? AnswerPopupWindow)?.toggleMinimize()
    }

    /// Switch the sheet between the full layout and the minimized peek: hide
    /// the action row / input / hint, hand the transcript the whole body, flip
    /// the button glyph, and tell the page to show only the latest answer. The
    /// window resize itself is the caller's (`AnswerPopupWindow.setMinimized`).
    func setMinimized(_ minimized: Bool) {
        for v in [actionRow, hairline, micBadge, input, sendButton, hint] as [NSView] {
            v.isHidden = minimized
        }
        fullBottomConstraint.isActive = !minimized
        minimizedBottomConstraint.isActive = minimized
        minimizeButton.image = NSImage(
            systemSymbolName: minimized ? "arrow.up.left.and.arrow.down.right" : "minus",
            accessibilityDescription: minimized ? "Expand" : "Minimize")
        minimizeButton.toolTip = minimized ? "Expand" : "Minimize to the latest answer"
        minimizeButton.setAccessibilityLabel(minimized ? "Expand" : "Minimize")
        web.setCompact(minimized)
        // The peek reads from the top of the answer; the full sheet follows the
        // newest turn to the bottom as before. The minimized window's height is
        // driven by the compact content once the page measures it (see
        // `onHeightChanged` → `fitMinimizedHeight`).
        if minimized { scrollToTop() } else { scrollToBottomIfNeeded(force: true) }
    }

    /// The window height that shows a compact answer of `contentHeight` in full:
    /// the fixed chrome above the transcript (header + rule) plus the answer
    /// plus the bottom margin, with a hair of slack so the fit never overflows
    /// into a scroll bar. The chrome height is invariant — the header is pinned
    /// to the top — so this is correct whatever height the window is at now.
    func minimizedPanelHeight(forContentHeight contentHeight: CGFloat) -> CGFloat {
        layoutSubtreeIfNeeded()
        let topChrome = max(0, bounds.height - chatScroll.frame.maxY)  // window top → transcript top
        let bottomMargin: CGFloat = 14
        return topChrome + contentHeight + bottomMargin + 2
    }

    /// Force the transcript to repaint after the window resizes — WKWebView can
    /// otherwise leave a blank/stale frame following a size change. Nudging its
    /// height constraint a single point and back forces a synchronous relayout
    /// and re-tile (reliable where a JS repaint hint is not); the JS nudge is a
    /// cheap belt-and-braces on top.
    func repaintTranscript() {
        guard webHeight != nil else { return }
        let base = webHeight.constant
        webHeight.constant = base + 1
        layoutSubtreeIfNeeded()
        webHeight.constant = base
        layoutSubtreeIfNeeded()
        web.nudgeRepaint()
    }

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
        web.reset()
        retryAction = nil
        chipURLs = []
        setActions(.none)
        setStatus("")
    }

    /// The status word and its dot. Colour is rationed to three meanings:
    /// accent while Suno is working, success at rest ("Ready"), warning once a
    /// turn has "Stopped". An empty status hides the dot entirely. Both the dot
    /// and the word take the colour, the way the sheet's `StatusText` does.
    func setStatus(_ text: String) {
        statusLabel.stringValue = text
        let color: NSColor?
        switch text {
        case "":        color = nil
        case "Ready":   color = .sunoSuccess
        case "Stopped": color = .sunoWarning
        default:        color = .sunoAccent   // Thinking… / Answering… / Listening…
        }
        if let color {
            statusDot.isHidden = false
            statusDot.layer?.backgroundColor = color.cgColor
            statusLabel.textColor = color
        } else {
            statusDot.isHidden = true
            statusLabel.textColor = .sunoFaint
        }
    }

    /// The transient "Thinking…" line (also reused by the error card). Cleared
    /// by the next real content so history never keeps a stale placeholder.
    /// Supersedes any parked error card, so its retry wiring goes too.
    func showThinking() {
        retryAction = nil
        web.removeMarker()
        web.showThinking()
    }

    /// The dictated turn as a voice-message bubble: the recording's own
    /// loudness envelope drawn as the waveform, the duration beside it. The
    /// transcribed text is deliberately never shown — the bubble IS the turn.
    func addUserTurn(envelope samples: [Float], seconds: Double) {
        retryAction = nil
        web.removeMarker()
        web.addVoiceTurn(envelope: samples, seconds: seconds)
        scrollToBottomIfNeeded(force: true)
    }

    /// A typed follow-up: a plain text bubble on the right.
    func addUserTurn(text: String) {
        retryAction = nil
        web.removeMarker()
        web.addTypedTurn(text)
        scrollToBottomIfNeeded(force: true)
    }

    // MARK: live follow-up recording (2026-09-04; field mic 2026-09-05)

    /// Recording UI for a dictated follow-up. Since the mic moved into the
    /// input row, this drives the mic badge — pulse rings + level ring live
    /// there, not in the transcript.
    func beginListening() {
        micBadge.setRecording(true)
        scrollToBottomIfNeeded(force: false)
    }

    func updateListening(level: Float) {
        micBadge.update(level: level)
    }

    /// On stop the pill becomes the turn's permanent voice bubble (the real
    /// envelope waveform). This — not `addUserTurn` — is how a dictated
    /// follow-up enters the transcript; the conversion happens before the
    /// thinking marker, so the transcript reads turn → thinking in order.
    /// The mic badge returns to rest here too: recording is over.
    func commitListeningAsVoice(envelope samples: [Float], seconds: Double) {
        micBadge.setRecording(false)
        web.commitListening(samples: samples, seconds: seconds)
        scrollToBottomIfNeeded(force: true)
    }

    /// Esc during a follow-up recording: the take is discarded and the
    /// transcript returns to exactly what it showed before — in-flight work
    /// included. The Thinking… marker is deliberately kept: if the recording
    /// interrupted the thinking phase, the restored state still owns it.
    func cancelListening() {
        micBadge.setRecording(false)
    }

    /// Deletes the transient marker right before the first answer token lands.
    func beginAnswer() {
        retryAction = nil
        web.beginAnswer()
        scrollToBottomIfNeeded(force: false)
    }

    /// Clears a stale Thinking… marker without replacing it — used when a
    /// hotkey press abandons an in-flight transcription so the listening
    /// pill doesn't sit under a marker whose turn no longer exists.
    func removeMarker() {
        retryAction = nil
        web.removeMarker()
    }

    func appendAnswer(_ chunk: String) {
        web.appendAnswer(chunk)
        scrollToBottomIfNeeded(force: false)
    }

    func endAnswer() {
        web.endAnswer()
        scrollToBottomIfNeeded(force: false)
    }

    func showErrorCard(message: String, onRetry: @escaping () -> Void) {
        web.removeMarker()
        retryAction = onRetry
        web.showError(message)
        setActions(.error)
        scrollToBottomIfNeeded(force: false)
    }

    /// The finished answer's row: Insert / Copy plus the cited-source chips.
    func showAnswerActions(sources: [String]) {
        setActions(.answer(sources))
    }

    /// True while an error card is on the transcript — its "Try again" is
    /// wired and waiting. Used to keep the status label honest when a
    /// follow-up recording is cancelled over a parked failure.
    var showsErrorCard: Bool { retryAction != nil }

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
                let chip = actionButton(domain, #selector(chipTapped(_:)))
                chip.tag = i
                // Faint accent dot instead of a text glyph — colour marks the
                // chip as an outbound link, the same rationing the site uses.
                let dot = NSMutableAttributedString(string: "●  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                    .foregroundColor: NSColor.sunoAccent.withAlphaComponent(0.65),
                    .baselineOffset: 1,
                ])
                dot.append(NSAttributedString(string: domain, attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.sunoInk,
                ]))
                chip.attributedTitle = dot
                chipURLs.append(URL(string: "https://" + domain)!)
                actionRow.addArrangedSubview(chip)
            }
        }
        // The action row arrives with its turn, not before it.
        actionRow.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Timing.quick
            actionRow.animator().alphaValue = 1
        }
    }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        // Paper secondary action (SunoSecondaryButtonStyle's AppKit twin): a
        // soft wash capsule, no border, ink label; hover deepens one step.
        let b = PaperButton(title: title, target: self, action: action)
        b.setAccessibilityRole(.button)
        b.addSubview(NSHoverPad(area: NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)))
        return b
    }
}

/// The follow-up field's text field: a plain field whose cell insets its text
/// so nothing rides the rounded well's edge. Mirrors `SunoFieldStyle`, which
/// pads its SwiftUI twin by 11pt horizontally.
final class PaddedTextField: NSTextField {
    override static var cellClass: AnyClass? {
        get { PaddedTextFieldCell.self }
        set { }
    }
}

/// Insets the text (and the field editor) horizontally, and vertically centres
/// the single line inside the taller well — AppKit fields top-align by default,
/// which would float the text against the well's top edge in a 34pt row.
final class PaddedTextFieldCell: NSTextFieldCell {
    var padding = NSSize(width: 11, height: 0)

    private func inset(_ rect: NSRect) -> NSRect {
        let padded = rect.insetBy(dx: padding.width, dy: padding.height)
        let lineHeight = ceil(font?.boundingRectForFont.height ?? padded.height)
        guard lineHeight < padded.height else { return padded }
        return NSRect(x: padded.origin.x,
                      y: padded.origin.y + (padded.height - lineHeight) / 2,
                      width: padded.width, height: lineHeight)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: inset(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView, editor: editor,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: inset(rect), in: controlView, editor: editor,
                     delegate: delegate, start: start, length: length)
    }
}

/// A borderless capsule button painted the paper way: wash fill, ink label,
/// hover deepens the fill one step. Sized like the SwiftUI secondary style —
/// horizontal 10 / vertical 5 padding around an 11.5pt medium label.
final class PaperButton: NSButton {
    private var padHover = false
    static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
        .foregroundColor: NSColor.sunoInk,
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        common()
    }

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect.zero)
        common()
        attributedTitle = NSAttributedString(string: title, attributes: Self.labelAttributes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        common()
    }

    private func common() {
        isBordered = false
        wantsLayer = true
        setAccessibilityRole(.button)
        restyle()
    }

    func setHover(_ entered: Bool) {
        padHover = entered
        restyle()
    }

    /// Paint + size. Called on every state change; cheap (one layer write).
    private func restyle() {
        guard let layer = layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Timing.quick)
        layer.backgroundColor = (padHover ? NSColor.sunoRuleStrong.withAlphaComponent(0.7)
                                          : NSColor.sunoWash).cgColor
        CATransaction.commit()
        layer.cornerRadius = 11
    }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + 20, height: ceil(text.height) + 10)
    }
}

/// A pad view that fills its button and owns the tracking area driving hover
/// styling — NSButton exposes no hover callbacks, so the pad observes the
/// enters/exits and hands them to the panel's unified handler.
final class NSHoverPad: NSView {
    let area: NSTrackingArea
    init(area: NSTrackingArea) {
        self.area = area
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        translatesAutoresizingMaskIntoConstraints = false
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError("no nib") }

    override func layout() {
        super.layout()
        // Fill the button so `.inVisibleRect` tracking covers its whole hit area.
        frame = superview?.bounds ?? bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil   // clicks pass through to the button underneath
    }

    override func mouseEntered(with event: NSEvent) {
        // Hand the event to the panel view, which owns one hover handler for
        // every capsule on the sheet (send CTA + wash actions + chips).
        var view: NSView? = superview
        while let v = view, !(v is AnswerPanelView) { view = v.superview }
        (view as? AnswerPanelView)?.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        var view: NSView? = superview
        while let v = view, !(v is AnswerPanelView) { view = v.superview }
        (view as? AnswerPanelView)?.mouseExited(with: event)
    }
}

/// The scroll view's document, flipped so (0,0) is the top-left and content
/// grows downward — the web transcript appends at the visual bottom.
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// The header band as a drag handle: a mouse-down here moves the whole window,
/// so the dialog can be dragged anywhere on screen. It drives the drag itself
/// (rather than relying on `isMovableByWindowBackground`) so the transcript,
/// field and buttons keep their own mouse handling; the close/minimize buttons
/// sit above it and take their clicks first.
final class HeaderDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.performDrag(with: event)
    }
}

// MARK: - Recording bubble ("magic bubble" chrome, A7 — deliberately NOT the pill)

final class RecordingBubbleWindow: NSPanel {
    private let bubbleView: RecordingBubbleView
    /// The window is larger than the visible disc so the radiating rings have
    /// transparent room to expand into (nothing clips a layer past its window).
    /// The disc's diameter and the ring margin live in `RecordingBubbleView`.
    static let size: CGFloat = 148

    init() {
        let frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        bubbleView = RecordingBubbleView(frame: frame)
        super.init(
            contentRect: frame,
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
        // Centre the disc on the cursor's x, sitting a little above it — the
        // window's transparent margin (half the disc-to-window gap) is folded in.
        let margin = (Self.size - RecordingBubbleView.disc) / 2
        let x = anchor.x - Self.size / 2
        let y = anchor.y + 28 - margin
        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 0
        bubbleView.startAnimating()
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = 1
        }
        bubbleView.playEntrance()
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
            // The rings and heartbeat run only while the bubble is on screen.
            self?.bubbleView.stopAnimating()
        })
    }
}

final class RecordingBubbleView: NSView {
    /// The visible dark disc's diameter. The view (and window) are larger, so
    /// the radiating rings have transparent room to expand into.
    static let disc: CGFloat = 96

    private let discLayer = CALayer()
    private let pulseA = CALayer()
    private let pulseB = CALayer()
    private let levelRing = CALayer()
    /// The SunoFlow mark itself — the ear, no sound waves — listening. Its
    /// stroke breathes white↔accent while recording; the radiating rings carry
    /// the "sound arriving" that the dropped waves used to draw.
    private let earLayer = CAShapeLayer()
    private var displayedLevel: Float = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let layer = layer else { return }
        layer.masksToBounds = false

        let discFrame = CGRect(
            x: (frame.width - Self.disc) / 2,
            y: (frame.height - Self.disc) / 2,
            width: Self.disc, height: Self.disc)

        // The rings sit BEHIND the disc: at rest they hide under it; while
        // recording they expand past its edge and fade — a halo of sound. Built
        // once, invisible (opacity 0) until start/stopAnimating attaches the
        // animation, so nothing radiates while the bubble is off screen.
        for sub in [pulseA, pulseB] {
            sub.frame = discFrame
            sub.cornerRadius = Self.disc / 2
            sub.backgroundColor = NSColor.sunoAccent.cgColor
            sub.opacity = 0
            layer.addSublayer(sub)
        }

        // The disc.
        discLayer.frame = discFrame
        discLayer.cornerRadius = Self.disc / 2
        discLayer.backgroundColor = NSColor.sunoInk.withAlphaComponent(0.94).cgColor
        discLayer.borderWidth = 1
        discLayer.borderColor = NSColor.sunoRuleStrong.cgColor
        discLayer.shadowColor = NSColor.sunoInk.cgColor
        discLayer.shadowOpacity = 0.22
        discLayer.shadowRadius = 12
        discLayer.shadowOffset = CGSize(width: 0, height: -3)
        layer.addSublayer(discLayer)

        // The loudness ring, hugging the disc edge, in front of the disc.
        levelRing.frame = discFrame.insetBy(dx: 2, dy: 2)
        levelRing.cornerRadius = levelRing.bounds.width / 2
        levelRing.borderColor = NSColor.sunoAccent.cgColor
        levelRing.borderWidth = 2
        levelRing.backgroundColor = NSColor.clear.cgColor
        layer.addSublayer(levelRing)

        // The ear, centred in the disc and sized to ~40% of it, on top.
        let earBox = discFrame.insetBy(dx: Self.disc * 0.28, dy: Self.disc * 0.28)
        let mark = BrandMark.earMark(in: earBox)
        earLayer.frame = bounds
        earLayer.path = mark.path
        earLayer.lineWidth = mark.lineWidth
        earLayer.lineCap = .round
        earLayer.lineJoin = .round
        earLayer.fillColor = NSColor.clear.cgColor
        earLayer.strokeColor = NSColor.white.cgColor
        layer.addSublayer(earLayer)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// A gentle spring scale-in as the bubble fades up — the same settle idea
    /// the dictation pill and the answer sheet arrive on, so every floating
    /// surface shares one motion.
    func playEntrance() {
        guard let layer = layer else { return }
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.82
        pop.toValue = 1.0
        pop.mass = Theme.Spring.mass
        pop.stiffness = Theme.Spring.stiffness
        pop.damping = Theme.Spring.damping
        pop.duration = pop.settlingDuration
        layer.add(pop, forKey: "arrive")
    }

    /// Recording is live: the accent rings radiate outward past the disc (the
    /// sound arriving — the mark's dropped waves, set in motion), and the ear
    /// listens: its stroke breathes white↔accent and it gently scales.
    func startAnimating() {
        attachPulse(pulseA, delay: 0.0)
        attachPulse(pulseB, delay: 0.75)

        let color = CABasicAnimation(keyPath: "strokeColor")
        color.fromValue = NSColor.white.cgColor
        color.toValue = NSColor.sunoAccent.cgColor
        color.duration = 1.1
        color.autoreverses = true
        color.repeatCount = .infinity
        color.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        earLayer.add(color, forKey: "listen.color")

        let beat = CABasicAnimation(keyPath: "transform.scale")
        beat.fromValue = 1.0
        beat.toValue = 1.06
        beat.duration = 1.1
        beat.autoreverses = true
        beat.repeatCount = .infinity
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        earLayer.add(beat, forKey: "listen.scale")
    }

    func stopAnimating() {
        for sub in [pulseA, pulseB] {
            sub.removeAnimation(forKey: "pulse.scale")
            sub.removeAnimation(forKey: "pulse.fade")
        }
        earLayer.removeAnimation(forKey: "listen.color")
        earLayer.removeAnimation(forKey: "listen.scale")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        earLayer.strokeColor = NSColor.white.cgColor
        levelRing.borderWidth = 2
        displayedLevel = 0
        CATransaction.commit()
    }

    /// One expanding, fading accent ring emerging from behind the disc.
    private func attachPulse(_ sublayer: CALayer, delay: TimeInterval) {
        let t0 = CACurrentMediaTime() + delay
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.42
        scale.duration = 1.5
        scale.repeatCount = .infinity
        scale.beginTime = t0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45
        fade.toValue = 0.0
        fade.duration = 1.5
        fade.repeatCount = .infinity
        fade.beginTime = t0
        sublayer.add(scale, forKey: "pulse.scale")
        sublayer.add(fade, forKey: "pulse.fade")
    }

    func update(level: Float) {
        // Light smoothing so the ring breathes instead of jittering. Loudness
        // rides the level ring's thickness; the ear's colour breath carries the
        // constant "listening" pulse.
        displayedLevel = displayedLevel * 0.7 + level * 0.3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelRing.borderWidth = 2 + CGFloat(displayedLevel) * 5
        CATransaction.commit()
    }
}

// MARK: - Follow-up mic, built into the input row (2026-09-05)

/// The input row's mic: a quiet faint glyph at rest, an accent capsule with
/// two expanding pulse rings and a live level ring while a dictated follow-up
/// records — the recording bubble's visual language, shrunk to the field.
/// Click = start / stop the take (Esc still cancels).
final class MicBadgeView: NSControl {
    var onToggle: (() -> Void)?
    private let pulseA = CALayer()
    private let pulseB = CALayer()
    private let levelRing = CALayer()
    private var displayedLevel: Float = 0
    private var pulsesAttached = false
    private var isRecording = false
    private var hovered = false

    /// The resting badge fill: a soft-accent wash that hovers a step deeper, so
    /// the mic reads clearly as the dictate action rather than a faint grey
    /// smudge on white paper.
    private var restBadgeColor: NSColor {
        hovered ? NSColor.sunoAccent.withAlphaComponent(0.16) : .sunoAccentSoft
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        wantsLayer = true
        guard let layer = layer else { return }
        layer.cornerRadius = 12
        // Resting paint: a soft-accent capsule with an accent mic — quiet, but
        // with real contrast (the old faint-grey-on-grey mic was barely visible).
        layer.backgroundColor = NSColor.sunoAccentSoft.cgColor

        levelRing.cornerRadius = 9
        levelRing.borderWidth = 1.5
        levelRing.borderColor = NSColor.sunoAccent.cgColor
        levelRing.backgroundColor = NSColor.clear.cgColor
        levelRing.opacity = 0
        levelRing.frame = CGRect(x: 3, y: 3, width: 18, height: 18)
        layer.addSublayer(levelRing)

        let mic = NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!)
        mic.translatesAutoresizingMaskIntoConstraints = false
        mic.contentTintColor = .sunoAccent
        mic.wantsLayer = true              // its layer carries the heartbeat scale
        addSubview(mic)
        NSLayoutConstraint.activate([
            mic.centerXAnchor.constraint(equalTo: centerXAnchor),
            mic.centerYAnchor.constraint(equalTo: centerYAnchor),
            mic.widthAnchor.constraint(equalToConstant: 13),
            mic.heightAnchor.constraint(equalToConstant: 13),
        ])
        self.micView = mic

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))

        setAccessibilityLabel("Dictate a follow-up")
        setAccessibilityRole(.button)
        toolTip = "Dictate a follow-up"
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// Fixed 24×24 badge — NSControl without cell content reports
    /// noIntrinsicMetric, and without this Auto Layout stretches the badge
    /// between its leading anchor and the field.
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    private var micView: NSImageView!

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        if !isRecording { applyRestPaint() }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if !isRecording { applyRestPaint() }
    }

    /// The resting look: soft-accent badge (deeper on hover) with an accent mic.
    private func applyRestPaint() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Timing.quick)
        layer?.backgroundColor = restBadgeColor.cgColor
        micView.contentTintColor = .sunoAccent
        CATransaction.commit()
    }

    /// Rest ↔ recording. Recording: ink badge, accent mic, pulse rings +
    /// level ring riding the mic's loudness. The pulse sublayers are added
    /// and REMOVED with the state — an infinite CABasicAnimation overrides
    /// the model opacity while attached, so hiding them by setting `opacity`
    /// would leave them pulsing forever.
    func setRecording(_ recording: Bool) {
        guard let layer = layer else { return }
        isRecording = recording
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.Timing.quick)
        if recording {
            layer.backgroundColor = NSColor.sunoInk.cgColor
            micView.contentTintColor = NSColor.sunoAccent
            attachPulsesIfNeeded()
            startMicHeartbeat()
            levelRing.opacity = 1
        } else {
            layer.backgroundColor = restBadgeColor.cgColor
            micView.contentTintColor = .sunoAccent
            micView.layer?.removeAnimation(forKey: "heartbeat")
            pulseA.removeFromSuperlayer()
            pulseB.removeFromSuperlayer()
            pulsesAttached = false
            CATransaction.setDisableActions(true)
            levelRing.opacity = 0
            levelRing.borderWidth = 1.5
            displayedLevel = 0
            CATransaction.setDisableActions(false)
        }
        CATransaction.commit()
    }

    private func attachPulsesIfNeeded() {
        guard !pulsesAttached else { return }
        pulsesAttached = true
        for (sub, delay) in [(pulseA, 0.0), (pulseB, 0.7)] {
            sub.frame = bounds.insetBy(dx: 2, dy: 2)
            sub.cornerRadius = sub.bounds.width / 2
            sub.backgroundColor = NSColor.sunoAccent.cgColor
            sub.opacity = 0
            layer?.addSublayer(sub)
            let t0 = CACurrentMediaTime() + delay
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1.0
            scale.toValue = 1.3
            scale.duration = 1.4
            scale.repeatCount = .infinity
            scale.beginTime = t0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.4
            fade.toValue = 0.0
            fade.duration = 1.4
            fade.repeatCount = .infinity
            fade.beginTime = t0
            sub.add(scale, forKey: "pulse.scale")
            sub.add(fade, forKey: "pulse.fade")
        }
    }

    /// The pulsating mic: a slow heartbeat scale on the glyph while a follow-up
    /// records, so the field's mic reads as "listening" the same way the
    /// recording bubble's does. Removed on stop.
    private func startMicHeartbeat() {
        let beat = CABasicAnimation(keyPath: "transform.scale")
        beat.fromValue = 1.0
        beat.toValue = 1.18
        beat.duration = 0.62
        beat.autoreverses = true
        beat.repeatCount = .infinity
        beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        micView.layer?.add(beat, forKey: "heartbeat")
    }

    func update(level: Float) {
        guard pulsesAttached else { return }
        displayedLevel = displayedLevel * 0.7 + level * 0.3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        levelRing.borderWidth = 1.5 + CGFloat(displayedLevel) * 4
        levelRing.frame = bounds.insetBy(dx: 3, dy: 3)
        CATransaction.commit()
    }
}

/// The transcript web view. A plain WKWebView swallows scroll-wheel events:
/// the page is sized to its content (never scrolls internally), so the wheel
/// dies at the web view and the enclosing NSScrollView never scrolls (proved
/// in a harness: page scrollY 1200 while the clip stayed at 0). Forwarding
/// vertical deltas to the scroll view restores it; horizontal deltas stay
/// with the page so wide math blocks and code fences keep their own scroll.
final class TranscriptWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)   // page-owned: math/code blocks scroll horizontally
            return
        }
        if let scroll = enclosingScrollView, event.scrollingDeltaY != 0 {
            scroll.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: event)
    }
}