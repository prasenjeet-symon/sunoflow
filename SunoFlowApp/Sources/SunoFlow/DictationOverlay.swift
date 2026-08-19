import Cocoa

/// A panel that never becomes key or main, so showing it never steals keyboard
/// focus from the text field the user is dictating into (critical — otherwise
/// the paste would land in the wrong place).
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OverlayMode {
    case recording
    case processing
}

/// A small, elegant floating "bubble" at the top-center of the screen shown
/// during dictation — a compact frosted capsule with a gradient waveform that
/// reacts to the voice, a springy pop-in, and a soft drop shadow. Non-activating
/// and click-through, so it never takes focus.
final class DictationOverlay {
    private var panel: NonActivatingPanel?
    private var bubble: BubbleView?

    private let panelSize = NSSize(width: 132, height: 42)
    private let topGap: CGFloat = 8

    func show(mode: OverlayMode) {
        if panel == nil {
            buildPanel()
        }
        guard let panel = panel, let bubble = bubble else { return }

        bubble.mode = mode
        let target = topCenterOrigin()

        // Begin slightly higher and transparent, then slide down + fade in,
        // while the waveform pops with a spring.
        panel.setFrameOrigin(NSPoint(x: target.x, y: target.y + 8))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(target)
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrameOrigin(up)
        } completionHandler: {
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
        panel.hasShadow = true // soft drop shadow follows the frosted capsule
        panel.ignoresMouseEvents = true
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
        // visibleFrame excludes the menu bar, so this sits just below it, centered.
        let vf = screen.visibleFrame
        return NSPoint(
            x: (vf.midX - panelSize.width / 2).rounded(),
            y: (vf.maxY - panelSize.height - topGap).rounded()
        )
    }
}

/// The capsule bubble: a frosted pill with a dense, gradient-tinted waveform
/// that animates with the audio level.
private final class BubbleView: NSView {
    var mode: OverlayMode = .recording

    private let effect = NSVisualEffectView()
    private let gradient = CAGradientLayer()
    private let barsMask = CALayer()
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
        // Frosted capsule that stays visible on any background, light or dark.
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = bounds.height / 2
        effect.layer?.masksToBounds = true
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        // Gradient waveform, revealed through a mask of animated bars.
        gradient.colors = [
            NSColor(calibratedRed: 0.545, green: 0.486, blue: 1.0, alpha: 1.0).cgColor,  // violet
            NSColor(calibratedRed: 1.0, green: 0.561, blue: 0.816, alpha: 1.0).cgColor,   // pink
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.mask = barsMask
        effect.layer?.addSublayer(gradient)

        layoutBubble()
    }

    override func layout() {
        super.layout()
        effect.layer?.cornerRadius = bounds.height / 2
        layoutBubble()
    }

    private func layoutBubble() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let waveRect = CGRect(
            x: insetX, y: insetY,
            width: bounds.width - insetX * 2,
            height: bounds.height - insetY * 2
        )
        gradient.frame = waveRect
        barsMask.frame = CGRect(origin: .zero, size: waveRect.size)

        rebuildBarsIfNeeded(waveWidth: waveRect.width)
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
            bar.backgroundColor = NSColor.white.cgColor // mask: coverage is what matters
            bar.cornerRadius = barWidth / 2
            barsMask.addSublayer(bar)
            bars.append(bar)
        }
        heights = Array(repeating: barWidth, count: count)
    }

    private func layoutBars() {
        guard !bars.isEmpty else { return }
        let count = bars.count
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * barGap
        let startX = (barsMask.bounds.width - totalWidth) / 2
        let midY = barsMask.bounds.height / 2

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

    /// Springy "bubble" pop of the waveform when the overlay appears.
    func playEntrance() {
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.7
        pop.toValue = 1.0
        pop.mass = 1
        pop.stiffness = 240
        pop.damping = 15
        pop.initialVelocity = 6
        pop.duration = pop.settlingDuration
        gradient.add(pop, forKey: "pop")
    }

    private func tick() {
        phase += 0.15

        // Smooth the level; let it decay when the voice goes quiet.
        displayLevel += (CGFloat(rawLevel) - displayLevel) * 0.35
        rawLevel *= 0.9

        guard !bars.isEmpty else { return }
        let minH = barWidth
        let maxH = barsMask.bounds.height
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
