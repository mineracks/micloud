import Foundation

/// `BackfillSource` for a folder (iCloud Drive or any granted directory): enumerate regular files, and for
/// each, materialise it if dataless (iCloud thin-cache), then upload to Nextcloud. Reuses the proven
/// `NextcloudWebDAV` path. A file iCloud can't deliver (or that's unreadable) throws → the engine quarantines
/// it rather than stalling. Pure Foundation — lives in MicloudKit, no PhotoKit / UI.
/// Remote paths one lane is working on right now, so the other lane leaves them alone. The backfill pulling a
/// placeholder down from iCloud looks, to the live watcher, exactly like a file that changed: the watcher then
/// uploaded the same bytes at the same moment (Nextcloud: "is locked, existing lock on file: exclusive" → 423)
/// and evicted the file when it was done — under the backfill's own PUT, whose read then met a placeholder
/// (EDEADLK, "The file couldn't be opened"). 40 % of the lane's first attempts failed that way.
public final class PathClaims: @unchecked Sendable {
    private let lock = NSLock(); private var set = Set<String>()
    public init() {}
    public func claim(_ p: String) { lock.lock(); set.insert(p); lock.unlock() }
    public func release(_ p: String) { lock.lock(); set.remove(p); lock.unlock() }
    public func isClaimed(_ p: String) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(p) }
}

/// An error with the step it happened in, so the ledger says "materialise:" or "upload:" and not just
/// "The file couldn't be opened".
public struct StepError: Error, CustomStringConvertible, LocalizedError {
    public let step: String; public let underlying: Error
    public var description: String { "\(step): \(underlying)" }
    public var errorDescription: String? { description }
}

public final class DriveBackfillSource: BackfillSource, @unchecked Sendable {
    public let id: SourceID = .documents
    private let root: URL
    private let dav: NextcloudWebDAV
    private let remotePrefix: String
    private let evictAfterUpload: Bool
    private let materializeTimeout: TimeInterval
    private let limit: Int          // 0 = whole folder; >0 = the newest N files (trial mode)
    private let claims: PathClaims?

    public init(root: URL, dav: NextcloudWebDAV, remotePrefix: String = "Documents",
                evictAfterUpload: Bool = false, materializeTimeout: TimeInterval = 120, limit: Int = 0,
                claims: PathClaims? = nil) {
        self.root = root; self.dav = dav; self.remotePrefix = remotePrefix
        self.evictAfterUpload = evictAfterUpload; self.materializeTimeout = materializeTimeout; self.limit = limit
        self.claims = claims
    }

    public func enumerateItems() async throws -> [BackfillEntry] {
        let fm = FileManager.default
        // Canonicalise both sides — macOS's /private symlink otherwise breaks the relative-path math.
        let canonRoot = root.resolvingSymlinksInPath()
        let base = canonRoot.path
        var scanned: [(entry: BackfillEntry, mtime: Date)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let en = fm.enumerator(at: canonRoot, includingPropertiesForKeys: keys) else { return [] }
        while let url = en.nextObject() as? URL {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            guard rv?.isRegularFile == true else { continue }
            let rel = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rel.isEmpty { continue }
            scanned.append((BackfillEntry(key: rel, relativePath: rel, bytes: Int64(rv?.fileSize ?? 0)),
                            rv?.contentModificationDate ?? .distantPast))
        }
        // Trial mode: keep only the newest `limit` files (most recently modified) — a fast, low-exposure taste.
        if limit > 0 && scanned.count > limit {
            scanned.sort { $0.mtime > $1.mtime }
            scanned = Array(scanned.prefix(limit))
        }
        return scanned.map(\.entry)
    }

    public func alreadyPresent(_ entries: [BackfillEntry]) async -> Set<String> {
        await dav.presentKeys(entries.map { (key: $0.key, remote: remotePrefix.isEmpty ? $0.key : "\(remotePrefix)/\($0.key)", bytes: $0.bytes) })
    }

    public func process(_ entry: BackfillEntry) async throws {
        // Hard deadline around the whole item. A read of a dataless file blocks inside the kernel until iCloud
        // delivers it; when iCloud is stuck (bird idle, downloads never arriving) that read never returns and a
        // worker is wedged for good — three wedged workers and the lane shows 0 B/s forever. The deadline turns
        // that into a retryable failure instead.
        let budget = materializeTimeout * 2 + Double(entry.bytes) / 500_000       // +2 s per MB on top of the materialise wait
        let rel = remotePrefix.isEmpty ? entry.key : "\(remotePrefix)/\(entry.key)"
        claims?.claim(rel); defer { claims?.release(rel) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.processUnbounded(entry) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                throw WebDAVError.noResponse("gave up after \(Int(budget)) s on \(entry.relativePath)")
            }
            try await group.next()
            group.cancelAll()
        }
    }

