import SwiftUI
import AppKit
import Photos
import EventKit
import Contacts

/// The "what still needs a click" card. macOS prompts for Photos / Calendars / Reminders / Contacts on first
/// use and the Files folder is one open panel — but **Full Disk Access** (Safari bookmarks, Notes, Messages)
/// can only be switched on by the person in System Settings; no API can ask for it. So: every grant with a
/// live status, one button that lands on the exact Settings pane (or fires the system prompt when that is
/// still possible), and a re-check every few seconds so the card clears itself the moment they toggle it.
@MainActor final class PermissionsModel: ObservableObject {
    enum State { case granted, missing, unknown }
    struct Row: Identifiable {
        let id: String; let symbol: String; let state: State
        /// Settings pane id (`x-apple.systempreferences:com.apple.preference.security?<pane>`), nil = in-app prompt only.
        let pane: String?
        /// True while macOS will still show its own prompt (status "not determined"); after a deny only Settings helps.
        let canPrompt: Bool
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var requesting: Set<String> = []     // clicked, macOS prompt up, answer pending
    @Published private(set) var grantedAt: [String: Date] = [:]   // rows that went green THIS session, and when
    @Published private(set) var telemetryError: String? = nil     // LokiSink.lastError, shown under the localnet row
    static let linger: TimeInterval = 4                           // a green row stays this long, then leaves
    private var timer: Timer?
    private let ekStore = EKEventStore()        // retained: a request's prompt dies with its store
    private let cnStore = CNContactStore()
    var onDriveGranted: ((URL) -> Void)?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    var missing: [Row] { rows.filter { $0.state == .missing } }
    /// Rows worth showing: what is still missing, plus rows that went green in the last few seconds so the
    /// person sees the tick before the row leaves. Granted-at-launch rows never appear.
    var shown: [Row] {
        rows.filter { r in
            r.state == .missing || (r.state == .granted && grantedAt[r.id].map { Date().timeIntervalSince($0) < Self.linger } ?? false)
        }
    }
    var visible: Bool { !shown.isEmpty }

    func refresh() {
        var r: [Row] = []
        let ph = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        r.append(Row(id: "photos", symbol: "photo.on.rectangle",
                     state: (ph == .authorized || ph == .limited) ? .granted : .missing,
                     pane: "Privacy_Photos", canPrompt: ph == .notDetermined))
        r.append(ekRow("calendars", symbol: "calendar", type: .event, pane: "Privacy_Calendars"))
        r.append(ekRow("reminders", symbol: "checklist", type: .reminder, pane: "Privacy_Reminders"))
        let cn = CNContactStore.authorizationStatus(for: .contacts)
        r.append(Row(id: "contacts", symbol: "person.crop.circle", state: cn == .authorized ? .granted : .missing,
                     pane: "Privacy_Contacts", canPrompt: cn == .notDetermined))
        let driveOK = DriveGrant.hasSaved || (Production.on && Production.iCloudDriveReadable)
        r.append(Row(id: "drive", symbol: "folder", state: driveOK ? .granted : .missing, pane: nil, canPrompt: true))
        if Production.on {
            r.append(Row(id: "fda", symbol: "lock.open", state: Self.fullDiskAccess(), pane: "Privacy_AllFiles", canPrompt: false))
            // Telemetry to a Loki on the LAN / tailnet is gated by macOS "Local Network" privacy: a denied or
            // unanswered prompt makes every push fail silently. Surface the sink's own last error as a row.
            if let loki = MicloudApp.loki {
                let err = loki.lastError
                r.append(Row(id: "localnet", symbol: "antenna.radiowaves.left.and.right", state: err == nil ? .granted : .missing,
                             pane: "Privacy_LocalNetwork", canPrompt: false))
                telemetryError = err
            }
        }
        let before = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.state) })
        for row in r where row.state == .granted {
            requesting.remove(row.id)
            if before[row.id] == .missing { grantedAt[row.id] = Date() }     // transition → linger as green
        }
        rows = r
    }

    private func ekRow(_ id: String, symbol: String, type: EKEntityType, pane: String) -> Row {
        let st = EKEventStore.authorizationStatus(for: type)
        var granted = st == .authorized
        if #available(macOS 14, *) { granted = granted || st == .fullAccess }
        return Row(id: id, symbol: symbol, state: granted ? .granted : .missing, pane: pane, canPrompt: st == .notDetermined)
    }

    /// Full Disk Access has no API — probe it the way the lanes will: open a TCC-protected store read-only.
    /// EPERM = not granted. ENOENT on every candidate (a Mac that has never used Safari / Messages / Notes)
    /// = nothing to protect yet, reported as unknown so the card does not nag about it.
    static func fullDiskAccess() -> State {
        let home = RealHome.url
        let candidates = ["Library/Safari/Bookmarks.plist", "Library/Messages/chat.db",
                          "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"]
        var sawMissingFile = false
        for rel in candidates {
            let fd = open(home.appendingPathComponent(rel).path, O_RDONLY)
            if fd >= 0 { close(fd); return .granted }
            if errno == ENOENT { sawMissingFile = true; continue }
            return .missing            // EPERM / EACCES = TCC said no
        }
        return sawMissingFile ? .unknown : .missing
    }

    func grant(_ row: Row) {
        if row.canPrompt && row.id != "drive" { requesting.insert(row.id) }
        let done: @Sendable () -> Void = { Task { @MainActor in self.requesting.remove(row.id); self.refresh() } }
        switch row.id {
        case "photos" where row.canPrompt:
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in done() }
        case "calendars" where row.canPrompt, "reminders" where row.canPrompt:
            let type: EKEntityType = row.id == "calendars" ? .event : .reminder
            if #available(macOS 14, *) {
                if type == .event { ekStore.requestFullAccessToEvents { _, _ in done() } } else { ekStore.requestFullAccessToReminders { _, _ in done() } }
            } else { ekStore.requestAccess(to: type) { _, _ in done() } }
        case "contacts" where row.canPrompt:
            cnStore.requestAccess(for: .contacts) { _, _ in done() }
        case "drive":
            if let url = DriveGrant.prompt(suggested: Production.on ? Production.iCloudDrive : nil) { onDriveGranted?(url); refresh() }
        default:
            if let pane = row.pane, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

