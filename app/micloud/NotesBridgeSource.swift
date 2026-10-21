import Foundation

/// Demo bridge for the **Notes** lane. Nextcloud Notes stores every note as a plain `.md`/`.txt` file inside a
/// Files folder (its `notesPath`, default `/Notes`), so we can carry a note exactly like a Drive file: the
/// orchestrator writes the note the visitor just "jotted" on the Mac into `MICLOUD_NOTES_BRIDGE_DIR`, and this
/// source uploads it — through the SAME proven `NextcloudWebDAV` path as Documents — into the folder the
/// Nextcloud Notes app reads. It flows through the normal `BackfillEngine`, so the Notes badge / activity graph
/// / live log all react for real and the APP does the upload. `nil` in production (env unset) → never built.
///
/// Mirrors the photo/calendar bridges: each file is uploaded once (ledger content-hash from size+mtime), so the
/// periodic re-backfill is idempotent until the note actually changes.
final class NotesBridgeSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .notes
    private let dir: String
    private let dav: NextcloudWebDAV
    private let remotePrefix: String
    private static let noteExts: Set<String> = ["md", "txt", "markdown"]

    init(dir: String, dav: NextcloudWebDAV, remotePrefix: String) {
        self.dir = dir; self.dav = dav; self.remotePrefix = remotePrefix
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        var out: [BackfillEntry] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            guard Self.noteExts.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append(BackfillEntry(key: "notesbridge:\(name)", relativePath: name, bytes: size,
                                     contentHash: "\(size)-\(Int(mtime))"))
        }
        return out
    }

    func process(_ entry: BackfillEntry) async throws {
        let path = (dir as NSString).appendingPathComponent(entry.relativePath)
        let rel = remotePrefix.isEmpty ? entry.relativePath : "\(remotePrefix)/\(entry.relativePath)"
        try await dav.ensureParents(of: rel)
        try await dav.upload(localFile: URL(fileURLWithPath: path), to: rel)
    }

    func capacityTargets() -> [BackfillTarget] { [dav] }
}
