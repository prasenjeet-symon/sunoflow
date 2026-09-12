// Suno Answer — the query → answer popup feature (docs/SUNO_ANSWER_RESEARCH.md).
//
// Stage 1 of the settled build order (G1–G3): the entire client experience is
// real — the hotkey (registered by AppDelegate from Preferences), the screen
// capture that freezes at the moment the question starts, on-device STT via
// the shared transcription client, the focusable popup, insert-at-cursor, and
// the full dismissal set. Only the answer itself is stubbed: `StubStream`
// stands in for the gateway's `POST /answer` SSE stream until stage 2, and is
// the single seam the real client replaces.

import AppKit
import UniformTypeIdentifiers

/// Raw display capture for a question (F3/A9: the image rides turn 1 only).
///
/// Preflight first — without the Screen Recording permission
/// `CGDisplayCreateImage` returns a valid but entirely black image, not nil.
enum ScreenShot {
    static func capture() -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        return CGDisplayCreateImage(CGMainDisplayID())
    }

    /// Same downscale policy the cleanup screen-context uses (D2: ~1600px
    /// client-side) so the image is cheap to hold and later to send.
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

    /// JPEG bytes for the wire. CGImage has no direct JPEG encoder; NSBitmapImageRep
    /// does. Nil on encode failure — the turn just goes without the image.
    ///
    /// Now that the image rides *every* turn (per-turn capture), the bytes on
    /// the wire matter more: a 0.55 quality factor (the D2 benchmark) trims a
    /// ~1600px screen JPEG by roughly a quarter (measured ~246KB → ~178KB) with
    /// no legibility loss that hurts the answer. Note this saves *upload bytes*,
    /// not model *tokens* — vision models bill by the image's pixel dimensions
    /// (tiles), so the 1600px cap in `downscale` is the lever for token cost;
    /// quality only trims the transfer.
    static func jpegData(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(
            using: NSBitmapImageRep.FileType.jpeg,
            properties: [.compressionFactor: 0.55]
        ) else { return nil }
        // Belt-and-braces against the gateway's per-route body cap: a 1600px
        // JPEG at 0.55 lands far under it, but a pathological desktop (4K of
        // solid noise) must fail here, not at the gateway.
        return data.count <= 3 << 20 ? data : nil
    }
}

final class AnswerFlow: NSObject {
    enum State { case idle, recording, followUpRecording, thinking, streaming, showing }

    /// D4 taxonomy — plain copy, no raw fallback ever, "Try again" is the only
    /// door. Stage 2: the codes arrive from the gateway via the sidecar; the
    /// not_entitled refusal is NOT in this enum because it opens the account
    /// sheet rather than showing an error card.
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
    /// The state a follow-up recording interrupted — Esc-cancel restores it,
    /// because cancelling the take never stopped the in-flight work. Kept
    /// current by finishStream/handleStreamFailure while the recording owns
    /// the UI.
    private var preFollowUpState: State = .showing

    private let recorder = AudioRecorder()
    private var recordingFile: URL?
    private var anchor = NSPoint.zero
    private var screenshot: CGImage?
    private var query = ""
    /// The just-recorded question's loudness envelope and duration, snapshotted
    /// at stop — the voice bubble in the popup is drawn from these. Nil for
    /// typed follow-ups. Cleared with the session (A2).
    private var dictatedEnvelope: [Float]?
    private var dictatedSeconds: Double = 0
    private var streamText = ""
    private var lastAnswer: String?
    /// The last try-on image — Copy and Save act on it while the session lives.
    private var lastImage: NSImage?
    /// The try-on generation riding the current turn's stream, and the
    /// item name the answer surfaced. The garment is this turn's `screenshot`.
    private var tryonTask: URLSessionDataTask?

    /// This session's prior turns, oldest first — the only memory the gateway
    /// gets (it is stateless; F3/A9). Turn 1 is empty; every answer that
    /// finishes appends here so follow-ups carry context. A2 ephemeral: the
    /// array dies with the popup.
    private var history: [(q: String, a: String)] = []

