import Foundation

/// Thread-safe holder of the latest `HealthSnapshot`, with a change callback the dashboard subscribes to.
///
/// Sources are handed `store.record` as their heartbeat sink (see `DriveSource(heartbeat:)`), so every
/// mirror action flows here and fans out to observers. A self-host user needs no Grafana/Loki — the in-app
/// dashboard reads this directly; the turnkey build can *additionally* forward each heartbeat to Loki.
public final class HealthStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = HealthSnapshot()
    private var recent: [Heartbeat] = []                 // rolling history for the "Live" feed, newest last
    private let recentCap = 60
    private var activity = 0                              // monotonic count of item-level events (for the activity graph)
    // Items mirrored since local midnight, persisted so the number survives the relay's restarts (it restarts
    // on every deploy). "mirrored this session" counted "→" lines in a 40-event window: 0 on a Mac that had
    // just mirrored a file (2026-10-19).
    private var mirroredDay = "", mirroredCount = 0
    private static let mirroredKey = "micloud.mirroredToday"
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    private var observers: [UUID: @Sendable (HealthSnapshot) -> Void] = [:]
    /// Optional forwarder (e.g. `LokiSink.push`) — sees every heartbeat after it is recorded.
    public var forward: (@Sendable (Heartbeat) -> Void)?

    public init() {
        if let d = UserDefaults.standard.dictionary(forKey: Self.mirroredKey), let day = d["day"] as? String, let n = d["count"] as? Int {
            mirroredDay = day; mirroredCount = n
        }
    }

    /// A heartbeat that names one item landing on the sovereign copy (an upload, a live mirror, a photo created).
    public static func isMirrorAction(_ hb: Heartbeat) -> Bool {
        guard let it = hb.lastItem else { return false }
        return it.contains("→") || it.hasPrefix("mirrored ") || it.contains(": created")
    }

    /// Items mirrored since local midnight on this Mac.
    public func mirroredToday() -> Int {
        lock.lock(); defer { lock.unlock() }
        return mirroredDay == Self.dayFmt.string(from: Date()) ? mirroredCount : 0
    }

    /// Monotonic count of item-level sync events seen so far — the dashboard buckets its delta over time to
    /// draw the activity graph. Counts a heartbeat as "activity" when it names a concrete item (an upload,
    /// not a phase/status message).
    public func activityCount() -> Int { lock.lock(); defer { lock.unlock() }; return activity }

    /// Record a heartbeat (keeps the most recent per source; appends to the rolling feed) and notify
    /// observers with the new snapshot.
    public func record(_ hb: Heartbeat) {
        lock.lock()
        snapshot.record(hb)
        recent.append(hb)
        if recent.count > recentCap { recent.removeFirst(recent.count - recentCap) }
        // count as activity when the heartbeat names a concrete item being mirrored (upload lines), not a
        // scan/phase/status message — this is what the activity graph plots.
        if hb.status == .syncing, let it = hb.lastItem, it.contains("→") || it.contains(" left") || it.contains(": created") || it.contains(": duplicate") {
            activity += 1
        }
        if Self.isMirrorAction(hb) {
            let today = Self.dayFmt.string(from: Date())
            if mirroredDay != today { mirroredDay = today; mirroredCount = 0 }
            mirroredCount += 1
            UserDefaults.standard.set(["day": today, "count": mirroredCount], forKey: Self.mirroredKey)
        }
        let snap = snapshot
        let obs = Array(observers.values)
        let fwd = forward
        lock.unlock()
        for o in obs { o(snap) }
        fwd?(hb)
    }

    /// The current snapshot (for a one-shot read).
    public func current() -> HealthSnapshot { lock.lock(); defer { lock.unlock() }; return snapshot }

    /// The most recent heartbeats, newest first — what the dashboard's "Live" feed renders.
    public func recentEvents(_ max: Int = 60) -> [Heartbeat] {
        lock.lock(); defer { lock.unlock() }
        return Array(recent.suffix(max).reversed())
    }

    /// Subscribe to snapshot changes. Fires immediately with the current snapshot. Returns a token
    /// to `cancel` the subscription.
    @discardableResult
    public func observe(_ cb: @escaping @Sendable (HealthSnapshot) -> Void) -> UUID {
        lock.lock(); let id = UUID(); observers[id] = cb; let snap = snapshot; lock.unlock()
        cb(snap); return id
    }
    public func cancel(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }
}

/// Coordinates the configured sync sources: starts/stops them and funnels a `reconcileAll`.
///
/// Sources are constructed with `store.record` as their heartbeat sink, so the engine only owns
/// lifecycle — it does not sit in the per-item hot path. A source that throws on `start`/`reconcile`
/// is recorded as `.error` for its `SourceID` rather than bringing the whole engine down.
public final class SyncEngine: @unchecked Sendable {
    public let store: HealthStore
    private let lock = NSLock()
    private var sources: [SyncSource]

    public init(sources: [SyncSource] = [], store: HealthStore) {
        self.store = store
        self.sources = sources
    }

    private func snapshotSources() -> [SyncSource] { lock.lock(); defer { lock.unlock() }; return sources }

    /// Add a source and start it immediately (sources can come online after launch — e.g. the Drive
    /// source once the user grants a folder). A start failure is recorded as `.error`, not fatal.
    public func add(_ s: SyncSource) async {
        lock.lock(); sources.append(s); lock.unlock()
        do { try await s.start() }
        catch { store.record(Heartbeat(source: s.id, status: .error, lastItem: "start failed: \(error)")) }
    }

    public func start() async {
        for s in snapshotSources() {
            do { try await s.start() }
            catch { store.record(Heartbeat(source: s.id, status: .error, lastItem: "start failed: \(error)")) }
        }
    }

    public func stop() async { for s in snapshotSources() { await s.stop() } }

    /// Force a full reconciliation on every source (the dashboard's "Sync now" + the mop-up timer).
    public func reconcileAll() async {
        for s in snapshotSources() {
            do { try await s.reconcile() }
            catch { store.record(Heartbeat(source: s.id, status: .error, lastItem: "reconcile failed: \(error)")) }
        }
    }
}
