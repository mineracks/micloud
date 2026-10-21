import Foundation

/// **Mail lane (production).** Apple Mail's local store (`~/Library/Mail/V10`) → Nextcloud
/// `Mail/<account>/<Mailbox>/<id>.emlx`, one file per message, append-only: nothing is ever deleted on the
/// server. Mail keeps a full local copy of every IMAP mailbox it has finished downloading, so this is the
/// whole history, not a live feed. Partially downloaded messages (`*.partial.emlx`) are skipped until Mail
/// completes them. Needs the relay entitlement for `/Library/Mail/` + Full Disk Access.
///
/// Store layout:  `<account-uuid>/<Box>.mbox[/<Sub>.mbox]/<uuid>/Data/<n>/<n>/Messages/<id>.emlx`
/// Remote layout: `Mail/<account-uuid-prefix>/<Box>[/<Sub>]/<id>.emlx` (the UUID shard dirs are noise).
final class MailSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .mail
    private let dav: NextcloudWebDAV
    private let root: URL
    static let remotePrefix = "Mail"
    private let lock = NSLock()
    private var partial = 0
    /// Messages Mail has only partly downloaded (`*.partial.emlx`: headers, maybe the text, not the attachments).
    /// 80,713 of 130,421 on the relay (2026-10-19) — the card read "Up to date" over them. They complete when
    /// Mail runs with the account's attachments set to download, so say what is waited on.
    var deferredAtSource: DeferredAtSource? {
        lock.lock(); defer { lock.unlock() }
        return partial > 0 ? DeferredAtSource(count: partial, reason: "waiting for Mail to download them") : nil
    }

    init(dav: NextcloudWebDAV) {
        self.dav = dav
        root = RealHome.url.appendingPathComponent("Library/Mail/V10", isDirectory: true)
    }

    /// Map a store-relative path to its server name; nil = not a message we carry.
    static func remoteName(for rel: String) -> String? {
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.count >= 3, let file = parts.last, file.hasSuffix(".emlx"), !file.hasSuffix(".partial.emlx") else { return nil }
        let account = parts[0]
        guard account != "MailData" else { return nil }
        let boxes = parts.dropFirst().dropLast().filter { $0.hasSuffix(".mbox") }.map { String($0.dropLast(5)) }
        guard !boxes.isEmpty else { return nil }
        return ([String(account.prefix(8))] + boxes + [file]).joined(separator: "/")
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw NSError(domain: "micloud.mail", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mail store not found (Mail signed in? Full Disk Access?)"])
        }
        let base = root.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var out: [BackfillEntry] = []
        var partialSeen = 0
        defer { lock.lock(); partial = partialSeen; lock.unlock() }
        while let url = en.nextObject() as? URL {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            guard rv?.isRegularFile == true else { continue }
            if url.lastPathComponent.hasSuffix(".partial.emlx") { partialSeen += 1; continue }
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let remote = Self.remoteName(for: rel) else { continue }
            out.append(BackfillEntry(key: rel, relativePath: remote, bytes: Int64(rv?.fileSize ?? 0)))
        }
        return out
    }

    func alreadyPresent(_ entries: [BackfillEntry]) async -> Set<String> {
        await dav.presentKeys(entries.map { (key: $0.key, remote: "\(Self.remotePrefix)/\($0.relativePath)", bytes: $0.bytes) })
    }

    func process(_ entry: BackfillEntry) async throws {
        let local = root.appendingPathComponent(entry.key)
        let rel = "\(Self.remotePrefix)/\(entry.relativePath)"
        if await dav.exists(rel, bytes: entry.bytes) { throw BackfillEngine.AlreadyOnTarget() }   // never send twice
        try await dav.ensureParents(of: rel)
        try await dav.upload(localFile: local, to: rel)
    }

    func capacityTargets() -> [BackfillTarget] { [NextcloudFolderTarget(dav: dav, path: Self.remotePrefix)] }
}
