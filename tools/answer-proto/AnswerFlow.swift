// PROTOTYPE — throwaway. State machine + stubbed answer stream for the Suno
// Answer G2 popup questions (docs/SUNO_ANSWER_RESEARCH.md §G2). Lives in
// tools/answer-proto/, never ships. Production wiring replaces StubStream
// with the real SSE client and moves the state machine into AppDelegate.

import AppKit
import Carbon

// ───────────────────────── env knobs ─────────────────────────

enum ProtoKnobs {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static func string(_ name: String) -> String? {
        guard let raw = env[name], !raw.isEmpty else { return nil }
        return raw
    }
    private static func number(_ name: String) -> Double? {
        string(name).flatMap(Double.init)
    }

    static var focusMode: String { string("PROTO_FOCUS") ?? "on-appear" }
    static var isClickToFocus: Bool { focusMode == "click" }
    static var ttfb: TimeInterval { number("PROTO_TTFB") ?? 1.5 }
    /// Stub stream speed in characters per second (flash-lite streams fast).
    static var speed: Double { number("PROTO_SPEED") ?? 220 }
    static var failMode: String? { string("PROTO_FAIL") }
    static var sidecarStubbed: Bool { string("PROTO_SIDECAR") == "0" }
    static var keyOverride: String? { string("PROTO_KEY") }
}

/// ⌃⌥Space (A6). Default OFF in production (consent-gated); here it is on so
/// the prototype can be driven without touching Settings.
enum DefaultAnswerHotkey {
    static let keyCode: UInt32 = 49
    static let modifiers: UInt32 = UInt32(controlKey | optionKey)
    /// Fallback when ⌃⌥Space is taken: ⌘⌥Space (⌃⌘Space is the emoji picker).
    static let fallbackKeyCode: UInt32 = 49
    static let fallbackModifiers: UInt32 = UInt32(cmdKey | optionKey)
}

enum ProtoError: Error {
    case noKey
    case entitlement
    case badStatus(Int)
}

enum ScreenShot {
    /// Raw display capture (F3/A9: the image rides turn 1). Preflight first —
    /// without permission CGDisplayCreateImage returns a valid black image.
    static func capture() -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        return CGDisplayCreateImage(CGMainDisplayID())
    }

    /// Same downscale policy the cleanup screen-context uses (D2: ~1600px
    /// client-side) so the thumbnail is cheap to hold and later to send.
    static func downscale(_ image: CGImage, maxEdge: CGFloat) -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let longest = max(w, h)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
}

// ───────────────────────── state machine ─────────────────────────

final class AnswerFlow: NSObject {
    enum State { case idle, recording, thinking, streaming, showing }

    /// D4 taxonomy — plain copy, no raw fallback ever, "Try again" is the only door.
    enum AnswerError: String {
        case unavailable, timeout, limit, unable

        var message: String {
            switch self {
            case .unavailable: return "Suno can't reach the service right now. Check your connection, then try again."
            case .timeout:     return "This took too long and was stopped. Try again."
            case .limit:       return "You've used today's messages. Your limit resets tomorrow."
            case .unable:      return "Suno couldn't answer that one. Try rephrasing your question."
            }
        }
    }

    private(set) var state: State = .idle

    private let recorder = AudioRecorder()
    private var recordingFile: URL?
    private var anchor = NSPoint.zero
    private var screenshot: CGImage?
    private var query = ""
    private var streamText = ""
    private var lastAnswer: String?

    /// Every piece of deferred work carries the generation it started under;
    /// anything that fires late finds the counter moved and dies quietly.
    private var generation = 0
    private var transcribeTask: URLSessionDataTask?
    private var tokenTimer: DispatchSourceTimer?
    private var failTimer: DispatchSourceTimer?

    let bubble = RecordingBubbleWindow()
    let popup = AnswerPopupWindow(view: AnswerPanelView())

    private var hotkey: HotkeyManager?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// Last time the popup became key — backs the click-outside veto window
    /// (a click that GRANTS focus must not immediately count as "outside").
    private var popupBecameKeyAt: Date?

    // MARK: wiring

