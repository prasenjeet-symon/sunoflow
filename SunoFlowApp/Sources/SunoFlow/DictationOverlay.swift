import Cocoa

/// A panel that never becomes key or main, so showing it never steals keyboard
/// focus from the text field the user is dictating into (critical — otherwise
/// the paste would land in the wrong place). Shared with `TranscriptCard`,
/// which needs the same guarantee while still accepting clicks.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OverlayMode {
    case recording
    case processing
}

/// The small pill at the top-centre of the screen shown while dictating: a
/// sheet of paper the size of a badge, with an accent waveform that reacts to
/// the voice. Non-activating and click-through, so it never takes focus.
///
/// A non-default voice also names itself in a small chip below the pill, so
/// the tone stays readable once colour alone has to carry it. See
/// `BubbleView`.
///
/// Drawn from the same tokens as the dashboard and `TranscriptCard` — paper,
/// hairline, one accent, `Theme.spring` for the motion — so the two things that
/// float over other apps look like one product. See `applySunoPaper`.
final class DictationOverlay {
    private var panel: NonActivatingPanel?
    private var bubble: BubbleView?

    /// The pill itself is sized in `BubbleView.pillSize`; the panel is larger
    /// — see `BubbleView.margin` and `BubbleView.chipSpace`.
    private let topGap: CGFloat = 8

    private var panelSize: NSSize {
        NSSize(
            width: BubbleView.pillSize.width + BubbleView.margin * 2,
            height: BubbleView.pillSize.height + BubbleView.margin + BubbleView.chipSpace
        )
    }

    // Incremented on every show(). A hide()'s completion handler captures the
    // value it saw when it started and bails out if show() ran in the meantime
    // — otherwise a quick re-dictation re-shows the panel only to have the
    // stale hide() callback dismiss it moments later, so the overlay
    // intermittently fails to appear.
    private var showGeneration = 0

    /// Takes the pill back down after a standalone tone announcement — the one
    /// case where it appears with no dictation behind it and nothing else will
    /// ever dismiss it.
    private var toneDismissTimer: Timer?

    /// True between `show` and `hide`, i.e. while a dictation owns the pill.
    /// A tone announced during one must not schedule a dismissal: the pill has
    /// to stay up until the words are pasted.
    private var dictationActive = false

    func show(mode: OverlayMode) {
        showGeneration += 1
        if panel == nil {
            buildPanel()
        }
        guard let panel = panel, let bubble = bubble else { return }

        // A tone announcement may already have the pill on screen. Re-running
        // the entrance from alpha 0 would blink it, so only the first arrival
        // gets the animation.
        let alreadyUp = isOnScreen
        toneDismissTimer?.invalidate()
        toneDismissTimer = nil
        dictationActive = true

        bubble.mode = mode
        bubble.setTone(Preferences.shared.tone, animated: alreadyUp)
        panel.setFrameOrigin(topCenterOrigin())
        if !alreadyUp {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20 // Theme.gentle
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        bubble.start()
        if !alreadyUp {
            bubble.playEntrance()
        }
    }

    /// Show the pill in the new voice: recolour it, radiate, and show its name
    /// in the chip below.
    ///
    /// The pill normally exists only while dictating, but the tone key is most
    /// useful *before* speaking — so when nothing is on screen this summons it
    /// briefly and takes it away again. Pressed during a dictation it simply
    /// recolours the pill already there and re-chips it.
    func announceTone(_ tone: Tone) {
        if panel == nil {
            buildPanel()
        }
        guard let panel = panel, let bubble = bubble else { return }

        let alreadyUp = isOnScreen
        if !alreadyUp {
            showGeneration += 1
            panel.setFrameOrigin(topCenterOrigin())
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20 // Theme.gentle
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
            bubble.playEntrance()
        }

        // Only crossfade the colour when the old one was actually visible.
        bubble.setTone(tone, animated: alreadyUp)
        // The ripple, not the chip — `setTone` above already placed it.
        bubble.announceTone()

        toneDismissTimer?.invalidate()
        guard !dictationActive else { return }
        // Long enough to read a word, short enough not to sit over the user's
        // work. Each further press restarts it, so cycling reads as one
        // continuous pill rather than a stutter of appearances.
        toneDismissTimer = Timer.scheduledTimer(
            withTimeInterval: 1.35, repeats: false
        ) { [weak self] _ in
            self?.hide()
        }
    }

    /// Whether the panel is actually visible, rather than merely built.
    private var isOnScreen: Bool {
        guard let panel = panel else { return false }
        return panel.isVisible && panel.alphaValue > 0.01
    }

    func update(mode: OverlayMode) {
        bubble?.mode = mode
    }

    func updateLevel(_ level: Float) {
        bubble?.setLevel(level)
    }

    func hide() {
        toneDismissTimer?.invalidate()
        toneDismissTimer = nil
        dictationActive = false
        guard let panel = panel else { return }
        let bubble = self.bubble
        let up = NSPoint(x: panel.frame.origin.x, y: panel.frame.origin.y + 6)
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13 // Theme.quick
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(up)
        } completionHandler: {
            // A show() that started during this fade-out increments
            // showGeneration, meaning the user re-dictated right after the
            // previous transcript landed. In that case leave the panel up —
            // dismissing it would kill the freshly-started overlay.
            guard generation == self.showGeneration else { return }
            bubble?.stop()
            panel.orderOut(nil)
        }
    }