    private func processUnbounded(_ entry: BackfillEntry) async throws {
        let local = root.appendingPathComponent(entry.key)
        let fm = FileManager.default
        // Ground truth from stat(2), not the ubiquity resource key: URL caches resource values per instance, so a
        // loop polling `.ubiquitousItemDownloadingStatus` on the same URL kept seeing "not downloaded" after
        // the file had landed (the live lane mirrored the very same files seconds later) and timed out.
        func isDataless() -> Bool { Self.isDataless(local.path) }
        func downloadStatus() -> URLUbiquitousItemDownloadingStatus? { isDataless() ? .notDownloaded : .current }
        // Ask the server FIRST — before pulling an evicted file down from iCloud only to find it there.
        let rel = remotePrefix.isEmpty ? entry.key : "\(remotePrefix)/\(entry.key)"
        if await dav.exists(rel, bytes: entry.bytes) { throw BackfillEngine.AlreadyOnTarget() }
        // Parents before the download, so the file is on disk for the shortest possible time.
        do { try await dav.ensureParents(of: rel) } catch { throw StepError(step: "folders", underlying: error) }
        // materialise a dataless iCloud file, then wait for it (bounded) — else throw → quarantine
        let wasDataless = downloadStatus() == .notDownloaded
        if wasDataless {
            // Two requests, belt and braces. The ubiquity API call is the documented way; from inside the sandbox
            // (read-only grant on Mobile Documents) it returns without error and nothing arrives — 395 "iCloud
            // never delivered" on files that `brctl download` fetched in seconds. A plain read of the first byte
            // is what the kernel turns into the download, and it is what every ordinary app does by accident.
            try? fm.startDownloadingUbiquitousItem(at: local)
            do { try await Self.materialiseByReading(local) }   // returns once a byte was read, i.e. the file is here
            catch { throw StepError(step: "materialise", underlying: error) }
            let start = Date()
            while isDataless() {
                if Date().timeIntervalSince(start) > materializeTimeout + Double(entry.bytes) / 1_000_000 {   // +1 s per MB: a 2 GB video is not a timeout
                    throw WebDAVError.noResponse("iCloud never delivered \(entry.relativePath)")
                }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        do { try await dav.upload(localFile: local, to: rel) }
        catch { throw StepError(step: "upload", underlying: error) }
        // Put back what we found: a placeholder we pulled down goes back to being a placeholder, so a 450 GB
        // Drive does not end up resident on a 460 GB disk. A file the user had resident stays resident.
        if evictAfterUpload && wasDataless { try? fm.evictUbiquitousItem(at: local) }
    }

    /// SF_DATALESS from stat(2) — the only uncached answer to "is this file still a placeholder".
    static func isDataless(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_flags & UInt32(SF_DATALESS)) != 0
    }

    /// Read one byte on a plain thread: the read blocks inside the kernel until iCloud has delivered the file.
    /// Off the cooperative pool on purpose — a blocked read must not starve the other lanes' tasks. The item's
    /// deadline (see `process`) still bounds the wait; a read that outlives it just finishes later, unobserved.
    static func materialiseByReading(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                // The relay runs with dataless materialisation OFF at process scope (so that scanning 160k
                // files never blocks on iCloud); an open() of a dataless file then fails with EDEADLK (11,
                // "The file couldn't be opened"). Turn it ON for this thread only, for this read only.
                setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
                defer { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT) }
                // Raw syscalls, proven on the box: with the process policy OFF, open(2) succeeds and it is the
                // read(2) that fails with EDEADLK; with the thread policy ON the same read blocks until the
                // bytes are here and returns 1.
                let fd = open(url.path, O_RDONLY)
                guard fd >= 0 else { cont.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)); return }
                var b: UInt8 = 0
                let n = read(fd, &b, 1)
                let err = errno
                close(fd)
                if n < 0 { cont.resume(throwing: POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)) }
                else { cont.resume() }
            }
        }
    }

    public func capacityTargets() -> [BackfillTarget] { [NextcloudFolderTarget(dav: dav, path: remotePrefix)] }
}
