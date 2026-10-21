import SwiftUI
import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

// micloud for iPhone — the Mac's sync dashboard in your pocket, and the Health lane the Mac cannot run.
//
// The Mac publishes `micloud/status.json` to the person's OWN Nextcloud (no micloud-central server): per-lane
// progress, rates, ETA, the activity graph and the live log — the same numbers its dashboard draws. This app
// signs in to that Nextcloud once (Login Flow v2, see Pairing.swift), renders that report at the cadence the
// Mac publishes it, and archives Apple Health to `Health/` on the same server (HealthArchive.swift), which the
// Mac's Health tile then reports. Built with swiftc against the iOS SDK (no Xcode project).

// ── palette (micloud brand) ──────────────────────────────────────────────────────
extension Color { init(h: UInt32) { self.init(.sRGB, red: Double((h>>16)&0xFF)/255, green: Double((h>>8)&0xFF)/255, blue: Double(h&0xFF)/255) } }
enum K {
    /// Widest the card column goes: an iPad shows the same column, centred, not a stretched phone.
    static let columnWidth: CGFloat = 680
    static let navy = Color(h: 0x131A2A), navy2 = Color(h: 0x0C1220), ground = Color(h: 0xEEF1F6)
    static let card = Color.white, ink = Color(h: 0x171F2E), inkSoft = Color(h: 0x5A6478), inkFaint = Color(h: 0x939CAF)
    static let line = Color(h: 0xE4E8F0), accent = Color(h: 0xF7931A), accentDeep = Color(h: 0xE27D0B), accentSoft = Color(h: 0xFFF2E0)
    static let ok = Color(h: 0x1F9E63), okSoft = Color(h: 0xE7F5EE), sync = Color(h: 0x2C7BE5), syncSoft = Color(h: 0xE7F0FD)
    static let err = Color(h: 0xE5484D), errSoft = Color(h: 0xFCEBEB), track = Color(h: 0xEAEEF5), barLight = Color(h: 0xFFC873)
}
func sc(_ s: SourceStatus) -> (Color, Color, String) {
    switch s {
    case .healthy: return (K.ok, K.okSoft, L("status.uptodate"))
    case .syncing: return (K.sync, K.syncSoft, L("status.syncing"))
    case .stale:   return (K.accentDeep, K.accentSoft, L("status.stale"))
    case .error:   return (K.err, K.errSoft, L("status.error"))
    case .disabled:return (K.inkFaint, K.line, L("status.off"))
    }
}
func phaseStyle(_ p: LaneReport.Phase) -> (Color, Color, String) {
    switch p {
    case .scanning:     return (K.sync, K.syncSoft, L("phase.scanning"))
    case .transferring: return (K.sync, K.syncSoft, L("phase.transferring"))
    case .paused:       return (K.accentDeep, K.accentSoft, L("phase.paused"))
    case .done:         return (K.ok, K.okSoft, L("phase.done"))
    case .blocked:      return (K.err, K.errSoft, L("phase.blocked"))
    case .stopped:      return (K.inkFaint, K.line, L("phase.stopped"))
    }
}
func sym(_ id: SourceID) -> String {
    switch id {
    case .photos: return "photo.on.rectangle.angled"; case .documents: return "folder"
    case .calendars: return "calendar"; case .contacts: return "person.crop.circle"
    case .reminders: return "checklist"; case .notes: return "note.text"
    case .bookmarks: return "bookmark"; case .mail: return "envelope"; case .health: return "heart"
    case .messages: return "message"
    }
}
func ago(_ d: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(d)))
    if s < 5 { return L("ago.now") }; if s < 60 { return L("ago.sec", "\(s)") }
    if s < 3600 { return L("ago.min", "\(s/60)") }; if s < 86400 { return L("ago.hour", "\(s/3600)") }
    return L("ago.day", "\(s/86400)")
}
func fmtBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]; return f.string(fromByteCount: b)
}
func fmtETA(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "—" }
    let m = Int(s / 60), h = m / 60
    if h >= 24 {
        // Half-days, as the Mac card: "~1½ days" says more than "~37h 12m" and less than a false "~1 day".
        let halves = Int((s / 43_200).rounded())
        let whole = halves / 2, half = halves % 2 == 1
        if halves == 2 { return L("eta.day") }
        return L("eta.days", half ? "\(whole)½" : "\(whole)")
    }
    if h > 0 { return L("eta.hours", "\(h)", "\(m % 60)") }
    if m > 0 { return L("eta.minutes", "\(m)") }
    return L("eta.underMinute")
}

