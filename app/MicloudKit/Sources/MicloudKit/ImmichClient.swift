import Foundation
import CryptoKit

/// Minimal Immich client for **one-way** photo upload over `URLSession` (no bundled CLI — the
/// sandbox forbids spawning one). The API key is passed in; in the app it comes from the Keychain
/// and never touches `MicloudConfig` on disk.
///
/// Scope is exactly what `PhotosSource` needs: upload an asset original. Immich dedups server-side
/// by checksum, so a re-upload returns `.duplicate` (HTTP 200) rather than storing twice — the
/// idempotency `PhotosSource` relies on for its reconcile pass.
public struct ImmichClient: Sendable {
    public let apiRoot: URL            // https://immich.example.com/api
    public let deviceId: String        // stable per-install id → groups these assets in Immich
    private let apiKey: String
    private let session: URLSession

    public init(apiRoot: URL, apiKey: String, deviceId: String = "micloud", session: URLSession = .shared) {
        self.apiRoot = apiRoot; self.apiKey = apiKey; self.deviceId = deviceId; self.session = session
    }

    /// The no-copy-paste way to connect Immich: sign in ONCE with the person's Immich email + password and
    /// mint a dedicated API key named after this Mac. The password is used for the login call and dropped;
    /// only the key is kept. This is what the Immich mobile app does too — nobody has to find
    /// "Account settings → API keys". Needs Immich ≥ 1.108 (the `permissions` field).
    public static func createAPIKey(apiRoot: URL, email: String, password: String, keyName: String,
                                    session: URLSession = .shared) async throws -> String {
        let (lc, login) = try await post(apiRoot, "auth/login", ["email": email, "password": password], session: session)
        guard (200...201).contains(lc), let access = login["accessToken"] as? String else { throw ImmichError.status(lc, "auth/login") }
        return try await mintAPIKey(apiRoot: apiRoot, accessToken: access, name: keyName, session: session)
    }

    // ── browser sign-in (OAuth), the same flow the Immich mobile app uses ─────────────────────────────
    /// Every OAuth-enabled Immich already accepts the mobile app's redirect (`app.immich:///oauth-callback`,
    /// or the server's mobile-redirect override in front of it). micloud registers that URL scheme on the
    /// Mac, so the browser hands the code straight back to the app — no password, no key to copy.
    public static let oauthRedirect = "app.immich:///oauth-callback"
    public struct OAuthStart: Sendable { public let url: URL; public let state: String?; public let codeVerifier: String? }

    /// `GET /api/server/features` → does this server offer OAuth at all?
    public static func oauthAvailable(apiRoot: URL, session: URLSession = .shared) async -> Bool {
        var r = URLRequest(url: apiRoot.appendingPathComponent("server/features"))
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await session.data(for: r),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return d["oauth"] as? Bool ?? false
    }
    /// `POST /api/oauth/authorize` → the provider's sign-in URL. The state (and PKCE verifier on newer
    /// servers) come back in cookies the session keeps, and in the body on servers that return them.
    public static func oauthStart(apiRoot: URL, session: URLSession = .shared) async throws -> OAuthStart {
        let (c, d) = try await post(apiRoot, "oauth/authorize", ["redirectUri": oauthRedirect], session: session)
        guard (200...201).contains(c), let s = d["url"] as? String, let url = URL(string: s) else { throw ImmichError.status(c, "oauth/authorize") }
        return OAuthStart(url: url, state: d["state"] as? String, codeVerifier: d["codeVerifier"] as? String)
    }
    /// `POST /api/oauth/callback` with the URL the browser handed back → an access token for this session.
    public static func oauthFinish(apiRoot: URL, callback: URL, start: OAuthStart, session: URLSession = .shared) async throws -> String {
        var body: [String: Any] = ["url": callback.absoluteString]
        if let s = start.state { body["state"] = s }
        if let v = start.codeVerifier { body["codeVerifier"] = v }
        let (c, d) = try await post(apiRoot, "oauth/callback", body, session: session)
        guard (200...201).contains(c), let access = d["accessToken"] as? String else { throw ImmichError.status(c, "oauth/callback") }
        return access
    }
    /// Mint a dedicated API key for this install, then end the browser/login session — only the key is kept.
    public static func mintAPIKey(apiRoot: URL, accessToken: String, name: String, session: URLSession = .shared) async throws -> String {
        let (kc, key) = try await post(apiRoot, "api-keys", ["name": name, "permissions": ["all"]], bearer: accessToken, session: session)
        _ = try? await post(apiRoot, "auth/logout", [:], bearer: accessToken, session: session)
        guard (200...201).contains(kc), let secret = key["secret"] as? String else { throw ImmichError.status(kc, "api-keys") }
        return secret
    }
    private static func post(_ apiRoot: URL, _ path: String, _ body: [String: Any], bearer: String? = nil,
                             session: URLSession) async throws -> (Int, [String: Any]) {
        var r = URLRequest(url: apiRoot.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let b = bearer { r.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (code, obj)
    }

    /// Disk situation for the capacity preflight: `GET /api/server/storage` → total + used bytes.
    public func storage() async throws -> TargetStorage {
        var r = URLRequest(url: apiRoot.appendingPathComponent("server/storage"))
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
            throw ImmichError.status((resp as? HTTPURLResponse)?.statusCode ?? -1, "server/storage")
        }
        struct S: Decodable { let diskSizeRaw: Int64; let diskUseRaw: Int64 }
        let s = try JSONDecoder().decode(S.self, from: data)
        return TargetStorage(totalBytes: s.diskSizeRaw, usedBytes: s.diskUseRaw)
    }

    /// `GET /api/assets/statistics` → how many assets this user already has (images + videos).
    public func assetCount() async throws -> Int {
        var r = URLRequest(url: apiRoot.appendingPathComponent("assets/statistics"))
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw ImmichError.status((resp as? HTTPURLResponse)?.statusCode ?? -1, "assets/statistics") }
        struct S: Decodable { let total: Int }
        return try JSONDecoder().decode(S.self, from: data).total
    }