struct PermissionsCard: View {
    @ObservedObject var model: PermissionsModel
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let done = model.missing.isEmpty
        if model.visible {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: done ? "checkmark.seal.fill" : "hand.raised.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(done ? C.ok : C.pause)
                    Text(loc.t(done ? "perm.allDone" : "perm.title")).font(.system(size: 14.5, weight: .semibold)).foregroundColor(C.ink)
                }
                if !done {
                    Text(loc.t("perm.body")).font(.system(size: 12.5)).foregroundColor(C.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.shown) { row in
                    let granted = row.state == .granted
                    let waiting = model.requesting.contains(row.id)
                    HStack(spacing: 10) {
                        Image(systemName: granted ? "checkmark.circle.fill" : row.symbol)
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(granted ? C.ok : C.pause)
                            .frame(width: 28, height: 28).background(C.card).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loc.t("perm.\(row.id)")).font(.system(size: 13, weight: .semibold)).foregroundColor(C.ink)
                            Text(granted ? loc.t("perm.allowed") : waiting ? loc.t("perm.waiting")
                                 : row.id == "localnet" ? loc.t("perm.localnet.settings", model.telemetryError ?? "")
                                 : loc.t(row.canPrompt ? "perm.\(row.id).hint" : "perm.\(row.id).settings"))
                                .font(.system(size: 11.5)).foregroundColor(granted ? C.ok : C.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if granted {
                            Text(loc.t("perm.allowed")).font(.system(size: 12, weight: .semibold)).foregroundColor(C.ok)
                                .padding(.horizontal, 10).padding(.vertical, 5).background(C.okSoft).clipShape(Capsule())
                        } else if waiting {
                            ProgressView().controlSize(.small)
                        } else {
                            Button { model.grant(row) } label: {
                                Text(loc.t(row.canPrompt ? "perm.allow" : "perm.openSettings"))
                                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: 0x3A2600))
                                    .padding(.horizontal, 12).padding(.vertical, 7).background(C.accent).clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: granted)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(done ? C.okSoft : C.pauseSoft).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke((done ? C.ok : C.pause).opacity(0.35), lineWidth: 1))
            .animation(.easeInOut(duration: 0.3), value: done)
        }
    }
}


/// Browser → app hand-off for OAuth sign-ins. The app registers the `app.immich` URL scheme (build.sh
/// Info.plist); macOS delivers the callback URL here and whoever is waiting (the onboarding model) gets it.
@MainActor enum OAuthCallbacks {
    static var pending: ((URL) -> Void)?
    static func deliver(_ url: URL) { pending?(url) }
}
