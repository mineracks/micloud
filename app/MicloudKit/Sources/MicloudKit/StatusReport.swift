import Foundation

/// The small JSON the Mac publishes to the user's OWN Nextcloud so the iOS companion can check in on the
/// sync from anywhere — no micloud-central server, the status lives on the user's infrastructure.
/// Written to `micloud/status.json` on the sovereign target.
public struct StatusReport: Codable, Sendable, Equatable {
    public var host: String            // which Mac
    public var appVersion: String
    public var generatedAt: Date
    public var overall: SourceStatus   // the single "everything's protected" signal
    public var snapshot: HealthSnapshot // per-source heartbeats (status / lastItem / counts / timestamps)
    /// Per-lane backfill progress — what the Mac's dashboard cards show (files, bytes, "already there",
    /// speed, ETA, phase). Optional so a report from an older Mac still decodes.
    public var lanes: [SourceID: LaneReport]?
    /// Items/second over the last 60 s, oldest first — the activity graph.
    public var activity: [Double]?
    /// The most recent heartbeats, newest first — the live sync log.
    public var events: [Heartbeat]?
    /// How often the Mac is republishing right now (seconds) — a reader polls at this cadence.
    public var refreshSeconds: Double?
    /// Items mirrored since local midnight on the publishing Mac (survives its restarts) — the hero stat.
    public var mirroredToday: Int?

    public init(host: String, appVersion: String, generatedAt: Date = Date(), snapshot: HealthSnapshot,
                lanes: [SourceID: LaneReport]? = nil, activity: [Double]? = nil, events: [Heartbeat]? = nil,
                refreshSeconds: Double? = nil, mirroredToday: Int? = nil) {
        self.mirroredToday = mirroredToday
        self.host = host; self.appVersion = appVersion; self.generatedAt = generatedAt
        self.overall = snapshot.overall; self.snapshot = snapshot
        self.lanes = lanes; self.activity = activity; self.events = events; self.refreshSeconds = refreshSeconds
    }

    public static let remotePath = "micloud/status.json"

    /// Is the Mac still publishing? Two missed refresh windows (minimum 90 s) and the reader should say so.
    public var isFresh: Bool { Date().timeIntervalSince(generatedAt) < max(90, (refreshSeconds ?? 30) * 3) }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }
    public static func decode(_ data: Data) throws -> StatusReport {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(StatusReport.self, from: data)
    }

    /// Publish to the sovereign target (idempotent overwrite via WebDAV PUT).
    public func publish(via dav: NextcloudWebDAV) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-status-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try encoded().write(to: tmp)
        try await dav.ensureParents(of: Self.remotePath)
        try await dav.upload(localFile: tmp, to: Self.remotePath)
    }
}

/// One fan-out target's share of a lane. Immich and Nextcloud hold different fractions of the same photo
/// library (2026-10-15: Immich ≈ 100 %, Nextcloud 44 %), and a single bar could not say which was which.
public struct TargetProgress: Codable, Sendable, Equatable {
    public var name: String          // "Immich", "Nextcloud"
    public var settled: Int          // items this target holds — found there at reconcile, or sent by this Mac
    public var sent: Int             // of those, uploaded by this Mac
    public var settledBytes: Int64   // ledger (estimated) bytes of the settled items
    public init(name: String, settled: Int, sent: Int, settledBytes: Int64) {
        self.name = name; self.settled = settled; self.sent = sent; self.settledBytes = settledBytes
    }
}

/// One backfill lane as the Mac's dashboard sees it. Mirrors `BackfillJob` + `BackfillProgress` in the Mac app
/// closely enough that a remote dashboard (the iPhone app, or a Mac in monitor mode) renders the same card
/// with the same numbers — including the honest item-rate ETA.
/// Items the source itself has not finished producing — Mail messages it has only partly downloaded, for one.
/// Not pending (there is nothing to send yet) and not excluded (the user wants them): the card says what the
/// backup is waiting on instead of reading "Up to date" over 80,000 messages that are not in it (2026-10-19).
public struct DeferredAtSource: Codable, Sendable, Equatable {
    public let count: Int
    public let reason: String   // follows the number, lower-case: "waiting for Mail to download them"
    public init(count: Int, reason: String) { self.count = count; self.reason = reason }
}

public struct LaneReport: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case scanning, transferring, paused, done, blocked, stopped }
    public var phase: Phase
    public var total: Int, done: Int, skipped: Int, failed: Int, pending: Int, inFlight: Int, quarantined: Int
    public var totalBytes: Int64, confirmedBytes: Int64, quarantinedBytes: Int64
    public var rate: Double          // bytes/s (EWMA)
    public var itemRate: Double      // items/s (EWMA)
    public var etaSeconds: Double?   // nil = not measurable yet
    public var lastItem: String
    public var capacityNote: String? // set when the target tripped the capacity gate
    public var stalled: Bool?        // transferring, but nothing settled for 2 min (the publisher's clock)
    /// Per-target share when the lane fans out to more than one (photos → Immich + Nextcloud); absent otherwise.
    public var targets: [TargetProgress]?
    /// Items no longer at the source but still in the sovereign copy (the backup never deletes). Not in `total`.
    public var kept: Int?
    /// Items the source has not finished producing (see `DeferredAtSource`).
    public var deferred: DeferredAtSource?

    public init(phase: Phase, total: Int, done: Int, skipped: Int, failed: Int, pending: Int, inFlight: Int, quarantined: Int,
                totalBytes: Int64, confirmedBytes: Int64, quarantinedBytes: Int64, rate: Double, itemRate: Double,
                etaSeconds: Double?, lastItem: String, capacityNote: String? = nil, stalled: Bool? = nil,
                targets: [TargetProgress]? = nil, kept: Int? = nil, deferred: DeferredAtSource? = nil) {
        self.kept = kept; self.deferred = deferred
        self.phase = phase; self.total = total; self.done = done; self.skipped = skipped; self.failed = failed
        self.pending = pending; self.inFlight = inFlight; self.quarantined = quarantined
        self.totalBytes = totalBytes; self.confirmedBytes = confirmedBytes; self.quarantinedBytes = quarantinedBytes
        self.rate = rate; self.itemRate = itemRate; self.etaSeconds = etaSeconds; self.lastItem = lastItem
        self.capacityNote = capacityNote; self.stalled = stalled; self.targets = targets
    }

    public var settled: Int { done + skipped }
    public var remainingBytes: Int64 { max(0, totalBytes - confirmedBytes - quarantinedBytes) }
    /// Same rule as the Mac card: byte-weighted, (confirmed + given-up) / total, 1.0 when nothing is left to try.
    public var fraction: Double {
        guard totalBytes > 0 else { return phase == .done ? 1 : 0 }
        return min(1, Double(confirmedBytes + quarantinedBytes) / Double(totalBytes))
    }
    public var isActive: Bool { phase == .scanning || phase == .transferring }
}
