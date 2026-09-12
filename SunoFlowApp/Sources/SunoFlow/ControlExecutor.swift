import AppKit
import CoreGraphics

/// Executes one planned action on the user's machine via CGEvents, and maps
/// the planner's key names to Carbon virtual key codes.
///
/// This is the half of Suno Control that touches the machine, so it is the
/// half that must never guess: every action arrives as a decoded ControlAction
/// with its fields already validated by the gateway (bounds, required
/// fields). The executor's own job is faithful translation to events — and
/// staying honest about what it cannot do (Accessibility denied, unknown key).
enum ControlExecutor {
    // MARK: - Permission

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false,
        ] as CFDictionary)
    }

    /// Prompt the user for Accessibility if it is missing (same one
    /// TextInjector's paste path needs).
    static func promptForAccessibilityPermissionIfNeeded() {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true,
        ] as CFDictionary)
    }

    // MARK: - Actions

    /// Perform one action. Coordinates are in SCREENSHOT PIXEL space; the
    /// caller supplies the screenshot's dimensions so the conversion to
    /// global screen points happens here, once, with real numbers.
    ///
    /// Returns false when the action could not be performed (no permission,
    /// unknown key) — the loop stops rather than carry on blindly.
    static func perform(
        _ action: ControlAction,
        imageWidth: Int,
        imageHeight: Int
    ) -> Bool {
        switch action.action {
        case "click":
            guard let p = point(action, imageWidth: imageWidth, imageHeight: imageHeight) else { return false }
            moveTo(p)
            click(.left, at: p, clicks: 1)
            return true
        case "double_click":
            guard let p = point(action, imageWidth: imageWidth, imageHeight: imageHeight) else { return false }
            moveTo(p)
            click(.left, at: p, clicks: 2)
            return true
        case "right_click":
            guard let p = point(action, imageWidth: imageWidth, imageHeight: imageHeight) else { return false }
            moveTo(p)
            click(.right, at: p, clicks: 1)
            return true
        case "move":
            guard let p = point(action, imageWidth: imageWidth, imageHeight: imageHeight) else { return false }
            moveTo(p)
            return true
        case "drag":
            guard let from = point(action, imageWidth: imageWidth, imageHeight: imageHeight),
                  let to = point2(action, imageWidth: imageWidth, imageHeight: imageHeight) else { return false }
            drag(from: from, to: to)
            return true
        case "type":
            guard let text = action.text, !text.isEmpty else { return false }
            // Synthetic per-character Unicode events are ignored by several
            // apps — Safari's address bar above all — so text lands through the
            // pasteboard and ⌘V instead, the same insertion path dictation
            // uses (the only one that works across arbitrary apps).
            TextInjector.insert(text)
            // press_enter (computer_use): submit the field in the same step. A
            // real Return keypress works where a pasted trailing newline would
            // not — terminals in bracketed-paste mode, many web inputs.
            if action.press_enter == true {
                usleep(120_000) // let the paste land before Return
                _ = pressKey("return", modifiers: [])
            }
            return true
        case "key":
            guard let key = action.key else { return false }
            return pressKey(key, modifiers: action.modifiers ?? [])
        case "scroll":
            let dir = (action.direction ?? "down").lowercased()
            let ticks = action.amount ?? 3
            return scroll(direction: dir, ticks: ticks, action: action, imageWidth: imageWidth, imageHeight: imageHeight)
        case "wait":
            // The loop sleeps; nothing to do here.
            return true
        default:
            return false
        }
    }

    // MARK: - Coordinate conversion

    /// Convert a screenshot-pixel point into global screen points. The
    /// screenshot is the whole main display, downscaled to a max edge — so the
    /// scale factor is display-points-per-image-pixel, uniform on both axes.
    private static func scale(imageWidth: Int, imageHeight: Int) -> CGPoint {
        let screenBounds = CGDisplayBounds(CGMainDisplayID())
        let w = Double(screenBounds.width)
        let h = Double(screenBounds.height)
        let iw = Double(max(imageWidth, 1))
        let ih = Double(max(imageHeight, 1))
        return CGPoint(x: w / iw, y: h / ih)
    }

    private static func point(_ action: ControlAction, imageWidth: Int, imageHeight: Int) -> CGPoint? {
        guard let x = action.x, let y = action.y else { return nil }
        let s = scale(imageWidth: imageWidth, imageHeight: imageHeight)
        return CGPoint(x: Double(x) * s.x, y: Double(y) * s.y)
    }

    private static func point2(_ action: ControlAction, imageWidth: Int, imageHeight: Int) -> CGPoint? {
        guard let x = action.x2, let y = action.y2 else { return nil }
        let s = scale(imageWidth: imageWidth, imageHeight: imageHeight)
        return CGPoint(x: Double(x) * s.x, y: Double(y) * s.y)
    }

    private static func moveTo(_ p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
        move.post(tap: .cghidEventTap)
        usleep(30_000) // let the receiving app process the hover before the press
    }

    private enum Button {
        case left
        case right

        var down: CGEventType {
            self == .left ? .leftMouseDown : .rightMouseDown
        }
        var up: CGEventType {
            self == .left ? .leftMouseUp : .rightMouseUp
        }
        var field: CGMouseButton {
            self == .left ? .left : .right
        }
    }

    private static func click(_ button: Button, at p: CGPoint, clicks: Int) {
        for n in 1...max(1, clicks) {
            let down = CGEvent(mouseEventSource: nil, mouseType: button.down, mouseCursorPosition: p, mouseButton: button.field)!
            down.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            down.post(tap: .cghidEventTap)
            usleep(20_000)
            let up = CGEvent(mouseEventSource: nil, mouseType: button.up, mouseCursorPosition: p, mouseButton: button.field)!
            up.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up.post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    private static func drag(from: CGPoint, to: CGPoint) {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)!
        down.post(tap: .cghidEventTap)
        usleep(50_000)
        // Interpolate so apps that track drags see movement, not a jump.
        let steps = 20
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(
                x: Double(from.x) + (Double(to.x) - Double(from.x)) * t,
                y: Double(from.y) + (Double(to.y) - Double(from.y)) * t
            )
            let ev = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)!
            ev.post(tap: .cghidEventTap)
            usleep(10_000)
        }
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)!
        up.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    private static func scroll(
        direction: String, ticks: Int, action: ControlAction,
        imageWidth: Int, imageHeight: Int
    ) -> Bool {
        // A scroll can land wherever the cursor is; when the planner also sent
        // coordinates, move there first.
        if action.x != nil && action.y != nil, let p = point(action, imageWidth: imageWidth, imageHeight: imageHeight) {
            moveTo(p)
        }
        let up = direction == "up"
        let down = direction == "down"
        let left = direction == "left"
        let right = direction == "right"
        guard up || down || left || right else { return false }

        let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: left || right ? 2 : 1,
                         wheel1: 0, wheel2: 0, wheel3: 0)!
        let sign: Int32 = (up || left) ? 1 : -1
        for _ in 0..<max(1, ticks) {
            if left || right {
                ev.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(sign))
            } else {
                ev.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(sign))
            }
            ev.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        return true
    }

    // MARK: - Keys

    /// Planner key names → Carbon virtual key codes (kVK_*). The letters and
    /// digits are generated in `alphaNumerics` and merged in here.
    private static let keyCodes: [String: UInt16] = Self.specialKeys
        .merging(Self.alphaNumerics) { current, _ in current }

    private static let specialKeys: [String: UInt16] = [
        "space": 0x31, "tab": 0x30, "enter": 0x24, "return": 0x24,
        "escape": 0x35, "delete": 0x33, "backspace": 0x33,
        "forwarddelete": 0x75, "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pagedown": 0x79,
        "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        // Punctuation the model reaches for in shortcuts (⌘, for Settings, ⌘+/⌘-
        // for zoom, ⌘/ for help). Both the X11 keysym name the computer_use tool
        // emits and the literal character are accepted; an unlisted key is still
        // refused, so completeness here is what keeps a shortcut from stopping
        // the whole run.
        "comma": 0x2B, ",": 0x2B,
        "period": 0x2F, ".": 0x2F,
        "slash": 0x2C, "/": 0x2C,
        "semicolon": 0x29, ";": 0x29,
        "apostrophe": 0x27, "quote": 0x27, "'": 0x27,
        "minus": 0x1B, "-": 0x1B,
        "equal": 0x18, "=": 0x18,
        "bracketleft": 0x21, "[": 0x21,
        "bracketright": 0x1E, "]": 0x1E,
        "backslash": 0x2A, "\\": 0x2A,
        "grave": 0x32, "`": 0x32,
    ]

    // The full kVK_ANSI letter and digit rows. The letters MUST be complete: a
    // `key` action naming a letter the table lacks is refused, which stops the
    // run — and an earlier partial table (missing i,j,k,l,m,n,o,p,u) broke every
    // shortcut using them, ⌘L (address bar) and ⌥⌘L (Downloads) above all.
    private static let alphaNumerics: [String: UInt16] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
        "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
        "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
        "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
        "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
        "z": 0x06,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
        "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
    ]
    private static func pressKey(_ name: String, modifiers: [String]) -> Bool {
        var flags: CGEventFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "command", "cmd": flags.insert(.maskCommand)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        let normalized = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard let vkey = keyCodes[normalized] else { return false }

        let down = CGEvent(keyboardEventSource: nil, virtualKey: vkey, keyDown: true)!
        down.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: vkey, keyDown: false)!
        up.flags = flags
        up.post(tap: .cghidEventTap)
        usleep(30_000)
        return true
    }
}