    func install() {
        popup.panelView?.onSend = { [weak self] text in self?.sendTyped(text) }
        popup.panelView?.onRetry = { [weak self] in self?.retry() }
        popup.panelView?.onInsert = { [weak self] in self?.insertLast() }
        popup.panelView?.onCopy = { [weak self] in
            guard let self, let text = self.lastAnswer, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            AppLog.log("answer proto: copied \(text.count) chars")
        }
        popup.panelView?.onDismiss = { [weak self] in self?.dismiss() }
        popup.panelView?.onPanelClicked = { [weak self] in self?.panelClicked() }
        popup.onBecameKey = { [weak self] in self?.popupBecameKeyAt = Date() }

        let hk = HotkeyManager(id: 3)
        hk.onHotkey = { [weak self] in self?.toggle() }
        var code = DefaultAnswerHotkey.keyCode
        var mods = DefaultAnswerHotkey.modifiers
        if !hk.register(keyCode: code, modifiers: mods) {
            code = DefaultAnswerHotkey.fallbackKeyCode
            mods = DefaultAnswerHotkey.fallbackModifiers
            let ok = hk.register(keyCode: code, modifiers: mods)
            AppLog.log("answer proto: ⌃⌥Space taken, fallback ⌘⌥Space registered=\(ok)")
        }
        hotkey = hk

        // Click-outside (A10): global mouse monitor sees clicks in other apps
        // without intercepting them. Fires only while the popup is up.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.clickOutside()
        }
        // Esc (A10) — local monitor so it only acts when our app has the event.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 /* esc */ else { return event }
            if self.state != .idle {
                self.dismiss()
                return nil
            }
            return event
        }

        AppLog.log("answer proto installed: focus=\(ProtoKnobs.focusMode) ttfb=\(ProtoKnobs.ttfb) speed=\(ProtoKnobs.speed)")
    }

    // MARK: hotkey

    func toggle() {
        switch state {
        case .idle:       startRecording()
        case .recording:  stopAndAsk()
        case .thinking, .streaming, .showing: dismiss()
        }
    }

    // MARK: recording

    private func startRecording() {
        // Capture NOW — the screen is frozen at the moment the question starts
        // (F3/A9); the thumbnail rides the first turn only.
        screenshot = ScreenShot.capture().map { ScreenShot.downscale($0, maxEdge: 1600) }
        anchor = NSEvent.mouseLocation
        do {
            recordingFile = try recorder.startRecording()
        } catch {
            AppLog.log("answer proto: recorder failed: \(error)")
            return
        }
        recorder.onLevel = { [weak self] level in self?.bubble.update(level: level) }
        bubble.show(at: anchor)
        state = .recording
        AppLog.log("answer proto: recording gen=\(generation) anchor=(\(Int(anchor.x)),\(Int(anchor.y))) screen=\(screenshot != nil)")
    }

    private func stopAndAsk() {
        recorder.stopRecording()
        bubble.hide()
        guard let file = recordingFile else { dismiss(); return }
        recordingFile = nil
        state = .thinking
        streamText = ""
        popup.panelView?.reset()
        popup.show(at: anchor, clickToFocus: ProtoKnobs.isClickToFocus)
        popup.panelView?.setStatus("Thinking…")
        popup.panelView?.showThinking()
        let gen = generation
        AppLog.log("answer proto: asking gen=\(gen)")
        transcribe(file, gen: gen) { [weak self] result in
            guard let self, self.generation == gen, self.state == .thinking else { return }
            switch result {
            case .success(let raw):
                let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else { self.showError(.unable); return }
                self.query = q
                self.beginStream()
            case .failure(let error):
                AppLog.log("answer proto: STT failed: \(error)")
                self.showError(.unavailable)
            }
        }
    }

    // MARK: STT (real sidecar; production moves this into the shared client)

    private func transcribe(_ file: URL, gen: Int, completion: @escaping (Result<String, Error>) -> Void) {
        if ProtoKnobs.sidecarStubbed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.generation == gen else { return }
                completion(.success("what's the fastest way to ship a mac app outside the app store"))
            }
            return
        }
        guard let audio = try? Data(contentsOf: file) else {
            completion(.failure(ProtoError.badStatus(0)))
            return
        }
        guard let key = ProtoKnobs.keyOverride ?? Keychain.deviceKey() else {
            AppLog.log("answer proto: no device key — set PROTO_KEY or allow Keychain access")
            completion(.failure(ProtoError.noKey))
            return
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/transcribe?cleanup=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "X-SunoFlow-Device-Key")
        let boundary = "Proto-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse, let data else {
                    completion(.failure(ProtoError.badStatus(0)))
                    return
                }
                if http.statusCode == 402 {
                    completion(.failure(ProtoError.entitlement))
                    return
                }
                guard http.statusCode == 200 else {
                    completion(.failure(ProtoError.badStatus(http.statusCode)))
                    return
                }
                struct Response: Decodable { let raw: String; let cleaned: String }
                do {
                    completion(.success(try JSONDecoder().decode(Response.self, from: data).raw))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        transcribeTask = task
        task.resume()
    }

    // MARK: stubbed answer stream (C3; the real SSE client replaces StubStream)

    private func beginStream() {
        state = .streaming
        popup.panelView?.addUserTurn(text: query, thumbnail: screenshot)
        popup.panelView?.setStatus("Answering…")
        // Quota counts a message when its stream starts (batch-2 consequence).
        AppLog.log("answer proto: stream start (quota spent) gen=\(generation)")
        let gen = generation
        if let fail = ProtoKnobs.failMode.flatMap({ AnswerError(rawValue: $0) }) {
            // Realistic shape: the TTFB elapses, THEN the error card appears.
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + ProtoKnobs.ttfb)
            timer.setEventHandler { [weak self] in
                timer.cancel()
                guard let self, self.generation == gen, self.state == .streaming else { return }
                self.showError(fail)
            }
            failTimer = timer
            timer.resume()
            return
        }
        emit(StubStream.answer(for: query), gen: gen)
    }

    private func emit(_ text: String, gen: Int) {
        streamText = ""
        popup.panelView?.beginAnswer()
        var index = text.startIndex
        let intervalMs = 80
        let perTick = max(1, Int((ProtoKnobs.speed * Double(intervalMs) / 1000.0).rounded()))
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + ProtoKnobs.ttfb, repeating: .milliseconds(intervalMs))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.generation == gen, self.state == .streaming else {
                timer.cancel()
                return
            }
            if index >= text.endIndex {
                timer.cancel()
                self.finishStream()
                return
            }
            var end = index
            for _ in 0..<perTick where end < text.endIndex {
                end = text.index(after: end)
            }
            let chunk = String(text[index..<end])
            index = end
            self.streamText += chunk
            self.popup.panelView?.appendAnswer(chunk)
            self.popup.panelView?.scrollToBottom()
        }
        tokenTimer = timer
        timer.resume()
    }

    private func finishStream() {
        guard state == .streaming else { return }
        state = .showing
        lastAnswer = streamText
        popup.panelView?.endAnswer(sources: StubStream.sources(for: query))
        popup.panelView?.setStatus("Ready")
        AppLog.log("answer proto: stream done (\(streamText.count) chars)")
    }

    private func showError(_ error: AnswerError) {
        state = .showing
        popup.panelView?.showErrorCard(message: error.message) { [weak self] in self?.retry() }
        popup.panelView?.setStatus("Stopped")
        AppLog.log("answer proto: error card \(error.rawValue)")
    }

    // MARK: follow-ups + retry

    private func sendTyped(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A typed follow-up aborts anything in flight and starts its own turn
        // (A4: follow-ups typed into the popup are supported).
        generation += 1
        cancelWork()
        query = trimmed
        state = .streaming
        popup.panelView?.addUserTurn(text: trimmed, thumbnail: nil)
        popup.panelView?.setStatus("Answering…")
        AppLog.log("answer proto: typed follow-up (quota spent) gen=\(generation)")
        emit(StubStream.answer(for: trimmed), gen: generation)
    }

    private func retry() {
        // "Try again" re-sends the identical turn; the image stays client-side.
        generation += 1
        cancelWork()
        state = .streaming
        popup.panelView?.setStatus("Answering…")
        AppLog.log("answer proto: retry (quota spent again) gen=\(generation)")
        emit(StubStream.answer(for: query), gen: generation)
    }

    // MARK: dismissal (A10) + insert (A5)

    func dismiss() {
        guard state != .idle else { return }
        generation += 1
        cancelWork()
        recorder.stopRecording()
        bubble.hide()
        popup.hide()
        state = .idle
        streamText = ""
        AppLog.log("answer proto: dismissed (abort) gen=\(generation)")
    }

    private func cancelWork() {
        transcribeTask?.cancel()
        transcribeTask = nil
        tokenTimer?.cancel()
        tokenTimer = nil
        failTimer?.cancel()
        failTimer = nil
    }

    private func panelClicked() {
        guard ProtoKnobs.isClickToFocus, !popup.isKeyWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        popup.makeKeyAndOrderFront(nil)
        popup.panelView?.focusInput()
        AppLog.log("answer proto: click-to-focus promoted panel to key")
    }

    private func clickOutside() {
        guard state != .idle, state != .recording else { return }
        let point = NSEvent.mouseLocation
        guard !popup.frame.insetBy(dx: -4, dy: -4).contains(point) else { return }
        // Veto: a click that just GRANTED focus (resign/click race) is not a
        // dismissal — this is exactly the G2 focus race we are measuring.
        if let granted = popupBecameKeyAt, Date().timeIntervalSince(granted) < 0.35 {
            AppLog.log("answer proto: click-outside suppressed (focus granted 0.\(Int(Date().timeIntervalSince(granted) * 1000))s ago)")
            return
        }
        dismiss()
    }

    private func insertLast() {
        guard let text = lastAnswer, !text.isEmpty else { return }
        let wasKey = popup.isKeyWindow
        AppLog.log("answer proto: INSERT popupWasKey=\(wasKey) chars=\(text.count) — G2 focus datapoint")
        dismiss()
        // If our accessory app is frontmost (popup had focus), hand focus back
        // to the previous app before pasting, or the paste lands nowhere.
        if NSApp.isActive { NSApp.hide(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            TextInjector.insert(text)
        }
    }
}

