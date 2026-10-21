import Foundation

/// One item to back up, as seen by the engine: a stable ledger `key`, a `relativePath` (for exclusion
/// matching + display), and its `bytes`.
public struct BackfillEntry: Sendable, Equatable {
    public let key: String
    public let relativePath: String
    public let bytes: Int64
    /// Optional content fingerprint. When set, the ledger re-queues this key if the hash changed since last
    /// time (so a live watcher re-uploads *edited* items); `nil` = no change detection (upload once).
    public let contentHash: String?
    public init(key: String, relativePath: String, bytes: Int64, contentHash: String? = nil) {
        self.key = key; self.relativePath = relativePath; self.bytes = bytes; self.contentHash = contentHash
    }
}

/// What one `process` pass did per fan-out target. Only lanes with more than one target report it (photos →
/// Immich + Nextcloud); single-target lanes keep the plain `process(_:)`.
public struct TargetOutcome: Sendable, Equatable {
    public var sent: Set<String>        // targets that received the bytes from this Mac
    public var present: Set<String>     // targets that already held the item (nothing moved)
    public var bytes: Int64?            // real size of the original, when it was fetched
    public init(sent: Set<String> = [], present: Set<String> = [], bytes: Int64? = nil) {
        self.sent = sent; self.present = present; self.bytes = bytes
    }
}

/// Where a run is: `preparing` = enumerate + reconcile (nothing settles by design — the dashboard must not
/// read that as a stall), `transferring` = the worker pool is draining.
public enum BackfillStage: Sendable, Equatable { case preparing, transferring }

/// A source the engine can drive **generically**. Every lane (Photos, Documents, and future ones) provides
/// one, so the machinery — ledger, exclusions, capacity, concurrency, ETA, quarantine — is written once.
public protocol BackfillSource: Sendable {
    var id: SourceID { get }
    /// Every item currently at the source. The engine applies `ExclusionRules` to each `relativePath`.
    func enumerateItems() async throws -> [BackfillEntry]
    /// Materialize + upload ONE item to the sovereign target(s). Throwing routes it to retry, then quarantine.
    func process(_ entry: BackfillEntry) async throws
    /// Targets to capacity-check before transferring (each assumed to receive the full backlog).
    func capacityTargets() -> [BackfillTarget]
    /// RECONCILE before transferring: which of these entries are already on every target? Sources answer with
    /// one listing per server folder (not one request per file), so a fresh Mac confirms a mirrored tree in
    /// minutes instead of days. Default: nothing known.
    func alreadyPresent(_ entries: [BackfillEntry]) async -> Set<String>
    /// Fan-out lanes: the targets by display name ("Immich", "Nextcloud"). Empty = one target, no per-target view.
    func targetNames() -> [String]
    /// Fan-out reconcile: per target, which entries it already holds. A target that cannot be listed is left out.
    func alreadyPresentPerTarget(_ entries: [BackfillEntry]) async -> [String: Set<String>]
    /// Fan-out process: send to every target NOT in `skipping` (the ledger knows those already hold it) and
    /// say what happened per target. nil = this source has no per-target view (it used `process(_:)`).
    func process(_ entry: BackfillEntry, skipping: Set<String>) async throws -> TargetOutcome?
    /// Items the source has not finished producing (Mail's part-downloaded messages). nil = not applicable.
    var deferredAtSource: DeferredAtSource? { get }
}

public extension BackfillSource {
    var deferredAtSource: DeferredAtSource? { nil }
    func alreadyPresent(_ entries: [BackfillEntry]) async -> Set<String> { [] }
    func targetNames() -> [String] { [] }
    func alreadyPresentPerTarget(_ entries: [BackfillEntry]) async -> [String: Set<String>] { [:] }
    func process(_ entry: BackfillEntry, skipping: Set<String>) async throws -> TargetOutcome? { try await process(entry); return nil }
}

public struct BackfillConfig: Sendable {
    public var concurrency: Int = 3
    public var maxAttempts: Int = 4
    public var capacityThreshold: Double = 0.85
    public init(concurrency: Int = 3, maxAttempts: Int = 4, capacityThreshold: Double = 0.85) {
        self.concurrency = concurrency; self.maxAttempts = maxAttempts; self.capacityThreshold = capacityThreshold
    }
}

