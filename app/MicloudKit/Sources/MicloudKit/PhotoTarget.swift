import Foundation

/// Outcome of pushing one photo original to a sovereign target.
/// `.duplicate` = the target already had it (checksum match); `.created` = newly stored.
public enum PhotoUploadResult: Sendable, Equatable { case created, duplicate }

/// What a target holds, listed ONCE for the reconcile pass. `names` = original filenames it stores.
/// `fingerprints` = capture-second + pixel-size keys (`PhotoFingerprint.key`) that are unique on the target —
/// the only handle that survives a target that renamed everything: the Immich iPhone app stores assets as
/// `<iPhone asset id>.jpeg`, an id this Mac never sees (2026-10-15: 208,266 of 213,014, zero overlap with the
/// Mac's own asset ids), so by name this Mac found 381 of them.
public struct PhotoPresence: Sendable {
    public var names: Set<String>
    public var fingerprints: Set<String>
    public init(names: Set<String>, fingerprints: Set<String> = []) { self.names = names; self.fingerprints = fingerprints }
}
public enum PhotoFingerprint {
    /// Whole seconds since 1970 + stored pixel size. Both sides floor the same EXIF instant.
    public static func key(createdAt: Date, width: Int, height: Int) -> String {
        "\(Int(createdAt.timeIntervalSince1970.rounded(.down)))|\(width)x\(height)"
    }
    /// Wall-clock form: the EXIF time as written, no zone. 54,883 of this library's assets carry no EXIF
    /// zone, and Immich (running in UTC) stored their instant ten hours off the Mac's — but the wall clock
    /// it keeps as `localDateTime` is exactly what the Mac shows for a photo taken in its own zone.
    public static func naiveKey(wallClock: String, width: Int, height: Int) -> String {
        "\(wallClock.prefix(19))|\(width)x\(height)"
    }
    public static func naiveKey(createdAt: Date, in tz: TimeZone, width: Int, height: Int) -> String {
        naiveKey(wallClock: wallClockFormatter(tz).string(from: createdAt), width: width, height: height)
    }
    private static func wallClockFormatter(_ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }
}

/// A sovereign destination for photo originals. **Both Immich and Nextcloud satisfy it**, so
/// `PhotosSource` can fan out to one or both per `MicloudConfig.PhotosComponent.toImmich/toNextcloud`.
/// One-way only (the contract in `SyncSource`): a target never writes back to iCloud.
public protocol PhotoTarget: Sendable {
    var label: String { get }
    /// What the dashboard calls this target ("Immich", "Nextcloud") — the per-target ledger key.
    var displayName: String { get }
    /// Upload a photo/video original. `createdAt`/`modifiedAt` come from the `PHAsset` so the
    /// target can preserve capture time (Immich uses them; Nextcloud ignores them).
    func uploadPhoto(localFile: URL, filename: String,
                     createdAt: Date, modifiedAt: Date) async throws -> PhotoUploadResult
    /// Does the target already hold an original by this name? Used only for names unique in the library,
    /// so the relay can skip without downloading the original from iCloud first. Default: don't know → false.
    func has(filename: String) async -> Bool
    /// Every original filename the target holds (reconcile pass). nil = cannot enumerate → not used.
    func allFilenames() async -> Set<String>?
    /// Names + fingerprints in one listing (reconcile pass). Default: names only.
    func presence() async -> PhotoPresence?
    /// One asset by capture time + stored pixel size — the per-item form of the fingerprint match, for a
    /// reconcile of a handful of pending items without a whole-library listing. Default: don't know → false.
    func has(createdAt: Date, width: Int, height: Int) async -> Bool
}
public extension PhotoTarget {
    var displayName: String { label }
    func has(filename: String) async -> Bool { false }
    func has(createdAt: Date, width: Int, height: Int) async -> Bool { false }
    func allFilenames() async -> Set<String>? { nil }
    func presence() async -> PhotoPresence? { await allFilenames().map { PhotoPresence(names: $0) } }
}

/// Nextcloud as a photo target: uploads into a folder its Photos app indexes (e.g. `Photos/iCloud-Camera`).
/// Nextcloud has no server-side checksum dedup, so a re-upload overwrites idempotently → always `.created`.
public struct NextcloudPhotoTarget: PhotoTarget {
    public let dav: NextcloudWebDAV
    public let photosPath: String
    public init(dav: NextcloudWebDAV, photosPath: String) { self.dav = dav; self.photosPath = photosPath }

    public var label: String { "nextcloud" }
    public var displayName: String { "Nextcloud" }
    public func has(filename: String) async -> Bool { await dav.exists("\(photosPath)/\(filename)") }
    public func allFilenames() async -> Set<String>? { Set(await dav.listFolder(photosPath).keys) }
    public func uploadPhoto(localFile: URL, filename: String,
                            createdAt: Date, modifiedAt: Date) async throws -> PhotoUploadResult {
        let rel = "\(photosPath)/\(filename)"
        let size = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.int64Value
        if await dav.exists(rel, bytes: size) { return .duplicate }     // already there (previous relay) — never send twice
        try await dav.ensureParents(of: rel)
        try await dav.upload(localFile: localFile, to: rel)
        return .created
    }
}

extension ImmichClient: PhotoTarget {
    public var label: String { "immich(\(apiRoot.host ?? "?"))" }
    public var displayName: String { "Immich" }
    public func has(filename: String) async -> Bool { (try? await hasAsset(originalFileName: filename)) ?? false }
    public func allFilenames() async -> Set<String>? { try? await allOriginalFileNames() }
    public func presence() async -> PhotoPresence? { try? await allPresence() }
    public func has(createdAt: Date, width: Int, height: Int) async -> Bool { (try? await hasAsset(createdAt: createdAt, width: width, height: height)) ?? false }
    public func uploadPhoto(localFile: URL, filename: String,
                            createdAt: Date, modifiedAt: Date) async throws -> PhotoUploadResult {
        try await uploadAsset(localFile: localFile, filename: filename,
                              createdAt: createdAt, modifiedAt: modifiedAt)
    }
}
