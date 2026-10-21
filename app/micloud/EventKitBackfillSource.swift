import Foundation
import EventKit
import SQLite3

/// `BackfillSource` for Calendars or Reminders via EventKit. Enumerates items, serialises each to a `.ics`
/// once (cached), and uploads it to a Nextcloud folder. Per-item, so progress / quarantine / resume all work.
/// One class, two entity types — the Calendars and Reminders tiles share it.
final class EventKitBackfillSource: BackfillSource, @unchecked Sendable {
    let id: SourceID
    private let store: EKEventStore
    private let entity: EKEntityType
    private let dav: NextcloudWebDAV
    private let folder: String
    private let lookbackYears: Int
    /// Demo bridge (events only). On hosts where EventKit can't read the local calendar — notably the driven
    /// demo VM, where `store.events(matching:)` returns 0 even with full access — the orchestrator drops each
    /// just-created event as a ready `.ics` in this directory. The source enumerates those files so the REAL
    /// backfill pipeline carries them: the ledger, activity graph, sync log, and Calendars badge all react,
    /// and the app itself does the CalDAV upload. `nil` in production (env unset) → pure no-op.
    private let bridgeDir: String?
    private let lock = NSLock()
    private var content: [String: Data] = [:]
    /// Exception dates per series UID, keyed by the Calendar store's modification date (re-read only when
    /// the store changed). See `exceptionDates()`.
    private var exdateCache: (mtime: Date, map: [String: [Date]])?