    // MARK: - Building

    private func buildPanel() {
        let panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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
        // The pill draws its own lift, inside a panel deliberately larger than
        // it so that shadow has somewhere to fall.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Same reasoning as the settings window: this palette was drawn light,
        // so pin the appearance instead of letting macOS invent a dark variant.
        panel.appearance = NSAppearance(named: .aqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bubble = BubbleView(frame: NSRect(origin: .zero, size: panelSize))
        bubble.autoresizingMask = [.width, .height]
        panel.contentView = bubble

        self.panel = panel
        self.bubble = bubble
    }

    private func topCenterOrigin() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return .zero }
        // visibleFrame excludes the menu bar, so the pill sits just below it,
        // centred. The pill's top inside the panel is chipSpace up from the
        // panel's bottom edge (the space below it is transparent), so the
        // origin is the gap minus everything under the pill's top edge.
        let vf = screen.visibleFrame
        let size = panelSize
        return NSPoint(
            x: (vf.midX - size.width / 2).rounded(),
            y: (vf.maxY - topGap - BubbleView.chipSpace
                - BubbleView.pillSize.height).rounded()
        )
    }
}

/// The pill: paper with a hairline edge, and a dense accent waveform that
/// animates with the audio level.
private final class BubbleView: NSView {
    var mode: OverlayMode = .recording

    /// Transparent breathing room around the pill — above and beside for the
    /// shadow and the tone rings to expand into; below is `chipSpace`.
    ///
    /// The rings set the size, not the shadow. Nothing clips a layer that grows
    /// past its window — it simply stops being drawn — so at the ring's full
    /// 1.3x the pill's 132pt width reaches 172pt, and the panel has to be wider
    /// than that or the wave arrives with its ends sliced off.
    static let margin: CGFloat = 24
    /// Extra panel depth below the pill for the tone chip. Sized for the chip
    /// plus its hang and the room its shadow needs, and part of the panel
    /// whether a chip is showing or not — the pill never moves.
    static let chipSpace: CGFloat = 36

    /// The pill is 132×42. The panel is larger by `margin` above and on both
    /// sides (for the shadow and the tone rings) and by `chipSpace` below (for
    /// the tone chip), so the pill sits `margin` from the panel's top and the
    /// layout mirrors that.
    static let pillSize = NSSize(width: 132, height: 42)

    private let pill = NSView()
    private let waveform = CALayer()
    private var bars: [CALayer] = []
    private var heights: [CGFloat] = []

    /// The voice's name, in a paper chip hanging below the pill. A change also
    /// radiates rings; for a non-default voice the chip then stays up as long
    /// as the pill does, because seven hues are not learnable on their own —
    /// the colour tells you something changed, the word tells you to what.
    /// `faithful` takes the chip away, leaving today's pill.
    private let chipLayer = CALayer()
    private let chipLabel = CATextLayer()
    /// Whether the chip is on screen — true for every voice but `faithful`.
    private var chipVisible = false
    /// Two capsule outlines that expand out of the pill's edge and fade. Two,
    /// staggered, so it reads as a wave leaving the pill rather than one ring
    /// popping off it.
    private var rings: [CAShapeLayer] = []
    private var tone: Tone = .faithful

    private var timer: Timer?
    private var phase: CGFloat = 0
    private var rawLevel: Float = 0
    private var displayLevel: CGFloat = 0

    // Waveform geometry.
    private let insetX: CGFloat = 15
    private let insetY: CGFloat = 11
    private let barWidth: CGFloat = 3
    private let barGap: CGFloat = 4

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

