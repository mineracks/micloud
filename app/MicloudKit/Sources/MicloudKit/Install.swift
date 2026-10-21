import Foundation

/// The persisted, **non-secret** record of one micloud install: has the user finished onboarding, which
/// backend did they choose, and the endpoint URLs. Secrets (the sovereign key, the Nextcloud app-password)
/// live in `SovereignStore`, never here — so this is safe to write as plain JSON under Application Support.
public struct Install: Codable, Equatable, Sendable {
    public enum Backend: String, Codable, Sendable {
        case none       // not chosen yet
        case diy        // user's own Nextcloud / Immich
        case hosted     // mineracks-hosted trial LXC
    }

    public var onboarded: Bool
    public var backend: Backend
    public var nextcloudURL: String?
    public var nextcloudUser: String?
    public var immichURL: String?
    /// Set when `backend == .hosted`: when the free trial LXC is torn down unless the user pays.
    public var trialExpires: Date?
    /// Has the user written down their recovery phrase? Onboarding lets them defer this (value first); the
    /// dashboard nudges until it's true. Defaults true when decoding older records that predate the field.
    public var recoveryBackedUp: Bool
    /// Monitor mode: this Mac does not sync anything — it signs in to the same Nextcloud and renders the
    /// dashboard another Mac publishes there (`micloud/status.json`). Nil/false = a normal, syncing install.
    public var monitor: Bool?

    public init(onboarded: Bool = false, backend: Backend = .none,
                nextcloudURL: String? = nil, nextcloudUser: String? = nil,
                immichURL: String? = nil, trialExpires: Date? = nil, recoveryBackedUp: Bool = true,
                monitor: Bool? = nil) {
        self.onboarded = onboarded; self.backend = backend
        self.nextcloudURL = nextcloudURL; self.nextcloudUser = nextcloudUser
        self.immichURL = immichURL; self.trialExpires = trialExpires
        self.recoveryBackedUp = recoveryBackedUp; self.monitor = monitor
    }
    public var isMonitor: Bool { monitor == true }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onboarded = try c.decode(Bool.self, forKey: .onboarded)
        backend = try c.decode(Backend.self, forKey: .backend)
        nextcloudURL = try c.decodeIfPresent(String.self, forKey: .nextcloudURL)
        nextcloudUser = try c.decodeIfPresent(String.self, forKey: .nextcloudUser)
        immichURL = try c.decodeIfPresent(String.self, forKey: .immichURL)
        trialExpires = try c.decodeIfPresent(Date.self, forKey: .trialExpires)
        recoveryBackedUp = try c.decodeIfPresent(Bool.self, forKey: .recoveryBackedUp) ?? true
        monitor = try c.decodeIfPresent(Bool.self, forKey: .monitor)
    }
}

/// How much of each source to back up. The hosted 24h trial caps the *heavy* types (photos/files) to a
/// recent slice — a fast, low-exposure taste that also drives the "back up everything" upsell — while the
/// light types (calendars/contacts/notes/reminders) stay complete, since a truncated address book or
/// calendar looks broken and they're cheap. DIY / paid installs are uncapped (`.full`).
public struct SyncCaps: Sendable, Equatable {
    public let photos: Int          // 0 = unlimited
    public let documents: Int
    public init(photos: Int, documents: Int) { self.photos = photos; self.documents = documents }
    public static let full  = SyncCaps(photos: 0, documents: 0)
    public static let trial = SyncCaps(photos: 100, documents: 50)   // newest-N by recency; light types stay full
    public static func forBackend(_ b: Install.Backend) -> SyncCaps { b == .hosted ? .trial : .full }
}

/// Loads/saves the `Install` record at `Application Support/micloud/install.json`.
public enum InstallStore {
    public static var url: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("micloud", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("install.json")
    }

    public static func load() -> Install {
        guard let data = try? Data(contentsOf: url),
              let install = try? JSONDecoder.iso.decode(Install.self, from: data) else { return Install() }
        return install
    }

    public static func save(_ install: Install) {
        if let data = try? JSONEncoder.isoPretty.encode(install) { try? data.write(to: url, options: .atomic) }
    }
}

extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
extension JSONEncoder { static var isoPretty: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }
