import Foundation

/// Production (relay) mode — the app does the WHOLE job unattended, no demo bridges, no test limits.
/// Switched on by `MICLOUD_PRODUCTION=1` in the environment (the launch agent sets it; see
/// `com.mineracks.micloud.plist` + `configure.sh`). Everything here is read once at launch.
///
/// What it changes versus the driven-demo defaults in `Coordinator.start`:
///   • Photos: live source watches the newest `livePhotosWindow` items for instant mirroring, and the
///     ledger-backed backfill (resumable, incremental, dedup by content) carries the whole library —
///     caps are `.full` for a DIY install. Re-launching never re-uploads: the ledger remembers.
///   • Calendars / Reminders / Contacts: always on (MICLOUD_MORE implied), polled every `pollSecs`.
///   • Drive: always on; the watched folder is the saved grant, else iCloud Drive itself
///     (`~/Library/Mobile Documents/com~apple~CloudDocs`, which contains Desktop + Documents when
///     "Desktop & Documents" sync is on). The sandbox still needs ONE user-selected grant of that
///     folder (the open panel appears the first time; Screen Sharing is enough) — afterwards it is a
///     security-scoped bookmark and no human is needed again.
///   • Demo bridges (photos/notes/bookmarks/mail folders): ignored.
///   • Telemetry: every heartbeat → Loki (`MICLOUD_LOKI_URL`, else config.json `telemetryLokiURL`),
///     plus an `alive` tick per enabled source every `aliveSecs`.
enum Production {
    static let env = ProcessInfo.processInfo.environment
    static let on: Bool = env["MICLOUD_PRODUCTION"] == "1"
    /// What the bundle says it is (build.sh stamps it) — published in status.json so a remote reader can name it.
    static let appVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1"
    static let livePhotosWindow = Int(env["MICLOUD_LIVE_PHOTOS"] ?? "") ?? 50
    static let pollSecs = Double(env["MICLOUD_POLL_SECS"] ?? "") ?? 900
    static let aliveSecs = Double(env["MICLOUD_ALIVE_SECS"] ?? "") ?? 300
    static let hostLabel: String = env["MICLOUD_HOST_LABEL"]
        ?? (Host.current().localizedName ?? "mac").lowercased().replacingOccurrences(of: " ", with: "-")

    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// Relay build: `micloud-relay.entitlements` grants read access to iCloud Drive, so the Files lane can
    /// default to the WHOLE drive (Desktop + Documents included) with no open panel at all. The App Store
    /// build has no such exception, this reads false, and the powerbox panel is used instead.
    static var iCloudDriveReadable: Bool {
        guard let d = opendir(iCloudDrive.path) else { return false }
        closedir(d); return true
    }

    static func lokiURL() -> URL? {
        if let s = env["MICLOUD_LOKI_URL"], let u = URL(string: s) { return u }
        let fm = FileManager.default
        guard let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
        let cfg = base.appendingPathComponent("micloud/\(MicloudConfig.filename)")
        guard let data = try? Data(contentsOf: cfg), let c = try? MicloudConfig.decode(data) else { return nil }
        return c.telemetryLokiURL
    }
}