// ── model: polls the Mac's report ───────────────────────────────────────────────
@MainActor final class StatusModel: ObservableObject {
    @Published var report: StatusReport?
    @Published var lastChecked: Date?
    @Published var error: String?
    @Published var loading = false
    @Published var tick = Date()
    var dav: NextcloudWebDAV?
    private var timer: Timer?

    init(dav: NextcloudWebDAV?) {
        self.dav = dav
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick = Date() } }
    }
    func refresh() async {
        guard let dav else { return }
        loading = true; defer { loading = false }
        do {
            let data = try await dav.fetch(StatusReport.remotePath)
            report = try StatusReport.decode(data); lastChecked = Date(); self.error = nil
        } catch is CancellationError {
            return                                   // polling was restarted; not a verdict on the Mac
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            NSLog("micloud status fetch failed: %@", "\(error)")
            // No report yet (a Mac that hasn't published) reads differently from "can't reach the server".
            self.error = report == nil ? L("err.noReport") : L("err.unreachable")
        }
    }
    /// Poll at the cadence the Mac says it publishes (floor 5 s) while the app is on screen.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            let every = max(5, report?.refreshSeconds ?? 15)
            try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
        }
    }
    var overall: SourceStatus { report?.overall ?? .disabled }
    var isFresh: Bool { report?.isFresh ?? false }
}

@main
struct MicloudPhoneApp: App {
    @StateObject private var pairing: Pairing
    @StateObject private var model: StatusModel
    @StateObject private var health: HealthArchive

    init() {
        let p = Pairing()
        _pairing = StateObject(wrappedValue: p)
        _model = StateObject(wrappedValue: StatusModel(dav: p.dav))
        _health = StateObject(wrappedValue: HealthArchive(dav: p.dav))
        // Must be registered before the app finishes launching, or iOS refuses the identifier.
        // This is what lets the historical backfill run overnight on the charger instead of
        // making someone sit and watch a progress bar.
        #if canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: HealthArchive.backfillTaskID, using: nil) { task in
            let work = Task { @MainActor in
                let archive = HealthArchive(dav: Pairing().dav)
                await archive.runBackfill(budget: 25)
                archive.scheduleBackfill()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Root(pairing: pairing, model: model, health: health)
        }
    }
}

struct Root: View {
    @ObservedObject var pairing: Pairing
    @ObservedObject var model: StatusModel
    @ObservedObject var health: HealthArchive
    @Environment(\.scenePhase) private var phase
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        Group {
            if pairing.isPaired { StatusScreen(pairing: pairing, model: model, health: health) }
            else { PairScreen(pairing: pairing) }
        }
        .onChange(of: pairing.dav == nil) { _, _ in
            model.dav = pairing.dav; health.dav = pairing.dav; model.report = nil; model.error = nil
            stopPolling(); startPolling()
        }
        .onChange(of: phase) { _, p in if p == .active { startPolling() } else { stopPolling() } }
        .task {
            startPolling()
            // Once Health has been turned on, every launch resumes it: a cold launch after a TestFlight
            // update must not leave the archive sitting on "0 records" with nothing to tap (2026-10-19 —
            // begin() only ran behind a simulator env flag or the Turn-on button, which hides once started).
            if pairing.isPaired, health.started || ProcessInfo.processInfo.environment["MICLOUD_HEALTH_AUTORUN"] == "1" {
                try? await Task.sleep(nanoseconds: 1_500_000_000); await health.begin()
            }
        }
    }
    /// Idempotent: the scene going active and the first `.task` both call this; a second start must not cancel
    /// the fetch the first one has in flight (that cancel surfaced as "your Mac hasn't published a status yet").
    private func startPolling() {
        guard pairing.isPaired, pollTask == nil else { return }
        pollTask = Task { await model.poll() }
    }
    private func stopPolling() { pollTask?.cancel(); pollTask = nil }
}

