import AppKit
import SwiftUI

/// Hosts the SwiftUI settings form in a real window. Because SunoFlow is an
/// accessory (menu-bar) app, we briefly become a regular app while settings are
/// open so the window can take keyboard focus (needed for the text editor and
/// the hotkey recorder), then drop back to accessory on close.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var hasCentered = false

    /// Set by `SettingsView` when there are unsaved AI-config edits. When true,
    /// closing the window prompts the user to save first.
    var hasUnsavedAIChanges = false

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "SunoFlow"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 920, height: 620))
        window.minSize = NSSize(width: 760, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !hasCentered {
            window?.center()
            hasCentered = true
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedAIChanges else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save AI settings?"
        alert.informativeText = "You have unsaved changes to the AI cleanup settings. Do you want to save them before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Save, then close. The actual save is triggered via notification;
            // SettingsView will call back when done. For now, block the close —
            // SettingsView saves synchronously-ish and will close.
            NotificationCenter.default.post(name: .sunoSaveAndClose, object: nil)
            return false
        case .alertSecondButtonReturn:
            hasUnsavedAIChanges = false
            NotificationCenter.default.post(name: .sunoAIConfigClean, object: nil)
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Return to the menu-bar-only lifestyle so the app has no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}