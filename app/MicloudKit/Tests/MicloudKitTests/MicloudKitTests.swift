import XCTest
@testable import MicloudKit

// Runs under full Xcode (`swift test`). For CLT-only environments, `swift run Smoke` covers the same logic.
final class MicloudKitTests: XCTestCase {

    func testConfigRoundTrip() throws {
        var cfg = MicloudConfig(instance: "acme", hostLabel: "mini-01")
        cfg.nextcloud = .init(baseURL: URL(string: "https://nc.example.com")!, username: "alice")
        cfg.immich = .init(baseURL: URL(string: "https://immich.example.com")!)
        XCTAssertEqual(try MicloudConfig.decode(cfg.encoded()), cfg)
    }

    func testForbiddenNameIsStoredUnderAcceptedName() {
        // Nextcloud refuses `.htaccess` (400, forbidden_filenames); it goes up as `htaccess.txt`, other names untouched.
        XCTAssertEqual(NextcloudWebDAV.storedName(".htaccess"), "htaccess.txt")
        XCTAssertEqual(NextcloudWebDAV.storedName(".HTACCESS"), "htaccess.txt")
        XCTAssertEqual(NextcloudWebDAV.storedName(".htaccess.bak"), ".htaccess.bak")
        XCTAssertEqual(NextcloudWebDAV.storedName("notes.txt"), "notes.txt")
        let dav = NextcloudWebDAV(filesRoot: URL(string: "https://nc.example.com/remote.php/dav/files/alice")!,
                                  username: "alice", appPassword: "x")
        XCTAssertEqual(dav.url(for: "Documents/site/public_html/.htaccess").absoluteString,
                       "https://nc.example.com/remote.php/dav/files/alice/Documents/site/public_html/htaccess.txt")
    }

    func testImmichSHA1MatchesKnownVector() throws {
        // Immich's asset checksum is the plain SHA-1 of the bytes; "abc" is the FIPS 180 vector.
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-sha1-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f); defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertEqual(try ImmichClient.sha1Hex(of: f), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testDerivedEndpoints() {
        let nc = MicloudConfig.NextcloudTarget(baseURL: URL(string: "https://nc.example.com")!, username: "alice")
        XCTAssertEqual(nc.webdavFilesRoot.absoluteString, "https://nc.example.com/remote.php/dav/files/alice")
        let im = MicloudConfig.ImmichTarget(baseURL: URL(string: "https://immich.example.com")!)
        XCTAssertEqual(im.apiRoot.absoluteString, "https://immich.example.com/api")
    }

    func testHealthSnapshotOverallIsWorstActive() {
        var snap = HealthSnapshot()
        snap.record(Heartbeat(source: .photos, status: .healthy))
        snap.record(Heartbeat(source: .documents, status: .syncing))
        XCTAssertEqual(snap.overall, .syncing)
        snap.record(Heartbeat(source: .documents, status: .error))
        XCTAssertEqual(snap.overall, .error)
    }

    func testStalenessWindow() {
        var snap = HealthSnapshot()
        snap.record(Heartbeat(source: .photos, status: .healthy, timestamp: Date().addingTimeInterval(-3600)))
        XCTAssertTrue(snap.isStale(.photos, window: 900))
        XCTAssertFalse(snap.isStale(.photos, window: 7200))
        XCTAssertTrue(snap.isStale(.contacts, window: 900))
    }

    func testLedgerTracksEachTargetAndCalibratesSizes() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-ledger-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: f) }
        let l = try BackfillLedger(path: f)
        try l.addDiscovered([("a", 100, nil), ("b", 100, nil), ("c", 100, nil)])
        // reconcile: Immich already holds a + b, Nextcloud nothing
        try l.markTargetPresent(["a", "b"], target: "Immich")
        XCTAssertEqual(try l.targetsHolding("a"), ["Immich"])
        XCTAssertEqual(try l.targetsHolding("c"), [])
        // a goes to Nextcloud only; the real file was half the estimate
        try l.markTargets("a", present: [], sent: ["Nextcloud"])
        try l.markDone("a", actualBytes: 50)
        var p = try l.progress(targets: ["Immich", "Nextcloud"])
        XCTAssertEqual(p.targets.map(\.name), ["Immich", "Nextcloud"])
        XCTAssertEqual(p.targets[0].settled, 2); XCTAssertEqual(p.targets[0].sent, 0)
        XCTAssertEqual(p.targets[1].settled, 1); XCTAssertEqual(p.targets[1].sent, 1)
        XCTAssertEqual(p.remaining(for: p.targets[0]).items, 1)
        XCTAssertEqual(p.remaining(for: p.targets[1]).items, 2)
        XCTAssertNil(p.sizeCalibration, "one sample must not calibrate")
        // a done row never downgrades to present; a present row upgrades to done
        try l.markTargets("a", present: ["Nextcloud"], sent: [])
        try l.markTargets("b", present: [], sent: ["Immich"])
        p = try l.progress(targets: ["Immich", "Nextcloud"])
        XCTAssertEqual(p.targets[1].sent, 1); XCTAssertEqual(p.targets[0].sent, 1)
        // 20 measured uploads at half the estimate → remaining bytes read at half
        try l.addDiscovered((0..<20).map { ("m\($0)", 100, nil) })
        for i in 0..<20 { try l.markDone("m\(i)", actualBytes: 50) }
        try l.addDiscovered([("z", 1000, nil)])
        p = try l.progress(targets: ["Immich", "Nextcloud"])
        XCTAssertEqual(p.sizeCalibration ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.remainingBytes, 1200)              // b, c, z — estimates
        XCTAssertEqual(p.calibratedRemainingBytes, 600)
        // old ledgers: settled rows become 'present' on every target, pending rows do not
        try l.seedTargetsForSettled(["Immich", "Nextcloud"])
        XCTAssertEqual(try l.targetsHolding("m3"), ["Immich", "Nextcloud"])
        XCTAssertEqual(try l.targetsHolding("z"), [])
    }

    func testPhotoFingerprintFloorsToTheSameSecondAsImmich() {
        // Immich: "2026-07-17T17:45:02.609Z"; PhotoKit: the same instant as a Date. Same key, fraction dropped.
        let d = ImmichClient.parseISO("2026-07-17T17:45:02.609Z")!
        XCTAssertEqual(PhotoFingerprint.key(createdAt: d, width: 5712, height: 4284), "1784310302|5712x4284")
        XCTAssertEqual(PhotoFingerprint.key(createdAt: d.addingTimeInterval(0.39), width: 1, height: 1), "1784310302|1x1")
        XCTAssertEqual(ImmichClient.parseISO("2026-07-17T17:45:02Z"), d.addingTimeInterval(-0.609))
        // Wall clock: Immich's localDateTime as written, the Mac's creationDate rendered in the photo's zone.
        XCTAssertEqual(PhotoFingerprint.naiveKey(wallClock: "2026-07-18T03:45:02.609Z", width: 4, height: 3), "2026-07-18T03:45:02|4x3")
        XCTAssertEqual(PhotoFingerprint.naiveKey(createdAt: d, in: TimeZone(identifier: "Australia/Brisbane")!, width: 4, height: 3), "2026-07-18T03:45:02|4x3")
    }
}
