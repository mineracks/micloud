import Foundation
import SwiftUI
import UIKit

// Pairing the iPhone with the person's Nextcloud — the same "Sign in with Nextcloud" the Mac app uses
// (Login Flow v2): the server's own sign-in page opens in an in-app browser sheet, the person signs in the
// way they always do (password, SSO, 2FA), Nextcloud hands THIS app its own app password, and the sheet
// closes by itself. Nothing to copy, no token page to find. The app password lives in the iOS Keychain; the
// server + login name in UserDefaults (non-secret). That one credential is all the phone needs: it reads
// `micloud/status.json` (the Mac's dashboard) and writes `Health/` (the archive the Mac's Health tile reports).

@MainActor
final class Pairing: ObservableObject {
    enum State: Equatable { case idle, signingIn, failed(String) }
    @Published var server = ""
    @Published private(set) var user: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var dav: NextcloudWebDAV?

    private static let service = "com.mineracks.micloud.phone"
    private var flow: Task<Void, Never>?

    var isPaired: Bool { dav != nil }
    var serverHost: String { URL(string: server)?.host ?? server }

    init() { restore() }

    /// Env creds (simulator drills via SIMCTL_CHILD_*) win; otherwise the saved pairing.
    private func restore() {
        let env = ProcessInfo.processInfo.environment
        if let s = env["NEXTCLOUD_URL"], let root = URL(string: s), let u = env["NEXTCLOUD_USER"], let p = env["NEXTCLOUD_PASS"] {
            server = s; user = u
            dav = NextcloudWebDAV(filesRoot: root, username: u, appPassword: p, session: Self.session(for: root))
            return
        }
        let d = UserDefaults.standard
        guard let s = d.string(forKey: "nc.server"), let u = d.string(forKey: "nc.user"),
              let base = URL(string: s), let p = Self.keychainRead("nextcloud:\(u)") else { return }
        server = s; user = u
        dav = Self.makeDav(base: base, user: u, password: p)
    }

    private static func makeDav(base: URL, user: String, password: String) -> NextcloudWebDAV {
        let root = base.appendingPathComponent("remote.php/dav/files").appendingPathComponent(user)
        return NextcloudWebDAV(filesRoot: root, username: user, appPassword: password, session: session(for: base))
    }

    /// Real servers get real TLS checks. Only a bare-IP server (a lab box with a self-signed cert) is trusted blindly.
    private static func session(for url: URL) -> URLSession {
        let host = url.host ?? ""
        let ipLike = host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
        return URLSession(configuration: .ephemeral, delegate: ipLike ? TrustAll() : nil, delegateQueue: nil)
    }

    func signIn() {
        guard let base = NextcloudLoginFlow.normalise(server) else { state = .failed(L("pair.badServer")); return }
        server = base.absoluteString; state = .signingIn
        flow?.cancel()
        flow = Task { @MainActor in
            // Keep running for the ~30 s iOS grants after Safari comes to the front: a person with an existing
            // SSO session is approved before they even look back. Otherwise the poll freezes with the app and
            // resumes the moment they return — Nextcloud keeps the flow open for 20 minutes.
            var bg: UIBackgroundTaskIdentifier = .invalid
            bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
            defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
            do {
                let session = Self.session(for: base)
                let name = "micloud on " + UIDevice.current.name
                let started = try await NextcloudLoginFlow.start(server: base, clientName: name, session: session)
                // The real Safari, exactly like the Mac app opens the default browser: the server's sign-in page
                // with whatever SSO sits in front of it. An in-app auth sheet was tried first and lost Cloudflare
                // Access's sign-in state on the way back from Google (it ended on the Access launcher page).
                await UIApplication.shared.open(started.loginURL)
                let creds = try await NextcloudLoginFlow.waitForApproval(started, session: session)
                guard Self.keychainWrite("nextcloud:\(creds.loginName)", creds.appPassword) else { state = .failed(L("pair.keychain")); return }
                UserDefaults.standard.set(creds.server.absoluteString, forKey: "nc.server")
                UserDefaults.standard.set(creds.loginName, forKey: "nc.user")
                server = creds.server.absoluteString; user = creds.loginName
                dav = Self.makeDav(base: creds.server, user: creds.loginName, password: creds.appPassword)
                state = .idle
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(L("pair.failed", "\(error)"))
            }
        }
    }
    func cancel() { flow?.cancel(); flow = nil; state = .idle }

    /// Forget the pairing on this phone. The app password stays valid server-side until revoked in
    /// Nextcloud → Settings → Security (named "micloud on <iPhone>"), the same as any device.
    func signOut() {
        if let u = user { Self.keychainDelete("nextcloud:\(u)") }
        UserDefaults.standard.removeObject(forKey: "nc.server"); UserDefaults.standard.removeObject(forKey: "nc.user")
        user = nil; dav = nil; state = .idle
    }

    // MARK: keychain

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func keychainWrite(_ account: String, _ value: String) -> Bool {
        var q = query(account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock   // background Health runs need it
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func keychainRead(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func keychainDelete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) } else { h(.performDefaultHandling, nil) }
    }
}
