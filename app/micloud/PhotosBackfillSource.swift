import Foundation
import Photos

/// `BackfillSource` over the photo library: enumerate image assets, and for each fetch the ORIGINAL via
/// `PHAssetResourceManager` and fan it out to the configured `PhotoTarget`s (Nextcloud + Immich). Sizes are
/// *estimated* from pixel dimensions for the preflight/ETA (PhotoKit exposes no cheap exact size via public
/// API); the bytes actually uploaded are the real original. An asset that can't be read throws → quarantine.
///
/// `limit` bounds a test run to the newest N; the production backfill leaves it 0 (the whole library).
final class PhotosBackfillSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .photos
    private let targets: [PhotoTarget]
    private let capTargets: [BackfillTarget]
    private let limit: Int
    /// Filenames that more than one asset shares (IMG_0001.HEIC after a camera roll reset, `lp_image.heic`…).
    /// Nextcloud is a plain folder, so two such assets would PUT the same path — 423 Locked when concurrent,
    /// and the second silently overwriting the first otherwise. Those get a stable per-asset suffix on
    /// Nextcloud; Immich dedups by checksum and keeps the original name.
    private var dupNames: Set<String> = []
    /// Per asset: capture instant + stored pixel size, for the fingerprint match (see `PhotoPresence`).
    private struct Meta { let created: Date?; let w: Int; let h: Int }
    private var meta: [String: Meta] = [:]
    private var dupPrints: Set<String> = []     // fingerprints shared by >1 asset in the library — ambiguous, never matched
    private let lock = NSLock()
    private let catalogURL: URL

    init(targets: [PhotoTarget], capacityTargets: [BackfillTarget], limit: Int = 0, catalogURL: URL? = nil) {
        self.targets = targets; self.capTargets = capacityTargets; self.limit = limit
        self.catalogURL = catalogURL ?? Self.defaultCatalogURL()
    }

    // ── the catalog: the library's entry list, kept current by PhotoKit's persistent change tracking ──────
    // A pass used to walk all 188,124 assets through PhotoKit — 3½ min of CPU, and once the lane is complete,
    // every 15 minutes for nothing. The list now lives on disk with the library's persistent change token; a
    // pass asks PhotoKit only for what changed since that token (same token → no PhotoKit work at all) and
    // rebuilds from scratch only when the token has expired or the catalog is missing (2026-10-18). This is
    // the Photos equivalent of the Drive lane's FSEvents journal.
    private struct Row: Codable { let name: String; let bytes: Int64; let created: Date?; let w: Int; let h: Int }
    private struct Catalog: Codable { var token: Data; var rows: [String: Row] }

    private static func defaultCatalogURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("micloud", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("photos-catalog.json")
    }

    private static let mediaPredicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)

    /// The per-asset facts a pass needs, from one `PHAsset`. `assetResources` is the slow call (it is what made
    /// the full walk 3½ minutes), so it is paid once per asset for the life of the catalog.
    private static func row(_ asset: PHAsset) -> Row {
        let resources = PHAssetResource.assetResources(for: asset)
        let res = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
        let name = res?.originalFilename ?? "\(asset.localIdentifier).jpg"
        // Rough sizes for preflight + ETA only (PhotoKit has no cheap exact size). Photo: ~0.25 B/px HEIC,
        // floor 500 KB. Video: ~0.6 B per pixel per second — measured against 30k real iPhone videos
        // (1920×1440 HEVC 1.46 MB/s, 1080p 1.59, 4K 9.2); the old flat 4 MB/s overstated the queue 2.3×.
        let px = Double(max(asset.pixelWidth * asset.pixelHeight, 1_000_000))
        let est: Int64 = asset.mediaType == .video
            ? Int64(max(asset.duration * px * 0.6, 1_000_000))
            : Int64(max(asset.pixelWidth * asset.pixelHeight / 4, 500_000))
        return Row(name: name, bytes: est, created: asset.creationDate, w: asset.pixelWidth, h: asset.pixelHeight)
    }

    private static func rows(_ fetched: PHFetchResult<PHAsset>, limit: Int = 0) -> [String: Row] {
        let n = limit > 0 ? min(limit, fetched.count) : fetched.count
        var out: [String: Row] = [:]; out.reserveCapacity(n)
        for i in 0..<n { let a = fetched.object(at: i); out[a.localIdentifier] = row(a) }
        return out
    }

    private static func fullRows(limit: Int = 0) -> [String: Row] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = mediaPredicate
        return rows(PHAsset.fetchAssets(with: opts), limit: limit)
    }

    private static func rows(forIdentifiers ids: [String]) -> [String: Row] {
        var out: [String: Row] = [:]
        let opts = PHFetchOptions(); opts.predicate = mediaPredicate
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + 500, ids.count)]); i += 500
            out.merge(rows(PHAsset.fetchAssets(withLocalIdentifiers: chunk, options: opts))) { _, new in new }
        }
        return out
    }

    private static func tokenData(_ t: PHPersistentChangeToken) -> Data? { try? NSKeyedArchiver.archivedData(withRootObject: t, requiringSecureCoding: true) }
    private static func token(_ d: Data) -> PHPersistentChangeToken? { try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: d) }

    /// Current rows + how they were obtained ("unchanged", "+3 ~0 −1", "built", "rebuilt: <why>").
    private func currentRows() -> ([String: Row], String) {
        let lib = PHPhotoLibrary.shared()
        // Read the token BEFORE fetching: a change that lands during the fetch is reported again next pass
        // (re-fetching one asset is idempotent); the other order would lose it.
        let now = lib.currentChangeToken
        var rows: [String: Row]; var how: String
        let stored = (try? Data(contentsOf: catalogURL)).flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) }
        if let cat = stored, let old = Self.token(cat.token) {
            if old == now { return (cat.rows, "unchanged") }
            do {
                var ins = Set<String>(), upd = Set<String>(), del = Set<String>()
                for ch in try lib.fetchPersistentChanges(since: old) {
                    let d = try ch.changeDetails(for: .asset)
                    ins.formUnion(d.insertedLocalIdentifiers); upd.formUnion(d.updatedLocalIdentifiers); del.formUnion(d.deletedLocalIdentifiers)
                }
                rows = cat.rows
                for k in del { rows[k] = nil }
                let refetch = Array(ins.union(upd).subtracting(del))
                let fresh = Self.rows(forIdentifiers: refetch)
                for k in refetch { rows[k] = fresh[k] }     // nil = not an image/video any more (or gone)
                how = "+\(ins.count) ~\(upd.count) −\(del.count)"
            } catch {
                // persistentChangeTokenExpired / persistentChangeDetailsUnavailable: PhotoKit no longer has the
                // history since our token — rebuild once, then resume incremental.
                rows = Self.fullRows(); how = "rebuilt: \((error as NSError).code)"
            }
        } else {
            rows = Self.fullRows(); how = stored == nil ? "built" : "rebuilt: unreadable catalog"
        }
        if let td = Self.tokenData(now), let data = try? JSONEncoder().encode(Catalog(token: td, rows: rows)) {
            try? data.write(to: catalogURL, options: .atomic)
        }
        return (rows, how)
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        let t0 = Date()
        // Trial mode (newest N) keeps the old direct walk — a bounded fetch, no catalog on a stranger's Mac.
        let (rows, how) = limit > 0 ? (Self.fullRows(limit: limit), "trial \(limit)") : currentRows()
        var list = rows.map { (key: $0.key, row: $0.value) }
        list.sort { ($0.row.created ?? .distantPast) > ($1.row.created ?? .distantPast) }
        var seen = Set<String>(), dups = Set<String>()
        for e in list { if !seen.insert(e.row.name).inserted { dups.insert(e.row.name) } }
        var m: [String: Meta] = [:]; var seenPrints = Set<String>(), dupP = Set<String>()
        m.reserveCapacity(list.count)
        for e in list {
            m[e.key] = Meta(created: e.row.created, w: e.row.w, h: e.row.h)
            if let c = e.row.created {
                for k in Self.prints(c, e.row.w, e.row.h) where !seenPrints.insert(k).inserted { dupP.insert(k) }
            }
        }
        lock.lock(); dupNames = dups; meta = m; dupPrints = dupP; lock.unlock()
        NSLog("micloud photos catalog: %d assets · %@ · %.1f s", list.count, how, Date().timeIntervalSince(t0))
        return list.map { BackfillEntry(key: $0.key, relativePath: $0.row.name, bytes: $0.row.bytes) }
    }

    /// `IMG_3903.HEIC` → `IMG_3903-5F2A1B3C.HEIC` (first 8 chars of the asset's stable local identifier).
    static func uniqueName(_ filename: String, assetID: String) -> String {
        let tag = String(assetID.prefix(while: { $0 != "/" }).prefix(8)).uppercased()
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? filename : url.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(stem)-\(tag)" : "\(stem)-\(tag).\(ext)"
    }

    func targetNames() -> [String] { targets.map(\.displayName) }

    /// Reconcile PER TARGET: which (library-unique) filenames each one already holds. One listing per target —
    /// ~180 paged requests for Immich, one PROPFIND for Nextcloud — not one request per asset. A target that
    /// cannot be listed is left out, so the engine treats nothing as "already there" for it.
    /// Below this many pending items the targets are asked per item (a HEAD, a search) instead of listed whole
    /// (~180 paged Immich requests + one 180,000-entry PROPFIND): a lane that is complete bar today's photos no
    /// longer re-lists both targets to confirm three files (2026-10-18).
    static let perItemCeiling = 100

    func alreadyPresentPerTarget(_ entries: [BackfillEntry]) async -> [String: Set<String>] {
        lock.lock(); let dups = dupNames; let m = meta; let dupP = dupPrints; lock.unlock()
        var out: [String: Set<String>] = [:]
        if entries.count <= Self.perItemCeiling {
            for t in targets {
                var keys = Set<String>()
                for e in entries {
                    // Same two handles as the listing path: the (per-asset-suffixed when shared) name, then the
                    // capture-time + pixel-size fingerprint when it is unambiguous in this library.
                    let name = dups.contains(e.relativePath) ? Self.uniqueName(e.relativePath, assetID: e.key) : e.relativePath
                    if await t.has(filename: name) { keys.insert(e.key); continue }
                    guard let mm = m[e.key], let c = mm.created, mm.w > 0, mm.h > 0,
                          !Self.prints(c, mm.w, mm.h).contains(where: { dupP.contains($0) }) else { continue }
                    if await t.has(createdAt: c, width: mm.w, height: mm.h) { keys.insert(e.key) }
                }
                NSLog("micloud reconcile photos: %@ — %d of %d present (per item)", t.label, keys.count, entries.count)
                out[t.displayName] = keys
            }
            return out
        }
        for t in targets {
            guard let p = await t.presence() else { NSLog("micloud reconcile photos: %@ cannot enumerate", t.label); continue }
            NSLog("micloud reconcile photos: %@ holds %d names · %d unique fingerprints", t.label, p.names.count, p.fingerprints.count)
            var keys = Set<String>(); var byName = 0, byPrint = 0
            for e in entries {
                // By name: the original name when it is unique in the library, else the per-asset suffixed
                // name Nextcloud stores for collisions (IMG_0001–9999 cycle: 72,183 of 82,985 files there).
                let name = dups.contains(e.relativePath) ? Self.uniqueName(e.relativePath, assetID: e.key) : e.relativePath
                if p.names.contains(name) { keys.insert(e.key); byName += 1; continue }
                // By fingerprint: capture time (instant, or wall clock) + pixel size, unique on both sides,
                // either orientation.
                guard !p.fingerprints.isEmpty, let mm = m[e.key], let c = mm.created else { continue }
                let candidates = Self.prints(c, mm.w, mm.h) + Self.prints(c, mm.h, mm.w)
                if candidates.contains(where: { !dupP.contains($0) && p.fingerprints.contains($0) }) {
                    keys.insert(e.key); byPrint += 1
                }
            }
            NSLog("micloud reconcile photos: %@ — %d by name, %d by fingerprint", t.label, byName, byPrint)
            out[t.displayName] = keys
        }
        return out
    }
    /// The two fingerprint families for one asset: the instant, and the wall clock in this Mac's zone.
    static func prints(_ created: Date, _ w: Int, _ h: Int) -> [String] {
        [PhotoFingerprint.key(createdAt: created, width: w, height: h),
         PhotoFingerprint.naiveKey(createdAt: created, in: .current, width: w, height: h)]
    }
    /// Single-target form: "already there" = every target holds it (and every target could be listed).
    func alreadyPresent(_ entries: [BackfillEntry]) async -> Set<String> {
        let per = await alreadyPresentPerTarget(entries)
        guard !targets.isEmpty, per.count == targets.count else { return [] }
        return per.values.reduce(Set(entries.map(\.key))) { $0.intersection($1) }
    }

    func process(_ entry: BackfillEntry) async throws {
        if let o = try await process(entry, skipping: []), o.sent.isEmpty { throw BackfillEngine.AlreadyOnTarget() }
    }

    /// Send the original to every target not in `skipping` (the ledger knows those already hold it — Immich
    /// for ~all of a library it had before this Mac existed) and report per target. Nothing is fetched from
    /// iCloud until at least one target is known to lack the item.
    func process(_ entry: BackfillEntry, skipping: Set<String>) async throws -> TargetOutcome? {
        var outcome = TargetOutcome()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [entry.key], options: nil).firstObject else { return outcome }   // gone from the library
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first else {
            throw NSError(domain: "micloud.photos", code: 1, userInfo: [NSLocalizedDescriptionKey: "no resource"])
        }
        let filename = resource.originalFilename
        let wanted = targets.filter { !skipping.contains($0.displayName) }
        guard !wanted.isEmpty else { return outcome }
        lock.lock(); let collides = dupNames.contains(filename); lock.unlock()
        // Already there? Ask the remaining targets by name BEFORE fetching the original from iCloud (Optimise
        // Mac Storage means every fetch is a download). Only safe for names unique in the library.
        var toSend = wanted
        if !collides {
            toSend = []
            for t in wanted {
                if await t.has(filename: filename) { outcome.present.insert(t.displayName) } else { toSend.append(t) }
            }
            if toSend.isEmpty { return outcome }
        }
        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? created
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + filename)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ropts = PHAssetResourceRequestOptions(); ropts.isNetworkAccessAllowed = true
        // One large original at a time. iCloud cuts an asset download off after about an hour (PHPhotosError
        // 3169 at 60 min, four times, on each of three 6 GB videos, 2026-10-19): three of them sharing a 4 MB/s
        // link got ~5.2 GB each per hour and never finished. Alone, a 6 GB fetch takes ~25 min. Small items
        // keep the engine's concurrency; only the big ones queue here.
        let big = entry.bytes >= Self.bigFetchBytes
        if big { await Self.bigFetchGate.acquire() }
        defer { if big { Self.bigFetchGate.release() } }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: tmp, options: ropts) { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            }
        }
        outcome.bytes = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value
        let ncName = collides ? Self.uniqueName(filename, assetID: entry.key) : filename
        for t in toSend {
            let name = t.label == "nextcloud" ? ncName : filename
            if try await t.uploadPhoto(localFile: tmp, filename: name, createdAt: created, modifiedAt: modified) == .duplicate {
                outcome.present.insert(t.displayName)
            } else { outcome.sent.insert(t.displayName) }
        }
        return outcome
    }

    func capacityTargets() -> [BackfillTarget] { capTargets }

    /// Originals at or above this (ledger estimate) fetch one at a time — see `process`.
    static let bigFetchBytes: Int64 = 1 << 30
    static let bigFetchGate = AsyncGate()
}

/// A one-at-a-time gate for async code (an `NSLock` cannot be held across an `await`). FIFO.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        lock.lock()
        if !busy { busy = true; lock.unlock(); return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c); lock.unlock()
        }
    }
    func release() {
        lock.lock()
        if waiters.isEmpty { busy = false; lock.unlock(); return }
        let next = waiters.removeFirst(); lock.unlock()
        next.resume()   // ownership passes straight to the next waiter
    }
}
