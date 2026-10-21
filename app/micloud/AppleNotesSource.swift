import Foundation
import SQLite3
import Compression

/// **Notes lane (production).** Apple Notes → Nextcloud Notes (REST v1). Port of `icloud-notes-sync.py`:
/// reads a consistent SNAPSHOT of `NoteStore.sqlite` (+ -wal/-shm; the live store is locked by Notes.app and
/// the WAL holds the recent edits), pulls each note's body out of `ZICNOTEDATA.ZDATA` = gzip(protobuf) by
/// walking the wire format to field 2→2→2 (greedy printable-string fallback), splits the duplicated title
/// line, and creates/updates/deletes the matching Nextcloud note. AppleScript is deliberately NOT used: every
/// property access on a CloudKit note blocks on a sync fetch (the -1712 hang). Read-only — never writes Apple's format.
/// Safety: a >10 % drop in note count versus the manifest refuses to sync (a wave of deletions from a corrupted
/// store must not reach the server). Needs the relay entitlements + Full Disk Access.
final class AppleNotesSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .notes
    private let rest: NextcloudREST
    private let capacity: BackfillTarget
    private let store: URL
    private let lock = NSLock()
    private var manifest = LaneManifest(name: "notes")
    private var pending: [String: Note] = [:]
    struct Note { let title: String; let content: String; let category: String; let modified: Int }
    struct SanityGate: Error, CustomStringConvertible { let prior: Int; let now: Int; var description: String { "Notes count dropped \(prior) → \(now): refusing to mirror deletions until a human looks" } }

    init(dav: NextcloudWebDAV, session: URLSession) {
        rest = NextcloudREST(dav: dav, session: session, userAgent: "micloud-notes/1.0")
        capacity = dav
        store = RealHome.url.appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    // ── gzip + protobuf scraping ────────────────────────────────────────────
    static func gunzip(_ d: Data) -> Data? {
        guard d.count > 18, d[0] == 0x1f, d[1] == 0x8b else { return nil }
        var i = 10; let flg = d[3]
        if flg & 0x04 != 0 { guard d.count > i + 2 else { return nil }; let xlen = Int(d[i]) | Int(d[i+1]) << 8; i += 2 + xlen }
        if flg & 0x08 != 0 { while i < d.count, d[i] != 0 { i += 1 }; i += 1 }
        if flg & 0x10 != 0 { while i < d.count, d[i] != 0 { i += 1 }; i += 1 }
        if flg & 0x02 != 0 { i += 2 }
        guard i < d.count - 8 else { return nil }
        let raw = d.subdata(in: i..<(d.count - 8))
        let isize = Int(d[d.count-4]) | Int(d[d.count-3]) << 8 | Int(d[d.count-2]) << 16 | Int(d[d.count-1]) << 24
        let cap = max(isize, raw.count * 4, 1 << 16)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap); defer { dst.deallocate() }
        let n = raw.withUnsafeBytes { src in compression_decode_buffer(dst, cap, src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB) }
        return n > 0 ? Data(bytes: dst, count: n) : nil
    }
    private static func varint(_ b: Data, _ i: inout Int) -> UInt64? {
        var n: UInt64 = 0, shift: UInt64 = 0
        while i < b.count { let x = b[b.startIndex + i]; i += 1; n |= UInt64(x & 0x7f) << shift; if x & 0x80 == 0 { return n }; shift += 7; if shift > 63 { return nil } }
        return nil
    }
    /// (field, wireType, payload) for every entry; stops cleanly on malformed input.
    static func walk(_ b: Data) -> [(Int, Int, Data)] {
        var out: [(Int, Int, Data)] = []; var i = 0
        while i < b.count {
            guard let tag = varint(b, &i) else { break }
            let f = Int(tag >> 3), w = Int(tag & 7)
            switch w {
            case 0: guard varint(b, &i) != nil else { return out }; out.append((f, 0, Data()))
            case 1: guard i + 8 <= b.count else { return out }; i += 8; out.append((f, 1, Data()))
            case 5: guard i + 4 <= b.count else { return out }; i += 4; out.append((f, 5, Data()))
            case 2: guard let ln = varint(b, &i), i + Int(ln) <= b.count else { return out }
                    out.append((f, 2, b.subdata(in: (b.startIndex + i)..<(b.startIndex + i + Int(ln))))); i += Int(ln)
            default: return out
            }
        }
        return out
    }
    private static func field2(_ b: Data) -> Data? { walk(b).first { $0.0 == 2 && $0.1 == 2 }?.2 }
    private static func greedy(_ b: Data, depth: Int = 0, into c: inout [String]) {
        guard depth <= 8 else { return }
        for (_, w, p) in walk(b) where w == 2 {
            if let s = String(data: p, encoding: .utf8), s.count >= 3, s.contains(where: { $0.isLetter }) {
                let printable = s.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 } || $0 == "\n" || $0 == "\t" }.count
                if Double(printable) / Double(s.count) > 0.85 { c.append(s); continue }
            }
            if p.count > 1 { greedy(p, depth: depth + 1, into: &c) }
        }
    }
    static func text(from zdata: Data?) -> String? {
        guard let z = zdata, let d = gunzip(z) else { return nil }
        if let doc = field2(d), let note = field2(doc), let t = field2(note), let s = String(data: t, encoding: .utf8) { return s }
        var c: [String] = []; greedy(d, into: &c); return c.max(by: { $0.count < $1.count })
    }

    // ── snapshot + SQL ──────────────────────────────────────────────────────
    private func snapshotAndRead() throws -> [String: Note] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { throw NSError(domain: "micloud.notes", code: 1, userInfo: [NSLocalizedDescriptionKey: "NoteStore.sqlite not found (Full Disk Access?)"]) }
        let tmp = fm.temporaryDirectory.appendingPathComponent("micloud-notes-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true); defer { try? fm.removeItem(at: tmp) }
        for sfx in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: store.path + sfx)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: tmp.appendingPathComponent(src.lastPathComponent)) }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.appendingPathComponent("NoteStore.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw NSError(domain: "micloud.notes", code: 2, userInfo: [NSLocalizedDescriptionKey: "sqlite open failed"]) }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT n.ZIDENTIFIER, n.ZTITLE1, n.ZSNIPPET, n.ZMODIFICATIONDATE1, COALESCE(f.ZTITLE2,''), b.ZDATA
              FROM ZICCLOUDSYNCINGOBJECT n
              LEFT JOIN ZICNOTEDATA b ON b.ZNOTE = n.Z_PK
              LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
             WHERE n.Z_ENT = 12 AND COALESCE(n.ZMARKEDFORDELETION,0) = 0 AND COALESCE(f.ZFOLDERTYPE,0) != 1
            """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw NSError(domain: "micloud.notes", code: 3, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]) }
        defer { sqlite3_finalize(st) }
        func col(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
        var out: [String: Note] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            guard let ident = col(0), !ident.isEmpty else { continue }
            let title = col(1) ?? "", snippet = col(2) ?? ""
            let mod = sqlite3_column_double(st, 3)
            let folder = col(4) ?? ""
            var zdata: Data? = nil
            if let p = sqlite3_column_blob(st, 5) { zdata = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 5))) }
            let text = Self.text(from: zdata) ?? ""
            var content = text
            if !title.isEmpty, let nl = text.firstIndex(of: "\n"), text[..<nl].trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) {
                content = String(text[text.index(after: nl)...]).drop(while: { $0 == "\n" }).description
            } else if !title.isEmpty, text.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) { content = "" }
            let t = (title.isEmpty ? (snippet.isEmpty ? "(untitled)" : snippet) : title).trimmingCharacters(in: .whitespacesAndNewlines)
            out[ident] = Note(title: t, content: content, category: folder.isEmpty ? "Notes" : folder, modified: mod > 0 ? Int(mod + 978_307_200) : Int(Date().timeIntervalSince1970))
        }
        return out
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        let notes = try snapshotAndRead()
        lock.lock(); let prior = manifest.items.count; lock.unlock()
        if prior > 0, Double(prior - notes.count) / Double(prior) > 0.10 { throw SanityGate(prior: prior, now: notes.count) }
        var entries: [BackfillEntry] = []
        lock.lock(); pending = notes
        for (ident, n) in notes {
            let hash = Hashing.sha256([n.title, n.content, n.category].joined(separator: "\u{1}"))
            entries.append(BackfillEntry(key: "note:\(ident)", relativePath: "\(n.category)/\(n.title)", bytes: Int64(n.content.utf8.count), contentHash: hash))
        }
        let gone = manifest.items.keys.filter { notes[$0] == nil }
        lock.unlock()
        for ident in gone {
            lock.lock(); let ncID = manifest.items[ident]?["nc_id"] as? Int; lock.unlock()
            if let ncID { let (st, _) = try await rest.call("DELETE", "index.php/apps/notes/api/v1/notes/\(ncID)"); guard [200, 204, 404].contains(st) else { continue } }
            lock.lock(); manifest.items[ident] = nil; manifest.save(); lock.unlock()
        }
        return entries
    }

    func process(_ entry: BackfillEntry) async throws {
        let ident = String(entry.key.dropFirst("note:".count))
        lock.lock(); let n = pending[ident]; let prior = manifest.items[ident]; lock.unlock()
        guard let n else { return }
        let payload: [String: Any] = ["title": n.title, "content": n.content, "category": n.category, "modified": n.modified, "favorite": false]
        var ncID = prior?["nc_id"] as? Int
        if let existing = ncID {
            let (st, _) = try await rest.call("PUT", "index.php/apps/notes/api/v1/notes/\(existing)", json: payload)
            if st == 404 { ncID = nil } else if ![200, 201].contains(st) { throw NextcloudREST.Failure(status: st, body: "update note \(n.title)") }
        }
        if ncID == nil {
            let (st, body) = try await rest.call("POST", "index.php/apps/notes/api/v1/notes", json: payload)
            guard [200, 201].contains(st), let newID = (body as? [String: Any])?["id"] as? Int else { throw NextcloudREST.Failure(status: st, body: "create note \(n.title)") }
            ncID = newID
        }
        lock.lock(); manifest.items[ident] = ["nc_id": ncID!, "hash": entry.contentHash ?? "", "modified": n.modified]; manifest.save(); lock.unlock()
    }

    func capacityTargets() -> [BackfillTarget] { [capacity] }
}
