import Cocoa
import ApplicationServices

/// What the OS knows about where a dictation is going: which application has
/// focus, what its window is called, and — in a browser — which site is open.
///
/// This is the cheapest context the app collects. Screen OCR costs a capture, a
/// downscale and a Vision pass; the cursor context costs a walk of the focused
/// element. This costs three Accessibility reads and no pixels at all, and
/// unlike anything inferred from a screenshot it is *observed* rather than
/// guessed: the bundle identifier is the application's own name for itself.
///
/// It goes to the cleanup gateway for two purposes, and the split matters:
/// - the **prompt** gets the app, its kind and the window title, as reference
///   material in the same sense CONTEXT and SCREEN are — it tells the model
///   whether these words are a Slack message or a shell command;
/// - **analytics** gets only the category and, for applications the gateway
///   already has a name for, that name. The title never leaves this purpose;
///   it is the part that carries content.
///
/// Best-effort throughout. Every failure is an empty field, never a thrown
/// error and never a blocked dictation.
enum ForegroundApp {

    /// One reading of the frontmost application.
    struct Snapshot {
        /// Bundle identifier, e.g. "com.tinyspeck.slackmacgap". The gateway
        /// maps this to a display name and a category; nothing here does.
        var id: String = ""
        /// Host of the page in front, for browsers only, e.g. "mail.google.com".
        /// Empty everywhere else.
        var site: String = ""
        /// The focused window's title — where browsers put the page title and
        /// editors put the filename.
        var detail: String = ""

        var isEmpty: Bool { id.isEmpty && site.isEmpty && detail.isEmpty }
    }

    /// Bundle identifiers that are browsers.
    ///
    /// The gateway owns the category taxonomy, and this is deliberately not a
    /// second copy of it: it answers a different, local question — "is it worth
    /// hunting for a URL in this app's Accessibility tree?" — and an app missing
    /// from it loses only the site, never the app itself. Categorisation still
    /// happens in exactly one place, on the server.
    private static let browsers: Set<String> = [
        "com.google.chrome",
        "com.google.chrome.beta",
        "com.google.chrome.canary",
        "com.apple.safari",
        "com.apple.safaritechnologypreview",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "company.thebrowser.arc",
        "com.operasoftware.opera",
        "com.vivaldi.vivaldi",
    ]

    /// How long any single Accessibility read may block.
    ///
    /// This runs on the dictation path, and AX is synchronous IPC into another
    /// process: a busy or wedged app can otherwise hold the caller for the
    /// system default of several seconds. A quarter second is far longer than a
    /// healthy app needs and short enough that a sick one costs nothing worth
    /// noticing.
    private static let axTimeout: Float = 0.25

    /// Nodes the URL search may visit before giving up. A browser publishes a
    /// large tree; the web area sits near the top of it, so a small budget finds
    /// it in the normal case and bounds the pathological one.
    private static let maxNodesVisited = 250

    /// A reading in progress, started when recording started.
    ///
    /// The work is cheap once Accessibility is warm — measured at ~20ms for the
    /// identity and title and ~13ms for the site — but the *first* read after
    /// launch pays to open the AX connection and was measured at 236ms against
    /// Safari. That is a quarter second sitting between the user's last word and
    /// their pasted text, for a field that is only ever a hint, so it is started
    /// with the recording instead, exactly as the screen capture is.
    ///
    /// Unlike the screen capture this never waits: `result()` returns whatever
    /// has landed. The screen OCR is worth waiting out because a dictation
    /// without it loses real vocabulary; the app is worth having and not worth a
    /// millisecond of delay, and a dictation short enough to outrun a cold AX
    /// connection is precisely one where latency matters most.
    final class Capture {
        private let lock = NSLock()
        private var value = Snapshot()

        fileprivate func finish(_ snap: Snapshot) {
            lock.lock(); defer { lock.unlock() }
            value = snap
        }

        /// What has been read so far — a complete snapshot in the normal case,
        /// an empty one if the dictation beat a cold Accessibility connection.
        func result() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// Starts reading the frontmost application on a background queue. Call when
    /// recording starts, while the user's target app is still the frontmost one.
    static func beginCapture() -> Capture {
        let capture = Capture()
        DispatchQueue.global(qos: .userInitiated).async {
            capture.finish(snapshot())
        }
        return capture
    }

    /// Reads the frontmost application. Returns an empty snapshot rather than
    /// failing. Call off the main thread — see `Capture`.
    static func snapshot() -> Snapshot {
        guard let front = NSWorkspace.shared.frontmostApplication else { return Snapshot() }

        // Our own windows are never a dictation target, and reporting SunoFlow
        // as the app someone dictates into would be self-referential noise in
        // the numbers.
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return Snapshot()
        }

        var snap = Snapshot()
        snap.id = front.bundleIdentifier ?? ""

        // Without the Accessibility permission the app identity above is still
        // valid — it comes from NSWorkspace, not from AX — but nothing below is
        // readable, so stop here rather than pay for reads that cannot succeed.
        guard TextInjector.hasAccessibilityPermission else { return snap }

        let appElement = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)

        guard let window = focusedWindow(of: appElement) else { return snap }
        snap.detail = (copyAttribute(window, kAXTitleAttribute) as? String) ?? ""

        if browsers.contains(snap.id.lowercased()) {
            snap.site = host(of: window)
        }
        return snap
    }

    // MARK: - AX plumbing

    private static func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w = copyAttribute(appElement, attribute) {
                return (w as! AXUIElement)
            }
        }
        return nil
    }

    /// The host of the page the browser is showing, or "".
    ///
    /// Browsers expose the address on the web area rather than the window, so
    /// this walks breadth-first from the window until it finds an element that
    /// answers `AXURL`. Breadth-first because the web area is shallow — a few
    /// levels under the window — while the *document* beneath it is arbitrarily
    /// deep, and a depth-first walk would descend into the page content instead.
    private static func host(of window: AXUIElement) -> String {
        var queue = [window]
        var visited = 0

        while !queue.isEmpty && visited < maxNodesVisited {
            var next: [AXUIElement] = []
            for element in queue {
                visited += 1
                if visited > maxNodesVisited { break }

                if let url = copyAttribute(element, kAXURLAttribute) as? NSURL,
                   let h = url.host, !h.isEmpty {
                    return h
                }
                if let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                    next.append(contentsOf: children)
                }
            }
            queue = next
        }
        return ""
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }
}