    private func setup() {
        // Layer-backed before the waveform is attached: applySunoPaper sets this
        // too, but not until layout, and a nil layer would silently swallow the
        // sublayer and leave an empty pill.
        pill.wantsLayer = true
        addSubview(pill)
        waveform.masksToBounds = false
        pill.layer?.addSublayer(waveform)

        // The rings sit outside the pill's bounds as they grow. Nothing clips
        // them — neither the pill nor the panel masks — which is what the
        // transparent margin around the pill is for.
        for _ in 0..<2 {
            let ring = CAShapeLayer()
            ring.fillColor = nil
            ring.lineWidth = 2
            ring.opacity = 0 // invisible except while radiating
            pill.layer?.addSublayer(ring)
            rings.append(ring)
        }

        // The chip lives outside the pill's bounds — it hangs below the pill
        // into `chipSpace`. Nothing clips sublayers here, which is the same
        // arrangement the rings rely on. The label is a child of the chip, so
        // one opacity fades the whole thing.
        chipLayer.shadowColor = NSColor.sunoInk.cgColor
        chipLayer.shadowOpacity = 0.12
        chipLayer.shadowRadius = 4
        chipLayer.shadowOffset = CGSize(width: 0, height: -1.5)
        chipLayer.opacity = 0 // invisible except while a voice owns it
        pill.layer?.addSublayer(chipLayer)

        chipLabel.alignmentMode = .center
        chipLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        chipLabel.fontSize = 9
        chipLabel.contentsScale = window?.backingScaleFactor ?? 2
        chipLayer.addSublayer(chipLabel)

        tone = Preferences.shared.tone
        layoutBubble()
    }

    override func layout() {
        super.layout()
        // Margins mirror the panel's own: even above and beside, chipSpace
        // below. The pill keeps its size and its position on screen — only the
        // panel's transparent skirt changed.
        pill.frame = NSRect(
            x: BubbleView.margin,
            y: BubbleView.chipSpace,
            width: BubbleView.pillSize.width,
            height: BubbleView.pillSize.height
        )
        // A capsule, like every other rounded thing in this design.
        pill.applySunoPaper(cornerRadius: pill.bounds.height / 2, lift: 10)
        layoutBubble()
    }

    private func layoutBubble() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        waveform.frame = CGRect(
            x: insetX, y: insetY,
            width: pill.bounds.width - insetX * 2,
            height: pill.bounds.height - insetY * 2
        )
        rebuildBarsIfNeeded(waveWidth: waveform.bounds.width)
        layoutBars()

        let radius = pill.bounds.height / 2
        for ring in rings {
            ring.frame = pill.bounds
            ring.path = CGPath(
                roundedRect: CGRect(origin: .zero, size: pill.bounds.size),
                cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            ring.strokeColor = tone.nsTint.cgColor
        }

        // The chip hangs below the pill's bottom edge, its width hugging the
        // text. The chip can exceed the pill's width for a long name — the
        // panel is pill-wide plus margins on both sides, and "Professional"
        // at 9pt stays well inside that.
        let chipHeight: CGFloat = 15
        let chipHang: CGFloat = 7
        let chipFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let chipTextWidth = (tone.label as NSString).size(
            withAttributes: [.font: chipFont]
        ).width
        let chipTextHeight = ceil((tone.label as NSString).size(
            withAttributes: [.font: chipFont]
        ).height)
        let chipWidth = (chipTextWidth + 18).rounded(.up)
        let chipX = (pill.bounds.width - chipWidth) / 2
        chipLayer.frame = CGRect(
            x: chipX, y: -chipHang - chipHeight,
            width: chipWidth, height: chipHeight
        )
        chipLayer.cornerRadius = chipHeight / 2
        chipLayer.backgroundColor = NSColor.sunoPaper.cgColor
        chipLayer.borderWidth = 1
        chipLayer.borderColor = NSColor.sunoRule.cgColor
        // CATextLayer draws from the top of its frame and never centres, so the
        // label gets the text's own height, offset into the middle of the chip.
        chipLabel.frame = CGRect(
            x: 0, y: (chipHeight - chipTextHeight) / 2,
            width: chipWidth, height: chipTextHeight
        )
        chipLabel.contentsScale = window?.backingScaleFactor ?? 2
        chipLabel.foregroundColor = tone.nsTint.cgColor
        CATransaction.commit()
    }

    private func rebuildBarsIfNeeded(waveWidth: CGFloat) {
        let pitch = barWidth + barGap
        let count = max(3, Int((waveWidth + barGap) / pitch))
        guard count != bars.count else { return }

        bars.forEach { $0.removeFromSuperlayer() }
        bars.removeAll()
        for _ in 0..<count {
            let bar = CALayer()
            bar.backgroundColor = tone.nsTint.cgColor
            bar.cornerRadius = barWidth / 2
            waveform.addSublayer(bar)
            bars.append(bar)
        }
        heights = Array(repeating: barWidth, count: count)
    }