    init(id: SourceID, entity: EKEntityType, store: EKEventStore, dav: NextcloudWebDAV,
         folder: String, lookbackYears: Int = 5, bridgeDir: String? = nil) {
        self.id = id; self.entity = entity; self.store = store; self.dav = dav
        self.folder = folder; self.lookbackYears = lookbackYears; self.bridgeDir = bridgeDir
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        // The destination calendar must exist or every PUT 404s (2,878 events + 690 reminders quarantined on
        // the relay's first night). Events and reminders get their own calendars; Tasks only shows VTODO ones.
        try await dav.ensureCalendar(folder, components: ["VEVENT", "VTODO"], displayName: "micloud")   // one calendar: events + reminders (Tasks app reads the VTODOs)
        var entries: [BackfillEntry] = []
        var cache: [String: Data] = [:]
        // Pick up sources/calendars/items created since the store last synced (e.g. events just added by
        // another app) — without this a long-lived store can keep returning a stale (often empty) view.
        store.refreshSourcesIfNecessary()
        if entity == .event {
            // Only the user's own calendars — skip read-only subscribed feeds (Holidays, sports schedules…)
            // and the auto-generated Birthdays calendar; those aren't the user's data to back up and would
            // flood the sovereign copy with hundreds of feed events.
            let cals = store.calendars(for: .event).filter { $0.type != .subscription && $0.type != .birthday && $0.allowsContentModifications }
            if !cals.isEmpty {
                let year: TimeInterval = 365 * 24 * 3600
                let pred = store.predicateForEvents(withStart: Date(timeIntervalSinceNow: -year * Double(lookbackYears)),
                                                    end: Date(timeIntervalSinceNow: year * 2), calendars: cals)
                // `events(matching:)` expands recurrences: a weekly meeting comes back once per occurrence, all
                // sharing one `calendarItemIdentifier`. Serialised one occurrence at a time, the same key reached
                // the ledger ~15 times per pass with ~15 different hashes — 96 recurring events were re-sent
                // every 15 minutes, for ever (4,326 "items" for 2,893 keys, 2026-10-18). One object per series:
                // the master (DTSTART of the series, RRULE) plus any occurrence the user edited on its own
                // (RECURRENCE-ID), which is how a calendar expects a series anyway.
                let exdates = exceptionDates()
                var occurrences: [String: [EKEvent]] = [:]; var order: [String] = []
                for e in store.events(matching: pred) {
                    let key = e.calendarItemIdentifier
                    if occurrences[key] == nil { order.append(key) }
                    occurrences[key, default: []].append(e)
                }
                for key in order {
                    let occ = occurrences[key] ?? []
                    guard let first = occ.first else { continue }
                    var master = first
                    if first.hasRecurrenceRules, let m = store.calendarItem(withIdentifier: key) as? EKEvent { master = m }   // the series' own start, not the window's first hit
                    let detached = occ.filter { $0.isDetached }
                    let data = Data(ICS.event(master, detached: detached, exdates: exdates[key] ?? []).utf8)
                    cache[key] = data
                    entries.append(BackfillEntry(key: key, relativePath: "\(safe(master.title ?? key))-\(shortHash(key)).ics", bytes: Int64(data.count), contentHash: stableHash(data)))
                }
            }
            // Demo bridge: pick up any ready-made .ics the orchestrator dropped (see `bridgeDir`). Each file is
            // uploaded once (ledger content-hash), so this is idempotent across the periodic re-backfill.
            if let dir = bridgeDir {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".ics") {
                    let path = (dir as NSString).appendingPathComponent(name)
                    guard let data = FileManager.default.contents(atPath: path) else { continue }
                    let key = "bridge:\(name)"
                    cache[key] = data
                    entries.append(BackfillEntry(key: key, relativePath: name, bytes: Int64(data.count), contentHash: stableHash(data)))
                }
            }
        } else {
            let cals = store.calendars(for: .reminder)
            let reminders: [EKReminder] = await withCheckedContinuation { c in
                store.fetchReminders(matching: store.predicateForReminders(in: cals)) { c.resume(returning: $0 ?? []) }
            }
            for r in reminders {
                let key = r.calendarItemIdentifier
                let data = Data(ICS.reminder(r).utf8)
                cache[key] = data
                entries.append(BackfillEntry(key: key, relativePath: "\(safe(r.title ?? key))-\(shortHash(key)).ics", bytes: Int64(data.count), contentHash: stableHash(data)))
            }
        }
        lock.lock(); content = cache; lock.unlock()
        return entries
    }

    func process(_ entry: BackfillEntry) async throws {
        lock.lock(); let data = content[entry.key]; lock.unlock()
        guard let data else { throw NSError(domain: "micloud.eventkit", code: 1, userInfo: [NSLocalizedDescriptionKey: "no cached item"]) }
        // Land the iCal object in a CalDAV calendar (`folder` = calendar name) → events appear in the
        // Nextcloud Calendar app, reminders (VTODOs) appear in the Tasks app. Not inert files.
        do {
            try await dav.putCalendarObject(calendar: folder, filename: entry.relativePath, ical: data)
        } catch let e as WebDAVError where e.description.lowercased().contains("already exists") {
            // The calendar already holds this UID under another filename — every object uploaded before
            // 2026-10-18 has a per-launch random suffix (`shortHash` was `hashValue`), and the same event can
            // reach EventKit once per calendar it's in. Nextcloud refuses a second object with that UID, so an
            // edited event was being dropped as "already there". Find the name the server has and land the
            // current bytes on it; only when nothing answers to the UID is it genuinely already on the target.
            let comp = entity == .event ? "VEVENT" : "VTODO"
            if !entry.key.hasPrefix("bridge:"),
               let existing = try? await dav.calendarObjectName(calendar: folder, uid: entry.key, component: comp),
               existing != entry.relativePath {
                try await dav.putCalendarObject(calendar: folder, filename: existing, ical: data)
                return
            }
            throw BackfillEngine.AlreadyOnTarget()
        } catch {
            // Keep the exact bytes the server refused next to the reason — a 400 from CalDAV names the line, not
            // the content, and nothing else on this Mac can regenerate the object for inspection.
            let dir = RealHome.manifests.deletingLastPathComponent().appendingPathComponent("rejected/\(id.rawValue)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: dir.appendingPathComponent(entry.relativePath))
            try? "\(error)".write(to: dir.appendingPathComponent(entry.relativePath + ".error"), atomically: true, encoding: .utf8)
            // Transport check: push the same bytes through the Files WebDAV (which stores them raw), read them
            // back, and log whether they survived. Tells a mangled-on-the-wire body from a server-side parse.
            if "\(error)".contains("HTTP 400") {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-rt-\(UUID().uuidString).ics")
                try? data.write(to: tmp); defer { try? FileManager.default.removeItem(at: tmp) }
                let probe = "micloud/.diag/\(entry.relativePath)"
                if (try? await dav.ensureParents(of: probe)) != nil, (try? await dav.upload(localFile: tmp, to: probe)) != nil,
                   let back = try? await dav.fetch(probe) {
                    NSLog("micloud caldav 400 round-trip %@: sent %d bytes, files-dav returned %d bytes, identical=%@",
                          entry.relativePath, data.count, back.count, back == data ? "yes" : "NO")
                }
            }
            throw error
        }
    }

    func capacityTargets() -> [BackfillTarget] { [dav] }

    /// Occurrences the user deleted from a series, per series UID. EventKit does not expose them (an
    /// `EKRecurrenceRule` has no exception dates; `events(matching:)` simply omits the deleted ones), so a
    /// series backed up from EventKit alone re-grows every deleted occurrence on the server. The Calendar
    /// store itself keeps them: `ExceptionDate(owner_id → CalendarItem.ROWID, date)` in
    /// `~/Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb` (CalendarItem.UUID is the
    /// `calendarItemIdentifier`; dates are seconds since 2001, an all-day exception is midnight UTC of the
    /// day). Read from a copy — CalendarAgent holds the live file in WAL mode — and only when the store's
    /// modification date moved. Needs the relay entitlement for that group container + Full Disk Access;
    /// without them the lane still runs, without EXDATEs (logged once per store change).
    private func exceptionDates() -> [String: [Date]] {
        let src = RealHome.url.appendingPathComponent("Library/Group Containers/group.com.apple.calendar/Calendar.sqlitedb")
        guard let mtime = (try? FileManager.default.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date else {
            if exdateCache == nil { NSLog("micloud calendars: exception dates unavailable — cannot stat %@", src.path) }
            lock.lock(); defer { lock.unlock() }; exdateCache = (.distantPast, [:]); return [:]
        }
        lock.lock(); let cached = exdateCache; lock.unlock()
        if let cached, cached.mtime == mtime { return cached.map }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("micloud-cal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var map: [String: [Date]] = [:]
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let copy = tmp.appendingPathComponent("Calendar.sqlitedb")
            try FileManager.default.copyItem(at: src, to: copy)
            for suffix in ["-wal", "-shm"] {   // the WAL carries the latest edits; the copy must open as one unit
                let side = URL(fileURLWithPath: src.path + suffix)
                if FileManager.default.fileExists(atPath: side.path) { try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                throw NSError(domain: "micloud.eventkit", code: 2, userInfo: [NSLocalizedDescriptionKey: "open: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "?")"])
            }
            defer { sqlite3_close(db) }
            var st: OpaquePointer?
            let sql = "SELECT ci.UUID, e.date FROM ExceptionDate e JOIN CalendarItem ci ON ci.ROWID = e.owner_id WHERE ci.UUID IS NOT NULL AND e.date IS NOT NULL;"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
                throw NSError(domain: "micloud.eventkit", code: 3, userInfo: [NSLocalizedDescriptionKey: "prepare: \(String(cString: sqlite3_errmsg(db)))"])
            }
            defer { sqlite3_finalize(st) }
            while sqlite3_step(st) == SQLITE_ROW {
                guard let c = sqlite3_column_text(st, 0) else { continue }
                map[String(cString: c), default: []].append(Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 1)))
            }
            NSLog("micloud calendars: exception dates read — %d series · %d dates", map.count, map.values.reduce(0) { $0 + $1.count })
        } catch {
            NSLog("micloud calendars: exception dates unavailable — %@ (Full Disk Access for micloud.app?)", "\(error)")
            map = [:]
        }
        lock.lock(); exdateCache = (mtime, map); lock.unlock()
        return map
    }

    private func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = String(s.unicodeScalars.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "item" : String(cleaned.prefix(60))
    }
    /// Stable across launches. `hashValue` is seeded per process, so until 2026-10-18 every relay restart gave
    /// every item a new filename — and an edit PUT under the new name was refused (UID already in the calendar).
    private func shortHash(_ s: String) -> String { String(stableHash(Data(s.utf8)).prefix(8)) }
}