// ───────────────────────── stub content ─────────────────────────

enum StubStream {
    static func answer(for query: String) -> String {
        let q = query.lowercased()
        if q.contains("weather") {
            return "Today: 24°C and partly cloudy, easing to 18°C overnight. Rain arrives Thursday afternoon (70%) and clears by Friday morning. The weekend stays dry with light winds — fine for anything outdoors.\n\n• Three services agree within a degree; the hourly breakdown is stubbed.\n• Anything time-sensitive comes from the freshest result, which is why grounding beats a frozen model here."
        }
        if q.contains("panel") || q.contains("focus") || q.contains("swift") || q.contains("key") {
            return "For a focusable floating panel: NSPanel with borderless styling and canBecomeKey overridden to true. The trap is .nonactivatingPanel — clicks land, but the panel never takes key focus, so typed follow-ups go nowhere. For focus-on-appear, call NSApp.activate(ignoringOtherApps:) then makeKeyAndOrderFront; for click-to-focus, order front and let the click promote it.\n\nThe G2 question is which of those two feels right — this prototype exists to answer it."
        }
        return "Here's the short version on “\(query)”:\n\nSuno Answer streams a grounded response over SSE from POST /answer, with google_search doing the lookups server-side. The top results agree on the core fact and differ on the details, and the freshest source is usually the one that matters for anything version- or price-shaped.\n\n• The consensus answer lands within the first two results.\n• Time-sensitive claims (prices, versions, dates) come from the newest result — that is the whole reason for grounding.\n\nThis text is stubbed; the question G2 answers is the feel, not the facts."
    }

    static func sources(for query: String) -> [String] {
        let q = query.lowercased()
        if q.contains("weather") { return ["weather.com", "accuweather.com", "yr.no"] }
        if q.contains("panel") || q.contains("focus") || q.contains("swift") || q.contains("key") {
            return ["developer.apple.com", "stackoverflow.com", "swift.org"]
        }
        return ["en.wikipedia.org", "stackoverflow.com", "developer.apple.com"]
    }
}