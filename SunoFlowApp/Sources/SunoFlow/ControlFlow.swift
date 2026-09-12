// Suno Control — the agent loop (feature branch build order step ③).
//
// The user states a goal by voice; the app screenshots the screen, sends it to
// the sidecar's /control (→ hosted gateway → Gemini planner), and the planner
// answers with EXACTLY ONE action. ControlFlow executes it via ControlExecutor,
// waits for the screen to settle, captures again, and asks again — until the
// planner says done/failed, the step or wall-clock cap hits, or the user
// clicks the capsule / re-presses the hotkey.
//
// Everything runs on the main queue like AnswerFlow; the network waits are
// bounded (40s URL timeout + the executor's own sleeps), so the run cannot
// wedge the app without the capsule still showing and the stop button working.

import AppKit
import CoreGraphics

// MARK: - Overlay capsule

/// The slim non-activating capsule at the bottom-center of the screen:
/// "3/12 · opening Calculator · click to stop". The WHOLE capsule is the stop
/// button, so stopping never requires aiming.
final class ControlOverlay: NSObject {
    private var panel: NSPanel?
    private var label: NSTextField?

    /// Installed by the flow; a click anywhere on the capsule stops the loop.
    var onClick: (() -> Void)?

    func show() {
        guard panel == nil else { return }
        let width: CGFloat = 420
        let height: CGFloat = 34
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        // The loop re-captures the screen every step, WHILE this capsule is up.
        // Left visible to the capture, our own opaque overlay would sit in the
        // bottom-centre of every frame the planner judges — occluding targets
        // there (the Dock, a centred dialog button) and adding SunoFlow chrome
        // the model has to ignore. sharingType = .none excludes the window from
        // CGDisplayCreateImage, so the planner only ever sees the user's screen.
        panel.sharingType = .none

        // The whole capsule is the stop button: one view class owns the hit,
        // and hitTest from the capsule answers for the label laid over it.
        let view = CapsuleHitView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.onClick = { [weak self] in self?.onClick?() }

        let capsule = NSView(frame: view.bounds)
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.sunoInkFill.cgColor
        capsule.layer?.cornerRadius = height / 2
        capsule.autoresizingMask = [.width, .height]
        view.addSubview(capsule)

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.white
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 14, y: (height - 15) / 2, width: width - 28, height: 15)
        label.autoresizingMask = [.width]
        label.isEditable = false
        label.isSelectable = false
        view.addSubview(label)

        panel.contentView = view

        // Bottom-center of the main display, above the Dock.
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameTopLeftPoint(NSPoint(x: screen.midX - width / 2, y: screen.minY + 14 + height))

        panel.orderFrontRegardless()
        self.panel = panel
        self.label = label
    }

    func update(_ text: String) {
        label?.stringValue = text
    }

    /// Make the capsule transparent to the mouse (interactive = false) while an
    /// action is executed, so a synthetic click the planner aimed at a target
    /// physically behind the capsule passes THROUGH to that target instead of
    /// hitting the capsule and stopping the loop. Restored afterwards so the
    /// click-anywhere-to-stop gesture works during the think + settle waits.
    func setInteractive(_ interactive: Bool) {
        panel?.ignoresMouseEvents = !interactive
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }

    var isVisible: Bool { panel != nil }
}

/// The overlay's content view: every click inside the panel (capsule body or
/// label) is one stop tap. A plain NSView's label subview would eat the hit.
private final class CapsuleHitView: NSView {
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - The loop

final class ControlFlow: NSObject {
    enum State { case idle, recording, running }

    private(set) var state: State = .idle

    /// Run caps (mirrors the decided contract; the gateway meters the calls).
    static let maxSteps = 100
    /// 30 minutes ≈ 100 steps at tool-mode planning latency (~15.6s/step plus
    /// capture/settle), so the step cap — not this timer — is what normally
    /// ends a maxed run. This stays the runaway backstop: if the network or
    /// the planner wedges, no run outlives half an hour.
    static let maxWallClockSeconds: TimeInterval = 1800
    /// After this many `wait` actions in a row, end the run. A model that keeps
    /// waiting with nothing else to do has finished the goal (or is stuck) — the
    /// computer-use tool has no "done" action, so left alone it waits out the
    /// whole step cap. A cold app launch is punctuated by a real action once it appears,
    /// so a short run of pure waits is the reliable "nothing left to do" signal.
    static let maxConsecutiveWaits = 3
    /// Actions whose effect lands almost immediately: the post-action settle
    /// pause before the next screenshot can be short. Anything else (a drag
    /// leaving an animation running, a scroll) keeps the full settle.
    static let quickActions: Set<String> = ["click", "double_click", "right_click", "type", "key"]

