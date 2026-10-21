import Foundation
import EventKit

/// A **stable** content fingerprint (FNV-1a) — unlike `Hasher`, it's identical across launches, so the
/// backfill ledger can tell an edited item from an unchanged one. Used by the live watchers.
func stableHash(_ data: Data) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(format: "%016llx", h)
}

/// Minimal, valid iCalendar (RFC 5545) serialisation for one event or reminder — enough to back each item
/// up as a `.ics` file Nextcloud (and any calendar app) can import. One VCALENDAR per item keeps the backfill
/// per-item (progress, quarantine, resume all work at item granularity).
enum ICS {
    /// One VCALENDAR for an event — or a whole recurring series: `e` is the master (its own start + RRULE),
    /// `detached` the occurrences the user edited individually (each a VEVENT with RECURRENCE-ID) and `exdates`
    /// the occurrences the user deleted (EXDATE, from the Calendar store — EventKit does not expose them). A
    /// date that is both detached and excepted is kept as the detached override: an EXDATE on the same instant
    /// would make the server drop the override.
    static func event(_ e: EKEvent, detached: [EKEvent] = [], exdates: [Date] = []) -> String {
        let overridden = detached.compactMap(\.occurrenceDate)
        let ex = exdates.filter { d in !overridden.contains { abs($0.timeIntervalSince(d)) < 1 } }
        var lines = vevent(e, master: true, exdates: ex)
        for d in detached { lines += vevent(d, master: false) }
        return wrap(lines.joined(separator: "\r\n"))
    }

    private static func vevent(_ e: EKEvent, master: Bool, exdates: [Date] = []) -> [String] {
        var lines = ["BEGIN:VEVENT"]
        lines.append("UID:\(e.calendarItemIdentifier)")
        if !master, let od = e.occurrenceDate { lines.append(e.isAllDay ? "RECURRENCE-ID;VALUE=DATE:\(day(od))" : "RECURRENCE-ID:\(dt(od))") }
        lines.append("SUMMARY:\(esc(e.title ?? "Untitled"))")
        if e.isAllDay {   // a date, not an instant — as UTC datetimes an all-day event lands on the wrong day east of Greenwich
            if let s = e.startDate { lines.append("DTSTART;VALUE=DATE:\(day(s))") }
            if let end = e.endDate { lines.append("DTEND;VALUE=DATE:\(day(end.addingTimeInterval(1)))") }   // EventKit end = 23:59:59; iCal end is exclusive
        } else {
            if let s = e.startDate { lines.append("DTSTART:\(dt(s))") }
            if let end = e.endDate { lines.append("DTEND:\(dt(end))") }
        }
        if master, let rules = e.recurrenceRules { for r in rules { lines.append("RRULE:\(rrule(r, allDay: e.isAllDay))") } }
        // One EXDATE per line, same value type as DTSTART (an all-day exception is stored as midnight UTC of
        // the day, so the UTC calendar day IS the day). Sorted: the bytes — and so the ledger hash — are stable.
        for d in exdates.sorted() { lines.append(e.isAllDay ? "EXDATE;VALUE=DATE:\(utcDay(d))" : "EXDATE:\(dt(d))") }
        if let loc = e.location, !loc.isEmpty { lines.append("LOCATION:\(esc(loc))") }
        if let notes = e.notes, !notes.isEmpty { lines.append("DESCRIPTION:\(esc(notes))") }
        lines.append("END:VEVENT")
        return lines
    }

