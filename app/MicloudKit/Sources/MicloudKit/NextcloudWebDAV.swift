import Foundation

/// Minimal Nextcloud WebDAV client for **one-way** upload of iCloud Drive files, over `URLSession`
/// (no bundled rclone — the sandbox forbids spawning it). Credentials (a Nextcloud app-password) are
/// passed in; in the app they come from the Keychain and never touch `MicloudConfig` on disk.
///
/// Scope is deliberately small — exactly what the DriveSource needs: PUT a file, make parent
/// collections, and MOVE (for soft-delete to a dated trash). No PROPFIND/sync-token yet.
public struct NextcloudWebDAV: Sendable {
    public let filesRoot: URL          // https://nc.example.com/remote.php/dav/files/<user>
    public let authHeader: String      // "Basic base64(user:password)" — reused by the Bookmarks REST source
    private let session: URLSession
    /// Collections this client has created or confirmed. Shared by every copy of the struct (reference), so a
    /// 10-deep tree costs ten MKCOL round trips once, not once per file — through Cloudflare that was most of a
    /// small file's upload time.
    private let known = KnownCollections()
    final class KnownCollections: @unchecked Sendable {
        private let lock = NSLock(); private var set = Set<String>()
        func has(_ p: String) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(p) }
        func add(_ p: String) { lock.lock(); set.insert(p); lock.unlock() }
    }

    public init(filesRoot: URL, username: String, appPassword: String, session: URLSession = .shared) {
        self.filesRoot = filesRoot
        self.authHeader = "Basic " + Data("\(username):\(appPassword)".utf8).base64EncodedString()
        self.session = session
    }

    /// Resolve a remote relative path (e.g. `Documents/sub/My File.txt`) against `filesRoot`,
    /// percent-encoding each path segment. Public so the DriveSource + tests can inspect mapping.
    public func url(for relativePath: String) -> URL {
        var u = filesRoot
        for seg in relativePath.split(separator: "/") { u.appendPathComponent(Self.storedName(String(seg))) }
        return u
    }

    /// Names Nextcloud refuses outright (`forbidden_filenames`, default `.htaccess`, matched case-insensitively
    /// for every path segment): Apache would read a user-supplied `.htaccess` as live config if the data
    /// directory were ever web-reachable, so the server answers 400 and the item quarantined for good — the
    /// one file in 175,000 a web-site backup could not carry (2026-10-15). Stored under a name the server
    /// accepts; the ledger keeps the original key, and every request (PUT, HEAD, PROPFIND, MOVE) maps through
    /// here so the presence check and both lanes agree on where the file lives. Not a dotfile, so the copy
    /// is visible in the Nextcloud UI.
    public static func storedName(_ name: String) -> String {
        name.lowercased() == ".htaccess" ? "htaccess.txt" : name
    }

    private func request(_ method: String, _ relativePath: String) -> URLRequest {
        var r = URLRequest(url: url(for: relativePath))
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return r
    }

    /// Files above this go up through Nextcloud's chunked-upload API instead of one PUT. Why: the public
    /// hostname sits behind Cloudflare, whose proxy rejects any request body over 100 MB — twelve Drive files of
    /// 122 MB–3.1 GB failed four times each ("cannot parse response", "connection lost") and were quarantined as
    /// "couldn't be read" (2026-10-15). The largest single PUT that ever succeeded was 101 MB.
    public static let chunkThreshold: Int64 = 64 << 20
    /// 50 MiB: under Cloudflare's cap and under Nextcloud's default `files.chunked_upload.max_size` (100 MiB).
    public static let chunkSize = 50 << 20

    /// PUT a local file to `relativePath` (call `ensureParents` first if the tree may not exist).
    /// Large files go in chunks — see `chunkThreshold`.
    public func upload(localFile: URL, to relativePath: String) async throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: localFile.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if size > Self.chunkThreshold {
            try await uploadChunked(localFile: localFile, size: size, mtime: attrs?[.modificationDate] as? Date, to: relativePath)
            return
        }
        var r = request("PUT", relativePath)
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await session.upload(for: r, fromFile: localFile)
        try Self.check(resp, ok: [200, 201, 204], op: "PUT \(relativePath)")
    }

    /// Nextcloud chunked upload (what the desktop client does): MKCOL `uploads/<user>/<id>/`, PUT the pieces
    /// as `00001`, `00002`, … (each under `chunkSize`, so each request is under the edge's body cap), then one
    /// MOVE of `<id>/.file` to the destination — the server assembles the file. `Destination` goes on every
    /// request (the v2 API wants it); `OC-Total-Length` lets the server check it has every byte.
    func uploadChunked(localFile: URL, size: Int64, mtime: Date?, to relativePath: String) async throws {
        let uploadId = "micloud-" + UUID().uuidString.lowercased()
        let dir = "uploads/\(user)/\(uploadId)"
        let destination = url(for: relativePath).absoluteString
        let chunks = Int((size + Int64(Self.chunkSize) - 1) / Int64(Self.chunkSize))
        func req(_ method: String, _ path: String) -> URLRequest {
            var r = davRequest(method, path)
            r.setValue(destination, forHTTPHeaderField: "Destination")
            return r
        }
        let (mkBody, mkResp) = try await session.data(for: req("MKCOL", dir))
        try Self.check(mkResp, ok: [201], op: "MKCOL \(dir) for \(relativePath)", body: mkBody)
        do {
            let fh = try FileHandle(forReadingFrom: localFile)
            defer { try? fh.close() }
            var offset: Int64 = 0
            for index in 1...max(1, chunks) {
                let n = Int(min(Int64(Self.chunkSize), size - offset))
                try fh.seek(toOffset: UInt64(offset))
                guard let data = try fh.read(upToCount: n), data.count == n else {
                    throw WebDAVError.noResponse("short read at \(offset) of \(relativePath)")
                }
                let name = String(format: "%05d", index)
                var put = req("PUT", "\(dir)/\(name)")
                put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                // A chunk is small and idempotent: a transient edge error costs one chunk, not the whole file.
                // Five tries, not three: on 2026-10-15 (ISP fault) 10 of 118 chunks arrived truncated (Nextcloud
                // 400 "expected 52428800 bytes but read 20226048") — at 8 % per chunk a 63-chunk file needs the
                // extra headroom, and every one of those ten went through on the next try.
                var attempt = 0
                while true {
                    do {
                        let (b, r) = try await session.upload(for: put, from: data)
                        try Self.check(r, ok: [200, 201, 204], op: "PUT chunk \(index)/\(chunks) of \(relativePath)", body: b)
                        break
                    } catch {
                        attempt += 1
                        if attempt >= 5 { throw error }
                        try await Task.sleep(nanoseconds: 2_000_000_000 * UInt64(attempt))
                    }
                }
                offset += Int64(n)
            }
            var mv = req("MOVE", "\(dir)/.file")
            mv.setValue("T", forHTTPHeaderField: "Overwrite")
            mv.setValue(String(size), forHTTPHeaderField: "OC-Total-Length")
            if let mtime { mv.setValue(String(Int(mtime.timeIntervalSince1970)), forHTTPHeaderField: "X-OC-Mtime") }
            do {
                let (b, r) = try await session.data(for: mv)
                try Self.check(r, ok: [201, 204], op: "MOVE assemble \(relativePath)", body: b)
            } catch {
                // Assembling gigabytes can outlive the edge's response timeout while the server is still
                // finishing. Before believing the error, ask the server whether the whole file is there.
                for _ in 0..<30 {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    if await exists(relativePath, bytes: size) { return }
                }
                throw error
            }
        } catch {
            _ = try? await session.data(for: davRequest("DELETE", dir))   // don't leave pieces behind
            throw error
        }
    }

    /// HEAD: is this file already on the server (optionally: with exactly this size)? A fresh Mac has an
    /// empty ledger — the server does not. Every uploader asks this first so nothing is sent twice.
    public func exists(_ relativePath: String, bytes: Int64? = nil) async -> Bool {
        guard let res = try? await session.data(for: request("HEAD", relativePath)),
              let h = res.1 as? HTTPURLResponse, h.statusCode == 200 else { return false }
        if let b = bytes, let len = h.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }), len != b { return false }
        return true
    }

    /// Bytes already stored under a folder (`oc:size`, PROPFIND Depth 0); 0 if it does not exist yet.
    public func folderBytes(_ relativePath: String) async -> Int64 {
        var r = request("PROPFIND", relativePath)
        r.setValue("0", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\" xmlns:oc=\"http://owncloud.org/ns\"><d:prop><oc:size/></d:prop></d:propfind>".utf8)
        guard let res = try? await session.data(for: r), let h = res.1 as? HTTPURLResponse, h.statusCode == 207,
              let s = String(data: res.0, encoding: .utf8),
              let a = s.range(of: "<oc:size>"), let z = s.range(of: "</oc:size>"), a.upperBound <= z.lowerBound else { return 0 }
        return Int64(s[a.upperBound..<z.lowerBound]) ?? 0
    }

    /// One PROPFIND Depth 1 → `[filename: bytes]` for the files directly in a folder (folders omitted).
    /// Empty if the folder does not exist. This is how the reconcile pass checks a whole directory at once.
    public func listFolder(_ relativePath: String) async -> [String: Int64] {
        var r = request("PROPFIND", relativePath)
        r.timeoutInterval = 300                    // a folder with tens of thousands of photos is a big listing
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>".utf8)
        let got: (Data, URLResponse)?
        do { got = try await session.data(for: r) } catch { NSLog("micloud listFolder %@: %@", relativePath, "\(error)"); got = nil }
        guard let res = got, let h = res.1 as? HTTPURLResponse, h.statusCode == 207,
              let s = String(data: res.0, encoding: .utf8) else {
            NSLog("micloud listFolder %@: HTTP %d", relativePath, (got?.1 as? HTTPURLResponse)?.statusCode ?? -1); return [:]
        }
        var out: [String: Int64] = [:]
        var rest = Substring(s)
        while let a = rest.range(of: "<d:response>"), let z = rest[a.upperBound...].range(of: "</d:response>") {
            let block = rest[a.upperBound..<z.lowerBound]; rest = rest[z.upperBound...]
            guard block.contains("<d:collection/>") == false,
                  let h1 = block.range(of: "<d:href>"), let h2 = block[h1.upperBound...].range(of: "</d:href>"),
                  let l1 = block.range(of: "<d:getcontentlength>"), let l2 = block[l1.upperBound...].range(of: "</d:getcontentlength>") else { continue }
            let href = String(block[h1.upperBound..<h2.lowerBound])
            let name = (href.removingPercentEncoding ?? href).split(separator: "/").last.map(String.init) ?? ""
            if let n = Int64(block[l1.upperBound..<l2.lowerBound]), !name.isEmpty { out[name] = n }
        }
        return out
    }

    /// Reconcile helper: group `(key, remoteRelativePath, bytes)` by folder, list each folder once (6 at a
    /// time), return the keys whose file is there with the same size.
    public func presentKeys(_ items: [(key: String, remote: String, bytes: Int64)]) async -> Set<String> {
        var byDir: [String: [(String, String, Int64)]] = [:]
        for it in items {
            let dir = it.remote.contains("/") ? String(it.remote[..<it.remote.lastIndex(of: "/")!]) : ""
            let name = Self.storedName(it.remote.split(separator: "/").last.map(String.init) ?? it.remote)
            byDir[dir, default: []].append((it.key, name, it.bytes))
        }
        var present = Set<String>()
        let dirs = Array(byDir.keys)
        var i = 0
        while i < dirs.count {
            let chunk = dirs[i..<min(i + 6, dirs.count)]; i += 6
            await withTaskGroup(of: (String, [String: Int64]).self) { g in
                for d in chunk { g.addTask { (d, await self.listFolder(d)) } }
                for await (d, listing) in g {
                    for (key, name, bytes) in byDir[d] ?? [] where listing[name] == bytes { present.insert(key) }
                }
            }
        }
        return present
    }

    /// Newest `getlastmodified` among a folder and its direct children (PROPFIND Depth 1); nil if absent.
    /// Nextcloud propagates child changes to folder mtimes, so this is "when did anything last land here".
    public func latestModified(_ relativePath: String) async -> Date? {
        var r = request("PROPFIND", relativePath)
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:getlastmodified/></d:prop></d:propfind>".utf8)
        guard let res = try? await session.data(for: r), let h = res.1 as? HTTPURLResponse, h.statusCode == 207,
              let s = String(data: res.0, encoding: .utf8) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        var best: Date?
        var rest = Substring(s)
        while let a = rest.range(of: "<d:getlastmodified>"), let z = rest[a.upperBound...].range(of: "</d:getlastmodified>") {
            if let d = f.date(from: String(rest[a.upperBound..<z.lowerBound])), best.map({ d > $0 }) ?? true { best = d }
            rest = rest[z.upperBound...]
        }
        return best
    }

    /// GET a file's bytes (used by the iOS companion to read `micloud/status.json`).
    public func fetch(_ relativePath: String) async throws -> Data {
        let (data, resp) = try await session.data(for: request("GET", relativePath))
        try Self.check(resp, ok: [200], op: "GET \(relativePath)")
        return data
    }

    /// MKCOL — create a collection. Idempotent: 405 (already exists) is treated as success.
    public func makeCollection(_ relativePath: String) async throws {
        if known.has(relativePath) { return }
        var attempt = 0
        while true {
            let (body, resp) = try await session.data(for: request("MKCOL", relativePath))
            // 423: another worker is creating this very collection right now (Nextcloud holds an exclusive
            // lock on the node for the length of its MKCOL). Give it a moment and ask again — the answer
            // becomes 405 (exists), which is success.
            if let h = resp as? HTTPURLResponse, h.statusCode == 423, attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: 700_000_000 * UInt64(attempt))
                continue
            }
            try Self.check(resp, ok: [201, 405], op: "MKCOL \(relativePath)", body: body)
            known.add(relativePath)
            return
        }
    }

    /// Idempotently create every parent collection of a file path.
    public func ensureParents(of relativePath: String) async throws {
        let segs = relativePath.split(separator: "/").dropLast()
        var acc = ""
        for s in segs { acc += (acc.isEmpty ? "" : "/") + s; try await makeCollection(acc) }
    }

    /// MOVE `from` → `to` (both relative). Used for soft-delete into a dated trash path.
    public func move(_ from: String, to: String) async throws {
        try await ensureParents(of: to)   // the destination's dated collection may not exist yet (soft-delete trash)
        var r = request("MOVE", from)
        r.setValue(url(for: to).absoluteString, forHTTPHeaderField: "Destination")
        r.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, resp) = try await session.data(for: r)
        try Self.check(resp, ok: [201, 204], op: "MOVE \(from) -> \(to)")
    }

    // ── CardDAV / CalDAV ──────────────────────────────────────────────────────
    // Contacts, calendar events and reminders must land in Nextcloud's NATIVE apps (Contacts / Calendar /
    // Tasks) so they're actually usable — not as inert .vcf/.ics files in the Files app. Those apps are fed
    // by CardDAV/CalDAV collections that hang off `/remote.php/dav/` (a sibling of `files/<user>`), so we PUT
    // the already-generated vCard/iCal bodies there instead of to a Files folder.

    /// The `/remote.php/dav/` base — the parent of `files/<user>`.
    public var davBase: URL { filesRoot.deletingLastPathComponent().deletingLastPathComponent() }
    /// The account username (last path segment of `filesRoot`), for building CardDAV/CalDAV user paths.
    public var user: String { filesRoot.lastPathComponent }

    /// PUT a body to an absolute collection path under `/remote.php/dav/` (percent-encoding each segment).
    public func putDAV(_ davPath: String, body: Data, contentType: String) async throws {
        var u = davBase
        for seg in davPath.split(separator: "/") { u.appendPathComponent(String(seg)) }
        var r = URLRequest(url: u)
        r.httpMethod = "PUT"
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.upload(for: r, from: body)
        try Self.check(resp, ok: [200, 201, 204], op: "PUT dav \(davPath)", body: data)
    }

    /// Land a vCard in the user's CardDAV addressbook → appears in the Nextcloud **Contacts** app.
    public func putContact(addressbook: String = "contacts", filename: String, vcard: Data) async throws {
        try await putDAV("addressbooks/users/\(user)/\(addressbook)/\(filename)",
                         body: vcard, contentType: "text/vcard; charset=utf-8")
    }

    private func davRequest(_ method: String, _ davPath: String) -> URLRequest {
        var u = davBase
        for seg in davPath.split(separator: "/") { u.appendPathComponent(String(seg)) }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return r
    }

    /// Make sure a CalDAV calendar exists — Nextcloud answers 404 to every PUT into a calendar nobody
    /// created, which is what a fresh account looks like. PROPFIND Depth 0, then MKCALENDAR if absent.
    public func ensureCalendar(_ calendar: String, components: [String], displayName: String? = nil) async throws {
        let davPath = "calendars/\(user)/\(calendar)"
        var probe = davRequest("PROPFIND", davPath)
        probe.setValue("0", forHTTPHeaderField: "Depth")
        if let res = try? await session.data(for: probe), let h = res.1 as? HTTPURLResponse, h.statusCode == 207 { return }
        var r = davRequest("MKCALENDAR", davPath)
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let comps = components.map { "<C:comp name=\"\($0)\"/>" }.joined()
        let name = (displayName ?? calendar).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        r.httpBody = Data(("<?xml version=\"1.0\" encoding=\"utf-8\" ?><C:mkcalendar xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><D:set><D:prop><D:displayname>" + name + "</D:displayname><C:supported-calendar-component-set>" + comps + "</C:supported-calendar-component-set></D:prop></D:set></C:mkcalendar>").utf8)
        let (_, resp) = try await session.data(for: r)
        try Self.check(resp, ok: [201, 405], op: "MKCALENDAR \(davPath)")   // 405 = it raced into existence
    }

    /// Land a VEVENT/VTODO in a CalDAV calendar → appears in the **Calendar** (events) / **Tasks** (todos) apps.
    /// NB: Nextcloud CalDAV is `calendars/<user>/<cal>/` (no `users/` segment — unlike CardDAV addressbooks).
    public func putCalendarObject(calendar: String, filename: String, ical: Data) async throws {
        try await putDAV("calendars/\(user)/\(calendar)/\(filename)",
                         body: ical, contentType: "text/calendar; charset=utf-8")
    }

    /// The filename of the object in `calendar` that carries `uid` (a REPORT calendar-query filtered on UID), or
    /// nil when none does. Why: a CalDAV calendar holds one object per UID — a PUT of an edited event under any
    /// other filename is refused ("already exists"), so the edit must go to the name the server already has.
    /// `component` is "VEVENT" or "VTODO" (the filter must name the component the UID lives in).
    public func calendarObjectName(calendar: String, uid: String, component: String) async throws -> String? {
        var r = davRequest("REPORT", "calendars/\(user)/\(calendar)")
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let u = uid.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        r.httpBody = Data(("<?xml version=\"1.0\" encoding=\"utf-8\" ?><C:calendar-query xmlns:D=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\"><D:prop><D:getetag/></D:prop><C:filter><C:comp-filter name=\"VCALENDAR\"><C:comp-filter name=\"" + component + "\"><C:prop-filter name=\"UID\"><C:text-match collation=\"i;octet\">" + u + "</C:text-match></C:prop-filter></C:comp-filter></C:comp-filter></C:filter></C:calendar-query>").utf8)
        let (data, resp) = try await session.data(for: r)
        try Self.check(resp, ok: [207], op: "REPORT calendars/\(calendar) uid", body: data)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // <d:href>/remote.php/dav/calendars/u/cal/name.ics</d:href> — prefix varies (d:, D:), so match the local name.
        let re = try NSRegularExpression(pattern: "<[A-Za-z]*:?href>([^<]+\\.ics)</[A-Za-z]*:?href>")
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range(at: 1), in: text) else { return nil }
        let href = String(text[range])
        let last = href.split(separator: "/").last.map(String.init) ?? href
        return last.removingPercentEncoding ?? last
    }

    /// `body`: the response body, so a 4xx names the server's reason in the error ("Calendar object with uid
    /// already exists…"), not just the code. Sabre answers in XML; keep the message element's text, else a snippet.
    private static func check(_ resp: URLResponse, ok: Set<Int>, op: String, body: Data? = nil) throws {
        guard let h = resp as? HTTPURLResponse else { throw WebDAVError.noResponse(op) }
        guard ok.contains(h.statusCode) else {
            var why = ""
            if let body, let text = String(data: body, encoding: .utf8) {
                if let a = text.range(of: "<s:message>"), let b = text.range(of: "</s:message>"), a.upperBound < b.lowerBound {
                    why = String(text[a.upperBound..<b.lowerBound])
                } else {
                    why = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                }
                why = String(why.prefix(200))
            }
            if why.isEmpty {
                // No readable reason: say who answered, so an edge (Cloudflare, a proxy) is told from the app.
                let server = (h.value(forHTTPHeaderField: "Server") ?? "?")
                let via = h.value(forHTTPHeaderField: "cf-ray") != nil ? " via cloudflare" : ""
                let enc = h.value(forHTTPHeaderField: "Content-Encoding").map { " \($0)" } ?? ""
                why = "[\(body?.count ?? 0) B\(enc) from \(server)\(via)]"
            }
            throw WebDAVError.status(h.statusCode, "\(op): \(why)")
        }
    }

    /// `PROPFIND` the files root for `quota-used-bytes` + `quota-available-bytes` (the capacity preflight).
    /// A negative `available` (unlimited/unknown, e.g. −3) → `TargetStorage(total: 0)` so the gate is skipped.
    public func storage() async throws -> TargetStorage {
        var r = request("PROPFIND", "")
        r.setValue("0", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>"#.utf8)
        let (data, resp) = try await session.data(for: r)
        try Self.check(resp, ok: [207, 200], op: "PROPFIND quota")
        let body = String(data: data, encoding: .utf8) ?? ""
        let used = Self.firstInt(in: body, afterTag: "quota-used-bytes") ?? 0
        let avail = Self.firstInt(in: body, afterTag: "quota-available-bytes") ?? -1
        return avail < 0 ? TargetStorage(totalBytes: 0, usedBytes: used)
                         : TargetStorage(totalBytes: used + avail, usedBytes: used)
    }

    /// Does `relativePath` already exist on the server, and roughly how many direct children does it have?
    /// A `PROPFIND Depth:1` — used as a connect-time preflight so onboarding can reassure the user that
    /// micloud only ever touches its own `micloud/` namespace (never their existing files). Returns
    /// `(exists, childCount)`; a missing folder (404) is `(false, 0)`, not an error.
    public func inventory(_ relativePath: String) async throws -> (exists: Bool, children: Int) {
        var r = request("PROPFIND", relativePath)
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data(#"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#.utf8)
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw WebDAVError.noResponse("PROPFIND inventory") }
        if http.statusCode == 404 { return (false, 0) }
        try Self.check(resp, ok: [207, 200], op: "PROPFIND inventory")
        // Depth:1 returns the folder itself + one <d:response> per child.
        let responses = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "response>").count / 2
        return (true, max(0, responses - 1))
    }

    /// First integer immediately after `<…tag>` in a WebDAV XML blob (namespace-agnostic).
    static func firstInt(in xml: String, afterTag tag: String) -> Int64? {
        guard let r = xml.range(of: tag + ">") else { return nil }
        let digits = xml[r.upperBound...].prefix { $0.isNumber || $0 == "-" }
        return Int64(digits)
    }
}

public enum WebDAVError: Error, CustomStringConvertible, Equatable, LocalizedError {
    case noResponse(String)
    case status(Int, String)
    public var description: String {
        switch self {
        case .noResponse(let op):    return "no HTTP response for \(op)"
        case .status(let c, let op): return "HTTP \(c) for \(op)"
        }
    }
    /// What `localizedDescription` shows — without this the phone said "(MicloudPhone.WebDAVError error 1.)".
    public var errorDescription: String? { description }
}
