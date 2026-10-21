import Foundation

/// Nextcloud **Login Flow v2** — the no-copy-paste way to connect. The person signs in with their normal
/// browser session (password, SSO, 2FA, whatever their server uses) and Nextcloud hands THIS app its own
/// app password. No "Settings → Security → Devices & sessions" scavenger hunt. It is the same mechanism
/// the official Nextcloud desktop client uses, and it works on every supported Nextcloud (16+).
/// https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html#login-flow-v2
public enum NextcloudLoginFlow {
    public struct Started: Sendable { public let loginURL: URL; let pollEndpoint: URL; let token: String }
    public struct Credentials: Sendable { public let server: URL; public let loginName: String; public let appPassword: String }
    public enum Failure: Error, CustomStringConvertible {
        case badServer, unsupported(Int), timeout
        public var description: String {
            switch self {
            case .badServer:          return "not a Nextcloud server (no login/v2 endpoint)"
            case .unsupported(let c): return "login/v2 answered HTTP \(c)"
            case .timeout:            return "the sign-in was not approved in time"
            }
        }
    }

    /// Normalise what a person types: scheme optional, trailing slash / `index.php` tolerated.
    public static func normalise(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/index.php") { s.removeLast("/index.php".count) }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return u
    }

    /// Ask the server for a login URL + poll token. `clientName` becomes the token's name in the person's
    /// security settings ("micloud on your Mac mini"), so they can recognise and revoke it later.
    public static func start(server: URL, clientName: String, session: URLSession = .shared) async throws -> Started {
        var r = URLRequest(url: server.appendingPathComponent("index.php/login/v2"))
        r.httpMethod = "POST"
        r.setValue(clientName, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw Failure.badServer }
        guard h.statusCode == 200 else { throw Failure.unsupported(h.statusCode) }
        struct R: Decodable { struct P: Decodable { let token: String; let endpoint: String }; let poll: P; let login: String }
        guard let d = try? JSONDecoder().decode(R.self, from: data),
              let login = URL(string: d.login), let ep = URL(string: d.poll.endpoint) else { throw Failure.badServer }
        return Started(loginURL: login, pollEndpoint: ep, token: d.poll.token)
    }

    /// Poll until the person has approved in the browser. Nextcloud answers 404 until then and expires
    /// the flow server-side after 20 minutes. Cancel the surrounding Task to abandon.
    public static func waitForApproval(_ s: Started, every: TimeInterval = 2, timeout: TimeInterval = 20 * 60,
                                       session: URLSession = .shared) async throws -> Credentials {
        let deadline = Date().addingTimeInterval(timeout)
        let body = "token=" + (s.token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s.token)
        while Date() < deadline {
            try Task.checkCancellation()
            var r = URLRequest(url: s.pollEndpoint)
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.httpBody = body.data(using: .utf8)
            if let res = try? await session.data(for: r), let h = res.1 as? HTTPURLResponse, h.statusCode == 200 {
                struct R: Decodable { let server: String; let loginName: String; let appPassword: String }
                guard let d = try? JSONDecoder().decode(R.self, from: res.0), let srv = URL(string: d.server) else { throw Failure.badServer }
                return Credentials(server: srv, loginName: d.loginName, appPassword: d.appPassword)
            }
            try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
        throw Failure.timeout
    }
}
