import Carbon
import Cocoa

/// Registers a single system-wide hotkey via the Carbon Event Manager.
/// Carbon hotkeys only fire on key-down, so this is used as a toggle
/// (press once to start, press again to stop) rather than hold-to-talk.
final class HotkeyManager {
    private static let signature: OSType = 0x53464c57 // 'SFLW'
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var onHotkey: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) {
        // Make register idempotent: if a handler/hotkey is already installed,
        // tear it down first so we never overwrite (and leak) the Carbon refs.
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let eventRef = eventRef, let userData = userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                NSLog("[SunoFlow] hotkey event fired, GetEventParameter status=\(status), id=\(hotKeyID.id)")
                if hotKeyID.id == HotkeyManager.hotKeyID {
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    manager.onHotkey?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        let id = EventHotKeyID(signature: HotkeyManager.signature, id: HotkeyManager.hotKeyID)
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        NSLog("[SunoFlow] RegisterEventHotKey status=\(registerStatus)")
    }

    /// Swap the active hotkey for a new key/modifier combination.
    func reregister(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        register(keyCode: keyCode, modifiers: modifiers)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    deinit {
        unregister()
    }
}

enum DefaultHotkey {
    // kVK_Space = 0x31 (49)
    static let keyCode: UInt32 = 49
    static let modifiers: UInt32 = UInt32(optionKey)
}

/// Formatting + conversion helpers for turning a (keyCode, Carbon modifier mask)
/// pair into something the user can read, and mapping Cocoa event modifiers to
/// the Carbon masks `RegisterEventHotKey` expects.
enum KeyCombo {
    /// Human-readable label, e.g. `⌥Space`, `⌃⌘K`, `F5`.
    static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierString(modifiers) + keyName(keyCode)
    }

    /// Canonical Apple order: ⌃ ⌥ ⇧ ⌘.
    static func modifierString(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    /// True for keys usable as a global hotkey without a modifier (function keys).
    static func isStandaloneKey(_ keyCode: UInt32) -> Bool {
        functionKeys.keys.contains(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        if let named = namedKeys[keyCode] { return named }
        if let fn = functionKeys[keyCode] { return fn }
        if let char = printableKeys[keyCode] { return char }
        return "Key \(keyCode)"
    }

    private static let namedKeys: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        76: "Enter", 117: "Fwd Del", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    // ANSI virtual key codes (kVK_ANSI_*). Layout-independent enough for a label.
    private static let printableKeys: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]
}
