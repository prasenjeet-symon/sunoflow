import Cocoa
import CoreGraphics
import Vision

/// Best-effort screen capture + on-device OCR for heuristic context.
///
/// When dictation stops, we capture the main display and run Vision's fast
/// OCR to extract the words visible on screen. This gives the cleanup LLM
/// rough context about the app the user is typing into (window titles, menu
/// items, nearby labels) so it can pick better terminology and phrasing.
///
/// Accuracy is *not* the goal — we only need the vocabulary on screen. So we
/// use Vision's `.fast` recognition level and downscale the capture to keep
/// it snappy. Everything runs on-device; only the extracted words leave the
/// machine, and they go to the cleanup endpoint alongside the transcript.
///
/// Requires the Screen Recording TCC permission. Without it,
/// `CGDisplayCreateImage` returns a valid but entirely black image (it does
/// *not* return nil), so we preflight with `CGPreflightScreenCaptureAccess`
/// and soft-fail (return nil) when permission is missing.
enum ScreenContext {
    /// Max edge length (pixels) we downscale the capture to before OCR.
    ///
    /// This was 1600px, chosen to keep a `.fast` pass cheap, and it was the
    /// single biggest cause of unusable OCR: UI text at that scale is too small
    /// to read, and the recognizer guessed. Measured on a 3420x2214 capture,
    /// only 49% of its 4+ letter words were real words, with 21 tokens carrying
    /// a digit or symbol substituted mid-word ("pa1r", "fr&sh", "invalldArant")
    /// and 16 run together with their neighbours ("restartfromdlsk").
    ///
    /// At 2400px those collapse to 0 and 2 — for the same time or slightly less,
    /// because a clearer image is less work to recognize, not more. Going beyond
    /// 2400 (measured to native 3400) buys nothing further.
    private static let maxCaptureEdge: CGFloat = 2400

    /// True if Screen Recording permission has already been granted.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system Screen Recording permission request (which opens
    /// System Settings on macOS 13+ and registers the app in the TCC list).
    /// Returns true if permission is already granted. Safe to call off the
    /// main thread.
    @discardableResult
    static func requestPermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    /// Convenience for the Settings UI: registers the app with TCC (so it
    /// appears in the Screen Recording list) and opens the System Settings
    /// pane so the user can toggle it.
    static func openSystemSettings() {
        // Register the app with TCC first — this is what makes SunoFlow appear
        // in the Screen Recording list. Run off the main thread because the
        // call can block while the system handles the request.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Captures the main display, runs fast on-device OCR, and returns the
    /// recognized words joined by spaces. Best-effort: returns nil on any
    /// failure (no permission, capture failed, OCR failed, no text found).
    /// Completion is called on the main queue.
    ///
    /// The screenshot and the downscale run on the background queue alongside
    /// the OCR, not on the caller's thread. This is called the instant
    /// dictation starts, when the main thread's next job is putting the
    /// recording overlay on screen, and a full Retina capture is not free.
    static func captureAndRecognize(completion: @escaping (String?) -> Void) {
        guard hasPermission else {
            completion(nil)
            return
        }
        let displayID = CGMainDisplayID()
        DispatchQueue.global(qos: .userInitiated).async {
            guard let fullImage = CGDisplayCreateImage(displayID) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let words = recognizeText(in: downscale(fullImage, maxEdge: maxCaptureEdge))
            DispatchQueue.main.async {
                completion(words)
            }
        }
    }

    // MARK: - OCR

    /// Runs Vision `.fast` OCR on a CGImage and returns the recognized words
    /// joined by spaces, or nil if nothing was recognized.
    private static func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        // `.accurate`, not `.fast`. The prompt licenses the model to re-spell a
        // transcript word to match a name or identifier it finds in SCREEN, so
        // a garbled capture is not merely unhelpful — it is a source of wrong
        // corrections. Accuracy is what this input is *for*.
        //
        // It costs ~0.45s more than `.fast` (0.70s against 0.26s on a 3420x2214
        // capture), which used to be unaffordable when OCR ran between the
        // user's last word and their pasted text. It no longer does: the capture
        // starts when recording starts and finishes while they are still
        // speaking, so the cost lands in time that was being spent anyway.
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AppLog.log("Screen OCR failed: \(error)")
            return nil
        }
        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }
        let words = observations.compactMap { $0.topCandidates(1).first?.string }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Downscale

    /// Returns a scaled copy of `image` that fits within `maxEdge` while
    /// preserving aspect ratio. If the image is already smaller, returns it
    /// unchanged. Keeps OCR fast on large Retina captures.
    private static func downscale(_ image: CGImage, maxEdge: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longest = max(w, h)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }
}