import Foundation

/// Demo bridge for the **Photos** lane. The app's real Photos source is PhotoKit, which needs a signed-in
/// iCloud photo library the driven demo Mac doesn't have (so the Photos tile would sit Off). When
/// `MICLOUD_PHOTOS_BRIDGE_DIR` is set, the orchestrator drops a real image file there and this source uploads
/// it to the sovereign photo targets (Nextcloud Photos / Immich) through the SAME `BackfillEngine` as every
/// other lane — so the Photos badge / activity graph / live log all react for real and the APP does the
/// upload. `nil` in production (env unset) → this source is never constructed.
///
/// Mirrors the calendar bridge (`EventKitBackfillSource.bridgeDir`): each file is uploaded once (ledger
/// content-hash from size+mtime), so the periodic re-backfill is idempotent.
final class PhotosFolderBridgeSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .photos
    private let dir: String
    private let targets: [PhotoTarget]
    private let capTargets: [BackfillTarget]
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff"]

    init(dir: String, targets: [PhotoTarget], capacityTargets: [BackfillTarget]) {
        self.dir = dir; self.targets = targets; self.capTargets = capacityTargets
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        var out: [BackfillEntry] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            guard Self.imageExts.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append(BackfillEntry(key: "photobridge:\(name)", relativePath: name, bytes: size,
                                     contentHash: "\(size)-\(Int(mtime))"))
        }
        return out
    }

    func process(_ entry: BackfillEntry) async throws {
        let path = (dir as NSString).appendingPathComponent(entry.relativePath)
        let url = URL(fileURLWithPath: path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let created = (attrs?[.creationDate] as? Date) ?? Date()
        let modified = (attrs?[.modificationDate] as? Date) ?? created
        for t in targets {
            _ = try await t.uploadPhoto(localFile: url, filename: entry.relativePath,
                                        createdAt: created, modifiedAt: modified)
        }
    }

    func capacityTargets() -> [BackfillTarget] { capTargets }
}
