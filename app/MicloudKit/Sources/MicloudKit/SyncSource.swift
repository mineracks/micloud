import Foundation

/// The iCloud surfaces micloud mirrors. Each maps to a native `SyncSource` in the app
/// (the agent's per-component scripts are the reference spec) and to a telemetry stream.
/// `CodingKeyRepresentable` so `[SourceID: …]` encodes as a JSON object keyed by lane name (status.json is read
/// by the iPhone app and by Macs in monitor mode, and by people); without it Swift writes a flat
/// [key, value, key, value…] array.
public enum SourceID: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case photos, documents, calendars, contacts, reminders, notes, bookmarks, mail, health, messages

    public var displayName: String {
        switch self {
        case .photos:    return "Photos"
        case .documents: return "Files"
        case .calendars: return "Calendars"
        case .contacts:  return "Contacts"
        case .reminders: return "Reminders"
        case .notes:     return "Notes"
        case .bookmarks: return "Bookmarks"
        case .mail:      return "Mail"
        case .health:    return "Health"
        case .messages:  return "Messages"
        }
    }

    /// Sources that can only ship in the notarized power build ("micloud pro edition") — they need Full
    /// Disk Access / Automation / an iOS companion, which the sandboxed App Store app can't use.
    public var isProOnly: Bool {
        switch self { case .notes, .bookmarks, .mail, .health, .messages: return true; default: return false }
    }
}

/// A single change observed at a source, to be mirrored to the sovereign target.
public struct SyncEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case upsert, delete }
    public let source: SourceID
    public let kind: Kind
    public let identifier: String        // stable id: asset localIdentifier, file path, event id…
    public let detectedAt: Date
    public init(source: SourceID, kind: Kind, identifier: String, detectedAt: Date = Date()) {
        self.source = source; self.kind = kind; self.identifier = identifier; self.detectedAt = detectedAt
    }
}

/// One-way mirror of a single iCloud surface to the sovereign copy.
///
/// Concrete implementations are framework-native and event-driven (PhotoKit change observer,
/// EventKit, FSEvents/NSMetadataQuery…). MicloudKit defines the *contract*; the concrete sources
/// need Apple frameworks + entitlements, so they live in the app target, not in this portable core.
///
/// Contract invariants (from the agent reference spec — non-negotiable):
///   • **One-way** — a source never writes to, changes, or deletes anything in iCloud.
///   • Deletes are **soft** — routed to a dated trash on the sovereign target, never hard-removed.
public protocol SyncSource: AnyObject, Sendable {
    var id: SourceID { get }
    /// Begin observing changes and mirroring them; returns once observation is established.
    func start() async throws
    /// Stop observing; in-flight uploads are allowed to finish.
    func stop() async
    /// Force a full reconciliation pass (the mop-up timer + the dashboard's "Sync now").
    func reconcile() async throws
}