    private let recorder = AudioRecorder()
    private let overlay = ControlOverlay()

    override init() {
        super.init()
        // Clicking the capsule is the always-available stop gesture.
        overlay.onClick = { [weak self] in self?.stop() }
    }

    // The loop's own generation guard: a fresh run invalidates any callbacks
    // still in flight from the run before (the same posture as AnswerFlow).
    private var generation = 0

    /// The goal under execution. Empty while idle.
    private var goal = ""

    private var steps: [ControlClient.Step] = []
    /// Count of `wait` actions since the last non-wait one — the backstop against
    /// a model that never signals completion (see maxConsecutiveWaits).
    private var consecutiveWaits = 0
    private var runStartedAt: TimeInterval = 0

    /// Short id tying one run's lines together in the dedicated control log.
    /// Held from the moment recording starts until the run stops.
    private var runID = ""
    /// The context observed at the current step (set when the screen is
    /// captured), so the executed action is logged next to where it happened.
    private var lastApp = ""
    private var lastWindow = ""

    /// Installed by AppDelegate; re-pressing the hotkey mid-run stops.
    var onStateChange: (() -> Void)?

    /// Installed by AppDelegate; a press while dictation is busy or a Suno
    /// Answer popup is open is ignored (the exclusivity rule the Answer
    /// hotkey itself honours against dictation).
    private var isBusy: () -> Bool = { false }

    func install(isBusy: @escaping () -> Bool) {
        self.isBusy = isBusy
    }

    private var maxRecordingTimer: Timer?
    private var runDeadlineTimer: Timer?

    // MARK: - Entry points

    /// The control hotkey fired. Idle → start recording the goal; running →
    /// stop the loop.
    func toggle() {
        guard !isBusy() else {
            NSSound.beep()
            AppLog.log("Control press ignored — dictation or Suno Answer is active")
            return
        }
        switch state {
        case .idle:
            startRecording()
        case .recording:
            // Re-press = "the goal is said". The same finish gesture as the
            // dictation hotkey (re-press stops and transcribes) and the Answer
            // hotkey (re-press stops and asks). Cancelling here silently ate
            // every take whose speaker pressed again — the only path that ran
            // was the 15s auto-stop.
            finishRecordingAndRun()
        case .running:
            stop()
        }
    }

    private func startRecording() {
        guard TextInjector.hasAccessibilityPermission else {
            ControlExecutor.promptForAccessibilityPermissionIfNeeded()
            ControlLog.event(ControlLog.newRunID(), "blocked: Accessibility permission not granted")
            return
        }
        runID = ControlLog.newRunID()
        runStartedAt = Date().timeIntervalSince1970
        do {
            _ = try recorder.startRecording()
        } catch {
            AppLog.log("control: recorder failed to start: \(error)")
            ControlLog.event(runID, "recorder failed to start: \(error)")
            return
        }
        state = .recording
        onStateChange?()
        ControlLog.recording(runID)
        // The take must be visible: without the capsule the user has no way to
        // tell the goal is being recorded at all. The capsule doubles as the
        // cancel gesture (a click stops without running).
        overlay.show()
        overlay.update("Suno Control — say your goal… (press again to run)")
        // Auto-stop a runaway goal take after 15s (goals are one sentence).
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.finishRecordingAndRun()
        }
        AppLog.log("control: recording goal")
    }

    /// The user pressed the control hotkey again mid-take (the finish gesture),
    /// or the auto-stop fired: run with what was said.
    func finishRecordingAndRun() {
        guard state == .recording else { return }
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        recorder.stopRecording()
        guard let file = recorder.currentFileURL else {
            AppLog.log("control: recording produced no file")
            stop(reason: "The goal didn't record. Suno Control stopped.")
            return
        }
        run(withAudioAt: file)
    }

    private func run(withAudioAt file: URL) {
        state = .running
        generation += 1
        let gen = generation
        onStateChange?()
        runDeadlineTimer = Timer.scheduledTimer(withTimeInterval: Self.maxWallClockSeconds, repeats: false) { [weak self] _ in
            self?.stop()
        }
        overlay.show()
        overlay.update("Suno Control · thinking…")

        TranscriptionClient.transcribe(
            fileURL: file, cleanup: false
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen, self.state == .running else {
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                switch result {
                case .success(let transcription):
                    let goal = transcription.raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !goal.isEmpty else {
                        self.stop(reason: "Heard nothing — Suno Control stopped.")
                        return
                    }
                    self.steps = []
                    self.consecutiveWaits = 0
                    ControlLog.runStarted(self.runID, goal: goal,
                                          maxSteps: Self.maxSteps, wallClock: Self.maxWallClockSeconds)
                    self.overlay.update("Suno Control · “\(goal)”")
                    self.step(goal: goal, gen: gen)
                case .failure(let error):
                    AppLog.log("control: STT failed: \(error)")
                    ControlLog.event(self.runID, "STT failed: \(error)")
                    self.stop(reason: "Couldn't hear the goal. Suno Control stopped.")
                }
            }
        }
    }

