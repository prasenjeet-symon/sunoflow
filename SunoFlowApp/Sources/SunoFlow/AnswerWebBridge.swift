import AppKit
import WebKit

/// The transcript half of the Suno Answer popup. A WKWebView page renders the
/// conversation: the dictated question as a voice-message waveform bubble
/// (never the transcribed text), typed follow-ups as text bubbles, and answers
/// as Markdown with KaTeX math (inline `$…$` / `\[…\]`, display `$$…$$` /
/// ```math fences, multi-line aligned environments). Everything ships inside
/// the bundle — markdown-it, KaTeX, and the KaTeX woff2 fonts load from
/// `Resources/AnswerWeb/`, so the popup renders offline and sends nothing
/// anywhere. The chrome around the transcript (header, action row, input)
/// stays native AppKit in ``AnswerPanelView``.
///
/// Layout: the page reports its content height; the web view is pinned to the
/// bottom of the transcript area and grows upward. The chat scroll stays so
/// very long answers still scroll when they overflow the fixed 480pt panel.
final class AnswerWebBridge: NSObject, WKNavigationDelegate {
    /// True once the page signalled `window.__sunoReady`. Calls before that
    /// are buffered and replayed in order.
    private(set) var ready = false

    /// Height the page wants, from the DOM body. Drives the view's height
    /// constraint; the panel keeps the scroll for overflow.
    var onHeightChanged: ((CGFloat) -> Void)?

    private let webView: WKWebView
    private var pending: [(AnswerWebBridge) -> Void] = []

    /// The height constraint the panel owns; the bridge updates `.constant`
    /// as the page grows.
    var heightConstraint: NSLayoutConstraint?

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.minimumFontSize = 10
        // TranscriptWebView forwards wheel events to the enclosing scroll
        // view — a plain WKWebView swallows them (see the class comment).
        webView = TranscriptWebView(frame: NSRect(x: 0, y: 0, width: 376, height: 40), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground") // KVC; no public API pre-macOS 14
        webView.wantsLayer = true
        if let layer = webView.layer {
            layer.backgroundColor = NSColor.clear.cgColor
        }
        load()
    }

    var view: NSView { webView }

    private func load() {
        // Bundle resources live beside answer.html (answer/ is the folder
        // reference copied by build.sh / release.sh).
        if let base = Bundle.main.resourceURL?.appendingPathComponent("AnswerWeb") {
            webView.loadFileURL(
                base.appendingPathComponent("answer.html"),
                allowingReadAccessTo: base
            )
        }
    }

    func reloadForTesting() {
        ready = false
        pending = []
        load()
    }