// ── pairing ─────────────────────────────────────────────────────────────────────
struct PairScreen: View {
    @ObservedObject var pairing: Pairing
    var body: some View {
        ZStack { K.ground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 10) {
                        HStack(spacing: 3) { Text("mi").foregroundColor(.white); Text("cloud").foregroundColor(K.accent) }
                            .font(.system(size: 30, weight: .semibold))
                        Text(L("pair.tagline")).font(.system(size: 13)).foregroundColor(Color.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 34)
                    .background(LinearGradient(colors: [K.navy, K.navy2], startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("pair.title")).font(.system(size: 19, weight: .bold)).foregroundColor(K.ink)
                        Text(L("pair.body")).font(.system(size: 13.5)).foregroundColor(K.inkSoft).fixedSize(horizontal: false, vertical: true)
                        Text(L("pair.server")).font(.system(size: 12, weight: .semibold)).foregroundColor(K.inkSoft)
                        TextField("https://cloud.example.com", text: $pairing.server)
                            .keyboardType(.URL).textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .font(.system(size: 15)).padding(12).background(K.ground).clipShape(RoundedRectangle(cornerRadius: 10))
                            .disabled(pairing.state == .signingIn)
                        if pairing.state == .signingIn {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L("pair.waiting")).font(.system(size: 12.5)).foregroundColor(K.inkSoft).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button(L("pair.cancel")) { pairing.cancel() }.font(.system(size: 12.5, weight: .semibold)).foregroundColor(K.inkSoft)
                            }.padding(10).background(K.syncSoft).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            Button { pairing.signIn() } label: {
                                HStack(spacing: 7) { Image(systemName: "person.badge.key.fill"); Text(L("pair.signin")) }
                                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(K.accent).clipShape(RoundedRectangle(cornerRadius: 12))
                            }.disabled(pairing.server.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if case .failed(let why) = pairing.state {
                            Text(why).font(.system(size: 12.5, weight: .medium)).foregroundColor(K.err).fixedSize(horizontal: false, vertical: true)
                        }
                        Text(L("pair.footnote")).font(.system(size: 11.5)).foregroundColor(K.inkFaint).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16).background(K.card).clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(K.line, lineWidth: 1))
                }
                .padding(16)
                .frame(maxWidth: K.columnWidth).frame(maxWidth: .infinity)
            }
        }
    }
}

// ── dashboard ───────────────────────────────────────────────────────────────────
struct StatusScreen: View {
    @ObservedObject var pairing: Pairing
    @ObservedObject var model: StatusModel
    @ObservedObject var health: HealthArchive
    @State private var showSettings = false
    @State private var showAllEvents = false

    private var laneOrder: [SourceID] { SourceID.allCases }