    private func layoutBars() {
        guard !bars.isEmpty else { return }
        let count = bars.count
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * barGap
        let startX = (waveform.bounds.width - totalWidth) / 2
        let midY = waveform.bounds.height / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let x = startX + CGFloat(i) * (barWidth + barGap)
            let h = heights[i]
            bar.frame = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
            bar.cornerRadius = barWidth / 2
        }
        CATransaction.commit()
    }

    // MARK: - Animation

    func setLevel(_ level: Float) {
        rawLevel = level
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        setLayerOpacity(waveform, 0, 1, duration: 0)
        rawLevel = 0
        displayLevel = 0
        for i in 0..<heights.count { heights[i] = barWidth }
        layoutBars()
    }

    /// The pill settles down from above as the waveform scales in. `Theme.spring`
    /// is near-critically damped, so both land rather than bounce.
    func playEntrance() {
        if let layer = pill.layer {
            let settle = CASpringAnimation(keyPath: "transform")
            settle.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, 14, 0))
            settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            settle.mass = Theme.Spring.mass
            settle.stiffness = Theme.Spring.stiffness
            settle.damping = Theme.Spring.damping
            settle.duration = settle.settlingDuration
            layer.add(settle, forKey: "arrive")
        }

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.82
        pop.toValue = 1.0
        pop.mass = Theme.Spring.mass
        pop.stiffness = Theme.Spring.stiffness
        pop.damping = Theme.Spring.damping
        pop.duration = pop.settlingDuration
        waveform.add(pop, forKey: "pop")
    }

    // MARK: - Tone

    /// Recolour everything the voice owns, and set the chip: shown for any
    /// non-default voice, hidden for `faithful` — the pill then reads exactly
    /// as it did before voices existed. `animated` crossfades the colour;
    /// false snaps everything, which is what a pill arriving in a colour
    /// wants — there is no previous colour to travel from. The chip fades
    /// only when its visibility actually flips: Professional → Formal swaps
    /// the word without blinking the chip, while → faithful lets it fall.
    func setTone(_ tone: Tone, animated: Bool) {
        let wasVisible = chipVisible
        self.tone = tone
        chipVisible = tone != .faithful

        chipLabel.string = tone.label

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        let colour = tone.nsTint.cgColor
        for bar in bars { bar.backgroundColor = colour }
        for ring in rings { ring.strokeColor = colour }
        chipLabel.foregroundColor = colour
        CATransaction.commit()

        if chipVisible != wasVisible {
            if animated {
                setLayerOpacity(chipLayer, chipVisible ? 0 : 1, chipVisible ? 1 : 0, duration: 0.18)
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                chipLayer.opacity = chipVisible ? 1 : 0
                CATransaction.commit()
            }
        }
    }

    /// Announce the voice: radiate. The chip's arrival is `setTone`'s to
    /// animate — this is only the press's ripple.
    func announceTone() {
        radiate()
    }

    /// Two capsule outlines leaving the pill's edge and fading out.
    ///
    /// 1.3 is as far as they can travel: the panel is only `margin` larger than
    /// the pill on each side, and nothing clips a layer that grows past its
    /// window — it simply stops being drawn.
    private func radiate() {
        for (i, ring) in rings.enumerated() {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1.0
            grow.toValue = 1.3
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0.0

            let wave = CAAnimationGroup()
            wave.animations = [grow, fade]
            wave.duration = 0.55
            wave.beginTime = CACurrentMediaTime() + Double(i) * 0.13
            wave.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // No fill mode: before it begins, the ring shows its model opacity
            // of 0 rather than sitting there at the start of the animation.
            ring.add(wave, forKey: "radiate")
        }
    }

    /// A plain opacity crossfade. Written out because CATextLayer and CALayer
    /// both need the model value set as well as the animation, or the layer
    /// snaps back the moment the animation is removed.
    private func setLayerOpacity(_ layer: CALayer, _ from: Float, _ to: Float, duration: CFTimeInterval) {
        layer.removeAnimation(forKey: "fade")
        layer.opacity = to
        guard duration > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }

    private func tick() {
        phase += 0.15

        // Smooth the level; let it decay when the voice goes quiet.
        displayLevel += (CGFloat(rawLevel) - displayLevel) * 0.35
        rawLevel *= 0.9

        guard !bars.isEmpty else { return }
        let minH = barWidth
        let maxH = waveform.bounds.height
        let span = maxH - minH
        let count = bars.count

        for i in 0..<count {
            // Center-weighted envelope: taller in the middle, tapering at the
            // edges, so the waveform reads as a soft bubble rather than a flat row.
            let envInput = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 0.5
            let envelope = 0.5 + 0.5 * sin(.pi * envInput) // 0.5 at edges, 1.0 center

            let amp: CGFloat
            switch mode {
            case .recording:
                // Travelling wave whose amplitude follows the voice.
                let osc = 0.5 + 0.5 * sin(phase + CGFloat(i) * 0.5)
                amp = min(1.0, (0.08 + displayLevel * (0.5 + 0.8 * osc)) * envelope)
            case .processing:
                let osc = 0.5 + 0.5 * sin(phase * 1.8 + CGFloat(i) * 0.5)
                amp = (0.24 + 0.3 * osc) * envelope
            }
            let target = minH + span * amp
            heights[i] += (target - heights[i]) * 0.35
        }
        layoutBars()
    }
}
