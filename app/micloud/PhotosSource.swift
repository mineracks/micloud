import Foundation
import Photos

/// PhotoKit-backed `SyncSource`: mirrors photo-library originals to the configured `PhotoTarget`s
/// (Nextcloud and/or Immich), one-way, emitting `Heartbeat`s into the `HealthStore` so the dashboard
/// updates live. This is the proven probe logic (PHAssetResourceManager originals + PhotoTarget
/// fan-out) promoted into an engine component.
///
/// For the demo it mirrors the newest `limit` images so a run doesn't push the whole library; the
/// production source drops the limit and drives off the change observer + a reconcile pass.
final class PhotosSource: NSObject, SyncSource, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    let id: SourceID = .photos

    private let targets: [PhotoTarget]
    private let heartbeat: @Sendable (Heartbeat) -> Void
    private let limit: Int
    private let lock = NSLock()
    private var mirroredThisSession = 0
    private var libraryCount = 0
    private var mirroring = false             // a drain is running
    private var seen: Set<String> = []        // localIdentifiers already handled — the watcher never re-mirrors
    private var fetchResult: PHFetchResult<PHAsset>?   // what the change observer diffs against
    private var queue: [PHAsset] = []         // inserted assets waiting for the drain
    private var queued: Set<String> = []

    init(targets: [PhotoTarget], limit: Int, heartbeat: @escaping @Sendable (Heartbeat) -> Void) {
        self.targets = targets; self.limit = limit; self.heartbeat = heartbeat
    }

    // ── SyncSource ────────────────────────────────────────────────────────────
    func start() async throws {
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            emit(.error, "Photos access denied — grant it in System Settings › Privacy"); return
        }
        PHPhotoLibrary.shared().register(self)
        await mirrorNewest()
    }

    func stop() async { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    func reconcile() async throws { await mirrorNewest() }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Only what PhotoKit says was INSERTED. Until 2026-10-18 every notification (iCloud Photos fires them
        // constantly — thumbnails, metadata, edits) re-fetched the newest 50 assets and asked both targets
        // about each: ~100 requests per notification for, nearly always, nothing new.
        lock.lock(); let fr = fetchResult; lock.unlock()
        guard let fr, let d = changeInstance.changeDetails(for: fr) else { return }   // nil = our set is unaffected
        lock.lock(); fetchResult = d.fetchResultAfterChanges; lock.unlock()
        guard d.hasIncrementalChanges else { Task { await mirrorNewest() }; return }   // PhotoKit cannot say what changed
        let fresh = d.insertedObjects
        if !fresh.isEmpty { enqueue(fresh) }
    }

    // ── mirror ──────────────────────────────────────────────────────────────
    /// Catch-up at start (and on an explicit reconcile): the newest `limit` items not yet handled — assets that
    /// arrived while the relay was down. After that the change observer feeds `enqueue` directly.
    private func mirrorNewest() async {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = { () -> PHFetchResult<PHAsset> in   // photos AND videos (the tile says "Photos & videos"; videos were silently left out)
            opts.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            return PHAsset.fetchAssets(with: opts) }()
        lock.lock(); libraryCount = assets.count; fetchResult = assets; lock.unlock()
        let n = limit > 0 ? min(assets.count, limit) : assets.count   // 0 = whole library
        var todo: [PHAsset] = []
        for i in 0..<n { todo.append(assets.object(at: i)) }
        enqueue(todo)   // `enqueue` drops what was already handled
    }

    /// Queue new assets and start a drain if none is running. A notification that lands mid-drain is appended,
    /// not dropped (the old in-flight guard discarded it until the next notification).
    private func enqueue(_ assets: [PHAsset]) {
        lock.lock()
        for a in assets where !seen.contains(a.localIdentifier) && queued.insert(a.localIdentifier).inserted { queue.append(a) }
        let start = !mirroring && !queue.isEmpty
        if start { mirroring = true }
        lock.unlock()
        if start { Task { await self.drain() } }
    }

    private func drain() async {
        while true {
            lock.lock()
            if queue.isEmpty { mirroring = false; lock.unlock(); break }   // decided under the same lock `enqueue` checks
            let batch = queue; queue.removeAll(); lock.unlock()
            emit(.syncing, "mirroring \(batch.count) new", pending: batch.count)
            for (idx, a) in batch.enumerated() {
                await mirror(a, remaining: batch.count - idx - 1)
                lock.lock(); seen.insert(a.localIdentifier); queued.remove(a.localIdentifier); lock.unlock()   // handled even on failure — no retry loop
            }
            emit(.healthy, targets.isEmpty ? "no targets configured" : "up to date", pending: 0)
        }
    }

    private func mirror(_ asset: PHAsset, remaining: Int) async {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo || $0.type == .video }) ?? resources.first else { return }
        let filename = resource.originalFilename
        let created = asset.creationDate ?? Date()
        let modified = asset.modificationDate ?? created
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + filename)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ropts = PHAssetResourceRequestOptions(); ropts.isNetworkAccessAllowed = true
        do {
            // Bounded iCloud fetch. PhotoKit retries a dead CloudKit connection for as long as it likes
            // (21 min on 2026-10-18); past the deadline the request is cancelled and the item is left to the
            // ledger-backed backfill, which has its own size-scaled timeout and retries.
            try await Self.fetch(resource, to: tmp, options: ropts, deadline: Self.fetchDeadline(bytes: Self.estimatedBytes(asset)))
            for t in targets {
                let r = try await t.uploadPhoto(localFile: tmp, filename: filename,
                                                createdAt: created, modifiedAt: modified)
                lock.lock(); if r == .created { mirroredThisSession += 1 }; lock.unlock()
                emit(.syncing, "\(filename) → \(t.label): \(r)", pending: remaining)
            }
        } catch {
            emit(.error, "\(filename): \(error)", pending: remaining)
        }
    }

    /// Videos by resolution × duration (0.6 B/px/s, as the ledger since dd90b64); images need no allowance.
    static func estimatedBytes(_ a: PHAsset) -> Int64 {
        guard a.mediaType == .video else { return 0 }
        return Int64(a.duration * Double(a.pixelWidth * a.pixelHeight) * 0.6)
    }

    /// Hard cap only — the real guard is the stall watchdog in `fetch`. 5 minutes plus a minute per 100 MB
    /// looked generous until three 6 GB videos shared a 4 MB/s iCloud link (2026-10-19): ~70 min each against
    /// a 65 min deadline. What the deadline was for was a *dead* connection (21 min of nothing, 2026-10-18),
    /// and that is told by the bytes not arriving, not by the clock.
    static func fetchDeadline(bytes: Int64?) -> TimeInterval {
        max(4 * 3600, 300 + Double(max(0, bytes ?? 0)) / 100_000_000 * 60)
    }
    /// No bytes for this long = the connection is dead; cancel and leave the item to the backfill's retry.
    static let fetchStallSeconds: TimeInterval = 300

    private struct FetchTimedOut: Error, CustomStringConvertible {
        let seconds: TimeInterval
        let stalled: Bool
        var description: String { stalled ? "iCloud fetch stalled — no data for \(Int(seconds)) s, left to the backfill"
                                          : "iCloud fetch gave up after \(Int(seconds)) s — left to the backfill" }
    }

    /// `requestData` under a watchdog: the PhotoKit request is cancelled when no chunk has arrived for
    /// `fetchStallSeconds` (or at the hard `deadline`), so the continuation resumes exactly once either way
    /// (the completion handler fires with a cancellation error).
    private static func fetch(_ resource: PHAssetResource, to tmp: URL, options: PHAssetResourceRequestOptions,
                              deadline: TimeInterval) async throws {
        let manager = PHAssetResourceManager.default()
        final class Box: @unchecked Sendable {
            var id: PHAssetResourceDataRequestID?; var timedOut: FetchTimedOut?; var lastChunk = Date(); let lock = NSLock()
        }
        let box = Box()
        let started = Date()
        let timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                box.lock.lock()
                let idle = Date().timeIntervalSince(box.lastChunk), total = Date().timeIntervalSince(started)
                var fire: FetchTimedOut?
                if idle > fetchStallSeconds { fire = FetchTimedOut(seconds: fetchStallSeconds, stalled: true) }
                else if total > deadline { fire = FetchTimedOut(seconds: deadline, stalled: false) }
                if let fire { box.timedOut = fire }
                let id = box.id
                box.lock.unlock()
                if fire != nil { if let id { manager.cancelDataRequest(id) }; return }
            }
        }
        defer { timer.cancel() }
        // `requestData` (not `writeData`) is the variant that hands back a request id to cancel.
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let out = try FileHandle(forWritingTo: tmp)
        defer { try? out.close() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                out.write(chunk)
                box.lock.lock(); box.lastChunk = Date(); box.lock.unlock()
            }, completionHandler: { err in
                box.lock.lock(); let timedOut = box.timedOut; box.lock.unlock()
                if let timedOut { c.resume(throwing: timedOut) }
                else if let err { c.resume(throwing: err) } else { c.resume() }
            })
            box.lock.lock(); box.id = id; box.lock.unlock()
        }
    }

    private func emit(_ status: SourceStatus, _ item: String, pending: Int = 0) {
        lock.lock(); let total = libraryCount; lock.unlock()
        heartbeat(Heartbeat(source: id, status: status, lastItem: item,
                            pendingCount: pending, itemCount: total))
    }
}
