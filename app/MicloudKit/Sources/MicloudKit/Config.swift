import Foundation

/// The single per-instance configuration surface for a micloud install.
///
/// This is the native re-modelling of the agent's `config.env` (Phase 1). Two deliberate
/// differences, because the App Store build is sandboxed and framework-native:
///   • Sovereign targets are **direct endpoints** (Nextcloud WebDAV URL, Immich URL), not
///     rclone remote names — uploads go via `URLSession`, not a bundled CLI.
///   • **Secrets never live here.** The Nextcloud app-password and Immich API key live in the
///     Keychain, referenced by account; this struct is safe to persist as plain JSON.
public struct MicloudConfig: Codable, Equatable, Sendable {

    // ── Identity & telemetry ────────────────────────────────────────────────
    /// Instance id — becomes the telemetry `instance` label for fleet monitoring.
    public var instance: String
    /// Host label for this box (telemetry `host` label).
    public var hostLabel: String
    /// Loki push endpoint for fleet heartbeats; `nil` disables remote push entirely
    /// (a self-host user runs no Grafana/Loki — the in-app dashboard reads local state instead).
    public var telemetryLokiURL: URL?

    // ── Sovereign targets ───────────────────────────────────────────────────
    public var nextcloud: NextcloudTarget?
    public var immich: ImmichTarget?

    // ── Components ──────────────────────────────────────────────────────────
    public var components: Components

    public init(instance: String = "default",
                hostLabel: String = "default",
                telemetryLokiURL: URL? = nil,
                nextcloud: NextcloudTarget? = nil,
                immich: ImmichTarget? = nil,
                components: Components = Components()) {
        self.instance = instance
        self.hostLabel = hostLabel
        self.telemetryLokiURL = telemetryLokiURL
        self.nextcloud = nextcloud
        self.immich = immich
        self.components = components
    }

    /// Nextcloud (Drive / Documents / DAV target). WebDAV over `URLSession`.
    /// Password is stored in the Keychain under `account = username`, not here.
    public struct NextcloudTarget: Codable, Equatable, Sendable {
        public var baseURL: URL                 // https://nc.example.com
        public var username: String
        public var documentsPath: String        // e.g. "Documents"
        public var photosPath: String           // NC folder the Photos app indexes, e.g. "Photos/iCloud-Camera"
        public var trashPath: String            // soft-delete destination, e.g. ".trash/deltasync"

        public init(baseURL: URL, username: String,
                    documentsPath: String = "micloud/Documents",
                    photosPath: String = "micloud/Photos",
                    trashPath: String = "micloud/.trash") {
            self.baseURL = baseURL; self.username = username
            self.documentsPath = documentsPath; self.photosPath = photosPath; self.trashPath = trashPath
        }

        /// WebDAV files root for this user: `<base>/remote.php/dav/files/<user>/`.
        public var webdavFilesRoot: URL {
            baseURL.appendingPathComponent("remote.php/dav/files").appendingPathComponent(username)
        }
    }

    /// Immich (Photos target). API key in the Keychain under `account = baseURL host`.
    public struct ImmichTarget: Codable, Equatable, Sendable {
        public var baseURL: URL                 // https://immich.example.com
        public init(baseURL: URL) { self.baseURL = baseURL }
        /// Immich API root: `<base>/api`.
        public var apiRoot: URL { baseURL.appendingPathComponent("api") }
    }

    /// Which iCloud surfaces this instance mirrors, and where each goes.
    public struct Components: Codable, Equatable, Sendable {
        public var photos: PhotosComponent
        public var documents: Bool              // iCloud Drive + ~/Documents → Nextcloud
        public var calendars: Bool              // EventKit → CalDAV
        public var contacts: Bool               // Contacts → CardDAV
        public var reminders: Bool              // EventKit reminders
        public var notes: Bool
        public var bookmarks: Bool

        public init(photos: PhotosComponent = PhotosComponent(),
                    documents: Bool = true, calendars: Bool = false, contacts: Bool = false,
                    reminders: Bool = false, notes: Bool = false, bookmarks: Bool = false) {
            self.photos = photos; self.documents = documents; self.calendars = calendars
            self.contacts = contacts; self.reminders = reminders; self.notes = notes; self.bookmarks = bookmarks
        }
    }

    public struct PhotosComponent: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var toImmich: Bool
        public var toNextcloud: Bool
        public init(enabled: Bool = true, toImmich: Bool = true, toNextcloud: Bool = true) {
            self.enabled = enabled; self.toImmich = toImmich; self.toNextcloud = toNextcloud
        }
    }
}

public extension MicloudConfig {
    /// JSON on disk at `~/Library/Application Support/micloud/config.json` (App Group in the sandbox build).
    static let filename = "config.json"

    func encoded() throws -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
    static func decode(_ data: Data) throws -> MicloudConfig {
        try JSONDecoder().decode(MicloudConfig.self, from: data)
    }
}