/// Smoothed transfer rate (EWMA over file completions) → drives the ETA. Crude but stable enough for a
/// human-facing estimate; refined windowing can come later.
final class ThroughputMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var rate = 0.0
    private var last: Date?
    private let alpha = 0.2
    func record(bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let last {
            let dt = now.timeIntervalSince(last)
            if dt > 0.001 { let inst = Double(bytes) / dt; rate = (rate == 0) ? inst : alpha * inst + (1 - alpha) * rate }
        }
        last = now
    }
    var bytesPerSec: Double { lock.lock(); defer { lock.unlock() }; return rate }
}

/// Turns the ledger into a live, resumable backfill: enumerate → exclude → capacity preflight → bounded
/// upload pool → quarantine-on-give-up → progress/ETA heartbeats. Source-agnostic; one instance per job.
public final class BackfillEngine: @unchecked Sendable {
    public let ledger: BackfillLedger
    /// Structured progress for the backfill panel: (rolled-up progress, current bytes/sec, latest item label).
    /// Set before `run()`. Separate from the coarse `Heartbeat` the tile already consumes.
    public var onProgress: (@Sendable (BackfillProgress, Double, String, BackfillStage) -> Void)?
    /// Fired when a target trips the capacity gate (tight or won't-fit), so the UI can show the warning/block
    /// card; fired with `nil` when the preflight passes, to clear a stale warning.
    public var onCapacity: (@Sendable (CapacityReport?) -> Void)?
    public var sourceID: SourceID { source.id }
    private let source: BackfillSource
    private let exclusions: ExclusionRules
    private let config: BackfillConfig
    private let heartbeat: @Sendable (Heartbeat) -> Void
    private let meter = ThroughputMeter()
    private let lock = NSLock()
    private var paused = false
    private var stopRequested = false
    private var entries: [String: BackfillEntry] = [:]
    private var failStreak = 0          // consecutive failures across workers — a burst means the *source* is down, not the items
    private var stage: BackfillStage = .preparing
    private var targetNames: [String] { source.targetNames() }
    private func progress() throws -> BackfillProgress {
        var p = try ledger.progress(targets: targetNames)
        p.deferred = source.deferredAtSource
        return p
    }
    /// Quarantined rows older than this get another go at the start of a run (see `retryQuarantined(olderThan:)`).
    public static let quarantineRetryAfter: TimeInterval = 24 * 3600

    public init(source: BackfillSource, ledger: BackfillLedger, exclusions: ExclusionRules = ExclusionRules(),
                config: BackfillConfig = BackfillConfig(), heartbeat: @escaping @Sendable (Heartbeat) -> Void) {
        self.source = source; self.ledger = ledger; self.exclusions = exclusions
        self.config = config; self.heartbeat = heartbeat
    }