    /// Every piece of deferred work carries the generation it started under;
    /// anything that fires late finds the counter moved and dies quietly.
    private var generation = 0
    private var tokenTimer: DispatchSourceTimer?
    private var maxRecordingTimer: Timer?
    /// The in-flight answer request. Dismiss aborts it mid-stream so the
    /// sidecar stops paying upstream (A10).
    private var streamTask: URLSessionDataTask?

    /// Set at install. True while dictation is recording or about to paste —
    /// the two features are mutually exclusive (A8), and dictation wins.
    private var isDictationBusy: () -> Bool = { false }

    let bubble = RecordingBubbleWindow()
    let popup = AnswerPopupWindow(view: AnswerPanelView())

    // MARK: wiring

    func install(isDictationBusy: @escaping () -> Bool) {
        self.isDictationBusy = isDictationBusy
        popup.panelView?.onSend = { [weak self] text in self?.sendTyped(text) }
        popup.panelView?.onRetry = { [weak self] in self?.retry() }
        popup.panelView?.onInsert = { [weak self] in self?.insertLast() }
        popup.panelView?.onCopy = { [weak self] in
            guard let self else { return }
            if let image = self.lastImage {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(image.tiffRepresentation, forType: .tiff)
                AppLog.log("tryon: copied image")
                return
            }
            guard let text = self.lastAnswer, !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            AppLog.log("answer: copied \(text.count) chars")
        }
        popup.panelView?.onSave = { [weak self] in self?.saveTryonImage() }
        popup.panelView?.onDismiss = { [weak self] in self?.dismiss() }
        popup.panelView?.onPanelClicked = { [weak self] in self?.panelClicked() }
        // The input row's mic = the hotkey while the popup is open: same
        // toggle, same recording state machine, same Esc-to-cancel.
        popup.panelView?.onMicToggle = { [weak self] in self?.toggle() }

        // Esc (A10, revised 2026-09-04) — the only way out while the popup is
        // up. Clicks outside used to dismiss; they now do nothing, so a stray
        // click can never throw away a conversation mid-thought. A local
        // monitor, so it only acts when our app has the event — which is when
        // the popup holds focus.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 /* esc */ else { return event }
            switch self.state {
            case .idle:
                break
            case .followUpRecording:
                // Esc cancels just the recording — the conversation stays put.
                self.cancelFollowUpRecording()
                return nil
            default:
                self.dismiss()
                return nil
            }
            return event
        }