    /// RFC 5545 §3.3.10 from an `EKRecurrenceRule`. UNTIL is a DATE for all-day series (must match DTSTART's type).
    static func rrule(_ r: EKRecurrenceRule, allDay: Bool) -> String {
        let names = ["", "SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        var parts: [String] = []
        let freq: String
        switch r.frequency {
        case .daily: freq = "DAILY"
        case .weekly: freq = "WEEKLY"
        case .monthly: freq = "MONTHLY"
        case .yearly: freq = "YEARLY"
        @unknown default: freq = "DAILY"
        }
        parts.append("FREQ=\(freq)")
        if r.interval > 1 { parts.append("INTERVAL=\(r.interval)") }
        if let end = r.recurrenceEnd {
            if let d = end.endDate { parts.append("UNTIL=\(allDay ? day(d) : dt(d))") }
            else if end.occurrenceCount > 0 { parts.append("COUNT=\(end.occurrenceCount)") }
        }
        if let days = r.daysOfTheWeek, !days.isEmpty {
            parts.append("BYDAY=" + days.map { ($0.weekNumber != 0 ? "\($0.weekNumber)" : "") + names[$0.dayOfTheWeek.rawValue] }.joined(separator: ","))
        }
        let numeric: [(String, [NSNumber]?)] = [("BYMONTHDAY", r.daysOfTheMonth), ("BYMONTH", r.monthsOfTheYear), ("BYWEEKNO", r.weeksOfTheYear),
                                                ("BYYEARDAY", r.daysOfTheYear), ("BYSETPOS", r.setPositions)]
        for (k, v) in numeric { if let v, !v.isEmpty { parts.append("\(k)=" + v.map { "\($0.intValue)" }.joined(separator: ",")) } }
        if r.firstDayOfTheWeek > 0 && r.firstDayOfTheWeek < names.count { parts.append("WKST=\(names[r.firstDayOfTheWeek])") }
        return parts.joined(separator: ";")
    }

    static func reminder(_ r: EKReminder) -> String {
        var lines = ["BEGIN:VTODO"]
        lines.append("UID:\(r.calendarItemIdentifier)")
        lines.append("SUMMARY:\(esc(r.title ?? "Untitled"))")
        if let due = r.dueDateComponents?.date { lines.append("DUE:\(dt(due))") }
        lines.append("STATUS:\(r.isCompleted ? "COMPLETED" : "NEEDS-ACTION")")
        if let notes = r.notes, !notes.isEmpty { lines.append("DESCRIPTION:\(esc(notes))") }
        lines.append("END:VTODO")
        return wrap(lines.joined(separator: "\r\n"))
    }

    private static func wrap(_ inner: String) -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//mineracks//micloud//EN\r\n\(inner)\r\nEND:VCALENDAR\r\n"
    }
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f
    }()
    private static func dt(_ d: Date) -> String { fmt.string(from: d) }
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current; f.dateFormat = "yyyyMMdd"; return f
    }()
    private static func day(_ d: Date) -> String { dayFmt.string(from: d) }
    private static let utcDayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd"; return f
    }()
    private static func utcDay(_ d: Date) -> String { utcDayFmt.string(from: d) }
    /// RFC 5545 TEXT escaping. Notes arrive with CRLF, lone CR and Unicode line separators — any raw line
    /// break that survives here becomes a line the server cannot parse ("Invalid Mimedir file", 96 events
    /// on the relay's first night). Everything that is a line break becomes the two characters `\n`.
    private static func esc(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        t = String(t.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 })   // drop other control chars
        return t.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: ";", with: "\\;")
         .replacingOccurrences(of: ",", with: "\\,")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
    /// Fold content lines at 75 octets (RFC 5545 §3.1). NOT applied: every folded object was refused by
    /// Nextcloud 32 ("Invalid Mimedir file") although sabre parses the same bytes fine in isolation — the
    /// server sees something else on the wire. Unfolded long lines are accepted by every CalDAV server we
    /// target, so the objects go out unfolded until that is understood. Kept for the record.
    static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out = "", cur = "", bytes = 0
        for ch in line {
            let n = ch.utf8.count
            if bytes + n > 74 { out += (out.isEmpty ? "" : "\r\n ") + cur; cur = ""; bytes = 0 }
            cur.append(ch); bytes += n
        }
        return out + (out.isEmpty ? "" : "\r\n ") + cur
    }
}
