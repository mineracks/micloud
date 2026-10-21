import Foundation
import CryptoKit
import MicloudKit

// CLT-runnable smoke check — mirrors MicloudKitTests for environments without full Xcode.
// `swift run Smoke`

var cfg = MicloudConfig(instance: "acme", hostLabel: "mini-01")
cfg.nextcloud = .init(baseURL: URL(string: "https://nc.example.com")!, username: "alice")
cfg.immich = .init(baseURL: URL(string: "https://immich.example.com")!)
precondition(try! MicloudConfig.decode(cfg.encoded()) == cfg, "config round-trip")
precondition(cfg.nextcloud!.webdavFilesRoot.absoluteString == "https://nc.example.com/remote.php/dav/files/alice")
precondition(cfg.immich!.apiRoot.absoluteString == "https://immich.example.com/api")

var snap = HealthSnapshot()
snap.record(Heartbeat(source: .photos, status: .healthy))
snap.record(Heartbeat(source: .documents, status: .syncing))
precondition(snap.overall == .syncing)
snap.record(Heartbeat(source: .documents, status: .error))
precondition(snap.overall == .error, "overall = worst active")
snap.record(Heartbeat(source: .contacts, status: .healthy, timestamp: Date().addingTimeInterval(-3600)))
precondition(snap.isStale(.contacts, window: 900))
precondition(!snap.isStale(.contacts, window: 7200))

// WebDAV client — path resolution + percent-encoding (the fiddly bit)
let dav = NextcloudWebDAV(filesRoot: URL(string: "https://nc.example.com/remote.php/dav/files/alice")!,
                          username: "alice", appPassword: "app-pw")
let davURL = dav.url(for: "Documents/sub folder/My File.txt")
print("  WebDAV url: \(davURL.absoluteString)")
precondition(davURL.absoluteString.hasPrefix("https://nc.example.com/remote.php/dav/files/alice/Documents/"), "webdav base")
precondition(davURL.lastPathComponent == "My File.txt", "webdav filename decode")

// HealthStore — records + notifies observers with the folded snapshot
let store = HealthStore()
var lastSeen: HealthSnapshot?
let token = store.observe { snap in lastSeen = snap }        // fires immediately with empty
precondition(lastSeen != nil, "observe fires immediately")
store.record(Heartbeat(source: .photos, status: .syncing, lastItem: "IMG_1660.HEIC"))
precondition(lastSeen?.overall == .syncing, "store notified observer")
precondition(lastSeen?.heartbeats[.photos]?.lastItem == "IMG_1660.HEIC")
store.cancel(token)
store.record(Heartbeat(source: .photos, status: .healthy))
precondition(store.current().overall == .healthy, "cancelled observer not called but state advances")

// BackfillLedger — durability across a simulated process kill + crash recovery of in-flight rows
let tmpDB = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-smoke-\(UUID().uuidString).sqlite")
defer {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: tmpDB.path + suffix)) }
}
do {
    // "process run 1": discover 4, claim 2, finish 1, leave 1 in-flight, then drop the connection (= crash)
    let l = try BackfillLedger(path: tmpDB)
    try l.addDiscovered([("a.jpg", 100, nil), ("b.jpg", 200, nil), ("c.jpg", 300, nil), ("d.jpg", 400, nil)])
    var p = try l.progress()
    precondition(p.total == 4 && p.pending == 4 && p.totalBytes == 1000, "discovered 4 pending")
    let claimed = try l.claim(limit: 2)
    precondition(claimed.count == 2, "claimed 2")
    try l.markUploading(claimed[1].key)
    try l.markDone(claimed[0].key)                 // one truly done
    p = try l.progress()
    precondition(p.done == 1 && p.inFlight == 1 && p.pending == 2 && p.confirmedBytes == claimed[0].bytes, "mid-flight snapshot")
}   // `l` deinits here → sqlite3_close: this is our simulated kill (nothing marked the in-flight row)

// "process run 2": reopen the SAME file and recover
let l2 = try BackfillLedger(path: tmpDB)
let reset = try l2.recoverInterrupted()
precondition(reset == 1, "exactly the 1 in-flight row was reset to pending")
var p2 = try l2.progress()
precondition(p2.done == 1 && p2.inFlight == 0 && p2.pending == 3, "done preserved, in-flight requeued")
precondition(p2.confirmedBytes == 100 && !p2.isComplete, "confirmed bytes survive; not complete yet")
// re-scan must not clobber the done row
try l2.addDiscovered([("a.jpg", 100, nil), ("e.jpg", 500, nil)])
p2 = try l2.progress()
precondition(p2.done == 1 && p2.total == 5, "re-scan keeps done row, adds new one")
// drain to completion
while true { let b = try l2.claim(limit: 3); if b.isEmpty { break }; for it in b { try l2.markDone(it.key) } }
let p3 = try l2.progress()
precondition(p3.isComplete && p3.done == 5 && p3.confirmedBytes == 1500, "drained to complete")
print("  BackfillLedger: durable across reopen, crash-recovers in-flight rows, re-scan-safe, drains complete")

