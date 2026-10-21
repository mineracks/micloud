import Foundation

/// Health of one source, shown on the in-app dashboard and (for turnkey) pushed to Loki.
public enum SourceStatus: String, Codable, Sendable {
    case healthy       // synced recently, nothing pending
    case syncing       // actively mirroring
    case stale         // no heartbeat within the expected window
    case error         // last attempt failed
    case disabled      // component turned off for this instance
}

/// A point-in-time heartbeat for one source. The engine writes these to a local sink the
/// dashboard reads directly (a self-host user needs no Grafana/Loki), and optionally forwards
/// each to Loki for turnkey fleet monitoring.
public struct Heartbeat: Codable, Equatable, Sendable {
    public var source: SourceID
    public var status: SourceStatus
    public var timestamp: Date
    public var lastItem: String?        // human label of the most recent item mirrored
    public var pendingCount: Int        // items queued / awaiting upload
    public var itemCount: Int?          // total items at this source (e.g. photo-library size); nil if N/A
    public var cacheBytes: Int64?       // thin-cache footprint on this Mac (Drive); nil if N/A

    public init(source: SourceID, status: SourceStatus, timestamp: Date = Date(),
                lastItem: String? = nil, pendingCount: Int = 0, itemCount: Int? = nil, cacheBytes: Int64? = nil) {
        self.source = source; self.status = status; self.timestamp = timestamp
        self.lastItem = lastItem; self.pendingCount = pendingCount
        self.itemCount = itemCount; self.cacheBytes = cacheBytes
    }
}

/// The latest heartbeat per source, rolled into the snapshot the dashboard renders.
public struct HealthSnapshot: Codable, Equatable, Sendable {
    public var heartbeats: [SourceID: Heartbeat]
    public var generatedAt: Date

    public init(heartbeats: [SourceID: Heartbeat] = [:], generatedAt: Date = Date()) {
        self.heartbeats = heartbeats; self.generatedAt = generatedAt
    }

    /// Fold in a heartbeat, keeping only the most recent per source.
    public mutating func record(_ hb: Heartbeat) {
        if let existing = heartbeats[hb.source], existing.timestamp > hb.timestamp { return }
        heartbeats[hb.source] = hb
        generatedAt = Date()
    }

    /// Overall status = the worst active source. Drives the single "everything's protected" pill.
    public var overall: SourceStatus {
        let active = heartbeats.values.map(\.status).filter { $0 != .disabled }
        if active.contains(.error)   { return .error }
        if active.contains(.stale)   { return .stale }
        if active.contains(.syncing) { return .syncing }
        return active.isEmpty ? .disabled : .healthy
    }

    /// True when a heartbeat is older than `window` — the staleness rule the dashboard + alerts share.
    public func isStale(_ id: SourceID, window: TimeInterval, now: Date = Date()) -> Bool {
        guard let hb = heartbeats[id] else { return true }
        return now.timeIntervalSince(hb.timestamp) > window
    }
}