    var body: some View {
        ZStack(alignment: .top) {
            K.ground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    if let r = model.report {
                        if !r.isFresh { offlineNote(r) }
                        summary(r)
                        lanes(r)
                        healthCard
                        sources(r)
                        events(r)
                    } else if let e = model.error {
                        VStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 26)).foregroundColor(K.inkFaint)
                            Text(e).font(.subheadline).foregroundColor(K.inkSoft).multilineTextAlignment(.center)
                        }.padding(.vertical, 30).frame(maxWidth: .infinity)
                        healthCard
                    } else { ProgressView().padding(.top, 60) }
                }
                .padding(16)
                .frame(maxWidth: K.columnWidth).frame(maxWidth: .infinity)
            }
            .refreshable { await model.refresh() }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet(pairing: pairing, model: model) }
    }

    private var header: some View {
        let s = sc(model.report == nil ? .disabled : model.overall)
        return VStack(spacing: 12) {
            HStack {
                Spacer().frame(width: 30)
                Spacer()
                HStack(spacing: 3) { Text("mi").foregroundColor(.white); Text("cloud").foregroundColor(K.accent) }
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 15, weight: .semibold)).foregroundColor(Color.white.opacity(0.75))
                        .frame(width: 30, height: 30)
                }
            }
            HStack(spacing: 7) {
                Circle().fill(s.0).frame(width: 9, height: 9)
                Text(model.report == nil ? L("hdr.checking") : model.overall == .healthy ? L("hdr.protected")
                     : model.overall == .syncing ? L("hdr.syncing") : model.overall == .error ? L("hdr.attention") : L("hdr.idle"))
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(s.0)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(s.0.opacity(0.16)).overlay(Capsule().stroke(s.0.opacity(0.3), lineWidth: 1)).clipShape(Capsule())
            // The Mac's 60-second item series. Drawn whenever the Mac is reporting — flat included — with the Mac's
            // own caption; a minute inside one large video is a flat line and "0 this minute", not a missing graph
            // (it used to hide on all-zero, so the graph came and went with every big upload — 2026-10-18).
            if let r = model.report, r.isFresh, let a = r.activity, a.count > 1 {
                VStack(spacing: 3) {
                    Sparkline(values: a).frame(height: 34)
                    HStack {
                        Text(L("activity.window")).font(.system(size: 10.5)).foregroundColor(Color.white.opacity(0.55))
                        Spacer()
                        Text(L("activity.total", Int(a.reduce(0, +)))).font(.system(size: 10.5)).foregroundColor(Color.white.opacity(0.55)).monospacedDigit()
                    }
                }.padding(.horizontal, 18)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 14).padding(.bottom, 18)
        .background(LinearGradient(colors: [K.navy, K.navy2], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func offlineNote(_ r: StatusReport) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(K.accentDeep)
            Text(L("hdr.offline", r.host, ago(r.generatedAt, now: model.tick))).font(.system(size: 12.5, weight: .semibold)).foregroundColor(K.accentDeep)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(K.accentSoft).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func summary(_ r: StatusReport) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(r.host).font(.system(size: 16, weight: .semibold)).foregroundColor(K.ink)
                Text(L("summary.reported", ago(r.generatedAt, now: model.tick))).font(.system(size: 12.5)).foregroundColor(K.inkFaint)
            }
            Spacer()
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(K.accentDeep)
                    .padding(9).background(K.accentSoft).clipShape(Circle())
                    .opacity(model.loading ? 0.5 : 1)
            }
        }
        .padding(14).background(K.card).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(K.line, lineWidth: 1))
    }

    /// The backfill cards — same numbers and rules as the Mac's cards, laid out one per row.
    @ViewBuilder private func lanes(_ r: StatusReport) -> some View {
        let jobs = r.lanes ?? [:]
        let visible = laneOrder.filter { id in jobs[id].map { $0.phase != .done || $0.quarantined > 0 } ?? false }
        if !visible.isEmpty {
            VStack(spacing: 10) {
                ForEach(visible, id: \.self) { id in LaneCard(id: id, lane: jobs[id]!, hb: r.snapshot.heartbeats[id]) }
            }
        }
    }

    /// Every source the Mac has wired, as a compact row (lanes with a live card are summarised here too).
    private func sources(_ r: StatusReport) -> some View {
        let ids = laneOrder.filter { r.snapshot.heartbeats[$0] != nil }
        return VStack(spacing: 0) {
            ForEach(ids, id: \.self) { id in
                if let hb = r.snapshot.heartbeats[id] {
                    row(id, hb, lane: r.lanes?[id])
                    if id != ids.last { Divider().padding(.leading, 52) }
                }
            }
        }
        .background(K.card).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(K.line, lineWidth: 1))
    }

    private func row(_ id: SourceID, _ hb: Heartbeat, lane: LaneReport?) -> some View {
        let waiting = hb.status == .healthy && (lane?.deferred?.count ?? 0) > 0
        let s = waiting ? (K.accentDeep, K.accentSoft, L("status.waiting")) : sc(hb.status)
        let detail: String? = lane.map { l in
            if let d = l.deferred { return "\(l.settled.formatted()) backed up · \(d.count.formatted()) \(d.reason)" }
            return l.phase == .done ? L("row.done", l.settled.formatted(), l.skipped.formatted())
                                    : L("row.progress", l.settled.formatted(), l.total.formatted())
        } ?? hb.lastItem
        return HStack(spacing: 12) {
            Image(systemName: sym(id)).font(.system(size: 15, weight: .medium)).foregroundColor(K.accentDeep)
                .frame(width: 30, height: 30).background(K.accentSoft).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName(id)).font(.system(size: 15, weight: .semibold)).foregroundColor(K.ink)
                if let d = detail { Text(d).font(.system(size: 12)).foregroundColor(K.inkFaint).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let c = hb.itemCount { Text(c.formatted()).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(K.ink) }
                HStack(spacing: 5) {
                    Circle().fill(s.0).frame(width: 6, height: 6)
                    Text(s.2).font(.system(size: 11, weight: .semibold)).foregroundColor(s.0)
                }.padding(.horizontal, 7).padding(.vertical, 2).background(s.1).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder private func events(_ r: StatusReport) -> some View {
        if let ev = r.events, !ev.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("live.title")).font(.system(size: 13, weight: .semibold)).foregroundColor(K.inkSoft)
                    Spacer()
                    if ev.count > 8 {
                        Button(showAllEvents ? L("live.less") : L("live.more")) { withAnimation { showAllEvents.toggle() } }
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(K.accentDeep)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
                ForEach(Array((showAllEvents ? ev : Array(ev.prefix(8))).enumerated()), id: \.offset) { _, hb in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ago(hb.timestamp, now: model.tick)).font(.system(size: 11)).monospacedDigit().foregroundColor(K.inkFaint).frame(width: 52, alignment: .leading)
                        Circle().fill(sc(hb.status).0).frame(width: 6, height: 6).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sourceName(hb.source)).font(.system(size: 11.5, weight: .semibold)).foregroundColor(K.inkSoft)
                            if let it = hb.lastItem { Text(it).font(.system(size: 11.5)).foregroundColor(K.ink).lineLimit(2) }
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 14).padding(.vertical, 6)
                }
            }
            .padding(.bottom, 6)
            .background(K.card).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(K.line, lineWidth: 1))
        }
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill").font(.system(size: 15)).foregroundColor(.white)
                    .frame(width: 30, height: 30).background(K.err).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("health.title")).font(.system(size: 15, weight: .semibold)).foregroundColor(K.ink)
                    Text(L("health.subtitle")).font(.system(size: 12)).foregroundColor(K.inkFaint)
                }
                Spacer()
                if health.started {
                    HStack(spacing: 5) {
                        Circle().fill(K.ok).frame(width: 6, height: 6)
                        Text(L("health.on")).font(.system(size: 11, weight: .semibold)).foregroundColor(K.ok)
                    }.padding(.horizontal, 7).padding(.vertical, 2).background(K.okSoft).clipShape(Capsule())
                }
            }
            if !health.summary.isEmpty {
                Text(health.summary).font(.system(size: 12.5)).foregroundColor(K.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            // A thin, non-blocking bar. The backfill keeps running whether or not this is on screen.
            if let p = health.backfillProgress {
                ProgressView(value: p).tint(K.accent).scaleEffect(x: 1, y: 0.6, anchor: .center)
            }
            if !health.started || health.busy {
                Button { Task { await health.begin() } } label: {
                    HStack(spacing: 7) {
                        if health.busy { ProgressView().controlSize(.small).tint(.white) }
                        Text(health.busy ? L("health.busy") : L("health.action"))
                    }
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(K.accent).clipShape(RoundedRectangle(cornerRadius: 11))
                }.disabled(health.busy)
            } else {
                Text(L("health.auto")).font(.system(size: 11.5)).foregroundColor(K.inkFaint).fixedSize(horizontal: false, vertical: true)
                // Always a way to nudge it by hand — "On" with a stale count and no button is a dead end.
                Button { Task { await health.begin() } } label: {
                    Text(L("health.checknow")).font(.system(size: 13, weight: .semibold)).foregroundColor(K.accentDeep)
                }.buttonStyle(.plain)
            }
        }
        .padding(14).background(K.card).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(K.line, lineWidth: 1))
    }
}

