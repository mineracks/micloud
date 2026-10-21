import Foundation
import SQLite3

/// The state of one item in a backfill job. A worker moves a row
/// `pending → claimed → uploading → done` (committing each step); a transient failure goes `→ failed` and is
/// requeued to `pending` with backoff; items already on the target are `skipped`.
///
/// `quarantined` is the escape hatch for **poison items** — a corrupt/unreadable file, or one iCloud can't
/// deliver. After `maxAttempts` failures the row is quarantined: no longer retried, and — crucially — it does
/// NOT block completion. One bad file can never stall the whole backfill; it's set aside and surfaced to the
/// user ("N couldn't be read") with a retry option.
public enum BackfillState: String, Sendable, CaseIterable {
    case pending, claimed, uploading, done, failed, skipped, quarantined
}

/// One tracked item: a stable key (relative path or asset localIdentifier) + its byte size + state.
public struct BackfillItem: Sendable, Equatable {
    public let key: String
    public let bytes: Int64
    public let state: BackfillState
    public let attempts: Int
    public let lastError: String?
    public init(key: String, bytes: Int64, state: BackfillState, attempts: Int, lastError: String?) {
        self.key = key; self.bytes = bytes; self.state = state; self.attempts = attempts; self.lastError = lastError
    }
}

/// Aggregate progress rolled up from the ledger — what the dashboard's ring, bar, and ETA read.
/// `confirmedBytes` counts only server-acknowledged work (`done` + `skipped`), so the bar can't overstate.
public struct BackfillProgress: Sendable, Equatable {
    public var total = 0, done = 0, skipped = 0, failed = 0, pending = 0, inFlight = 0, quarantined = 0
    /// Rows for items no longer at the source — still in the copy (never deleted there), NOT in `total` or the
    /// bar. The card said "Mail 52,556 · Up to date" over 49,708 messages on the Mac (2026-10-19).
    public var kept = 0
    public var keptBytes: Int64 = 0
    /// What the source has not finished producing yet (Mail's part-downloaded messages). Set by the engine.
    public var deferred: DeferredAtSource? = nil
    public var totalBytes: Int64 = 0
    public var confirmedBytes: Int64 = 0       // done + skipped — server-acknowledged
    public var quarantinedBytes: Int64 = 0     // given-up (unreadable/corrupt)
    /// Work still to attempt — excludes quarantined bytes so the bar can reach 100% when nothing's left to try.
    public var remainingBytes: Int64 { max(0, totalBytes - confirmedBytes - quarantinedBytes) }
    public var settled: Int { done + skipped }
    /// Per fan-out target (photos → Immich + Nextcloud): how much of the SAME library each one holds. Empty
    /// for single-target lanes.
    public var targets: [TargetProgress] = []
    /// Real bytes ÷ ledger bytes over the items this Mac has actually uploaded. The photo ledger stores
    /// pixel-count *estimates* (done rows ran 1.5× over, queued videos 4×) and the card took the longer of the
    /// byte/item ETAs, so it read "~4½ days" while the item pace said two. nil until 20 uploads have been measured.
    public var sizeCalibration: Double? = nil
    /// `bytes` scaled by the measured estimate error (identity until calibrated).
    public func calibrated(_ bytes: Int64) -> Int64 {
        guard let k = sizeCalibration else { return bytes }
        return Int64((Double(bytes) * k).rounded())
    }
    public var calibratedRemainingBytes: Int64 { calibrated(remainingBytes) }
    /// What one target still lacks: items and (calibrated) bytes. Quarantined items are nobody's to receive.
    public func remaining(for t: TargetProgress) -> (items: Int, bytes: Int64) {
        (max(0, total - t.settled - quarantined), calibrated(max(0, totalBytes - t.settledBytes - quarantinedBytes)))
    }
    /// Byte-weighted share one target already holds — the same rule as the lane bar.
    public func fraction(for t: TargetProgress) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(t.settledBytes + quarantinedBytes) / Double(totalBytes))
    }
    /// Some files were set aside as unreadable — the UI shows "N couldn't be read".
    public var hasUnreadable: Bool { quarantined > 0 }
    /// Complete = we had work and nothing is pending / in-flight / retryably-failed. Quarantined rows are
    /// terminal and do NOT block completion — so one poison file can't strand the job at 99.9%.
    /// Nothing left to try — including the empty case (a Mac whose Notes store has no notes yet is DONE,
    /// not "needs attention").
    public var isComplete: Bool { pending == 0 && inFlight == 0 && failed == 0 }
    public init() {}
}

