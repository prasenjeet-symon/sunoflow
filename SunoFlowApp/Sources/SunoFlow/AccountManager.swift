import AppKit
import Foundation

/// Links this Mac to a SunoFlow account and holds the device key.
///
/// The pairing follows the device-authorisation flow the website implements:
/// ask for a code, send the user to the browser to approve it, then poll until
/// the key comes back. Nothing is typed by the user and the app never handles a
/// password — the browser does the signing in.
///
/// The key is the device's credential for the cleanup service. It lives in the
/// Keychain rather than UserDefaults so it is not readable from a plist by
/// anything that can read the user's home directory.
@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    enum State: Equatable {
        case notConnected
        case waiting(code: String)
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .notConnected
    /// Set when the gateway last refused us for a subscription reason, so the
    /// dashboard can say why instead of failing silently.
    @Published private(set) var entitlementNotice: String?

    private static let functionsBase = URL(string: "https://asia-south1-sunoflow-app.cloudfunctions.net")!
    private static let accountURL = URL(string: "https://sunoflow-app.web.app/dashboard.html")!

    private var pollTask: Task<Void, Never>?

    private init() {
        state = Keychain.deviceKey() == nil ? .notConnected : .connected
    }

    /// The device key, if this Mac has been connected. Read by the transcription
    /// client so the sidecar can authenticate to the cleanup gateway.
    var deviceKey: String? { Keychain.deviceKey() }

    /// Derived from `state`, not from a fresh Keychain read. SwiftUI evaluates
    /// these on every render pass, and a Keychain hit per frame is how one
    /// password prompt becomes a hundred.
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Pairing

    func connect() {
        pollTask?.cancel()
        entitlementNotice = nil
        state = .waiting(code: "…")

        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pairing = try await self.requestPairing()
                guard !Task.isCancelled else { return }
                self.state = .waiting(code: pairing.userCode)

                // Hand off to the browser, where the user is already signed in.
                if let url = URL(string: pairing.verificationURI) {
                    NSWorkspace.shared.open(url)
                }

                let key = try await self.awaitApproval(pairing)
                guard !Task.isCancelled else { return }

                Keychain.setDeviceKey(key)
                self.state = .connected
                AppLog.log("account: device connected")
            } catch is CancellationError {
                // `cancel()` already set the state.
            } catch {
                guard !Task.isCancelled else { return }
                self.state = .failed((error as? PairingError)?.message ?? error.localizedDescription)
                AppLog.log("account: pairing failed — \(error.localizedDescription)")
            }
        }
    }

    func cancelPairing() {
        pollTask?.cancel()
        pollTask = nil
        state = isConnected ? .connected : .notConnected
    }

    /// Forgets the key on this Mac. It does not revoke it on the server — only
    /// the account owner can do that, from the dashboard — so the wording in the
    /// UI has to be careful not to promise more than this does.
    func signOutThisMac() {
        pollTask?.cancel()
        Keychain.clearDeviceKey()
        entitlementNotice = nil
        state = .notConnected
        AppLog.log("account: device key removed from this Mac")
    }

    func openAccountPage() {
        NSWorkspace.shared.open(Self.accountURL)
    }

    /// Called when the gateway refuses a cleanup for subscription reasons.
    func noteEntitlementProblem(_ message: String) {
        entitlementNotice = message
    }

    func clearEntitlementNotice() { entitlementNotice = nil }

    // MARK: - Network

    private struct Pairing {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let interval: TimeInterval
        let expiresAt: Date
    }

    struct PairingError: Error {
        let message: String
    }

    private func requestPairing() async throws -> Pairing {
        var request = URLRequest(url: Self.functionsBase.appendingPathComponent("pairDevice"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": Host.current().localizedName ?? "Mac",
            "platform": "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
                .replacingOccurrences(of: "Version ", with: ""),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String
        else {
            throw PairingError(message: "Couldn't start the connection. Check your internet and try again.")
        }

        let interval = (json["interval"] as? Double) ?? 3
        let expiresIn = (json["expires_in"] as? Double) ?? 600
        return Pairing(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            interval: max(1, interval),
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    /// Polls until the user approves, the pairing expires, or we are cancelled.
    private func awaitApproval(_ pairing: Pairing) async throws -> String {
        var request = URLRequest(url: Self.functionsBase.appendingPathComponent("pollDevice"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device_code": pairing.deviceCode])

        while Date() < pairing.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(pairing.interval * 1_000_000_000))
            try Task.checkCancellation()

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse
            else { continue }   // transient network trouble: keep waiting

            switch http.statusCode {
            case 200:
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let key = json["api_key"] as? String
                else { throw PairingError(message: "The connection came back empty. Try again.") }
                return key
            case 428:
                continue        // still waiting for the user to approve
            default:
                throw PairingError(message: "That connection expired. Start again to get a fresh code.")
            }
        }
        throw PairingError(message: "The code expired before it was approved. Try again.")
    }
}

// MARK: - Keychain

/// Minimal Keychain wrapper for the one secret this app stores.
///
/// Two things here matter more than they look.
///
/// **The value is cached in memory.** A Keychain read is not free and, more
/// importantly, an *untrusted* read shows the user a password prompt. The key is
/// read on every dictation and by SwiftUI properties that re-evaluate on each
/// render, so an uncached read turns one prompt into a storm of them.
///
/// **Writes carry an explicit ACL naming this application.** Without one, macOS
/// records the creating binary and prompts whenever a different one asks —
/// which is what happens the first time the app is moved, for example from a
/// build directory into /Applications.
enum Keychain {
    private static let service = "com.sunoapp.sunoflow"
    private static let account = "deviceKey"

    private static let lock = NSLock()
    private static var cached: String?
    private static var didRepair = false

    static func deviceKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let value = read()
        cached = value
        return value
    }

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func setDeviceKey(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        write(key)
        cached = key
    }

    private static func write(_ key: String) {
        deleteItem()
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            // Available without an unlock prompt after first unlock, and never
            // synced to iCloud or included in a backup.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let access = selfAccess() {
            attributes[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.log("account: keychain write failed (\(status))")
        }
    }

    /// An ACL that trusts this application, so reads do not prompt.
    ///
    /// These APIs are long-deprecated but remain the only way to set a keychain
    /// ACL for an unsandboxed, directly-distributed Mac app. The modern
    /// data-protection keychain needs an application-identifier entitlement,
    /// which requires provisioning this app deliberately does not use.
    private static func selfAccess() -> SecAccess? {
        var trusted: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess,
              let trusted
        else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("SunoFlow device key" as CFString,
                              [trusted] as CFArray, &access) == errSecSuccess
        else { return nil }
        return access
    }

    /// Rewrites the stored key so its ACL names the binary that is running now.
    ///
    /// Called once at launch. An item written by a copy of the app at a
    /// different path — the usual case after installing into /Applications —
    /// prompts on every read until it is rewritten from the new location. The
    /// first read here may still prompt once; after that it is silent.
    static func repairAccessIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRepair else { return }
        didRepair = true
        guard let existing = cached ?? read() else { return }
        write(existing)
        cached = existing
        AppLog.log("account: keychain entry rewritten for this copy of the app")
    }

    static func clearDeviceKey() {
        lock.lock()
        defer { lock.unlock() }
        deleteItem()
        cached = nil
    }

    private static func deleteItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
