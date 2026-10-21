import Foundation

/// Shared bits for the production ("pro edition") lanes that read other apps' data on this Mac.
enum RealHome {
    /// The user's REAL home. Inside the sandbox `NSHomeDirectory()` is the app container; Safari, Notes and
    /// Messages keep their stores under the real one (reachable with the relay entitlements + Full Disk Access).
    static let url: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir), isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    /// Where the lanes keep their small id→server-id manifests (survives relaunches, never contains secrets).
    static var manifests: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("micloud/manifests", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Tiny JSON REST client for the Nextcloud *apps* (Bookmarks, Notes) — same base + Basic auth as the WebDAV
/// target, so an onboarded install needs no extra credential.
struct NextcloudREST: Sendable {
    let base: URL          // https://nc.example.com
    let authHeader: String
    let session: URLSession
    let userAgent: String

    init(dav: NextcloudWebDAV, session: URLSession, userAgent: String) {
        var c = URLComponents(url: dav.filesRoot, resolvingAgainstBaseURL: false)!
        c.path = ""; c.query = nil
        self.base = c.url ?? dav.filesRoot
        self.authHeader = dav.authHeader; self.session = session; self.userAgent = userAgent
    }

    struct Failure: Error, CustomStringConvertible { let status: Int; let body: String; var description: String { "HTTP \(status) \(body.prefix(160))" } }

    /// JSON in, JSON out. `params` become the query string. Returns (status, parsed JSON or nil).
    func call(_ method: String, _ path: String, params: [String: String] = [:], json: Any? = nil) async throws -> (Int, Any?) {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !params.isEmpty { c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!); req.httpMethod = method; req.timeoutInterval = 30
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let json { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let parsed = try? JSONSerialization.jsonObject(with: data)
        return (status, parsed)
    }
}

/// Minimal JSON-file manifest: `[String: [String: Any]]` keyed by the source's stable id.
struct LaneManifest {
    let url: URL
    var items: [String: [String: Any]]
    var extra: [String: Any]
    init(name: String) {
        url = RealHome.manifests.appendingPathComponent("\(name).json")
        if let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            items = o["items"] as? [String: [String: Any]] ?? [:]
            extra = o["extra"] as? [String: Any] ?? [:]
        } else { items = [:]; extra = [:] }
    }
    func save() {
        let o: [String: Any] = ["items": items, "extra": extra]
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { try? d.write(to: url, options: .atomic) }
    }
}

enum Hashing {
    static func sha256(_ s: String) -> String {
        // CryptoKit-free (keeps the swiftc link line unchanged): FNV-1a 64 over UTF-8, hex — plenty for change detection.
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