        AppLog.log("Suno Answer installed")
    }

    // MARK: hotkey toggle

    func toggle() {
        guard !isDictationBusy() else {
            NSSound.beep()
            AppLog.log("Answer press ignored — dictation is recording or processing (A8 exclusivity)")
            return
        }
        switch state {
        case .idle:              startRecording()
        case .recording:         stopAndAsk()
        case .followUpRecording: stopFollowUpAndAsk()
        // Popup open: the hotkey records a dictated follow-up instead of
        // tearing the session down (2026-09-04). Esc is the way out.
        case .thinking, .streaming, .showing: startFollowUpRecording()
        }
    }

    // MARK: recording

    private func startRecording() {
        anchor = NSEvent.mouseLocation
        do {
            recordingFile = try recorder.startRecording()
        } catch {
            NSSound.beep()
            AppLog.log("answer: recorder failed: \(error)")
            return
        }
        recorder.onLevel = { [weak self] level in self?.bubble.update(level: level) }
        state = .recording
        armMaxRecordingTimer()

        // The screenshot the model sees must never contain a Suno Answer
        // surface. The grab happens BEFORE the mic bubble is shown; on top of
        // that, force any still-visible surface off screen first — a fast
        // dismiss→re-ask can leave the previous popup or bubble mid fade-out,
        // and `CGDisplayCreateImage` grabs whatever the compositor is showing.
        // When something was actually hidden, let the compositor drop it before
        // the grab; otherwise (the common first-question case) grab inline with
        // no delay. The bubble is shown only after the grab, so it is never in
        // the frame. (F3/A9: the image still rides the first turn only.)
        let gen = generation
        let grabThenShowBubble: () -> Void = { [weak self] in
            guard let self, self.generation == gen, self.state == .recording else { return }
            self.screenshot = ScreenShot.capture().map { ScreenShot.downscale($0, maxEdge: 1600) }
            self.bubble.show(at: self.anchor)
            AppLog.log("answer: recording gen=\(gen) anchor=(\(Int(self.anchor.x)),\(Int(self.anchor.y))) screen=\(self.screenshot != nil)")
        }
        if hideAnswerSurfacesImmediately() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: grabThenShowBubble)
        } else {
            grabThenShowBubble()
        }
    }

    /// Force every Suno Answer surface off screen at once (no fade), so a
    /// screenshot can't catch one — including a popup or bubble still animating
    /// out from a just-dismissed session. Returns whether anything was hidden,
    /// so the caller only pays a compositor-settle delay when it's needed.
    @discardableResult
    private func hideAnswerSurfacesImmediately() -> Bool {
        var hid = false
        if bubble.isVisible {
            bubble.orderOut(nil); bubble.alphaValue = 1; hid = true
        }
        if popup.isVisible {
            popup.orderOut(nil); popup.alphaValue = 1; hid = true
        }
        return hid
    }

    /// Grab a fresh screen for the current turn with the popup kept out of the
    /// frame, then continue. The popup is only made transparent (alpha 0) — not
    /// reordered — so its key state, focus and z-order are untouched; a window at
    /// alpha 0 is composited away and never lands in the capture. When it was
    /// visible we let the compositor drop it before grabbing; otherwise (nothing
    /// on screen) we grab inline with no delay.
    private func captureForTurn(then completion: @escaping () -> Void) {
        let wasVisible = popup.isVisible && popup.alphaValue > 0.01
        if wasVisible { popup.alphaValue = 0 }
        let grab: () -> Void = { [weak self] in
            guard let self else { return }
            self.screenshot = ScreenShot.capture().map { ScreenShot.downscale($0, maxEdge: 1600) }
            if wasVisible { self.popup.alphaValue = 1 }
            completion()
        }
        if wasVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: grab)
        } else {
            grab()
        }
    }

    /// Bring the conversation back after it was made transparent for a capture
    /// or a dictated follow-up recording.
    private func restorePopupIfHidden() {
        guard popup.alphaValue < 0.99 else { return }
        popup.alphaValue = 1
        popup.makeKeyAndOrderFront(nil)
    }

    /// A forgotten question ends itself, like a dictation does — 30s is a long
    /// question already. Serves both recording flavors; whichever is live when
    /// the fuse burns down is the one that stops.
    private func armMaxRecordingTimer() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(max(Preferences.shared.maxRecordingSeconds, 30)), repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            switch self.state {
            case .recording:
                AppLog.log("answer: max recording duration reached — auto-stopping")
                self.stopAndAsk()
            case .followUpRecording:
                AppLog.log("answer: max recording duration reached — auto-stopping follow-up")
                self.stopFollowUpAndAsk()
            default:
                break
            }
        }
    }

    private func stopAndAsk() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        recorder.stopRecording()
        bubble.hide()
        guard let file = recordingFile else { dismiss(); return }
        recordingFile = nil
        // The bubble replays the real recording: snapshot the envelope and
        // duration before the next recording reuses the recorder.
        dictatedEnvelope = recorder.envelope
        dictatedSeconds = Double(recorder.envelope.count) * 1024.0 / 16000.0
        state = .thinking
        streamText = ""
        popup.panelView?.reset()
        popup.show(at: anchor)
        popup.panelView?.setStatus("Thinking…")
        popup.panelView?.showThinking()
        let gen = generation
        AppLog.log("answer: asking gen=\(gen)")
        transcribe(file, gen: gen) { [weak self] result in
            guard let self, self.generation == gen, self.state == .thinking else { return }
            switch result {
            case .success(let raw):
                let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else { self.showError(.unable); return }
                self.query = q
                self.addDictatedTurn()
                self.beginStream()
            case .failure(let error):
                AppLog.log("answer: STT failed: \(error)")
                self.showError(.unavailable)
            }
        }
    }

    // MARK: voice follow-ups (2026-09-04)

    /// Records a follow-up. Like the first question, it hides the conversation,
    /// grabs a fresh screen for THIS turn (per-turn capture, Suno's own UI kept
    /// out of frame), and shows the mic bubble at the cursor — one recording
    /// surface for every turn. Everything in flight keeps running while you
    /// speak; the abort happens at stop, exactly like a typed follow-up.
    private func startFollowUpRecording() {
        if state == .thinking {
            // A question's transcription is still in flight. It was never
            // rendered (the turn's bubble lands only after STT returns), so
            // abandoning it here keeps the transcript coherent: the take
            // being recorded becomes the turn. Same posture as a typed
            // follow-up arriving during thinking.
            AppLog.log("answer: hotkey during thinking — in-flight transcription abandoned")
            generation += 1
            cancelWork()
            popup.panelView?.removeMarker()
        }
        do {
            recordingFile = try recorder.startRecording()
        } catch {
            NSSound.beep()
            AppLog.log("answer: follow-up recorder failed: \(error)")
            return
        }
        recorder.onLevel = { [weak self] level in self?.bubble.update(level: level) }
        // Never .thinking — its work was just abandoned (above); a cancel
        // must not restore a dead state.
        preFollowUpState = state == .thinking ? .showing : state
        state = .followUpRecording
        anchor = NSEvent.mouseLocation
        popup.panelView?.setStatus("Listening…")
        // Take the conversation out of the frame, grab this turn's screen, then
        // show the mic bubble. The popup is only made transparent (state kept),
        // so an in-flight answer keeps streaming behind it and returns intact.
        popup.alphaValue = 0
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            guard self.generation == gen, self.state == .followUpRecording else {
                // Stopped/cancelled before the grab — put the popup back, unless
                // the session was dismissed (then it must stay gone).
                if self.state != .idle { self.restorePopupIfHidden() }
                return
            }
            self.screenshot = ScreenShot.capture().map { ScreenShot.downscale($0, maxEdge: 1600) }
            self.bubble.show(at: self.anchor)
        }
        armMaxRecordingTimer()
        AppLog.log("answer: follow-up recording gen=\(generation)")
    }

    /// Stops the follow-up and answers it: aborts whatever was in flight
    /// (stream or STT — the generation bump), then runs the same
    /// thinking → stream path as the first question.
    private func stopFollowUpAndAsk() {
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        recorder.stopRecording()
        // The mic bubble goes; the conversation comes back to receive the turn.
        bubble.hide()
        restorePopupIfHidden()
        guard let file = recordingFile else { dismiss(); return }
        recordingFile = nil
        // Snapshot the envelope before the next recording reuses the recorder.
        dictatedEnvelope = recorder.envelope
        dictatedSeconds = Double(recorder.envelope.count) * 1024.0 / 16000.0
        generation += 1
        cancelWork()
        // Whatever the interrupted turn was streaming is dead now — finalize
        // its partial text so it doesn't linger as raw plain text. (No-op
        // when the interrupted state was thinking/showing.)
        popup.panelView?.endAnswer()
        // The listening pill becomes this turn's permanent voice bubble — the
        // conversion happens at stop, before the thinking marker, so the
        // transcript reads turn → thinking in order.
        popup.panelView?.commitListeningAsVoice(envelope: dictatedEnvelope ?? [], seconds: dictatedSeconds)
        state = .thinking
        streamText = ""
        popup.panelView?.setStatus("Thinking…")
        popup.panelView?.showThinking()
        let gen = generation
        AppLog.log("answer: follow-up asking gen=\(gen)")
        transcribe(file, gen: gen) { [weak self] result in
            guard let self, self.generation == gen, self.state == .thinking else { return }
            switch result {
            case .success(let raw):
                let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !q.isEmpty else { self.showError(.unable); return }
                self.query = q
                self.beginStream()
            case .failure(let error):
                AppLog.log("answer: follow-up STT failed: \(error)")
                self.showError(.unavailable)
            }
        }
    }

    /// Esc while recording a follow-up: throw the take away, keep the
    /// conversation exactly as it was. No generation bump — an in-flight
    /// stream from the previous turn never stopped being live.
    private func cancelFollowUpRecording() {
        guard state == .followUpRecording else { return }
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        recorder.stopRecording()
        recordingFile = nil
        dictatedEnvelope = nil
        dictatedSeconds = 0
        // The mic bubble goes; the conversation comes back exactly as it was.
        bubble.hide()
        restorePopupIfHidden()
        popup.panelView?.cancelListening()
        state = preFollowUpState
        // A turn that failed while the take was being recorded parked its
        // error card below the pill; it survives the cancel, so the status
        // must agree with it ("Stopped", not a phantom "Ready").
        if popup.panelView?.showsErrorCard == true {
            popup.panelView?.setStatus("Stopped")
        } else if preFollowUpState == .streaming {
            popup.panelView?.setStatus("Answering…")
        } else {
            popup.panelView?.setStatus("Ready")
        }
        AppLog.log("answer: follow-up recording cancelled gen=\(generation)")
    }

    // MARK: STT (shared client, cleanup off — the raw transcript becomes the
    // question; the sidecar corrects it against the dictionary on the way out)

    private func transcribe(_ file: URL, gen: Int, completion: @escaping (Result<String, Error>) -> Void) {
        // Follow the SAME cloud-STT route dictation uses: with the local model
        // slow or not yet resident (a machine the warm-start controller keeps on
        // cloud), forcing local here would make Answer sluggish — or fail with an
        // empty transcript — while dictation is happily on cloud. The route is
        // always consented (the first-run disclosure covers it) and only applies
        // until the device cuts over to on-device, so Answer never becomes the
        // exception.
        TranscriptionClient.transcribe(fileURL: file, cleanup: false) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let transcription):
                    completion(.success(transcription.raw))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: answer stream (stage 2: real SSE client via the sidecar)

    private func beginStream() {
        state = .streaming
        popup.panelView?.setStatus("Answering…")
        // Quota counts a message when its stream starts (D5) — the gateway
        // increments on the way in, so this log marks the spend.
        AppLog.log("answer: stream start (quota spent) gen=\(generation) image=\(screenshot != nil)")
        runStream()
    }

    /// The dictated turn's bubble, added right before its answer streams: the
    /// recording's real envelope as the waveform — the transcribed text is
    /// deliberately never shown. A lost envelope (recorder produced nothing)
    /// degrades to a quiet plain bubble so the turn stays visible. Follow-ups
    /// skip this — their listening pill already became the bubble at stop.
    private func addDictatedTurn() {
        if let env = dictatedEnvelope, !env.isEmpty {
            popup.panelView?.addUserTurn(envelope: env, seconds: dictatedSeconds)
        } else {
            popup.panelView?.addUserTurn(text: "🎙 Voice question")
        }
    }

    /// One answer turn against the sidecar. The current turn's screenshot rides
    /// every turn now (per-turn capture): `screenshot` is refreshed — with Suno's
    /// own UI kept out of frame — at the start of each dictated recording and
    /// before each typed send, so the model always sees the current screen. A
    /// retry reuses whatever `screenshot` the failed turn had (same request).
    private func runStream() {
        streamText = ""
        popup.panelView?.beginAnswer()
        let gen = generation
        streamTask = AnswerClient.stream(
            AnswerClient.Request(
                query: query,
                history: history,
                imageJPEG: screenshot.flatMap { ScreenShot.jpegData($0) },
                tryonAvailable: PersonPhoto.exists
            ),
            onEvent: { [weak self] event in
                guard let self, self.generation == gen else { return }
                DispatchQueue.main.async { self.handleStreamEvent(event, gen: gen) }
            },
            completion: { [weak self] result in
                guard let self, self.generation == gen else { return }
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    switch result {
                    case .success:
                        self.finishStream()
                    case .failure(let error):
                        self.handleStreamFailure(error)
                    }
                }
            }
        )
    }

    private func handleStreamEvent(_ event: AnswerClient.Event, gen: Int) {
        guard generation == gen else { return }
        switch event {
        case .meta:
            break // lease refresh; nothing to render
        case .query(let corrected):
            // The sidecar fixed mis-heard words against the dictionary before
            // the gateway saw the question. The popup shows a voice bubble, so
            // there is no on-screen transcript to revise — the correction just
            // becomes the question the gateway, history, and Insert all see.
            query = corrected
        case .delta(let text):
            streamText += text
            popup.panelView?.appendAnswer(text)
        case .sources:
            break // cited-source chips are not shown; the event is ignored
        case .tryon(let item):
            handleTryon(item: item, gen: gen)
        case .done:
            finishStream()
        case .error:
            break // parser-internal; completion carries the failure
        }
    }

    private func handleStreamFailure(_ error: AnswerClientError) {
        if case .notEntitled(let code, let message) = error {
            // Same treatment as a dictation refusal: the account sheet, not
            // an error card. A10: the session ends — dismiss, then surface.
            // Never suppressed by a follow-up recording: a lapsed
            // subscription ends the session wherever it is.
            AppLog.log("answer: not entitled (\(code))")
            dismiss()
            NotificationCenter.default.post(
                name: .sunoAnswerNotEntitled, object: nil,
                userInfo: ["message": message, "code": code]
            )
            return
        }
        if state == .followUpRecording {
            // A previous turn's stream died while a follow-up is being
            // recorded. The recording keeps the state (and the "Listening…"
            // status); the card is parked BELOW the pill so the user sees
            // the turn failed, and the partial text is finalized so it does
            // not linger unrendered. The follow-up's own turn supersedes
            // the card; an Esc-cancel leaves it with a working Try again.
            AppLog.log("answer: stream failed during follow-up recording — card parked (\(error))")
            preFollowUpState = .showing
            popup.panelView?.endAnswer()
        }
        let flowError: AnswerError
        switch error {
        case .limit:      flowError = .limit
        case .timeout:    flowError = .timeout
        case .unable:     flowError = .unable
        default:          flowError = .unavailable
        }
        showError(flowError)
    }

    // MARK: try-on (the `tryon` event rides the answer stream)

    /// The answer surfaced a try-on request for `item`. With a person photo on
    /// file the generation runs right beside the still-streaming answer — the
    /// pending card lands first, the image replaces it when it lands. Without
    /// one, an informational card points at Settings; the answer keeps
    /// streaming either way. The garment is this turn's screenshot (the capture
    /// the answer turn already paid for — no recapture).
    private func handleTryon(item: String, gen: Int) {
        guard PersonPhoto.exists, let garmentJPEG = screenshot.flatMap({ ScreenShot.jpegData($0) }),
              let personJPEG = PersonPhoto.loadJPEG() else {
            AppLog.log("answer: tryon requested (\(item)) but no person photo on file")
            popup.panelView?.showTryonSetup()
            return
        }
        AppLog.log("tryon: requested item=\(item) gen=\(gen) garment=\(garmentJPEG.count)B")
        popup.panelView?.showTryonPending()
        tryonTask = TryonClient.generate(
            item: item,
            query: query,
            personJPEG: personJPEG,
            garmentJPEG: garmentJPEG,
            context: tryonContext()
        ) { [weak self] result in
            guard let self, self.generation == gen else { return }
            DispatchQueue.main.async {
                guard self.generation == gen else { return }
                switch result {
                case .success(let image):
                    guard let data = PersonPhoto.jpegData(image, quality: 0.9) else {
                        self.showTryonFailure(TryonClientError.unavailable)
                        return
                    }
                    AppLog.log("tryon: done item=\(item) (\(data.count)B)")
                    self.lastImage = image
                    self.popup.panelView?.showTryonImage(base64: data.base64EncodedString())
                case .failure(let error):
                    self.showTryonFailure(error)
                }
            }
        }
    }

    /// A failed generation clears the pending card and shows its message as an
    /// error card. A 402 refusal is NOT here: it opens the account sheet, like
    /// every other entitlement refusal, and the session goes with it.
    private func showTryonFailure(_ error: TryonClientError) {
        if case .notEntitled(let code, let message) = error {
            AppLog.log("tryon: not entitled (\(code))")
            dismiss()
            NotificationCenter.default.post(
                name: .sunoAnswerNotEntitled, object: nil,
                userInfo: ["message": message, "code": code]
            )
            return
        }
        AppLog.log("tryon: failed (\(error))")
        popup.panelView?.showErrorCard(message: error.message) { [weak self] in self?.retry() }
    }

    /// Save the last try-on image through NSSavePanel. The panel is a sheet on
    /// the popup, so the conversation stays put.
    private func saveTryonImage() {
        guard let image = lastImage else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Suno Try-on"
        panel.allowedContentTypes = [.png]
        guard let win = popup.panelView?.window else { return }
        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK, let url = panel.url,
                  let data = PersonPhoto.jpegData(image, quality: 0.95) else { return }
            do {
                try data.write(to: url, options: .atomic)
                AppLog.log("tryon: saved \(url.lastPathComponent)")
            } catch {
                NSSound.beep()
                AppLog.log("tryon: save failed: \(error)")
            }
        }
    }

    /// Observed context for the generation: frontmost app name and window
    /// title, read live at call time (the try-on fires mid-turn, so the target
    /// app is still frontmost). Best-effort; empty strings are fine.
    private func tryonContext() -> [String: String] {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return [:]
        }
        var app = front.localizedName ?? ""
        var window = ""
        // NSRunningApplication has no window access; the focused window's title
        // comes through the same Accessibility read ForegroundApp uses.
        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        if let focused = ForegroundApp.focusedWindow(of: appElement) {
            window = (ForegroundApp.copyAttribute(focused, kAXTitleAttribute) as? String) ?? ""
        }
        if app.count > 80 { app = String(app.prefix(80)) }
        if window.count > 200 { window = String(window.prefix(200)) }
        return ["app": app, "window": window]
    }

    private func finishStream() {
        // A stream that completes while a follow-up is being recorded still
        // banks into history — the user watched it finish — but the recording
        // keeps ownership of the state (and the action row stays down until
        // the follow-up's own answer arrives).
        guard state == .streaming || state == .followUpRecording else { return }
        let recordingFollowUp = state == .followUpRecording
        if !recordingFollowUp { state = .showing } else { preFollowUpState = .showing }
        lastAnswer = streamText
        history.append((q: query, a: streamText))
        popup.panelView?.endAnswer()
        if !recordingFollowUp {
            popup.panelView?.setStatus("Ready")
            // The Insert/Copy row appears with the answer. The gateway's
            // cited-source domains ride the stream but are not shown.
            popup.panelView?.showAnswerActions()
        }
        AppLog.log("answer: stream done (\(streamText.count) chars)")
    }

    private func showError(_ error: AnswerError) {
        let recording = state == .followUpRecording
        if !recording {
            state = .showing
            popup.panelView?.setStatus("Stopped")
        }
        // While a follow-up records, both are left alone: the state belongs
        // to the recording, and the status still says Listening….
        popup.panelView?.showErrorCard(message: error.message) { [weak self] in self?.retry() }
        AppLog.log("answer: error card \(error.rawValue)")
    }

    // MARK: follow-ups + retry

    private func sendTyped(_ text: String) {
        guard state != .followUpRecording else {
            // A dictated follow-up owns the turn; the mic has it.
            NSSound.beep()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A typed follow-up aborts anything in flight and starts its own turn
        // (A4: follow-ups typed into the popup are supported).
        generation += 1
        cancelWork()
        query = trimmed
        dictatedEnvelope = nil
        state = .streaming
        popup.panelView?.setStatus("Answering…")
        AppLog.log("answer: typed follow-up (quota spent) gen=\(generation)")
        // Per-turn capture: grab the current screen (popup briefly out of frame)
        // so a typed follow-up about a different part of the screen is grounded
        // in what's there now — then show the turn and stream.
        let gen = generation
        captureForTurn { [weak self] in
            guard let self, self.generation == gen, self.state == .streaming else { return }
            self.popup.panelView?.addUserTurn(text: trimmed)
            self.runStream()
        }
    }

    private func retry() {
        // Reachable only from a visible error card's Try again. While a
        // follow-up records (.followUpRecording) or its question is being
        // transcribed (.thinking) over a parked card, the recording owns the
        // turn — a retry here would fight it, so it beeps.
        guard state == .showing else { NSSound.beep(); return }
        // "Try again" re-sends the identical turn; the image stays client-side
        // (D4). The turn that failed is NOT in history, so this is exactly the
        // same request shape the failed turn had — including the screenshot if
        // this is still turn 1.
        generation += 1
        cancelWork()
        state = .streaming
        popup.panelView?.setStatus("Answering…")
        AppLog.log("answer: retry (quota spent again) gen=\(generation)")
        // Re-send the identical turn, image included — `screenshot` still holds
        // the failed turn's capture (the next turn hasn't overwritten it).
        runStream()
    }

    // MARK: dismissal (A10) + insert (A5)

    func dismiss() {
        guard state != .idle else { return }
        generation += 1
        cancelWork()
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil
        if recorder.isRecording {
            recorder.stopRecording()
        }
        bubble.hide()
        popup.hide()
        // The input row's mic badge lives outside the transcript; make sure it
        // returns to rest however the session ends.
        popup.panelView?.cancelListening()
        state = .idle
        // Ephemeral by design (A2): dismissing takes the whole conversation
        // with it — text, sources, screenshot, everything.
        streamText = ""
        query = ""
        dictatedEnvelope = nil
        dictatedSeconds = 0
        lastAnswer = nil
        lastImage = nil
        screenshot = nil
        history = []
        preFollowUpState = .showing
        AppLog.log("answer: dismissed (abort) gen=\(generation)")
    }

    private func cancelWork() {
        tokenTimer?.cancel()
        tokenTimer = nil
        streamTask?.cancel()
        streamTask = nil
        tryonTask?.cancel()
        tryonTask = nil
    }

    private func panelClicked() {
        guard !popup.isKeyWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        popup.makeKeyAndOrderFront(nil)
        popup.panelView?.focusInput()
        AppLog.log("answer: click promoted panel to key")
    }

    private func insertLast() {
        guard state != .followUpRecording else { NSSound.beep(); return }
        guard let text = lastAnswer, !text.isEmpty else { return }
        let wasKey = popup.isKeyWindow
        AppLog.log("answer: INSERT popupWasKey=\(wasKey) chars=\(text.count)")
        dismiss()
        // If our accessory app is frontmost (the popup had focus), hand focus
        // back to the previous app before pasting, or the paste lands nowhere.
        if NSApp.isActive { NSApp.hide(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            TextInjector.insert(text)
        }
    }
}