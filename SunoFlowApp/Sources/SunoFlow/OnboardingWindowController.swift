import AppKit
import SwiftUI

/// Hosts the first-run wizard in a real window.
///
/// Same shape as `SettingsWindowController`, and for the same reason: SunoFlow
/// is an accessory (menu-bar) app, so it has to become a regular app while a
/// window of its own is open or that window cannot take keyboard focus — which
/// setup needs twice over, for the shortcut recorder and for the text field the
/// final dictation lands in.
///
/// It is deliberately not resizable-into-nothing and not minimisable: this is a
/// short linear flow, not a document, and a half-finished setup hidden in the
/// Dock is worse than one still on screen.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var hasCentered = false

    private init() {
        let hosting = NSHostingController(rootView: OnboardingView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set up SunoFlow"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Light-only, like the dashboard and the website: the palette was never
        // drawn for a dark variant, and macOS would happily hand us one.
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 720, height: 620))
        window.minSize = NSSize(width: 660, height: 560)
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

    /// Named `dismiss` rather than `close` so it does not collide with
    /// `NSWindowController.close()`, which does the same thing but which the
    /// wizard should not be overriding.
    func dismiss() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Whatever the wizard borrowed goes back, however it was closed — the
        // red button included. A swallowed shortcut would otherwise leave the
        // app looking broken in exactly the way setup exists to prevent.
        AppDelegate.shared?.hotkeyInterceptor = nil
        // Return to the menu-bar-only lifestyle, unless settings is still up.
        if SettingsWindowController.shared.window?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