public enum BackfillError: Error, CustomStringConvertible {
    case open(String), sql(String)
    public var description: String {
        switch self { case .open(let m): return "ledger open failed: \(m)"; case .sql(let m): return "ledger sql: \(m)" }
    }
}

/// A durable, resumable work-ledger for **one** backfill job (one source→target pair), backed by SQLite in
/// **WAL mode** so every state transition is an atomic, crash-safe commit. The engine (Phase 2) fills it via
/// `addDiscovered`, drains `pending` with `claim`, and marks outcomes; the dashboard reads `progress()`.
///
/// Crash-safety rests on two things: (1) each transition is committed, so a kill can't leave a half-written
/// row; (2) `recoverInterrupted()` at startup resets any `claimed`/`uploading` row (an upload cut off
/// mid-flight) back to `pending`, and the upload is simply redone — which is safe because uploads are
/// idempotent (Nextcloud temp-then-MOVE, Immich checksum dedup). `done`/`skipped` rows are never touched,
/// so a resume continues exactly where it left off. Phase 1: no network, no UI.
public final class BackfillLedger: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    // SQLite wants to know whether to copy a bound string; TRANSIENT = "copy it now" (safe with Swift Strings).
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw BackfillError.open(path.path)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA busy_timeout=5000;")
        try exec("""
            CREATE TABLE IF NOT EXISTS items(
              key TEXT PRIMARY KEY,
              bytes INTEGER NOT NULL,
              state TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              updated_at REAL NOT NULL,
              hash TEXT);
            """)
        try? exec("ALTER TABLE items ADD COLUMN hash TEXT;")   // migrate older ledgers (errors harmlessly if present)
        try? exec("ALTER TABLE items ADD COLUMN actual_bytes INTEGER;")   // real size once uploaded (sizes are estimates)
        try? exec("ALTER TABLE items ADD COLUMN present INTEGER NOT NULL DEFAULT 1;")   // 0 = not in the last enumeration (see markPresence)
        try exec("CREATE INDEX IF NOT EXISTS idx_items_state ON items(state);")
        // Which fan-out target holds which item. `present` = found there (reconcile, or the server said
        // duplicate); `done` = this Mac sent it. An item with no row for a target still needs to go there.
        try exec("""
            CREATE TABLE IF NOT EXISTS item_targets(
              key TEXT NOT NULL,
              target TEXT NOT NULL,
              state TEXT NOT NULL,
              updated_at REAL NOT NULL,
              PRIMARY KEY(key, target));
            """)
        try exec("CREATE INDEX IF NOT EXISTS idx_item_targets_target ON item_targets(target);")
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // ── discovery ─────────────────────────────────────────────────────────────
    /// Insert discovered items as `pending`, batched in one transaction. For an **existing** key: if the
    /// content `hash` is unchanged the row is left as-is (a `done` row stays done — no re-upload); if the hash
    /// **differs** the row is re-queued to `pending` (an edited event/contact re-uploads). A `nil` hash means
    /// "no change detection" — existing rows are left alone, exactly like the old `INSERT OR IGNORE`.
    /// A row whose bytes and hash are unchanged is not written at all (the `WHERE` on the upsert): without it
    /// every pass rewrote all ~415,000 rows across the lanes to bump `updated_at`, which nothing reads except
    /// the quarantine listing's sort order (2026-10-18).
    public func addDiscovered(_ items: [(key: String, bytes: Int64, hash: String?)]) throws {
        guard !items.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN;")
        do {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                INSERT INTO items(key,bytes,state,attempts,updated_at,hash) VALUES(?,?,'pending',0,?,?)
                ON CONFLICT(key) DO UPDATE SET
                  state    = CASE WHEN excluded.hash IS NOT NULL AND items.hash IS NOT excluded.hash THEN 'pending' ELSE items.state END,
                  attempts = CASE WHEN excluded.hash IS NOT NULL AND items.hash IS NOT excluded.hash THEN 0 ELSE items.attempts END,
                  bytes = excluded.bytes,
                  hash = COALESCE(excluded.hash, items.hash),
                  updated_at = excluded.updated_at
                WHERE items.bytes IS NOT excluded.bytes OR (excluded.hash IS NOT NULL AND items.hash IS NOT excluded.hash);
                """, -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
            defer { sqlite3_finalize(st) }
            let now = Date().timeIntervalSince1970
            for it in items {
                sqlite3_reset(st); sqlite3_clear_bindings(st)
                sqlite3_bind_text(st, 1, it.key, -1, Self.TRANSIENT)
                sqlite3_bind_int64(st, 2, it.bytes)
                sqlite3_bind_double(st, 3, now)
                if let h = it.hash { sqlite3_bind_text(st, 4, h, -1, Self.TRANSIENT) } else { sqlite3_bind_null(st, 4) }
                guard sqlite3_step(st) == SQLITE_DONE else { throw BackfillError.sql(msg()) }
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }

    /// Record which rows the latest enumeration still saw. A row for an item that is gone from the source keeps
    /// its state (the copy keeps the item) but drops out of `progress()`'s totals and into `kept`, so the card
    /// counts what is on the Mac now. Only rows whose presence actually changed are written. Returns `kept`.
    @discardableResult
    public func markPresence(_ keys: [String]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN;")
        do {
            try exec("CREATE TEMP TABLE IF NOT EXISTS cur(key TEXT PRIMARY KEY);")
            try exec("DELETE FROM cur;")
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO cur(key) VALUES(?);", -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
            for k in keys {
                sqlite3_reset(st); sqlite3_clear_bindings(st)
                sqlite3_bind_text(st, 1, k, -1, Self.TRANSIENT)
                guard sqlite3_step(st) == SQLITE_DONE else { sqlite3_finalize(st); throw BackfillError.sql(msg()) }
            }
            sqlite3_finalize(st)
            try exec("UPDATE items SET present=0 WHERE present=1 AND key NOT IN (SELECT key FROM cur);")
            try exec("UPDATE items SET present=1 WHERE present=0 AND key IN (SELECT key FROM cur);")
            try exec("DELETE FROM cur;")
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
        return try scalarInt("SELECT COUNT(*) FROM items WHERE present=0;")
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }

    // ── crash recovery ────────────────────────────────────────────────────────
    /// Reset any in-flight rows (`claimed`/`uploading`) back to `pending`. Call **once at startup**; returns
    /// the count reset (the "re-checked N in-flight files" the resume banner shows). Terminal rows untouched.
    @discardableResult
    public func recoverInterrupted() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try exec("UPDATE items SET state='pending', updated_at=\(Date().timeIntervalSince1970) WHERE state IN ('claimed','uploading');")
        return Int(sqlite3_changes(db))
    }

    // ── worker drain ──────────────────────────────────────────────────────────
    /// Atomically claim up to `limit` pending rows (marks them `claimed`) and return them, inside one
    /// `BEGIN IMMEDIATE` transaction so concurrent workers can never grab the same row.
    public func claim(limit: Int) throws -> [BackfillItem] {
        lock.lock(); defer { lock.unlock() }
        var out: [BackfillItem] = []
        try exec("BEGIN IMMEDIATE;")
        do {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                // Untried items first: a re-queued failure (an iCloud file that never materialised) can hold a worker
                // for the whole materialise timeout, and by rowid those sit at the FRONT of the queue — 3 workers ×
                // 2 min each starved a 159,000-file sweep to ~1 item/min.
                "SELECT key,bytes,attempts,last_error FROM items WHERE state='pending' ORDER BY attempts, rowid LIMIT \(max(1, limit));",
                -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
            while sqlite3_step(st) == SQLITE_ROW {
                let key = String(cString: sqlite3_column_text(st, 0))
                let bytes = sqlite3_column_int64(st, 1)
                let attempts = Int(sqlite3_column_int64(st, 2))
                let err = sqlite3_column_text(st, 3).map { String(cString: $0) }
                out.append(BackfillItem(key: key, bytes: bytes, state: .claimed, attempts: attempts, lastError: err))
            }
            sqlite3_finalize(st)
            for it in out { try setState(it.key, .claimed) }   // same transaction
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
        return out
    }

    public func markUploading(_ key: String) throws { lock.lock(); defer { lock.unlock() }; try setState(key, .uploading) }
    /// `actualBytes` = the real size of what went up, when the source knows it — the calibration sample for
    /// a ledger whose sizes are estimates.
    public func markDone(_ key: String, actualBytes: Int64? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try setState(key, .done)
        guard let b = actualBytes, b > 0 else { return }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE items SET actual_bytes=? WHERE key=?;", -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, b); sqlite3_bind_text(st, 2, key, -1, Self.TRANSIENT)
        guard sqlite3_step(st) == SQLITE_DONE else { throw BackfillError.sql(msg()) }
    }
    public func markSkipped(_ key: String)   throws { lock.lock(); defer { lock.unlock() }; try setState(key, .skipped) }
    /// Bulk "already on the server" from the reconcile pass — only rows still pending are touched.
    public func markSkippedIfPending(_ keys: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN;")
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE items SET state='skipped', updated_at=? WHERE key=? AND state='pending';", -1, &st, nil) == SQLITE_OK, let st else { try exec("ROLLBACK;"); return }
        defer { sqlite3_finalize(st) }
        let now = Date().timeIntervalSince1970
        for k in keys {
            sqlite3_reset(st); sqlite3_bind_double(st, 1, now)
            sqlite3_bind_text(st, 2, k, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_step(st)
        }
        try exec("COMMIT;")
    }

    /// Keys still `pending` — the only rows a reconcile can change (`markSkippedIfPending`), so the only
    /// ones worth asking the server about.
    public func pendingKeys() throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var out = Set<String>()
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key FROM items WHERE state='pending' AND present=1;", -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(st, 0))) }
        return out
    }

    // ── per-target (fan-out lanes) ────────────────────────────────────────────
    /// Reconcile result for ONE target: these items are already there. Never downgrades a `done` row.
    public func markTargetPresent(_ keys: [String], target: String) throws {
        guard !keys.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN;")
        do {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO item_targets(key,target,state,updated_at) VALUES(?,?,'present',?);", -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
            defer { sqlite3_finalize(st) }
            let now = Date().timeIntervalSince1970
            for k in keys {
                sqlite3_reset(st); sqlite3_clear_bindings(st)
                sqlite3_bind_text(st, 1, k, -1, Self.TRANSIENT); sqlite3_bind_text(st, 2, target, -1, Self.TRANSIENT); sqlite3_bind_double(st, 3, now)
                guard sqlite3_step(st) == SQLITE_DONE else { throw BackfillError.sql(msg()) }
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }
    /// After one item's pass: `sent` targets received it from this Mac, `present` ones already had it.
    public func markTargets(_ key: String, present: Set<String>, sent: Set<String>) throws {
        guard !present.isEmpty || !sent.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO item_targets(key,target,state,updated_at) VALUES(?,?,?,?)
            ON CONFLICT(key,target) DO UPDATE SET state=CASE WHEN excluded.state='done' THEN 'done' ELSE item_targets.state END, updated_at=excluded.updated_at;
            """, -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        let now = Date().timeIntervalSince1970
        for (names, state) in [(sent, "done"), (present, "present")] {
            for n in names {
                sqlite3_reset(st); sqlite3_clear_bindings(st)
                sqlite3_bind_text(st, 1, key, -1, Self.TRANSIENT); sqlite3_bind_text(st, 2, n, -1, Self.TRANSIENT)
                sqlite3_bind_text(st, 3, state, -1, Self.TRANSIENT); sqlite3_bind_double(st, 4, now)
                guard sqlite3_step(st) == SQLITE_DONE else { throw BackfillError.sql(msg()) }
            }
        }
    }
    /// Ledgers written before per-target tracking: a `done`/`skipped` item meant every target had it. Give
    /// those rows a `present` row per target so the per-target bars start from the truth, not from zero.
    public func seedTargetsForSettled(_ targets: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        for t in targets {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO item_targets(key,target,state,updated_at) SELECT key, ?, 'present', ? FROM items WHERE state IN ('done','skipped');", -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_text(st, 1, t, -1, Self.TRANSIENT); sqlite3_bind_double(st, 2, now)
            guard sqlite3_step(st) == SQLITE_DONE else { throw BackfillError.sql(msg()) }
        }
    }
    /// Targets that already hold this item — the ones a worker must NOT send to again.
    public func targetsHolding(_ key: String) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT target FROM item_targets WHERE key=?;", -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, key, -1, Self.TRANSIENT)
        var out = Set<String>()
        while sqlite3_step(st) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(st, 0))) }
        return out
    }

    /// Record a failed attempt. Bumps the attempt count and, **atomically**, decides transient-vs-terminal:
    /// once attempts reach `maxAttempts` the row is `quarantined` (given up — no more retries, doesn't block
    /// completion); below the cap it's `failed` and eligible for `requeueFailed()`. This is what keeps a
    /// single unreadable/corrupt file from stalling the whole backfill.
    public func markFailed(_ key: String, error: String, maxAttempts: Int) throws {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            UPDATE items SET attempts=attempts+1, last_error=?, updated_at=?,
              state=CASE WHEN attempts+1 >= ? THEN 'quarantined' ELSE 'failed' END
            WHERE key=?;
            """, -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, error, -1, Self.TRANSIENT)
        sqlite3_bind_double(st, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int(st, 3, Int32(max(1, maxAttempts)))
        sqlite3_bind_text(st, 4, key, -1, Self.TRANSIENT)
        guard sqlite3_step(st) == SQLITE_DONE else { throw BackfillError.sql(msg()) }
    }

    /// Requeue transient `failed` rows back to `pending` for another attempt (the backoff scheduler).
    /// Quarantined rows are terminal and left alone.
    public func requeueFailed() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("UPDATE items SET state='pending' WHERE state='failed';")
    }

    /// Give quarantined items another full set of attempts — for when the CAUSE was fixed (a missing
    /// calendar, a grant that arrived late), not the items.
    public func requeueQuarantined() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("UPDATE items SET state='pending', attempts=0 WHERE state='quarantined';")
    }

    /// The items micloud gave up on (unreadable/corrupt/undeliverable), newest first — the "N couldn't be
    /// read" list, each with its last error.
    public func quarantinedItems(limit: Int = 500) throws -> [BackfillItem] {
        lock.lock(); defer { lock.unlock() }
        var out: [BackfillItem] = []
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT key,bytes,attempts,last_error FROM items WHERE state='quarantined' ORDER BY updated_at DESC LIMIT \(max(1, limit));",
            -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(BackfillItem(key: String(cString: sqlite3_column_text(st, 0)),
                                    bytes: sqlite3_column_int64(st, 1),
                                    state: .quarantined,
                                    attempts: Int(sqlite3_column_int64(st, 2)),
                                    lastError: sqlite3_column_text(st, 3).map { String(cString: $0) }))
        }
        return out
    }

    /// Reset quarantined rows to `pending` with a clean attempt count — the "Try again" after the user has
    /// fixed the source (repaired the file, freed the stuck iCloud download, etc.).
    public func retryQuarantined() throws {
        lock.lock(); defer { lock.unlock() }
        try exec("UPDATE items SET state='pending', attempts=0, last_error=NULL WHERE state='quarantined';")
    }

    /// The unattended version: quarantined rows that have sat for `seconds` get a fresh set of attempts. Why: the
    /// cause is usually outside the item — a proxy's body cap, a route since changed, an iCloud download that
    /// failed that afternoon — and "19 couldn't be transferred" stayed on the card until someone clicked Retry
    /// (2026-10-19). Returns how many were re-queued.
    @discardableResult
    public func retryQuarantined(olderThan seconds: TimeInterval) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let cutoff = Date().timeIntervalSince1970 - seconds
        let n = try scalarInt("SELECT COUNT(*) FROM items WHERE state='quarantined' AND updated_at < \(cutoff);")
        if n > 0 { try exec("UPDATE items SET state='pending', attempts=0, updated_at=\(Date().timeIntervalSince1970) WHERE state='quarantined' AND updated_at < \(cutoff);") }
        return n
    }

    // ── read ──────────────────────────────────────────────────────────────────
    /// `targets` names the lane's fan-out targets so each appears (at zero) even before it has a row.
    public func progress(targets: [String] = []) throws -> BackfillProgress {
        lock.lock(); defer { lock.unlock() }
        var p = BackfillProgress()
        // per-target share
        if !targets.isEmpty {
            var rows: [String: TargetProgress] = [:]
            var ts: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "SELECT t.target, COUNT(*), SUM(CASE WHEN t.state='done' THEN 1 ELSE 0 END), COALESCE(SUM(i.bytes),0) FROM item_targets t JOIN items i ON i.key=t.key WHERE i.present=1 GROUP BY t.target;",
                -1, &ts, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
            while sqlite3_step(ts) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(ts, 0))
                rows[name] = TargetProgress(name: name, settled: Int(sqlite3_column_int64(ts, 1)),
                                            sent: Int(sqlite3_column_int64(ts, 2)), settledBytes: sqlite3_column_int64(ts, 3))
            }
            sqlite3_finalize(ts)
            p.targets = targets.map { rows[$0] ?? TargetProgress(name: $0, settled: 0, sent: 0, settledBytes: 0) }
        }
        // size calibration: real ÷ estimated over the uploads we have measured
        var cs: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*), COALESCE(SUM(actual_bytes),0), COALESCE(SUM(bytes),0) FROM items WHERE actual_bytes > 0;", -1, &cs, nil) == SQLITE_OK {
            if sqlite3_step(cs) == SQLITE_ROW {
                let n = sqlite3_column_int64(cs, 0), real = sqlite3_column_int64(cs, 1), est = sqlite3_column_int64(cs, 2)
                if n >= Self.calibrationSamples, est > 0, real > 0 { p.sizeCalibration = Double(real) / Double(est) }
            }
            sqlite3_finalize(cs)
        }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT state, COUNT(*), COALESCE(SUM(bytes),0) FROM items WHERE present=1 GROUP BY state;",
            -1, &st, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        var ks: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT COUNT(*), COALESCE(SUM(bytes),0) FROM items WHERE present=0;", -1, &ks, nil) == SQLITE_OK {
            if sqlite3_step(ks) == SQLITE_ROW { p.kept = Int(sqlite3_column_int64(ks, 0)); p.keptBytes = sqlite3_column_int64(ks, 1) }
            sqlite3_finalize(ks)
        }
        while sqlite3_step(st) == SQLITE_ROW {
            let state = String(cString: sqlite3_column_text(st, 0))
            let count = Int(sqlite3_column_int64(st, 1))
            let bytes = sqlite3_column_int64(st, 2)
            p.total += count; p.totalBytes += bytes
            switch BackfillState(rawValue: state) {
            case .done:               p.done = count;    p.confirmedBytes += bytes
            case .skipped:            p.skipped = count; p.confirmedBytes += bytes
            case .quarantined:        p.quarantined = count; p.quarantinedBytes += bytes
            case .failed:             p.failed = count
            case .pending:            p.pending = count
            case .claimed, .uploading: p.inFlight += count
            case .none:               break
            }
        }
        return p
    }

    public static let calibrationSamples: Int64 = 20

    /// Drop every row (the "Stop" control — keep done work? No: Stop discards the plan; done files stay on the target).
    public func clearAll() throws { lock.lock(); defer { lock.unlock() }; try exec("DELETE FROM items;"); try exec("DELETE FROM item_targets;") }

    // ── low-level ─────────────────────────────────────────────────────────────
    private func setState(_ key: String, _ state: BackfillState) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE items SET state=?, updated_at=? WHERE key=?;", -1, &st, nil) == SQLITE_OK
        else { throw BackfillError.sql(msg()) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, state.rawValue, -1, Self.TRANSIENT)
        sqlite3_bind_double(st, 2, Date().timeIntervalSince1970)
        sqlite3_bind_text(st, 3, key, -1, Self.TRANSIENT)
        guard sqlite3_step(st) == SQLITE_DONE else { throw BackfillError.sql(msg()) }
    }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw BackfillError.sql(msg()) }
    }
    private func msg() -> String { db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown" }
}