    public func pause()  { lock.lock(); paused = true; lock.unlock() }
    public func resume() { lock.lock(); paused = false; lock.unlock() }
    public func stop()   { lock.lock(); stopRequested = true; lock.unlock() }
    private var isPaused: Bool  { lock.lock(); defer { lock.unlock() }; return paused }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopRequested }

    /// Enumerate → capacity preflight → drain, resuming automatically from the ledger. `confirmTight` proceeds
    /// past a >threshold warning (the UI's "back up anyway"); a won't-fit target always aborts before transfer.
    @discardableResult
    public func run(confirmTight: Bool = false) async -> BackfillProgress {
        do {
            try ledger.recoverInterrupted()
            if let n = try? ledger.retryQuarantined(olderThan: Self.quarantineRetryAfter), n > 0 {
                emit(.syncing, "retrying \(n) that couldn't be transferred")
            }

            // 1 · enumerate through exclusions → ledger
            emit(.syncing, "scanning \(source.id.displayName)…")
            let all = try await source.enumerateItems()
            let kept = all.filter { !exclusions.excludes($0.relativePath) }
            lock.lock(); entries = Dictionary(kept.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a }); lock.unlock()
            try ledger.addDiscovered(kept.map { (key: $0.key, bytes: $0.bytes, hash: $0.contentHash) })
            let keptBefore = (try? ledger.markPresence(kept.map(\.key))) ?? 0
            var prog = try progress()
            emit(.syncing, "found \(kept.count) items · \(all.count - kept.count) excluded" + (keptBefore > 0 ? " · \(keptBefore) kept from before" : ""), prog)
            // 1b · reconcile: what is already on the server (previous relay, another Mac) — skipped, not sent.
            // A fan-out lane reconciles PER TARGET: Immich may hold the whole library while Nextcloud holds
            // half, and an item is only "already there" when every target has it — but each target's own
            // share is recorded, so the workers skip the targets that have it and the card shows both bars.
            // Only the rows the ledger still has as PENDING are asked about: a reconcile never changes a settled
            // row (`markSkippedIfPending`, and `markTargetPresent` never downgrades `done`), so listing the server
            // for the 175,000 Drive files already done was ~14,000 PROPFINDs every 15 minutes for nothing — the
            // card sat on "Scanning" six minutes in every twenty (2026-10-18). Idle lane → no network at all.
            let names = targetNames
            if names.count > 1 { try ledger.seedTargetsForSettled(names) }
            let pendingKeys = try ledger.pendingKeys()
            let toCheck = kept.filter { pendingKeys.contains($0.key) }
            var present = Set<String>()
            if toCheck.isEmpty {
                emit(.syncing, "reconcile: nothing new to check", prog)
            } else {
                let perTarget = names.count > 1 ? await source.alreadyPresentPerTarget(toCheck) : [:]
                if perTarget.isEmpty {
                    present = await source.alreadyPresent(toCheck)
                } else {
                    present = Set(toCheck.map(\.key))
                    var summary: [String] = []
                    for n in names {
                        if let keys = perTarget[n] {
                            try ledger.markTargetPresent(Array(keys), target: n)
                            present.formIntersection(keys)
                            summary.append("\(n): \(keys.count) of \(toCheck.count) new already there")
                        } else { present = []; summary.append("\(n): could not list") }
                    }
                    emit(.syncing, summary.joined(separator: " · "), try? progress())
                }
                if !present.isEmpty { try ledger.markSkippedIfPending(Array(present)); prog = try progress() }
                emit(.syncing, "reconcile: \(present.count) already there · \(prog.pending) to send", prog)
            }

            // 2 · capacity preflight (per target; block on won't-fit, warn on tight)
            for t in source.capacityTargets() {
                let storage = try await t.storage()
                let stored = await t.alreadyStored(totalBytes: prog.remainingBytes, count: kept.count)
                let addBytes = max(0, prog.remainingBytes - stored)
                if stored > 0 { emit(.syncing, "\(t.label): \(Self.bytes(stored)) already there — \(Self.bytes(addBytes)) to add", prog) }
                let verdict = CapacityCheck.evaluate(storage: storage, addBytes: addBytes, threshold: config.capacityThreshold)
                let report = CapacityReport(targetLabel: t.label, verdict: verdict, storage: storage, addBytes: addBytes)
                switch verdict {
                case .wontFit(let shortBy):
                    onCapacity?(report)
                    emit(.error, "\(t.label): not enough space — short by \(Self.bytes(shortBy))", prog)
                    return prog
                case .tight(let frac):
                    guard confirmTight else {
                        onCapacity?(report)
                        emit(.stale, "\(t.label) would be \(pct(frac)) full — confirm to back up anyway", prog)
                        return prog
                    }
                    emit(.syncing, "\(t.label): proceeding at \(pct(frac)) full", prog)
                case .ok:
                    break
                }
            }
            onCapacity?(nil)   // preflight passed — clear any stale warning

            // 3 · drain with bounded concurrency
            lock.lock(); stage = .transferring; lock.unlock()
            emit(.syncing, "sending what is missing", prog)
            let finished = await drain()
            prog = try progress()
            guard finished else {                       // paused or stopped — don't claim completion
                emit(.syncing, isStopped ? "stopped" : "paused", prog)
                return prog
            }
            let msg = prog.hasUnreadable
                ? "backfill complete · \(prog.settled) backed up, \(prog.quarantined) couldn't be read"
                : "backfill complete · \(prog.settled) items"
            emit(.healthy, msg, prog)
            return prog
        } catch {
            let prog = (try? progress()) ?? BackfillProgress()
            emit(.error, "backfill error: \(error)", prog)
            return prog
        }
    }

    /// Returns true if it drained to completion, false if interrupted by pause/stop.
    private func drain() async -> Bool {
        while !isStopped {
            if isPaused { return false }
            var batch = (try? ledger.claim(limit: config.concurrency)) ?? []
            if batch.isEmpty {
                try? ledger.requeueFailed()                    // give transient failures another attempt
                batch = (try? ledger.claim(limit: config.concurrency)) ?? []
                if batch.isEmpty { return true }               // truly nothing left to do
            }
            await withTaskGroup(of: Void.self) { group in
                for item in batch { group.addTask { [self] in await handle(item) } }
            }
            // Brake: when every item fails on arrival (PhotoKit returning "internal error" for four minutes,
            // the server gone, iCloud wedged) the pool would otherwise race through thousands of items, each
            // burning one of its few attempts on a failure that was never about the item. Pause the lane for
            // a growing moment instead; any success resets it.
            lock.lock(); let streak = failStreak; lock.unlock()
            if streak >= Self.brakeAfter {
                let steps = streak / Self.brakeAfter
                let wait = min(120.0, 15.0 * pow(2.0, Double(steps - 1)))
                emit(.syncing, "\(streak) failures in a row — pausing \(Int(wait)) s before the next one", try? progress())
                let until = Date().addingTimeInterval(wait)
                while Date() < until, !isStopped, !isPaused { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        return false                                           // stopped
    }
    static let brakeAfter = 6

    /// Thrown by a source's `process` when the item is ALREADY on every target (a previous relay, another
    /// Mac, server dedup). Recorded as `skipped`, not `done`: the card then says "already there" and the
    /// transfer meter stays honest — nothing was moved.
    public struct AlreadyOnTarget: Error, Sendable { public init() {} }

    private func handle(_ item: BackfillItem) async {
        lock.lock(); let entry = entries[item.key]; lock.unlock()
        guard let entry else { try? ledger.markSkipped(item.key); return }   // no longer at source
        try? ledger.markUploading(item.key)
        let have = (try? ledger.targetsHolding(item.key)) ?? []
        do {
            if let o = try await source.process(entry, skipping: have) {
                // Fan-out lane: record each target's share; the item itself is done only if something moved.
                try? ledger.markTargets(item.key, present: o.present, sent: o.sent)
                if o.sent.isEmpty { try? ledger.markSkipped(item.key) }
                else { try? ledger.markDone(item.key, actualBytes: o.bytes); meter.record(bytes: o.bytes ?? entry.bytes) }
                lock.lock(); failStreak = 0; lock.unlock()
                emit(.syncing, line(for: entry, outcome: o, holding: have), try? progress())
                return
            }
            try? ledger.markDone(item.key)
            meter.record(bytes: entry.bytes)
            lock.lock(); failStreak = 0; lock.unlock()
        } catch is AlreadyOnTarget {
            try? ledger.markSkipped(item.key)
            lock.lock(); failStreak = 0; lock.unlock()
        } catch {
            try? ledger.markFailed(item.key, error: "\(error)", maxAttempts: config.maxAttempts)
            lock.lock(); failStreak += 1; lock.unlock()
        }
        emit(.syncing, line(for: entry), try? progress())
    }

    /// Fan-out: name the targets that received it ("→ Nextcloud"), or say where it already was.
    private func line(for entry: BackfillEntry, outcome o: TargetOutcome, holding: Set<String>) -> String {
        if !o.sent.isEmpty { return "\(entry.relativePath) → \(o.sent.sorted().joined(separator: ", "))" }
        let on = o.present.union(holding).sorted()
        return on.isEmpty ? "\(entry.relativePath) · no longer in the library" : "\(entry.relativePath) · already on \(on.joined(separator: ", "))"
    }

    private func line(for entry: BackfillEntry) -> String {
        // The "→" marks a concrete mirror action: the dashboard's activity graph and "mirrored this session"
        // counter register these. No rate or ETA here: the card already shows both, and a bytes-only estimate
        // on this line sat next to the card's (item-bound) estimate as two different numbers for one lane.
        "\(entry.relativePath) → your storage"
    }

    private func emit(_ status: SourceStatus, _ item: String, _ prog: BackfillProgress? = nil) {
        let p = prog ?? (try? progress())
        lock.lock(); let st = stage; lock.unlock()
        if let p { onProgress?(p, meter.bytesPerSec, item, st) }
        heartbeat(Heartbeat(source: source.id, status: status, lastItem: item,
                            pendingCount: (p?.pending ?? 0) + (p?.inFlight ?? 0), itemCount: p?.total))
    }

    private func pct(_ f: Double) -> String { "\(Int((f * 100).rounded()))%" }

    static func bytes(_ n: Int64) -> String {
        let u = ["B", "KB", "MB", "GB", "TB"]; var v = Double(n); var i = 0
        while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }    // decimal, like Finder / Nextcloud / the iPhone app
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, u[i])
    }
    static func duration(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "—" }
        let m = Int(s / 60), h = m / 60
        if h > 0 { return "\(h)h \(m % 60)m" }
        if m > 0 { return "\(m)m" }
        return "\(Int(s))s"
    }
}