// Poison file — an unreadable item must NOT strand the job. After maxAttempts it quarantines and the
// backfill still reports complete on everything else.
do {
    let pdb = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-poison-\(UUID().uuidString).sqlite")
    defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: pdb.path + s)) } }
    let l = try BackfillLedger(path: pdb)
    try l.addDiscovered([("good.jpg", 100, nil), ("corrupt.raw", 999, nil)])
    let cap = 3
    // "good" succeeds; "corrupt" fails every attempt
    try l.markDone("good.jpg")
    for attempt in 1...cap {
        _ = try l.claim(limit: 5)                      // claims corrupt (good is already done)
        try l.markFailed("corrupt.raw", error: "unreadable: bad header", maxAttempts: cap)
        let mid = try l.progress()
        if attempt < cap {
            precondition(mid.failed == 1 && mid.quarantined == 0 && !mid.isComplete, "still retrying under cap")
            try l.requeueFailed()                      // backoff scheduler puts it back to pending
        } else {
            precondition(mid.quarantined == 1 && mid.failed == 0, "quarantined at the cap")
        }
    }
    let pf = try l.progress()
    precondition(pf.isComplete, "job completes despite a poison file")
    precondition(pf.done == 1 && pf.quarantined == 1 && pf.hasUnreadable, "1 backed up, 1 set aside")
    precondition(pf.remainingBytes == 0, "quarantined bytes don't count as remaining → bar hits 100%")
    let bad = try l.quarantinedItems()
    precondition(bad.count == 1 && bad[0].key == "corrupt.raw" && bad[0].lastError?.contains("unreadable") == true, "poison surfaced with reason")
    // the user fixes the file and retries just the quarantined ones
    try l.retryQuarantined()
    let pr = try l.progress()
    precondition(pr.pending == 1 && pr.quarantined == 0 && !pr.isComplete, "retryQuarantined requeues the fixed file")
    print("  BackfillLedger: a poison file quarantines after \(cap) tries, job still completes, retry path works")
}

// Content-hash change detection — what makes the live watcher re-upload EDITED items only.
do {
    let hdb = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-hash-\(UUID().uuidString).sqlite")
    defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: hdb.path + s)) } }
    let l = try BackfillLedger(path: hdb)
    try l.addDiscovered([("ev1", 10, "h1")])
    _ = try l.claim(limit: 1); try l.markDone("ev1")
    let afterDone = try l.progress()
    precondition(afterDone.done == 1, "ev1 uploaded (done)")
    try l.addDiscovered([("ev1", 10, "h1")])               // re-scan, unchanged
    let same = try l.progress()
    precondition(same.done == 1 && same.pending == 0, "unchanged hash stays done — no re-upload")
    try l.addDiscovered([("ev1", 12, "h2")])               // re-scan, edited
    let changed = try l.progress()
    precondition(changed.done == 0 && changed.pending == 1, "changed hash re-queues for re-upload")
    print("  BackfillLedger: content-hash change detection re-queues edited items, keeps unchanged ones done")
}

// ExclusionRules — the shared gitignore-style filter used by EVERY source (backfill + live watcher)
var rules = ExclusionRules()                       // sensible defaults
precondition(rules.excludes(".DS_Store"), "junk file")
precondition(rules.excludes("Projects/app/.DS_Store"), "junk nested")
precondition(rules.excludes("scratch/build.tmp"), "*.tmp")
precondition(rules.excludes("code/node_modules/left-pad/index.js"), "node_modules/ directory")
precondition(rules.excludes("Library/Caches/com.foo/x.bin"), "*/Caches/*")
precondition(rules.excludes("Pictures/My Library.photoslibrary/db/x"), ".photoslibrary/ package")
precondition(!rules.excludes("Documents/report.pdf"), "keep a real document")
precondition(!rules.excludes("Photos/IMG_1660.HEIC"), "keep a photo original")
rules.add("*.mov"); rules.add("Private/")
precondition(rules.excludes("Movies/clip.MOV"), "custom *.mov (case-insensitive)")
precondition(rules.excludes("Private/keys.txt"), "custom dir Private/")
precondition(!rules.excludes("Documents/notes.txt"), "unaffected file still kept")
precondition(rules.kept(["a/.DS_Store", "b/report.pdf", "c.tmp", "d.pdf"]) == 2, "kept count = 2 of 4")
print("  ExclusionRules: default + custom globs filter paths (filename / dir / whole-path) for all sources")