/// One backfill lane, the Mac card's numbers on a phone-width card.
struct LaneCard: View {
    let id: SourceID
    let lane: LaneReport
    let hb: Heartbeat?
    var body: some View {
        let ps = phaseStyle(lane.phase)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: sym(id)).font(.system(size: 14, weight: .medium)).foregroundColor(K.accentDeep)
                    .frame(width: 28, height: 28).background(K.accentSoft).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(sourceName(id)).font(.system(size: 15, weight: .semibold)).foregroundColor(K.ink)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(ps.0).frame(width: 6, height: 6)
                    Text(ps.2).font(.system(size: 11, weight: .semibold)).foregroundColor(ps.0)
                }.padding(.horizontal, 8).padding(.vertical, 3).background(ps.1).clipShape(Capsule())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(K.track)
                    Capsule().fill(LinearGradient(colors: [K.barLight, K.accent], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * lane.fraction))
                }
            }.frame(height: 9)
            // Three per row; a phone is not wide enough for five numbers on one line.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                metric("\(lane.settled.formatted()) / \(lane.total.formatted())", L("metric.files"))
                metric("\(fmtBytes(lane.confirmedBytes)) / \(fmtBytes(lane.totalBytes))", L("metric.data"))
                if lane.skipped > 0 { metric(lane.skipped.formatted(), L("metric.already")) }
                if lane.phase == .transferring {
                    if lane.rate > 0 { metric("\(fmtBytes(Int64(lane.rate)))/s", L("metric.speed")) }
                    metric(lane.stalled == true ? L("eta.waiting") : lane.etaSeconds.map(fmtETA) ?? "—", L("metric.est"))
                }
            }
            // Fan-out lanes (photos → Immich + Nextcloud): one row per target, by file count like the Mac card.
            // The lane bar above is the slowest of them; these say which is which. Not while scanning — until the
            // reconcile has listed each target the rows would all read 0 %.
            if let targets = lane.targets, targets.count > 1, lane.phase != .scanning {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(targets, id: \.name) { t in TargetRow(lane: lane, target: t) }
                }
            }
            if lane.failed > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundColor(K.accentDeep)
                    Text(L("lane.retrying", lane.failed.formatted())).font(.system(size: 12)).foregroundColor(K.accentDeep)
                }
            }
            if let d = lane.deferred {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 11)).foregroundColor(K.accentDeep)
                    Text("\(d.count.formatted()) \(d.reason)").font(.system(size: 12)).foregroundColor(K.accentDeep)
                }
            }
            if let k = lane.kept, k > 0 {
                Text(L("lane.kept", k.formatted())).font(.system(size: 12)).foregroundColor(K.inkFaint)
            }
            if lane.quarantined > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(K.accentDeep)
                    Text(L("lane.unreadable", lane.quarantined.formatted())).font(.system(size: 12)).foregroundColor(K.accentDeep)
                }
            }
            if let note = lane.capacityNote {
                Text(L("lane.capacity", note)).font(.system(size: 12, weight: .medium)).foregroundColor(K.err).fixedSize(horizontal: false, vertical: true)
            }
            if !lane.lastItem.isEmpty {
                Text(lane.lastItem).font(.system(size: 11.5)).foregroundColor(K.inkFaint).lineLimit(2)
            }
        }
        .padding(14).background(K.card).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(K.line, lineWidth: 1))
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundColor(K.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10.5)).foregroundColor(K.inkFaint)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One target's share of a fan-out lane: name and "97% · 5,573 files · 374 GB to go" on the first line, its own
/// thin bar under them (a phone is not wide enough for name + bar + text on one line).
struct TargetRow: View {
    let lane: LaneReport
    let target: TargetProgress
    var body: some View {
        let denominator = max(1, lane.total - lane.quarantined)
        let f = lane.total > 0 ? min(1, Double(target.settled) / Double(denominator)) : 0
        let remItems = max(0, lane.total - target.settled - lane.quarantined)
        let remBytes = max(0, lane.totalBytes - target.settledBytes - lane.quarantinedBytes)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(target.name).font(.system(size: 12, weight: .semibold)).foregroundColor(K.ink)
                Spacer(minLength: 6)
                Text(remItems == 0
                     ? L("lane.target.complete", target.settled.formatted())
                     : L("lane.target.toGo", "\(Int((f * 100).rounded()))%", remItems.formatted(), fmtBytes(remBytes)))
                    .font(.system(size: 11.5)).monospacedDigit().foregroundColor(K.inkFaint).lineLimit(1).minimumScaleFactor(0.8)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(K.track)
                    Capsule().fill(remItems == 0 ? K.ok : K.accent).frame(width: max(3, geo.size.width * f))
                }
            }.frame(height: 5)
        }
    }
}

/// The Mac's 60-second activity series as a small line.
struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            let maxV = max(1, values.max() ?? 1)
            let n = max(1, values.count - 1)
            let inset: CGFloat = 2    // keep a flat (all-zero) line inside the frame instead of on its bottom edge
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(n)
                    let y = inset + (geo.size.height - 2 * inset) * (1 - CGFloat(v / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(K.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var pairing: Pairing
    @ObservedObject var model: StatusModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section(L("settings.account")) {
                    LabeledContent(L("settings.server"), value: pairing.serverHost)
                    LabeledContent(L("settings.user"), value: pairing.user ?? "—")
                    if let r = model.report {
                        LabeledContent(L("settings.mac"), value: r.host)
                        LabeledContent(L("settings.macVersion"), value: r.appVersion)
                    }
                }
                Section {
                    Button(role: .destructive) { pairing.signOut(); dismiss() } label: { Text(L("settings.signout")) }
                } footer: { Text(L("settings.signout.note")) }
            }
            .navigationTitle(L("settings.title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("btn.done")) { dismiss() } } }
        }
    }
}