    // MARK: readiness

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__sunoReady === true") { [weak self] _, _ in
            guard let self else { return }
            self.ready = true
            self.flushPending()
            self.measure()
        }
        // A second read 250ms out, in case scripts finished after the
        // navigation callback ran (WKWebView races script completion).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.ready else { return }
            self.webView.evaluateJavaScript("window.__sunoReady === true") { [weak self] value, _ in
                guard let self, (value as? Bool) == true else { return }
                self.ready = true
                self.flushPending()
                self.measure()
            }
        }
    }

    // MARK: external links

    // Links in an answer must open in the user's default browser, never in
    // this view — the transcript is a frameless local page with no way back.
    // The page itself loads only file URLs (answer.html sets html:false and
    // linkify:false, so no remote subresources either), so any non-file
    // navigation is a link the user clicked; hand it to the system.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, !url.isFileURL {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    // target=_blank links ask for a new web view; the system browser already
    // has tabs, so hand those off the same way.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    private func flushPending() {
        let calls = pending
        pending = []
        for call in calls { call(self) }
    }

    private func whenReady(_ call: @escaping (AnswerWebBridge) -> Void) {
        if ready { call(self) } else { pending.append(call) }
    }

    // MARK: height

    private func measure() {
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
            guard let self, let h = value as? CGFloat, h > 0 else { return }
            self.heightConstraint?.constant = h
            self.onHeightChanged?(h)
        }
    }

    // MARK: bridge calls (all funnel through whenReady)

    func reset() {
        // Clear the page's state; no navigation, so readiness is untouched.
        whenReady { $0.webView.evaluateJavaScript("window.sunoflow.reset()") }
    }

    func addVoiceTurn(envelope samples: [Float], seconds: Double) {
        guard !samples.isEmpty else { return }
        whenReady { bridge in
            var flat = ""
            flat.reserveCapacity(samples.count * 7)
            for s in samples {
                flat += String(format: "%.2f,", min(1, max(0, s)))
            }
            flat.removeLast()
            bridge.webView.evaluateJavaScript(
                "window.sunoflow.addVoiceTurn([\(flat)], \(String(format: "%.1f", seconds)))"
            ) { _, _ in bridge.measure() }
        }
    }

    func addTypedTurn(_ text: String) {
        whenReady { bridge in
            let json = Self.jsonString(text)
            bridge.webView.evaluateJavaScript(
                "window.sunoflow.addTypedTurn(\(json))"
            ) { _, _ in bridge.measure() }
        }
    }

    // MARK: live follow-up recording

    func beginListening() {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript("window.sunoflow.beginListening()") { _, _ in
                bridge.measure()
            }
        }
    }

    /// Level ticks fire ~15×/s; the page's own smoothing makes them breathe.
    /// No `measure()` — the pill is fixed-height, and a height query per
    /// buffer would spam the JS bridge.
    func updateListening(level: Float) {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript(
                "window.sunoflow.updateListening(\(String(format: "%.3f", min(1, max(0, level)))))"
            )
        }
    }

    func commitListening(samples: [Float], seconds: Double) {
        var flat = ""
        flat.reserveCapacity(samples.count * 7)
        for s in samples {
            flat += String(format: "%.2f,", min(1, max(0, s)))
        }
        if !flat.isEmpty { flat.removeLast() }
        whenReady { bridge in
            bridge.webView.evaluateJavaScript(
                "window.sunoflow.commitListening([\(flat)], \(String(format: "%.1f", seconds)))"
            ) { _, _ in bridge.measure() }
        }
    }

    func cancelListening() {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript("window.sunoflow.cancelListening()") { _, _ in
                bridge.measure()
            }
        }
    }

    func showThinking() {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript("window.sunoflow.showThinking()") { _, _ in
                bridge.measure()
            }
        }
    }

    /// Minimized peek: collapse the transcript to only the latest answer (or
    /// expand back to the full conversation). The page reports its new height,
    /// so the panel's transcript area sizes to the single answer.
    func setCompact(_ on: Bool) {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript("window.sunoflow.setCompact(\(on ? "true" : "false"))") { _, _ in
                bridge.measure()
            }
        }
    }

    /// Force a compositing repaint. WKWebView can leave stale/blank tiles after
    /// its enclosing view is resized (the minimize/restore animation); toggling
    /// a transform for one frame makes it repaint reliably.
    func nudgeRepaint() {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript(
                "document.documentElement.style.transform='translateZ(0)';" +
                "requestAnimationFrame(function(){document.documentElement.style.transform='';});"
            )
        }
    }

    func showError(_ message: String) {
        whenReady { bridge in
            let json = Self.jsonString(message)
            bridge.webView.evaluateJavaScript(
                "window.sunoflow.showError(\(json))"
            ) { _, _ in bridge.measure() }
        }
    }

    func beginAnswer() {
        whenReady { $0.webView.evaluateJavaScript("window.sunoflow.beginAnswer()") }
    }

    /// Removes the Thinking…/error marker from the page.
    func removeMarker() {
        whenReady { $0.webView.evaluateJavaScript("window.sunoflow.removeMarker()") }
    }

    func appendAnswer(_ chunk: String) {
        whenReady { bridge in
            let json = Self.jsonString(chunk)
            bridge.webView.evaluateJavaScript(
                "window.sunoflow.appendAnswer(\(json))"
            ) { _, _ in bridge.measure() }
        }
    }

    func endAnswer() {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript("window.sunoflow.endAnswer()") { _, _ in
                bridge.measure()
            }
        }
    }

    // MARK: try-on

    /// The "Trying it on…" pending card — the generation runs beside the
    /// answer stream, so the card lands while the prose continues.
    func showTryonPending() {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript("window.sunoflow.showTryonPending()") { _, _ in
                bridge.measure()
            }
        }
    }

    /// The finished try-on image, as base64 PNG (the alphabet is JS-string
    /// safe, so the literal needs no escaping).
    func showTryonImage(base64: String) {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript(
                "window.sunoflow.showTryonImage(\"\(base64)\")"
            ) { _, _ in bridge.measure() }
        }
    }

    /// Try-on needs a person photo and none is on file — an informational
    /// card, not an error; the answer itself keeps streaming.
    func showTryonSetup() {
        whenReady { bridge in
            bridge.webView.evaluateJavaScript("window.sunoflow.showTryonSetup()") { _, _ in
                bridge.measure()
            }
        }
    }

    /// Clears a stale pending card without replacing it.
    func removeTryonPending() {
        whenReady { $0.webView.evaluateJavaScript("window.sunoflow.removeTryonPending()") }
    }

    // MARK: JSON strings for JS literals

    private static func jsonString(_ text: String) -> String {
        // Escapes quotes, backslashes and control chars; the result is a
        // complete JS string literal including its quotes.
        let data = try? JSONSerialization.data(withJSONObject: [text])
        guard var s = String(data: data ?? Data(), encoding: .utf8) else { return "\"\"" }
        s.removeFirst(); s.removeLast()   // unwrap the single-element array
        return s
    }
}