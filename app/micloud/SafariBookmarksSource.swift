import Foundation

/// **Bookmarks lane (production).** Mirrors Safari's `~/Library/Safari/Bookmarks.plist` (the on-disk, iCloud-
/// synced bookmark tree) into Nextcloud Bookmarks (REST v2), keeping Safari's folder hierarchy under one root
/// folder. Port of `icloud-bookmarks-sync.py` (the agent's reference spec) onto the BackfillEngine:
///   • canonical id = Safari's `WebBookmarkUUID` (a URL can legitimately live in several folders)
///   • change detection = hash of {url, title, description, folder path}; unchanged → no PUT
///   • deletions: ids in the manifest but no longer in Safari → DELETE on the server (never the root folder)
///   • Reading List article *content* is not mirrored, only the entries; "History" is skipped
/// Needs the relay entitlements + Full Disk Access (Safari's folder is TCC-protected).
final class SafariBookmarksSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .bookmarks
    static let rootTitle = "iCloud Bookmarks"
    private let rest: NextcloudREST
    private let capacity: BackfillTarget
    private let plist: URL
    private let lock = NSLock()
    private var manifest = LaneManifest(name: "bookmarks")
    private var folderIDs: [String: Int]               // "a/b/c" → nc folder id (cache, persisted in manifest.extra)
    private var pending: [String: Item] = [:]          // uuid → item seen in the last enumerate
    struct Item { let url: String; let title: String; let desc: String; let segs: [String] }

    init(dav: NextcloudWebDAV, session: URLSession) {
        rest = NextcloudREST(dav: dav, session: session, userAgent: "micloud-bookmarks/1.0")
        capacity = dav
        plist = RealHome.url.appendingPathComponent("Library/Safari/Bookmarks.plist")
        folderIDs = (manifest.extra["folders"] as? [String: Int]) ?? [:]
    }

    // ── Safari tree ──────────────────────────────────────────────────────────
    private func friendly(_ title: String) -> String {
        ["BookmarksBar": "Favourites Bar", "BookmarksMenu": "Bookmarks Menu", "com.apple.ReadingList": "Reading List"][title] ?? title
    }
    private func walk(_ node: [String: Any], _ segs: [String], into out: inout [(String, Item)]) {
        let wt = node["WebBookmarkType"] as? String ?? ""
        if wt == "WebBookmarkTypeLeaf" {
            guard let url = node["URLString"] as? String, url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
            let ud = node["URIDictionary"] as? [String: Any] ?? [:]
            let title = ((ud["title"] as? String) ?? (node["Title"] as? String) ?? url).trimmingCharacters(in: .whitespacesAndNewlines)
            let uuid = (node["WebBookmarkUUID"] as? String) ?? Hashing.sha256(url)
            out.append((uuid, Item(url: url, title: title, desc: (ud["description"] as? String) ?? "", segs: segs)))
            return
        }
        for child in node["Children"] as? [[String: Any]] ?? [] {
            let t = child["Title"] as? String ?? ""
            if segs.isEmpty, t == "History" { continue }
            let seg = segs.isEmpty ? friendly(t) : (t.isEmpty ? "(unnamed)" : t)
            if (child["WebBookmarkType"] as? String) == "WebBookmarkTypeList" { walk(child, segs + [seg], into: &out) }
            else { walk(child, segs, into: &out) }
        }
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        let data = try Data(contentsOf: plist)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "micloud.bookmarks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bookmarks.plist unreadable"])
        }
        var found: [(String, Item)] = []
        walk(root, [], into: &found)
        var entries: [BackfillEntry] = []
        var seen = Set<String>()
        lock.lock()
        pending = [:]
        for (uuid, it) in found {
            pending[uuid] = it; seen.insert(uuid)
            let path = (it.segs + [it.title]).joined(separator: "/")
            let hash = Hashing.sha256([it.url, it.title, it.desc, it.segs.joined(separator: "/")].joined(separator: "\u{1}"))
            entries.append(BackfillEntry(key: "safari:\(uuid)", relativePath: path, bytes: Int64(it.url.utf8.count), contentHash: hash))
        }
        let gone = manifest.items.keys.filter { !seen.contains($0) }
        lock.unlock()
        // Deletions — mirror removals so the server matches Safari. A bookmark the user removed is not data loss
        // on their side; Nextcloud Bookmarks has no trash, so this is deliberate and matches the reference script.
        for uuid in gone {
            lock.lock(); let ncID = manifest.items[uuid]?["nc_id"] as? Int; lock.unlock()
            if let ncID { let (st, _) = try await rest.call("DELETE", "index.php/apps/bookmarks/public/rest/v2/bookmark/\(ncID)"); guard [200, 204, 404].contains(st) else { continue } }
            lock.lock(); manifest.items[uuid] = nil; manifest.save(); lock.unlock()
        }
        return entries
    }

    private func ensureFolder(_ segs: [String]) async throws -> Int {
        var parent = -1; var path = ""
        for seg in segs {
            path = path.isEmpty ? seg : path + "/" + seg
            lock.lock(); let cached = folderIDs[path]; lock.unlock()
            if let cached { parent = cached; continue }
            let (st, body) = try await rest.call("GET", "index.php/apps/bookmarks/public/rest/v2/folder", params: ["root": String(parent)])
            let existing = ((body as? [String: Any])?["data"] as? [[String: Any]]) ?? []
            if st == 200, let m = existing.first(where: { ($0["title"] as? String) == seg }), let fid = m["id"] as? Int {
                parent = fid
            } else {
                let (cst, cbody) = try await rest.call("POST", "index.php/apps/bookmarks/public/rest/v2/folder", json: ["title": seg, "parent_folder": parent])
                let item = ((cbody as? [String: Any])?["item"] as? [String: Any]) ?? (cbody as? [String: Any]) ?? [:]
                guard [200, 201].contains(cst), let fid = item["id"] as? Int else { throw NextcloudREST.Failure(status: cst, body: "create folder \(seg)") }
                parent = fid
            }
            lock.lock(); folderIDs[path] = parent; manifest.extra["folders"] = folderIDs; manifest.save(); lock.unlock()
        }
        return parent
    }

    func process(_ entry: BackfillEntry) async throws {
        let uuid = String(entry.key.dropFirst("safari:".count))
        lock.lock(); let it = pending[uuid]; let prior = manifest.items[uuid]; lock.unlock()
        guard let it else { return }
        let folder = try await ensureFolder([Self.rootTitle] + it.segs)
        let payload: [String: Any] = ["url": it.url, "title": it.title.isEmpty ? it.url : it.title, "description": it.desc, "folders": [folder], "tags": []]
        var ncID = prior?["nc_id"] as? Int
        if let existing = ncID {
            let (st, _) = try await rest.call("PUT", "index.php/apps/bookmarks/public/rest/v2/bookmark/\(existing)", json: payload)
            if st == 404 { ncID = nil } else if ![200, 201].contains(st) { throw NextcloudREST.Failure(status: st, body: "update \(it.url)") }
        }
        if ncID == nil {
            let (st, body) = try await rest.call("POST", "index.php/apps/bookmarks/public/rest/v2/bookmark", json: payload)
            let item = ((body as? [String: Any])?["item"] as? [String: Any]) ?? (body as? [String: Any]) ?? [:]
            guard [200, 201].contains(st), let newID = item["id"] as? Int else { throw NextcloudREST.Failure(status: st, body: "create \(it.url)") }
            ncID = newID
        }
        lock.lock(); manifest.items[uuid] = ["nc_id": ncID!, "hash": entry.contentHash ?? "", "url": it.url]; manifest.save(); lock.unlock()
    }

    func capacityTargets() -> [BackfillTarget] { [capacity] }
}
