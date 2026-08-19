import Cocoa

// Guard against a second copy launching (e.g. login item + a manual run): if
// another instance with our bundle id is already up, ask it to surface its
// Settings window (relaunching a menu-bar app is the usual way to reach its
// preferences), then bow out quietly.
if let bundleID = Bundle.main.bundleIdentifier {
    let selfPID = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != selfPID }
    if !others.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            AppNotifications.openSettings, object: nil, deliverImmediately: true
        )
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
