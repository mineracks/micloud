import Foundation

/// A target's disk situation, from its own API. `totalBytes == 0` means "unknown / unlimited" (e.g. a
/// Nextcloud with no quota) — the capacity gate treats that as pass, since it can't warn without numbers.
public struct TargetStorage: Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public init(totalBytes: Int64, usedBytes: Int64) { self.totalBytes = totalBytes; self.usedBytes = usedBytes }
    public var freeBytes: Int64 { max(0, totalBytes - usedBytes) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    public var isKnown: Bool { totalBytes > 0 }
}

/// The preflight verdict for one target: proceed, warn-but-fits, or won't-fit (block).
public enum CapacityVerdict: Sendable, Equatable {
    case ok(projectedFraction: Double)
    case tight(projectedFraction: Double)   // over the threshold but it fits → warn + "back up anyway"
    case wontFit(shortBy: Int64)            // block; micloud won't start a sync it can't finish
}

public enum CapacityCheck {
    /// Evaluate adding `addBytes` to a target. Unknown/unlimited storage → `.ok`. Won't fit → `.wontFit`.
    /// Otherwise `.tight` if the projected used fraction exceeds `threshold`, else `.ok`.
    public static func evaluate(storage: TargetStorage, addBytes: Int64, threshold: Double = 0.85) -> CapacityVerdict {
        guard storage.isKnown else { return .ok(projectedFraction: 0) }
        let projected = storage.usedBytes + addBytes
        if projected > storage.totalBytes { return .wontFit(shortBy: projected - storage.totalBytes) }
        let frac = Double(projected) / Double(storage.totalBytes)
        return frac > threshold ? .tight(projectedFraction: frac) : .ok(projectedFraction: frac)
    }
}

/// The preflight result for one target, surfaced to the UI so it can render the warning / block card.
public struct CapacityReport: Sendable, Equatable {
    public let targetLabel: String
    public let verdict: CapacityVerdict
    public let storage: TargetStorage
    public let addBytes: Int64
    public init(targetLabel: String, verdict: CapacityVerdict, storage: TargetStorage, addBytes: Int64) {
        self.targetLabel = targetLabel; self.verdict = verdict; self.storage = storage; self.addBytes = addBytes
    }
    public var projectedUsedBytes: Int64 { storage.usedBytes + addBytes }
}

/// A sovereign destination the backfill can capacity-check before transferring. `storage()` is defined on
/// each concrete client (where it can reach its own auth/session); this just unifies them for the engine.
public protocol BackfillTarget: Sendable {
    var label: String { get }
    func storage() async throws -> TargetStorage
    /// How much of a backlog of `totalBytes` / `count` items is ALREADY on this target (a previous relay,
    /// another Mac, the server's own dedup). The preflight subtracts it, so a fresh ledger on a new machine
    /// does not read as "needs the whole library again". Default: nothing known → 0.
    func alreadyStored(totalBytes: Int64, count: Int) async -> Int64
}
public extension BackfillTarget {
    func alreadyStored(totalBytes: Int64, count: Int) async -> Int64 { 0 }
}

extension NextcloudWebDAV: BackfillTarget {
    public var label: String { "nextcloud" }
}
/// Nextcloud seen from ONE destination folder: what is already stored under it counts against the backlog.
public struct NextcloudFolderTarget: BackfillTarget {
    public let dav: NextcloudWebDAV
    public let path: String
    public init(dav: NextcloudWebDAV, path: String) { self.dav = dav; self.path = path }
    public var label: String { "nextcloud" }
    public func storage() async throws -> TargetStorage { try await dav.storage() }
    public func alreadyStored(totalBytes: Int64, count: Int) async -> Int64 { min(totalBytes, await dav.folderBytes(path)) }
}
extension ImmichClient: BackfillTarget {   // label + storage() come from its own file
    /// Immich dedups by checksum at upload, so what it already holds costs nothing. Estimate by count:
    /// `GET /api/assets/statistics` (this user's assets) against the library size.
    public func alreadyStored(totalBytes: Int64, count: Int) async -> Int64 {
        guard count > 0, let have = try? await assetCount() else { return 0 }
        return Int64(Double(totalBytes) * min(1, Double(have) / Double(count)))
    }
}
