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
    /// Max edge length (pixels) we downscale the capture to before OCR. A full
    /// Retina screenshot can be ~5K–6K pixels; Vision `.fast` on that is slow,
    /// and we only need legible words, so we shrink to ~1600px which keeps text
    /// crisp enough while cutting pixel count ~10x.
    private static let maxCaptureEdge: CGFloat = 1600

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
    static func captureAndRecognize(completion: @escaping (String?) -> Void) {
        guard hasPermission else {
            completion(nil)
            return
        }
        let displayID = CGMainDisplayID()
        guard let fullImage = CGDisplayCreateImage(displayID) else {
            completion(nil)
            return
        }
        let scaled = downscale(fullImage, maxEdge: maxCaptureEdge)
        DispatchQueue.global(qos: .userInitiated).async {
            let words = recognizeText(in: scaled)
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
        request.recognitionLevel = .fast
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