    // MARK: - The loop proper

    /// The host operating system as a single descriptive string, sent with
    /// every planning step: the planner must use this platform's shortcuts,
    /// menus and conventions, and inferring it from pixels alone is unreliable
    /// (a flash-class model once proposed a Linux hotkey on a macOS screen).
    private static let hostOSDescription: String = {
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        let semver = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let arch: String
        #if arch(arm64)
        arch = "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        arch = "Intel (x86_64)"
        #else
        arch = "unknown architecture"
        #endif
        return "macOS \(semver) (\(info.operatingSystemVersionString)) · \(arch)"
    }()

    private func step(goal: String, gen: Int) {
        guard state == .running, generation == gen else { return }
        guard steps.count < Self.maxSteps else {
            stop(reason: "Stopped after \(Self.maxSteps) steps.")
            return
        }

        // Capture the screen as it is NOW — the planner judges only this.
        guard let raw = ScreenShot.capture() else {
            stop(reason: "Can't see the screen (Screen Recording permission). Suno Control stopped.")
            return
        }
        let shot = ScreenShot.downscale(raw, maxEdge: 1600)
        let jpeg = ScreenShot.jpegData(shot)
        let imageWidth = shot.width
        let imageHeight = shot.height

        // Observed context + the cursor's position in the image's pixel space.
        let snap = ForegroundApp.snapshot()
        lastApp = snap.id
        lastWindow = snap.detail
        let mouse = NSEvent.mouseLocation
        let screenBounds = CGDisplayBounds(CGMainDisplayID())
        // NSEvent.mouseLocation is bottom-left; the image's space is top-left.
        let scale = Double(imageWidth) / Double(screenBounds.width)
        let cursorX = Int(mouse.x * scale)
        let cursorY = Int((screenBounds.height - mouse.y) * scale)

        let context = ControlClient.Context(
            os: Self.hostOSDescription,
            app: snap.id,
            window: snap.detail,
            cursor_x: cursorX,
            cursor_y: cursorY,
            image_width: imageWidth,
            image_height: imageHeight
        )

        overlay.update("Suno Control · thinking…")
        ControlClient.plan(goal: goal, steps: steps, imageJPEG: jpeg, context: context) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.generation == gen, self.state == .running else { return }
                switch result {
                case .success(let action):
                    self.handle(action, goal: goal, gen: gen,
                                imageWidth: imageWidth, imageHeight: imageHeight)
                case .failure(.cancelled):
                    break // stop() already tore the loop down
                case .failure(.limit(let message)):
                    self.stop(reason: message)
                case .failure(.notEntitled(let code, let message)):
                    AppLog.log("control: not entitled (\(code))")
                    self.stop(reason: message)
                    NotificationCenter.default.post(name: .sunoAnswerNotEntitled, object: nil,
                                                    userInfo: ["message": message, "code": code])
                case .failure(let other):
                    let message: String
                    switch other {
                    case .unavailable(let m): message = m
                    case .safetyBlock(let m): message = m
                    default: message = "Suno Control is unavailable right now."
                    }
                    self.stop(reason: message)
                }
            }
        }
    }

    /// Renders one planned action's parameters for the log line, so a failed
    /// run can be reconstructed afterwards (what was clicked, what was typed).
    private func describeAction(_ action: ControlAction) -> String {
        var parts: [String] = []
        if let x = action.x, let y = action.y { parts.append("@\(x),\(y)") }
        if let x2 = action.x2, let y2 = action.y2 { parts.append("→\(x2),\(y2)") }
        if let text = action.text { parts.append("\"\(text.prefix(80))\"") }
        if let key = action.key { parts.append(key + (action.modifiers.map { "+" + $0.joined(separator: "+") } ?? "")) }
        if let dir = action.direction { parts.append("\(dir)\(action.amount.map { "×\($0)" } ?? "")") }
        if let secs = action.seconds { parts.append("\(secs)s") }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    /// Map the gateway's `usage` block to the control log's token type; nil when
    /// the gateway reported no usage.
    private static func tokenUsage(from u: ControlAction.Usage?) -> ControlLog.TokenUsage? {
        guard let u = u else { return nil }
        return ControlLog.TokenUsage(
            prompt: u.prompt_tokens ?? 0,
            output: u.output_tokens ?? 0,
            thinking: u.thinking_tokens ?? 0,
            total: u.total_tokens ?? 0)
    }

    private func handle(_ action: ControlAction, goal: String, gen: Int, imageWidth: Int, imageHeight: Int) {
        let note = action.note ?? ""
        let stepNumber = steps.count + 1
        // This planning call's token usage (when the gateway reported it), logged
        // next to the step so the control log carries real per-step cost.
        let tokens = Self.tokenUsage(from: action.usage)

        switch action.action {
        case "done":
            ControlLog.decision(runID, n: stepNumber, action: "done", note: note, tokens: tokens)
            stop(reason: note.isEmpty ? "Done." : note)
            return
        case "failed":
            ControlLog.decision(runID, n: stepNumber, action: "failed", note: note, tokens: tokens)
            stop(reason: note.isEmpty ? "Suno Control couldn't do it." : note)
            return
        default:
            break
        }

        // The capsule is excluded from the screenshot, so the planner is blind
        // to where it physically sits — a click it aims at a target under the
        // capsule must pass through, not stop the loop. Drop interactivity for
        // the duration of the action, then restore it for the waits that follow.
        overlay.setInteractive(false)
        let ok = ControlExecutor.perform(action, imageWidth: imageWidth, imageHeight: imageHeight)
        overlay.setInteractive(true)
        let stepSummary = "\(action.action)\(describeAction(action))"
        AppLog.log("control: step \(stepNumber): \(stepSummary) \(ok ? "" : "(REFUSED)")")
        // The dedicated feature log: the full step with its observed context.
        ControlLog.step(runID, n: stepNumber, maxSteps: Self.maxSteps,
                        app: lastApp, window: lastWindow,
                        action: action.action, detail: describeAction(action),
                        note: note, performed: ok, tokens: tokens)
        steps.append(ControlClient.Step(action: action.action, note: note))

        let summary = note.isEmpty ? action.action : note
        overlay.update("\(stepNumber)/\(Self.maxSteps) · \(summary)")

        if !ok {
            // The executor refused (no permission, unknown key…): stop honestly
            // rather than loop on a plan it cannot perform.
            stop(reason: "Suno Control couldn't perform the next step and stopped.")
            return
        }

        // Backstop for a model that won't signal completion: the tool has no
        // "done" action, so once the goal is achieved it tends to emit wait
        // after wait until the step cap. A short run of pure waits means it has
        // nothing left to do — end the run and show its own last note.
        if action.action == "wait" {
            consecutiveWaits += 1
        } else {
            consecutiveWaits = 0
        }
        if consecutiveWaits >= Self.maxConsecutiveWaits {
            stop(reason: note.isEmpty ? "Done." : note)
            return
        }

        // Let the screen settle before judging it again: the action may have
        // launched an app or navigated a page. Quick interactions (click, type,
        // key) settle almost immediately, so they only pay a short pause; drags
        // and scrolls can leave animations running, so they keep the full one.
        let quickSettle: TimeInterval = 0.7
        let fullSettle: TimeInterval = 1.2
        let pause: TimeInterval
        if action.action == "wait" {
            pause = min(max(action.seconds ?? 1, 0.5), 5)
        } else {
            pause = ControlFlow.quickActions.contains(action.action) ? quickSettle : fullSettle
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
            guard let self = self, self.generation == gen, self.state == .running else { return }
            self.step(goal: goal, gen: gen)
        }
    }

    // MARK: - Teardown

    /// Stop everything: any in-flight step's callback is invalidated by the
    /// generation bump, the overlay reports the reason, and the state returns
    /// to idle.
    func stop(reason: String? = nil) {
        guard state != .idle else { return }
        // Capture the run's tally before the reset below clears it.
        let loggedRunID = runID
        let stepsTaken = steps.count
        let duration = runStartedAt > 0 ? Date().timeIntervalSince1970 - runStartedAt : 0
        generation += 1
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        runDeadlineTimer?.invalidate()
        runDeadlineTimer = nil
        if state == .recording {
            recorder.stopRecording()
        }
        state = .idle
        steps = []
        consecutiveWaits = 0
        goal = ""
        if let reason = reason, !reason.isEmpty {
            overlay.update(reason)
            // Let the last words show before the capsule goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self = self, self.state == .idle else { return }
                self.overlay.hide()
            }
        } else {
            overlay.hide()
        }
        onStateChange?()
        AppLog.log("control: stopped (\(reason ?? "no reason"))")
        if !loggedRunID.isEmpty {
            ControlLog.stopped(loggedRunID, reason: reason ?? "", steps: stepsTaken, duration: duration)
        }
        runID = ""
        runStartedAt = 0
    }
}