    /// Every original filename this user has in Immich (paged `search/metadata`, 1000 per page). Used by the
    /// reconcile pass so a 180,000-asset library is confirmed with ~180 requests, not 180,000.
    public func allOriginalFileNames() async throws -> Set<String> {
        var names = Set<String>(); var page = 1
        while true {
            var r = URLRequest(url: apiRoot.appendingPathComponent("search/metadata"))
            r.httpMethod = "POST"
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.httpBody = try JSONSerialization.data(withJSONObject: ["size": 1000, "page": page, "withExif": false])
            let (data, resp) = try await session.data(for: r)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw ImmichError.status((resp as? HTTPURLResponse)?.statusCode ?? -1, "search/metadata page \(page)") }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let assets = obj?["assets"] as? [String: Any]
            for a in (assets?["items"] as? [[String: Any]]) ?? [] { if let n = a["originalFileName"] as? String { names.insert(n) } }
            guard let next = assets?["nextPage"], !(next is NSNull), let n = Int("\(next)") else { break }
            page = n
            if page > 5000 { break }
        }
        return names
    }

    /// Names AND fingerprints in one paged pass (`withExif` for the stored pixel size). A fingerprint is kept
    /// only when exactly one asset carries it — bursts and true duplicates share one and would be ambiguous.
    /// 2026-10-15: 184,295 of 212,922 assets had a unique key; the rest take the per-item checksum path.
    public func allPresence() async throws -> PhotoPresence {
        var names = Set<String>(); var counts: [String: Int] = [:]; var page = 1
        while true {
            var r = URLRequest(url: apiRoot.appendingPathComponent("search/metadata"))
            r.httpMethod = "POST"
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.httpBody = try JSONSerialization.data(withJSONObject: ["size": 1000, "page": page, "withExif": true])
            let (data, resp) = try await session.data(for: r)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw ImmichError.status((resp as? HTTPURLResponse)?.statusCode ?? -1, "search/metadata page \(page)") }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let assets = obj?["assets"] as? [String: Any]
            for a in (assets?["items"] as? [[String: Any]]) ?? [] {
                if let n = a["originalFileName"] as? String { names.insert(n) }
                if let ex = a["exifInfo"] as? [String: Any],
                   let w = (ex["exifImageWidth"] as? NSNumber)?.intValue, let hh = (ex["exifImageHeight"] as? NSNumber)?.intValue, w > 0, hh > 0 {
                    if let s = a["fileCreatedAt"] as? String, let d = Self.parseISO(s) {
                        counts[PhotoFingerprint.key(createdAt: d, width: w, height: hh), default: 0] += 1
                    }
                    if let s = a["localDateTime"] as? String, s.count >= 19 {
                        counts[PhotoFingerprint.naiveKey(wallClock: s, width: w, height: hh), default: 0] += 1
                    }
                }
            }
            guard let next = assets?["nextPage"], !(next is NSNull), let n = Int("\(next)") else { break }
            page = n
            if page > 5000 { break }
        }
        return PhotoPresence(names: names, fingerprints: Set(counts.filter { $0.value == 1 }.keys))
    }
    /// Immich writes `2026-07-17T17:45:02.609Z`; accept it with or without the fraction.
    public static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// `POST /api/search/metadata` by original filename → does this user already have such an asset?
    public func hasAsset(originalFileName: String) async throws -> Bool {
        var r = URLRequest(url: apiRoot.appendingPathComponent("search/metadata"))
        r.httpMethod = "POST"
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["originalFileName": originalFileName, "size": 1])
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw ImmichError.status((resp as? HTTPURLResponse)?.statusCode ?? -1, "search/metadata") }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let assets = obj?["assets"] as? [String: Any]
        if let n = assets?["total"] as? Int { return n > 0 }
        return ((assets?["items"] as? [Any])?.isEmpty == false)
    }

    /// One asset by capture time + stored pixel size, either orientation: the per-item form of `allPresence`'s
    /// fingerprint match (2026-10-18), so a reconcile of a few pending items costs two searches each instead of
    /// a ~180-page listing. Two windows: the instant, and the wall clock read as UTC — assets with no EXIF zone
    /// landed in Immich ten hours off the Mac's instant but keep the right `localDateTime`.
    public func hasAsset(createdAt: Date, width: Int, height: Int, tz: TimeZone = .current) async throws -> Bool {
        let wanted: Set<String> = [
            PhotoFingerprint.key(createdAt: createdAt, width: width, height: height),
            PhotoFingerprint.key(createdAt: createdAt, width: height, height: width),
            PhotoFingerprint.naiveKey(createdAt: createdAt, in: tz, width: width, height: height),
            PhotoFingerprint.naiveKey(createdAt: createdAt, in: tz, width: height, height: width)]
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let shifted = createdAt.addingTimeInterval(TimeInterval(tz.secondsFromGMT(for: createdAt)))
        for centre in [createdAt, shifted] {
            var r = URLRequest(url: apiRoot.appendingPathComponent("search/metadata"))
            r.httpMethod = "POST"
            r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.httpBody = try JSONSerialization.data(withJSONObject: [
                "takenAfter": iso.string(from: centre.addingTimeInterval(-2)), "takenBefore": iso.string(from: centre.addingTimeInterval(2)),
                "withExif": true, "size": 100])
            let (data, resp) = try await session.data(for: r)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else { throw ImmichError.status((resp as? HTTPURLResponse)?.statusCode ?? -1, "search/metadata (by time)") }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let assets = obj?["assets"] as? [String: Any]
            for a in (assets?["items"] as? [[String: Any]]) ?? [] {
                guard let ex = a["exifInfo"] as? [String: Any],
                      let w = (ex["exifImageWidth"] as? NSNumber)?.intValue, let hh = (ex["exifImageHeight"] as? NSNumber)?.intValue, w > 0, hh > 0 else { continue }
                var keys: [String] = []
                if let s = a["fileCreatedAt"] as? String, let d = Self.parseISO(s) { keys.append(PhotoFingerprint.key(createdAt: d, width: w, height: hh)) }
                if let s = a["localDateTime"] as? String, s.count >= 19 { keys.append(PhotoFingerprint.naiveKey(wallClock: s, width: w, height: hh)) }
                if keys.contains(where: wanted.contains) { return true }
            }
        }
        return false
    }

    /// Auth + liveness probe: `GET /api/users/me` (200 ⇒ key is valid and the server is up).
    public func checkAuth() async throws -> String {
        var r = URLRequest(url: apiRoot.appendingPathComponent("users/me"))
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw ImmichError.noResponse("users/me") }
        guard h.statusCode == 200 else { throw ImmichError.status(h.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let me = try? JSONDecoder().decode(Me.self, from: data)
        return me?.email ?? "ok"
    }

    /// Upload a photo/video original as an Immich asset. Idempotent: 201 ⇒ `.created`, and a
    /// checksum that already exists ⇒ 200 with `status: "duplicate"`.
    public func uploadAsset(localFile: URL, filename: String,
                            createdAt: Date, modifiedAt: Date,
                            deviceAssetId: String? = nil) async throws -> PhotoUploadResult {
        // Ask before sending. Immich dedups by SHA-1 of the bytes, and answering "duplicate" costs it one
        // row lookup — but only after the whole multipart body has arrived. On a library Immich already
        // held (1.2 TB, 2026-10-15) every photo the lane sent for Nextcloud's sake went up to Immich a
        // second time, doubling the remaining transfer. Hashing a file we already have on disk is cheap;
        // a failed check falls through to the upload, which stays idempotent.
        if let sha1 = try? Self.sha1Hex(of: localFile), (try? await hasAsset(sha1Hex: sha1)) == true { return .duplicate }
        let boundary = "micloud-\(UUID().uuidString)"
        let body = try Self.multipartBody(
            boundary: boundary, file: localFile, filename: filename,
            fields: [
                "deviceAssetId": deviceAssetId ?? "\(deviceId)-\(filename)",
                "deviceId": deviceId,
                "fileCreatedAt": Self.iso.string(from: createdAt),
                "fileModifiedAt": Self.iso.string(from: modifiedAt),
            ])
        defer { try? FileManager.default.removeItem(at: body) }

        var r = URLRequest(url: apiRoot.appendingPathComponent("assets"))
        r.httpMethod = "POST"
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await session.upload(for: r, fromFile: body)
        guard let h = resp as? HTTPURLResponse else { throw ImmichError.noResponse("POST assets") }
        guard (200...201).contains(h.statusCode) else {
            throw ImmichError.status(h.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try? JSONDecoder().decode(AssetCreateResponse.self, from: data)
        return decoded?.status == "duplicate" ? .duplicate : .created
    }

    /// `POST /api/assets/bulk-upload-check` — does the user already hold an asset with these bytes?
    /// `action: "reject", reason: "duplicate"` ⇒ yes. Hex SHA-1, as the Immich CLI sends it.
    public func hasAsset(sha1Hex: String) async throws -> Bool {
        var r = URLRequest(url: apiRoot.appendingPathComponent("assets/bulk-upload-check"))
        r.httpMethod = "POST"
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["assets": [["id": sha1Hex, "checksum": sha1Hex]]])
        let (data, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200 else {
            throw ImmichError.status((resp as? HTTPURLResponse)?.statusCode ?? -1, "assets/bulk-upload-check")
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let first = (obj?["results"] as? [[String: Any]])?.first else { return false }
        return (first["action"] as? String) == "reject" && (first["reason"] as? String) == "duplicate"
    }

    /// Streaming SHA-1 of a file (1 MiB reads), hex — Immich's asset checksum.
    public static func sha1Hex(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // ── wire types ───────────────────────────────────────────────────────────
    private struct Me: Decodable { let email: String }
    private struct AssetCreateResponse: Decodable { let id: String; let status: String }

    private static let iso = ISO8601DateFormatter()

    /// Assemble a `multipart/form-data` body into a temp file, streaming the asset in 1 MiB chunks
    /// so a large video is never fully loaded into RAM. Caller deletes the returned file.
    static func multipartBody(boundary: String, file: URL, filename: String,
                              fields: [String: String]) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("immich-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }
        func w(_ s: String) throws { try out.write(contentsOf: Data(s.utf8)) }

        for (k, v) in fields {
            try w("--\(boundary)\r\n")
            try w("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        try w("--\(boundary)\r\n")
        try w("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\n")
        try w("Content-Type: application/octet-stream\r\n\r\n")

        let inFH = try FileHandle(forReadingFrom: file)
        defer { try? inFH.close() }
        while let chunk = try inFH.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try w("\r\n--\(boundary)--\r\n")
        return tmp
    }
}

public enum ImmichError: Error, CustomStringConvertible {
    case noResponse(String)
    case status(Int, String)
    public var description: String {
        switch self {
        case .noResponse(let op):   return "no HTTP response for \(op)"
        case .status(let c, let m): return "Immich HTTP \(c): \(m.prefix(300))"
        }
    }
}
