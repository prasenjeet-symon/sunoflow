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
/// Drawn from the same tokens as the dashboard and `TranscriptCard` — paper,
/// hairline, one accent, `Theme.spring` for the motion — so the two things that
/// float over other apps look like one product. See `applySunoPaper`.
final class DictationOverlay {
    private var panel: NonActivatingPanel?
    private var bubble: BubbleView?

    /// The pill itself. The panel is larger — see `BubbleView.margin`.
    private let pillSize = NSSize(width: 132, height: 42)
    private let topGap: CGFloat = 8

    private var panelSize: NSSize {
        NSSize(
            width: pillSize.width + BubbleView.margin * 2,
            height: pillSize.height + BubbleView.margin * 2
        )
    }

    // Incremented on every show(). A hide()'s completion handler captures the
    // value it saw when it started and bails out if show() ran in the meantime
    // — otherwise a quick re-dictation re-shows the panel only to have the
    // stale hide() callback dismiss it moments later, so the overlay
    // intermittently fails to appear.
    private var showGeneration = 0

    func show(mode: OverlayMode) {
        showGeneration += 1
        if panel == nil {
            buildPanel()
        }
        guard let panel = panel, let bubble = bubble else { return }

        bubble.mode = mode
        panel.setFrameOrigin(topCenterOrigin())
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20 // Theme.gentle
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        bubble.start()
        bubble.playEntrance()
    }

    func update(mode: OverlayMode) {
        bubble?.mode = mode
    }

    func updateLevel(_ level: Float) {
        bubble?.setLevel(level)
    }

    func hide() {
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
        // centred. The margin is transparent, so it is subtracted back out.
        let vf = screen.visibleFrame
        let size = panelSize
        return NSPoint(
            x: (vf.midX - size.width / 2).rounded(),
            y: (vf.maxY - topGap - size.height + BubbleView.margin).rounded()
        )
    }
}

/// The pill: paper with a hairline edge, and a dense accent waveform that
/// animates with the audio level.
private final class BubbleView: NSView {
    var mode: OverlayMode = .recording

    /// Transparent breathing room around the pill for its shadow to fall into.
    static let margin: CGFloat = 16

    private let pill = NSView()
    private let waveform = CALayer()
    private var bars: [CALayer] = []
    private var heights: [CGFloat] = []

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
        layoutBubble()
    }

    override func layout() {
        super.layout()
        pill.frame = bounds.insetBy(dx: BubbleView.margin, dy: BubbleView.margin)
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
            bar.backgroundColor = NSColor.sunoAccent.cgColor
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
