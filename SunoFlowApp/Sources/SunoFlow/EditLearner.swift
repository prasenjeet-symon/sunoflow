import Cocoa

/// Watches what the user changes after a dictation is pasted, and feeds the
/// (pasted, edited) pair to the sidecar so it can learn recurring corrections.
///
/// Flow: right after we paste, we snapshot the focused field's full text. Later
/// — at the start of the next dictation, or after a fallback delay — we re-read
/// that same field and, if it changed, send both versions to /learn. The sidecar
/// diffs them and keeps only small, name/term-like substitutions.
final class EditLearner {
    private struct Pending {
        let element: AXUIElement
        let snapshot: String
    }

    private var pending: Pending?
    private var fallbackTimer: Timer?

    // Bound how much text we snapshot/compare (dictation targets are usually
    // small; this just avoids sending a whole huge document).
    private let maxSnapshotChars = 4000
    private let fallbackDelay: TimeInterval = 30

    /// Call right after we paste `inserted` text into the focused field.
    func noteInsertion() {
        guard let element = AccessibilityContext.focusedElement() else { return }
        // Read slightly later so the simulated Cmd+V has actually landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            guard let value = AccessibilityContext.value(of: element) else { return }
            self.pending = Pending(element: element, snapshot: self.clamp(value))
            self.scheduleFallback()
        }
    }

    /// Compare the snapshot against the field's current text and learn the diff.
    /// Safe to call anytime; a no-op if there's nothing pending.
    func captureIfNeeded() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil

        guard let pending = pending else { return }
        self.pending = nil

        guard let current = AccessibilityContext.value(of: pending.element) else { return }
        let edited = clamp(current)
        guard !edited.isEmpty, edited != pending.snapshot else { return }

        TranscriptionClient.learn(original: pending.snapshot, edited: edited) { learned in
            if learned > 0 {
                AppLog.log("Learned \(learned) correction(s) from your edits")
            }
        }
    }

    private func scheduleFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: fallbackDelay, repeats: false) { [weak self] _ in
            self?.captureIfNeeded()
        }
    }

    private func clamp(_ text: String) -> String {
        text.count > maxSnapshotChars ? String(text.suffix(maxSnapshotChars)) : text
    }
}
