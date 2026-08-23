import AppKit
import SwiftUI

/// Hosts the SwiftUI settings form in a real window. Because SunoFlow is an
/// accessory (menu-bar) app, we briefly become a regular app while settings are
/// open so the window can take keyboard focus (needed for the text editor and
/// the hotkey recorder), then drop back to accessory on close.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var hasCentered = false

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "SunoFlow"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Hide the title bar and let the content run under it, so the sidebar
        // reaches the top of the window and the traffic lights float over it.
        // `SettingsView` reserves the top-left space for them.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The dashboard is designed light-only, like the website. Pinning the
        // appearance keeps it identical on every Mac instead of handing macOS a
        // dark variant the palette was never drawn for.
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 980, height: 700))
        window.minSize = NSSize(width: 880, height: 620)
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
        // No unsaved-state to guard anymore: the cleanup model + instruction are
        // server-owned (the hosted gateway), so the settings window has nothing
        // that needs a save-before-close prompt.
        true
    }

    func windowWillClose(_ notification: Notification) {
        // Return to the menu-bar-only lifestyle so the app has no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}