// BackfillEngine — enumerate + exclude, drain to targets, quarantine a poison item, and a capacity block
func freshDB(_ tag: String) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("micloud-\(tag)-\(UUID().uuidString).sqlite") }
func wipe(_ u: URL) { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: URL(fileURLWithPath: u.path + s)) } }

do {  // normal run: 1 excluded, 1 poison, rest uploaded, job completes
    let db = freshDB("eng"); defer { wipe(db) }
    let ledger = try BackfillLedger(path: db)
    let items = [
        BackfillEntry(key: "a", relativePath: "Docs/a.pdf", bytes: 100),
        BackfillEntry(key: "b", relativePath: "Docs/build.tmp", bytes: 50),      // excluded by *.tmp
        BackfillEntry(key: "c", relativePath: "Docs/c.pdf", bytes: 200),
        BackfillEntry(key: "poison", relativePath: "Docs/corrupt.pdf", bytes: 999),
    ]
    let target = MockTarget(label: "mock", storageValue: TargetStorage(totalBytes: 10_000, usedBytes: 1_000))
    let src = MockSource(items: items, poisonKey: "poison", target: target)
    let engine = BackfillEngine(source: src, ledger: ledger, exclusions: ExclusionRules(),
                                config: BackfillConfig(concurrency: 2, maxAttempts: 2), heartbeat: { _ in })
    let prog = await engine.run(confirmTight: false)
    precondition(prog.total == 3, "build.tmp excluded → 3 discovered")
    precondition(prog.isComplete && prog.done == 2 && prog.quarantined == 1, "2 done, poison quarantined, complete")
    precondition(src.uploadedKeys() == ["a", "c"], "only the good files uploaded")
}
do {  // capacity: won't fit → abort before any transfer
    let db = freshDB("cap"); defer { wipe(db) }
    let ledger = try BackfillLedger(path: db)
    let src = MockSource(items: [BackfillEntry(key: "x", relativePath: "big.bin", bytes: 5_000)],
                         poisonKey: nil,
                         target: MockTarget(label: "full", storageValue: TargetStorage(totalBytes: 1_000, usedBytes: 900)))
    let engine = BackfillEngine(source: src, ledger: ledger, heartbeat: { _ in })
    let prog = await engine.run(confirmTight: false)
    precondition(!prog.isComplete && prog.done == 0 && src.uploadedKeys().isEmpty, "won't-fit blocks — no bytes sent")
}
print("  BackfillEngine: enumerate+exclude, drain, quarantine poison, complete; capacity blocks a won't-fit target")

// SovereignKey — client-side E2E encryption + BIP39 recovery-phrase round-trip
let sk = SovereignKey.generate()
precondition(sk.entropy.count == 16, "128-bit seed")
let phrase = sk.recoveryPhrase
precondition(phrase.count == 12, "12-word BIP39 phrase")
precondition(sk.fingerprint.count == 8 && sk.fingerprint == SovereignKey(recoveryPhrase: phrase)!.fingerprint, "8-char fingerprint, stable across round-trip")
precondition(SovereignKey(recoveryPhrase: phrase) == sk, "phrase round-trips to the SAME key")
precondition(SovereignKey(recoveryPhrase: ["notaword"] + Array(phrase.dropFirst())) == nil, "unknown word rejected")
// The last word carries 7 entropy bits + the 4 checksum bits (bit 0 = the lowest checksum bit). Flipping
// that bit keeps the entropy and breaks the checksum by construction. (A reversed phrase, used before, is a
// valid phrase 1 time in 16 — the 4-bit checksum — and failed this test about once a day.)
let lastIdx = SovereignKey.wordlist.firstIndex(of: phrase[11])!
let badChecksum = Array(phrase.dropLast()) + [SovereignKey.wordlist[lastIdx ^ 1]]
precondition(SovereignKey(recoveryPhrase: badChecksum) == nil, "wrong checksum rejected")
precondition(SovereignKey(recoveryPhrase: phrase.map { $0.uppercased() }) == sk, "case-insensitive words")
let secret = Data("sovereign secret — micloud can't read this".utf8)
let ct = try! sk.seal(secret)
precondition(ct != secret && ct.count > secret.count, "ciphertext differs + carries nonce/tag")
precondition(try! sk.open(ct) == secret, "own key decrypts")
precondition((try? SovereignKey.generate().open(ct)) == nil, "a DIFFERENT key cannot decrypt")
precondition((try? sk.open(ct.dropLast() + Data([0]))) == nil, "tampered ciphertext rejected (GCM integrity)")
print("  SovereignKey: 128-bit gen → 12-word BIP39 round-trip, HKDF→AES-256-GCM seal/open, fingerprint, wrong-key + tamper rejected")

