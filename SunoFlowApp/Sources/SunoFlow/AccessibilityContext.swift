import Cocoa

/// Best-effort reader of the text immediately before the cursor in the currently
/// focused app, via the Accessibility API. This is sent to the cleanup LLM as
/// reference so it gets names, terminology, capitalization, and sentence
/// continuation right.
///
/// Returns nil when unavailable — many apps (especially some web/Electron ones)
/// don't expose their text through Accessibility, and secure fields (passwords)
/// are deliberately skipped. Callers should treat nil as "no context".
enum AccessibilityContext {
    static func textBeforeCursor(maxChars: Int = 800) -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        guard let focusedRef = copyAttribute(systemWide, kAXFocusedUIElementAttribute) else {
            return nil
        }
        let element = focusedRef as! AXUIElement

        // Never read secure text fields (passwords).
        if let role = copyAttribute(element, kAXRoleAttribute) as? String,
           role == "AXSecureTextField" {
            return nil
        }
        if let subrole = copyAttribute(element, kAXSubroleAttribute) as? String,
           subrole == "AXSecureTextField" {
            return nil
        }

        guard let value = copyAttribute(element, kAXValueAttribute) as? String,
              !value.isEmpty else {
            return nil
        }

        // AX ranges are UTF-16 offsets, so work in NSString space to match.
        let ns = value as NSString
        var cursorLocation = ns.length
        if let rangeRef = copyAttribute(element, kAXSelectedTextRangeAttribute) {
            var cfRange = CFRange()
            if AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) {
                cursorLocation = max(0, min(cfRange.location, ns.length))
            }
        }

        let before = ns.substring(to: cursorLocation)
        let tail = before.count > maxChars ? String(before.suffix(maxChars)) : before
        let result = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// The currently focused UI element, if any. Used by the learning system to
    /// snapshot a field and later see what the user changed.
    static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focusedRef = copyAttribute(systemWide, kAXFocusedUIElementAttribute) else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    /// The full text value of an element, or nil (secure fields are skipped).
    static func value(of element: AXUIElement) -> String? {
        if let role = copyAttribute(element, kAXRoleAttribute) as? String,
           role == "AXSecureTextField" {
            return nil
        }
        return copyAttribute(element, kAXValueAttribute) as? String
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }
}
