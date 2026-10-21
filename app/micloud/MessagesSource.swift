import Foundation
import CryptoKit
import SQLite3

/// **Messages lane (production).** iMessage + SMS/MMS history → Nextcloud `Messages/iMessage/` as browsable
/// HTML, one file per conversation plus attachments. Port of `imessage-mirror-sync.sh`: (1) an online SQLite
/// backup of `~/Library/Messages/chat.db` (never read live — Messages holds it open), (2) the bundled
/// `imessage-exporter` renders the full history from the copy, (3) the export tree is uploaded through the same
/// WebDAV path as Files — content-hashed, so unchanged conversations cost nothing. Forward-only / append-only:
/// nothing is ever deleted on the server. The export is rebuilt at most once per `minInterval` (daily) — the
/// Messages database is large and this is history, not real-time chat.
/// Needs the relay entitlements + Full Disk Access, and `imessage-exporter` inside the bundle (build.sh copies it).
final class MessagesSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .messages
    private let dav: NextcloudWebDAV
    private let remotePrefix = "Messages/iMessage"
    private let minInterval: TimeInterval
    private let lock = NSLock()
    private var manifest = LaneManifest(name: "messages")
    private let staging: URL
    private var exportDir: URL { staging.appendingPathComponent("full-html", isDirectory: true) }
    struct Failure: Error, CustomStringConvertible { let description: String }

    init(dav: NextcloudWebDAV, minInterval: TimeInterval = 20 * 3600) {
        self.dav = dav; self.minInterval = minInterval
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        staging = base.appendingPathComponent("micloud/messages-staging", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    /// The bundled copy first (relay builds made with --bundle-exporter), then a Homebrew / local install:
    /// imessage-exporter is GPL-3.0, so the downloadable release does not ship it and asks for
    /// `brew install imessage-exporter` instead.
    static var exporter: URL? {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/imessage-exporter"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/imessage-exporter"),
                          URL(fileURLWithPath: "/usr/local/bin/imessage-exporter")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func snapshotDB(to dst: URL) throws {
        let src = RealHome.url.appendingPathComponent("Library/Messages/chat.db")
        guard FileManager.default.fileExists(atPath: src.path) else { throw Failure(description: "chat.db not found (Messages signed in? Full Disk Access?)") }
        var s: OpaquePointer?, d: OpaquePointer?
        guard sqlite3_open_v2(src.path, &s, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let s else { throw Failure(description: "open chat.db: \(s.map { String(cString: sqlite3_errmsg($0)) } ?? "?")") }
        defer { sqlite3_close(s) }
        try? FileManager.default.removeItem(at: dst)
        guard sqlite3_open(dst.path, &d) == SQLITE_OK, let d else { throw Failure(description: "create snapshot") }
        defer { sqlite3_close(d) }
        guard let b = sqlite3_backup_init(d, "main", s, "main") else { throw Failure(description: "backup init: \(String(cString: sqlite3_errmsg(d)))") }
        var rc: Int32
        repeat { rc = sqlite3_backup_step(b, 256); if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { usleep(50_000) } } while rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED
        sqlite3_backup_finish(b)
        guard rc == SQLITE_DONE else { throw Failure(description: "backup step rc=\(rc)") }
    }

    private func rebuildExportIfDue() throws {
        lock.lock(); let last = manifest.extra["exported_at"] as? Double ?? 0; lock.unlock()
        let fm = FileManager.default
        if Date().timeIntervalSince1970 - last < minInterval, fm.fileExists(atPath: exportDir.path) { return }
        guard let exporter = Self.exporter else { throw Failure(description: "imessage-exporter not found — brew install imessage-exporter (or rebuild with --bundle-exporter)") }
        let copy = staging.appendingPathComponent("chat-copy.db")
        try snapshotDB(to: copy); defer { try? fm.removeItem(at: copy) }
        let fresh = staging.appendingPathComponent("full-html.new", isDirectory: true)
        try? fm.removeItem(at: fresh)
        let p = Process(); p.executableURL = exporter
        // `-b` (--ignore-disk-warning): the exporter refuses to run when the SUM of attachment sizes declared in
        // chat.db exceeds free space (16.7 GB vs 11.9 GB on 2026-10-18), but Messages in iCloud keeps most of
        // them in the cloud — 253 files / 590 MB were local — and the exporter copies only what is on disk.
        // The mini sits at ~13 GB free by design (Photos "Optimise" thins to that), so the check never passes.
        p.arguments = ["-f", "html", "-o", fresh.path, "-c", "full", "-b", "-p", copy.path]
        // Never hand a child a Pipe nobody drains: its progress output fills the 64 KB buffer and the exporter
        // blocks on write() forever (0 % CPU, 1,205 empty files — the relay's first night). stdout → /dev/null,
        // stderr → a file we read after exit.
        let errFile = staging.appendingPathComponent("exporter.stderr")
        try? fm.removeItem(at: errFile); fm.createFile(atPath: errFile.path, contents: nil)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = try FileHandle(forWritingTo: errFile)
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
            throw Failure(description: "imessage-exporter exit \(p.terminationStatus): \(msg.suffix(200))")
        }
        try? fm.removeItem(at: exportDir); try fm.moveItem(at: fresh, to: exportDir)
        lock.lock(); manifest.extra["exported_at"] = Date().timeIntervalSince1970; manifest.save(); lock.unlock()
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        try rebuildExportIfDue()
        var out: [BackfillEntry] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(at: exportDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return out }
        let base = exportDir.standardizedFileURL.path
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count + 1))
            let rv = try? u.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(rv?.fileSize ?? 0)
            // Content hash, not size-mtime: a rebuilt export has fresh mtimes on every file, so the daily pass
            // re-queued all 4,093 conversations (~97 MB of PUTs a day) although almost none had changed
            // (2026-10-18). Hashing the 97 MB tree takes under a second; only files whose bytes moved re-upload.
            out.append(BackfillEntry(key: "imessage:\(rel)", relativePath: rel, bytes: size, contentHash: Self.sha256(u) ?? "\(size)-?"))
        }
        return out
    }

    /// Streamed SHA-256 of a file (attachments can be large); nil if unreadable.
    static func sha256(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let d = try? fh.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func process(_ entry: BackfillEntry) async throws {
        try await dav.upload(localFile: exportDir.appendingPathComponent(entry.relativePath), to: "\(remotePrefix)/\(entry.relativePath)")
    }

    func capacityTargets() -> [BackfillTarget] { [dav] }
}