// SovereignStore + InstallStore — persistence round-trips (Keychain-or-file for the key, JSON for install state)
SovereignStore.save(sk)
precondition(SovereignStore.loadKey() == sk, "sovereign key persists + reloads to the SAME key")
SovereignStore.saveSecret("smoke-account", "app-password-123")
precondition(SovereignStore.secret("smoke-account") == "app-password-123", "backend secret round-trips")
SovereignStore.deleteSecret("smoke-account")
precondition(SovereignStore.secret("smoke-account") == nil, "deleted secret is gone")
var inst = Install(onboarded: true, backend: .diy, nextcloudURL: "https://nc.example.com", nextcloudUser: "alice")
InstallStore.save(inst)
let loaded = InstallStore.load()
precondition(loaded == inst && loaded.onboarded && loaded.backend == .diy, "install record persists + reloads")
inst.onboarded = false; InstallStore.save(inst)   // leave the box in a not-onboarded state for the smoke runner
print("  SovereignStore + InstallStore: key/secret/install persist + reload; delete clears")

// License — Ed25519 sign/verify, expiry, tamper + wrong-key rejection (self-contained ephemeral keypair)
do {
    let lsk = Curve25519.Signing.PrivateKey()
    let pub = lsk.publicKey.rawRepresentation.base64EncodedString()
    let skB64 = lsk.rawRepresentation.base64EncodedString()
    let iat = Date(timeIntervalSince1970: 1_700_000_000)
    let good = LicensePayload(sub: "cust_123", plan: "annual", iat: iat, exp: iat.addingTimeInterval(365*86400))
    let token = try License.sign(good, privateKeyBase64: skB64)
    precondition(License.verify(token, publicKeyBase64: pub) == good, "valid token verifies to the same payload")
    precondition(Entitlement.from(token: token, now: iat).isPro == false || License.verify(token, publicKeyBase64: pub) != nil, "verify path exercised")
    precondition(License.verify(token) == nil, "a token signed by a DIFFERENT key fails the embedded pubkey")
    precondition(License.verify(token + "x", publicKeyBase64: pub) == nil, "tampered signature rejected")
    let expired = LicensePayload(sub: "cust_123", plan: "monthly", iat: iat, exp: iat.addingTimeInterval(86400))
    let expToken = try License.sign(expired, privateKeyBase64: skB64)
    precondition(License.verify(expToken, publicKeyBase64: pub) != nil, "expired token still has a valid signature")
    precondition(License.verify(expToken, publicKeyBase64: pub)!.isValid(now: iat.addingTimeInterval(2*86400)) == false, "expiry enforced by isValid")
    // If the real issuing private key is supplied, confirm it matches the EMBEDDED public key.
    if let realSK = ProcessInfo.processInfo.environment["MICLOUD_LICENSE_SK"] {
        let realToken = try License.sign(good, privateKeyBase64: realSK)
        precondition(License.verify(realToken) == good, "real private key round-trips through the EMBEDDED public key")
        precondition(Entitlement.from(token: realToken, now: iat).isPro, "real-key token resolves to a Pro entitlement")
        print("  License: ephemeral sign/verify/expiry/tamper + EMBEDDED-key match + Pro entitlement confirmed")
    } else {
        print("  License: ephemeral sign/verify, expiry enforced, tamper + wrong-key rejected")
    }
}

print("✓ MicloudKit smoke OK — config round-trip, derived endpoints, health snapshot, staleness, WebDAV, HealthStore, BackfillLedger, ExclusionRules, BackfillEngine, SovereignKey (\(SourceID.allCases.count) sources)")

// ── test doubles (hoisted; used above) ───────────────────────────────────────
struct MockTarget: BackfillTarget {
    let label: String
    let storageValue: TargetStorage
    func storage() async throws -> TargetStorage { storageValue }
}
final class MockSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .documents
    private let items: [BackfillEntry]
    private let poisonKey: String?
    private let target: BackfillTarget
    private let lock = NSLock()
    private var uploaded: Set<String> = []
    init(items: [BackfillEntry], poisonKey: String?, target: BackfillTarget) {
        self.items = items; self.poisonKey = poisonKey; self.target = target
    }
    func enumerateItems() async throws -> [BackfillEntry] { items }
    func process(_ entry: BackfillEntry) async throws {
        if entry.key == poisonKey { throw NSError(domain: "mock", code: 1, userInfo: [NSLocalizedDescriptionKey: "unreadable"]) }
        lock.lock(); uploaded.insert(entry.key); lock.unlock()
    }
    func capacityTargets() -> [BackfillTarget] { [target] }
    func uploadedKeys() -> Set<String> { lock.lock(); defer { lock.unlock() }; return uploaded }
}
