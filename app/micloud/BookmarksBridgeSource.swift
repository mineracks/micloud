import Foundation

/// Demo bridge for the **Bookmarks** lane. Nextcloud Bookmarks is REST-API-backed (not files), so unlike the
/// Notes/Photos bridges this POSTs each bookmark to the Bookmarks app's REST endpoint rather than uploading a
/// file. The orchestrator drops a small JSON `{url,title,description}` — the page the visitor just bookmarked in
/// Safari — into `MICLOUD_BOOKMARKS_BRIDGE_DIR`, and this carries it to Nextcloud Bookmarks through the SAME
/// `BackfillEngine` as every other lane, so the Bookmarks badge / activity graph / live log react for real.
/// `nil` in production (env unset). Idempotent: each file uploads once (ledger content-hash).
final class BookmarksBridgeSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .bookmarks
    private let dir: String
    private let endpoint: URL             // <nc-base>/index.php/apps/bookmarks/public/rest/v2/bookmark
    private let authHeader: String        // "Basic base64(user:app-password)" — from the same NC creds as WebDAV
    private let session: URLSession
    private let capacity: BackfillTarget  // reuse the NC WebDAV target for the capacity pre-check

    struct BookmarkError: Error { let status: Int }

    /// Derives the Bookmarks REST endpoint + auth from the app's NextcloudWebDAV (so it works with BOTH the
    /// env-injected creds AND the onboarded install path — the demo Mac uses the latter, where NEXTCLOUD_URL
    /// isn't in the environment; the creds live in the Keychain and reach us via `dav`).
    init(dir: String, dav: NextcloudWebDAV, session: URLSession) {
        self.dir = dir
        var comps = URLComponents(url: dav.filesRoot, resolvingAgainstBaseURL: false)
        comps?.path = "/index.php/apps/bookmarks/public/rest/v2/bookmark"; comps?.query = nil
        self.endpoint = comps?.url ?? dav.filesRoot
        self.authHeader = dav.authHeader
        self.session = session
        self.capacity = dav
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        var out: [BackfillEntry] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            guard name.lowercased().hasSuffix(".json") else { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append(BackfillEntry(key: "bookmarkbridge:\(name)", relativePath: name, bytes: size,
                                     contentHash: "\(size)-\(Int(mtime))"))
        }
        return out
    }

    func process(_ entry: BackfillEntry) async throws {
        let path = (dir as NSString).appendingPathComponent(entry.relativePath)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let url = (obj["url"] as? String) ?? ""
        guard !url.isEmpty else { return }
        let title = (obj["title"] as? String) ?? ""
        let desc = (obj["description"] as? String) ?? ""

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String {
            var cs = CharacterSet.alphanumerics; cs.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: cs) ?? ""
        }
        req.httpBody = Data("url=\(enc(url))&title=\(enc(title))&description=\(enc(desc))".utf8)

        let (_, resp) = try await session.data(for: req)
        // Any 2xx means the POST reached Nextcloud (a duplicate URL comes back 200 with status:error — that's
        // still "the bookmark is on your server", so we accept it and don't quarantine).
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BookmarkError(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    func capacityTargets() -> [BackfillTarget] { [capacity] }
}
