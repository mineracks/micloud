import Foundation
import MicloudKit

// Live end-to-end backfill against a real Nextcloud drill, exercising the actual BackfillEngine.
//   source nc-drill-creds.env; export NEXTCLOUD_URL=https://DRILL_HOST/remote.php/dav/files/admin
//   swift run BackfillLiveTest
// Proves: real capacity preflight (PROPFIND quota), bounded upload of a folder, a genuinely-unreadable file
// (chmod 000) quarantined rather than stalling, byte-exact on the drill, and incremental resume on re-run.

let env = ProcessInfo.processInfo.environment
guard let urlStr = env["NEXTCLOUD_URL"], let root = URL(string: urlStr),
      let user = env["NEXTCLOUD_USER"], let pass = env["NEXTCLOUD_PASS"] else {
    print("Set NEXTCLOUD_URL, NEXTCLOUD_USER, NEXTCLOUD_PASS."); exit(2)
}

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) } else { h(.performDefaultHandling, nil) }
    }
}

/// A folder as a BackfillSource: enumerate regular files → read + PUT to Nextcloud. An unreadable file
/// (chmod 000) throws on read, which the engine turns into a retry → quarantine.
final class FolderBackfillSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .documents
    let root: URL; let dav: NextcloudWebDAV; let remotePrefix: String
    init(root: URL, dav: NextcloudWebDAV, remotePrefix: String) { self.root = root; self.dav = dav; self.remotePrefix = remotePrefix }
    func enumerateItems() async throws -> [BackfillEntry] {
        let fm = FileManager.default
        // Canonicalize both sides — macOS's /private symlink otherwise makes url.path and root.path disagree.
        let canonRoot = root.resolvingSymlinksInPath()
        let base = canonRoot.path
        var out: [BackfillEntry] = []
        let en = fm.enumerator(at: canonRoot, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = en?.nextObject() as? URL {
            let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard rv?.isRegularFile == true else { continue }
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            out.append(BackfillEntry(key: rel, relativePath: rel, bytes: Int64(rv?.fileSize ?? 0)))
        }
        return out
    }
    func process(_ entry: BackfillEntry) async throws {
        let local = root.appendingPathComponent(entry.key)
        _ = try Data(contentsOf: local)                       // unreadable → throws → quarantine
        let rel = remotePrefix.isEmpty ? entry.key : "\(remotePrefix)/\(entry.key)"
        try await dav.ensureParents(of: rel)
        try await dav.upload(localFile: local, to: rel)
    }
    func capacityTargets() -> [BackfillTarget] { [dav] }
}

let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
let dav = NextcloudWebDAV(filesRoot: root, username: user, appPassword: pass, session: session)
let fm = FileManager.default

// build a temp folder: 5 good files + 1 unreadable poison
let dir = fm.temporaryDirectory.appendingPathComponent("micloud-backfill-\(Int(Date().timeIntervalSince1970))")
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
let poison = dir.appendingPathComponent("corrupt.bin")
defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: poison.path); try? fm.removeItem(at: dir) }
for i in 1...5 { try String(repeating: "micloud backfill test file \(i)\n", count: i * 10).write(to: dir.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8) }
try "should never upload".write(to: poison, atomically: true, encoding: .utf8)
try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: poison.path)   // make it unreadable

let dbURL = fm.temporaryDirectory.appendingPathComponent("micloud-backfill-\(UUID().uuidString).sqlite")
defer { for s in ["", "-wal", "-shm"] { try? fm.removeItem(at: URL(fileURLWithPath: dbURL.path + s)) } }
let remotePrefix = "micloud-backfill-test"

do {
    // capacity preflight sanity — real PROPFIND quota against the drill
    let storage = try await dav.storage()
    print("STORAGE  total=\(BF.bytes(storage.totalBytes)) used=\(BF.bytes(storage.usedBytes)) free=\(BF.bytes(storage.freeBytes)) known=\(storage.isKnown)")

    // run 1 — backfill the folder
    let ledger = try BackfillLedger(path: dbURL)
    let src = FolderBackfillSource(root: dir, dav: dav, remotePrefix: remotePrefix)
    let engine = BackfillEngine(source: src, ledger: ledger, config: BackfillConfig(concurrency: 3), heartbeat: { hb in
        if let it = hb.lastItem { print("  · \(hb.status.rawValue): \(it)") }
    })
    print("RUN 1 …")
    let p1 = await engine.run(confirmTight: true)
    print("  → done=\(p1.done) quarantined=\(p1.quarantined) complete=\(p1.isComplete)")
    guard p1.done == 5, p1.quarantined == 1, p1.isComplete else { print("❌ run 1 wrong outcome"); exit(1) }

    // verify byte-exact on the drill
    print("VERIFY on drill …")
    var ok = true
    for i in 1...5 {
        let name = "file\(i).txt"
        let expected = (try? Data(contentsOf: dir.appendingPathComponent(name)).count) ?? -1
        var r = URLRequest(url: dav.url(for: "\(remotePrefix)/\(name)")); r.httpMethod = "HEAD"
        r.setValue("Basic " + Data("\(user):\(pass)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (_, resp) = try await session.data(for: r)
        let len = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length")).flatMap { Int($0) } ?? -1
        let good = len == expected; ok = ok && good
        print("  \(good ? "✅" : "❌") \(name): drill=\(len) expected=\(expected)")
    }
    guard ok else { print("❌ drill verification failed"); exit(1) }

    // run 2 — add 2 more files, re-run SAME ledger → only the new ones upload (incremental resume/idempotency)
    for i in 6...7 { try "new file \(i)\n".write(to: dir.appendingPathComponent("file\(i).txt"), atomically: true, encoding: .utf8) }
    let ledger2 = try BackfillLedger(path: dbURL)
    let engine2 = BackfillEngine(source: FolderBackfillSource(root: dir, dav: dav, remotePrefix: remotePrefix),
                                 ledger: ledger2, config: BackfillConfig(concurrency: 3), heartbeat: { _ in })
    print("RUN 2 (added 2 files) …")
    let p2 = await engine2.run(confirmTight: true)
    print("  → total=\(p2.total) done=\(p2.done) quarantined=\(p2.quarantined) complete=\(p2.isComplete)")
    guard p2.total == 8, p2.done == 7, p2.quarantined == 1, p2.isComplete else { print("❌ run 2 wrong outcome"); exit(1) }

    print("\n✅ BackfillEngine LIVE: capacity preflight, folder→Nextcloud byte-exact, poison quarantined, incremental resume.")
} catch {
    print("❌ FAILED: \(error)"); exit(1)
}

// tiny byte formatter mirror (BackfillEngine.bytes is internal to the module)
enum BF { static func bytes(_ n: Int64) -> String {
    let u = ["B","KB","MB","GB","TB"]; var v = Double(n); var i = 0
    while v >= 1024 && i < u.count-1 { v /= 1024; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, u[i]) } }
