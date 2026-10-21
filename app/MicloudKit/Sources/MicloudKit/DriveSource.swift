import Foundation
import CoreServices   // FSEvents

/// The first real sync source: a **one-way** mirror of an iCloud Drive folder to Nextcloud.
///
/// Assembles the three proven pieces:
///   • **watch** — `FSEventStream` on the granted folder (T2: fires for other-device changes,
///     reports only changed paths, no tree walk).
///   • **materialise** — `startDownloadingUbiquitousItem` if the changed file is dataless (T1).
///   • **upload + evict** — WebDAV PUT to Nextcloud (`NextcloudWebDAV`), then
///     `evictUbiquitousItem` to keep the thin cache (T1).
///
/// Invariants (from the agent reference spec): never writes to iCloud; deletes are **soft**
/// (MOVE to a dated trash on the target, never hard-removed).
public final class DriveSource: SyncSource, @unchecked Sendable {
    public let id: SourceID = .documents

    private let root: URL                 // the granted iCloud Drive folder (security-scoped in the app)
    private let remotePrefix: String      // Nextcloud path prefix, e.g. "Documents"
    private let trashPrefix: String       // e.g. ".trash/deltasync"
    private let dav: NextcloudWebDAV
    private let heartbeat: @Sendable (Heartbeat) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "micloud.drivesource")

    /// Fired (best-effort) whenever a change is observed OR a live upload finally fails. The coordinator wires
    /// this to a debounced, ledger-backed backfill of this lane — the SAME safety net the other live lanes
    /// (Calendars/Reminders/Contacts) already use. So a transient WebDAV blip that the fast inline path can't
    /// ride out is guaranteed to be reconciled: the backfill re-enumerates the folder, and its ledger retries
    /// with backoff, requeues, and quarantines poison files instead of stalling. Optional — nil in unit tests.
    public var onActivity: (@Sendable () -> Void)?
    /// Paths another lane (the ledger-backed backfill) is working on right now: its download of a placeholder
    /// fires an FSEvent here that is not a change. Set by the coordinator; nil = no other lane.
    public var skipIf: (@Sendable (String) -> Bool)?

    // Loop prevention: our own evict makes a file dataless, which fires another FSEvent. Without this,
    // that self-triggered event re-materialises + re-uploads forever (and can overwrite the good copy
    // with a 0-byte dataless file mid-race). `inFlight` blocks concurrent handling of the same path;
    // `recentlyDone` ignores events for a path we just processed, for `quietWindow` seconds.
    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var recentlyDone: [String: Date] = [:]
    private let quietWindow: TimeInterval = 15

    private func claim(_ rel: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight.contains(rel) { return false }
        if let t = recentlyDone[rel], Date().timeIntervalSince(t) < quietWindow { return false }
        inFlight.insert(rel); return true
    }
    private func done(_ rel: String) { lock.lock(); inFlight.remove(rel); recentlyDone[rel] = Date(); lock.unlock() }
    private func drop(_ rel: String)  { lock.lock(); inFlight.remove(rel); recentlyDone[rel] = nil;   lock.unlock() }

    public init(watchedFolder: URL, remoteDocumentsPath: String, trashPath: String,
                dav: NextcloudWebDAV, heartbeat: @escaping @Sendable (Heartbeat) -> Void) {
        self.root = watchedFolder
        self.remotePrefix = remoteDocumentsPath
        self.trashPrefix = trashPath
        self.dav = dav
        self.heartbeat = heartbeat
    }

    // ── SyncSource ──────────────────────────────────────────────────────────
    public func start() async throws {
        var ctx = FSEventStreamContext()
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                         | kFSEventStreamCreateFlagUseCFTypes
                         | kFSEventStreamCreateFlagNoDefer)
        let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<DriveSource>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            for p in list.prefix(n) { me.enqueue(URL(fileURLWithPath: p)) }
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            throw WebDAVError.noResponse("FSEventStreamCreate(\(root.path))")
        }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        emit(.healthy, "watching \(root.lastPathComponent)")
    }

    public func stop() async {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
    }

    /// Full-pass mop-up: walk the watched tree and re-enqueue every regular file. Enqueue is idempotent (the
    /// `claim`/quiet-window dedup + idempotent WebDAV PUT mean an already-mirrored file is cheap to re-see), so
    /// this is safe to call on demand ("Sync now" / `SyncEngine.reconcileAll`) or after a reconnect. The
    /// heavy, resumable, ledger-backed sweep is `DriveBackfillSource`; this is the lightweight live-lane pass.
    public func reconcile() async throws {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        while let url = en.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { enqueue(url) }
        }
    }

    // ── internals ───────────────────────────────────────────────────────────
    private func enqueue(_ url: URL) { onActivity?(); Task { await handleChange(url) } }

    /// Upload with a short bounded retry so a transient WebDAV blip (server restart, a momentary network drop)
    /// doesn't drop the file on the floor. Persistent failure still throws — the caller then leaves the path
    /// un-stamped (so a later FSEvent can retry) and nudges the ledger-backed backfill via `onActivity`.
    private func uploadWithRetry(_ localURL: URL, to rel: String, attempts: Int = 3) async throws {
        var delay: UInt64 = 500_000_000   // 0.5s, doubling
        for attempt in 1...max(1, attempts) {
            do {
                try await dav.ensureParents(of: rel)
                try await dav.upload(localFile: localURL, to: rel)
                return
            } catch {
                if attempt == attempts { throw error }
                try? await Task.sleep(nanoseconds: delay); delay *= 2
            }
        }
    }

    /// The core one-way mirror action for a single changed path.
    func handleChange(_ localURL: URL) async {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: localURL.path, isDirectory: &isDir)
        let rel = remotePath(for: localURL)
        let name = localURL.lastPathComponent
        if !isDir.boolValue && !exists {                       // deletion → soft-delete, once
            guard claim(rel) else { return }
            defer { done(rel) }
            let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            do { try await dav.move(rel, to: "\(trashPrefix)/\(day)/\(rel)"); emit(.healthy, "trashed \(name)") }
            catch { emit(.error, "trash failed \(name): \(error)") }
            return
        }
        if isDir.boolValue || !exists { return }

        // Dedup: skip if already handling this path, or if we just processed it (our own evict fires an
        // event — this is what breaks the re-upload loop).
        guard claim(rel) else { return }
        if skipIf?(rel) == true { drop(rel); return }          // the backfill owns this one right now

        do {
            func status() -> URLUbiquitousItemDownloadingStatus? {
                try? localURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            }
            // A placeholder whose size the server already has is not a change — it is the backfill's evict
            // after its upload, or iCloud tidying up. Pulling it down again would re-upload and re-evict it
            // for nothing (and race the next lane). A local edit is never a placeholder, so this skips no edit.
            if status() == .notDownloaded,
               let sz = (try? fm.attributesOfItem(atPath: localURL.path))?[.size] as? Int64,
               await dav.exists(rel, bytes: sz) { done(rel); return }
            emit(.syncing, "sending \(name)")   // the feed showed a bare filename, then "mirrored <name>" — two lines, one file
            // materialise if dataless (T1) — the same way the backfill does: the ubiquity request is a no-op
            // from inside the sandbox, and the resource-key status is cached per URL. Reading the first byte
            // is the download; stat(2) is the truth about whether it landed.
            let wasDataless = DriveBackfillSource.isDataless(localURL.path)
            if wasDataless {
                try? fm.startDownloadingUbiquitousItem(at: localURL)
                try await DriveBackfillSource.materialiseByReading(localURL)
                try await waitDownloaded(localURL)
            }
            // HARD GUARD: never upload a still-dataless file — that would overwrite the good copy with 0 bytes.
            // Not a hard failure: drop the claim (don't stamp the quiet-window) so a retry can pick it up once
            // iCloud delivers it, and nudge the backfill safety net.
            if DriveBackfillSource.isDataless(localURL.path) {
                emit(.error, "still dataless, upload skipped: \(name)"); drop(rel); onActivity?(); return
            }
            try await uploadWithRetry(localURL, to: rel)
            emit(.healthy, "mirrored \(name)")
            done(rel)   // stamp the quiet-window BEFORE the evict, so the evict's own FSEvent is ignored
            // put back what we found: a placeholder we pulled down goes back to being one (T1 thin cache);
            // a file the user had resident stays resident.
            if wasDataless { try? fm.evictUbiquitousItem(at: localURL) }
        } catch {
            // A transient upload/materialise failure survived the retry. Do NOT stamp the quiet-window (that
            // would suppress a retry) — drop the claim so a subsequent FSEvent re-tries, and nudge the
            // ledger-backed backfill, which reliably reconciles this file (retry/requeue/quarantine).
            emit(.error, "\(name): \(error)")
            drop(rel)
            onActivity?()
        }
    }

    /// Map a local iCloud Drive path to its Nextcloud relative path under `remotePrefix`.
    private func remotePath(for localURL: URL) -> String {
        let rel: String
        if localURL.path.hasPrefix(root.path) {
            rel = String(localURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            rel = localURL.lastPathComponent
        }
        return remotePrefix.isEmpty ? rel : "\(remotePrefix)/\(rel)"
    }

    private func waitDownloaded(_ url: URL, timeout: TimeInterval = 60) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if !DriveBackfillSource.isDataless(url.path) { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func emit(_ s: SourceStatus, _ item: String) {
        heartbeat(Heartbeat(source: id, status: s, lastItem: item))
    }
}
