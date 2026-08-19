import Cocoa

/// Inserts text at the current cursor position in whatever app is focused,
/// by swapping the pasteboard contents and simulating Cmd+V. This is the
/// only text-insertion approach that reliably works across arbitrary apps
/// (native fields, Electron, browsers, terminals).
enum TextInjector {
    private static let virtualKeyV: CGKeyCode = 0x09

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let previousContents = previousContents {
                pasteboard.setString(previousContents, forType: .string)
            }
        }
    }

    private static func simulatePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    static var hasAccessibilityPermission: Bool {
        // kAXTrustedCheckOptionPrompt is a global constant we don't own, so take
        // it unretained — takeRetainedValue would over-release it on every call.
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func promptForAccessibilityPermissionIfNeeded() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options)
    }
}
