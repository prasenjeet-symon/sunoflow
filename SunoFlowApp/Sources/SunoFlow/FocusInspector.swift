import Cocoa

/// Where the next paste would land, judged at the moment a transcript is ready
/// to be inserted.
enum InsertionTarget {
    /// A text field, text view, terminal or other editable surface has focus,
    /// so a simulated Cmd+V will land somewhere useful.
    case editable
    /// Something has focus and it is definitely not somewhere text can go — a
    /// web page with no field selected, a Finder window, an image viewer.
    case notEditable
    /// Accessibility cannot say. Treated as "paste anyway": some apps publish
    /// no tree at all, and refusing to type into them would be a worse bug than
    /// the one this whole check exists to prevent.
    case unknown
}

/// Decides whether there is anywhere for a transcript to go.
///
/// Dictation inserts text by simulating Cmd+V into whatever is focused. When
/// nothing editable is focused that keystroke goes nowhere — the transcript is
/// silently lost, which from the user's side looks exactly like dictation
/// failing. This asks the Accessibility API what has focus so the caller can
/// offer the text instead of throwing it away (see `TranscriptCard`).
///
/// The classification is deliberately lopsided. Every plausible signal that a
/// surface takes text counts as `.editable`, and anything we cannot read at all
/// is `.unknown`; only a clear, positive "this is not a text surface" answer
/// returns `.notEditable`. A false `.notEditable` costs the user two clicks; a
/// false `.editable` costs them the dictation.
enum FocusInspector {

    /// Roles that always accept typed text. `AXTextArea` also covers terminals
    /// and most Electron/Chromium editing surfaces, which report themselves as
    /// text areas even though their value is not settable through AX.
    private static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
    ]

    /// Subroles that mark an otherwise generic element as a text input.
    private static let textSubroles: Set<String> = [
        "AXSecureTextField",
        "AXSearchField",
    ]

    /// What a paste right now would hit. Cheap enough to call inline on the
    /// main thread — it is a handful of synchronous AX reads.
    static func currentTarget() -> InsertionTarget {
        guard TextInjector.hasAccessibilityPermission else { return .unknown }

        guard let front = NSWorkspace.shared.frontmostApplication else {
            AppLog.log("Insertion target: no frontmost app → unknown")
            return .unknown
        }

        // Our own Settings window is never a dictation target. Nothing here
        // takes dictated text, so say so rather than pasting into a form field.
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            AppLog.log("Insertion target: SunoFlow itself is frontmost → not editable")
            return .notEditable
        }

        guard let element = focusedElement(of: front) else {
            // An app that answers AX questions but reports nothing focused
            // really has nothing focused. An app that answers nothing at all
            // tells us nothing, and we must not read that as an empty answer.
            let speaksAX = exposesAccessibility(front)
            AppLog.log("Insertion target: no focused element in \(front.localizedName ?? "?") "
                + "(AX-capable: \(speaksAX)) → \(speaksAX ? "not editable" : "unknown")")
            return speaksAX ? .notEditable : .unknown
        }

        return classify(element, app: front)
    }

    // MARK: - Classification

    private static func classify(_ element: AXUIElement, app: NSRunningApplication) -> InsertionTarget {
        let role = copyAttribute(element, "AXRole") as? String ?? ""
        let subrole = copyAttribute(element, "AXSubrole") as? String ?? ""

        func decide(_ target: InsertionTarget, _ why: String) -> InsertionTarget {
            AppLog.log("Insertion target: \(app.localizedName ?? "?") role=\(role.isEmpty ? "—" : role)"
                + " subrole=\(subrole.isEmpty ? "—" : subrole) → \(why)")
            return target
        }

        // An element that won't even name its role is broken, not empty.
        guard !role.isEmpty else { return decide(.unknown, "unknown (no role)") }

        if textRoles.contains(role) { return decide(.editable, "editable (text role)") }
        if textSubroles.contains(subrole) { return decide(.editable, "editable (text subrole)") }

        // Custom text surfaces — some web editors, some cross-platform toolkits —
        // don't use a text role but do let AX write their value.
        if isSettable(element, "AXValue") { return decide(.editable, "editable (settable value)") }

        return decide(.notEditable, "not editable")
    }

    // MARK: - AX plumbing

    /// The focused element, asked of the system first and of the frontmost app
    /// second. The system-wide element is usually right, but a few apps only
    /// answer when asked about themselves.
    private static func focusedElement(of app: NSRunningApplication) -> AXUIElement? {
        if let focused = copyAttribute(AXUIElementCreateSystemWide(), "AXFocusedUIElement") {
            return (focused as! AXUIElement)
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = copyAttribute(appElement, "AXFocusedUIElement") {
            return (focused as! AXUIElement)
        }
        return nil
    }

    /// True if the app publishes an Accessibility tree at all. Every AX-capable
    /// process answers `AXRole` with `AXApplication`; one that doesn't is opaque
    /// to us, and its silence must not be mistaken for "nothing is focused".
    private static func exposesAccessibility(_ app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return copyAttribute(appElement, "AXRole") != nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }
}
