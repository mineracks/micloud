import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// ── pairing (Mac → iPhone) ──────────────────────────────────────────────────────
/// Build the pairing payload the iPhone scans: the Nextcloud URL + username + app-password, base64 in a
/// `micloud://pair?d=` URL. Read from the paired creds (dev: env).
func pairingPayload() -> String? {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["NEXTCLOUD_URL"], let u = env["NEXTCLOUD_USER"], let p = env["NEXTCLOUD_PASS"] else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: ["url": url, "user": u, "pass": p]) else { return nil }
    return "micloud://pair?d=" + data.base64EncodedString()
}
func qrImage(_ text: String) -> Image? {
    let ctx = CIContext()
    let f = CIFilter.qrCodeGenerator(); f.message = Data(text.utf8); f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)),
          let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
    return Image(decorative: cg, scale: 1)
}

struct PairingSheet: View {
    @EnvironmentObject var loc: Localizer
    let dismiss: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text(loc.t("pair.title")).font(.system(size: 20, weight: .bold)).foregroundColor(C.ink)
            Text(loc.t("pair.subtitle")).font(.system(size: 13)).foregroundColor(C.inkSoft).multilineTextAlignment(.center)
            if let payload = pairingPayload(), let img = qrImage(payload) {
                img.interpolation(.none).resizable().frame(width: 220, height: 220)
                    .padding(14).background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.line, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(loc.t("pair.warn")).font(.system(size: 11.5)).foregroundColor(C.inkFaint).multilineTextAlignment(.center)
            } else {
                Text(loc.t("pair.noConfig")).font(.system(size: 13)).foregroundColor(C.inkFaint).padding(.vertical, 40)
            }
            Button(action: dismiss) {
                Text(loc.t("btn.done")).font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: 0x3A2600))
                    .padding(.horizontal, 22).padding(.vertical, 8).background(C.accent).clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .padding(28).frame(width: 380).background(C.ground)
    }
}

// ── design tokens (from web/dashboard-mockup.html) ──────────────────────────────
enum C {
    // "The Personal Archive" palette (publish/… website DESIGN.md, 2026-10-21): paper surfaces, evergreen
    // structure, leaf accents, clay for interaction. Status colours stay semantic but sit in the same key.
    static let navy   = Color(hex: 0x183E34)   // evergreen — hero + dark surfaces
    static let navy2  = Color(hex: 0x10302A)
    static let ground = Color(hex: 0xF5F3EB)   // paper
    static let card   = Color(hex: 0xFFFEF9)
    static let ink    = Color(hex: 0x1D302B)
    static let inkSoft = Color(hex: 0x56645B)
    static let inkFaint = Color(hex: 0x89988A)
    static let line   = Color(hex: 0xD4D8CD)
    static let accent = Color(hex: 0xBA562C)   // clay — interaction, focus, Pro
    static let accentDeep = Color(hex: 0x9E4722)
    static let accentSoft = Color(hex: 0xF3E4DC)
    static let leaf = Color(hex: 0xD5E8AD)     // leaf — DIY / selection / highlight on evergreen
    static let ok = Color(hex: 0x2D5647);   static let okSoft = Color(hex: 0xE3EFD3)
    static let sync = Color(hex: 0x3B6E8F); static let syncSoft = Color(hex: 0xE2ECF1)
    static let err = Color(hex: 0xB3362F);  static let errSoft = Color(hex: 0xF6E2DF)
    static let pause = Color(hex: 0x9A6A1E); static let pauseSoft = Color(hex: 0xF4ECD8)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF)/255, green: Double((hex >> 8) & 0xFF)/255,
                  blue: Double(hex & 0xFF)/255, opacity: 1)
    }
}

// per-source presentation: a localization key for the title + SF Symbol + the (non-localized) target name.
struct SourceMeta { let titleKey: String; let symbol: String; let target: String }
func meta(_ id: SourceID) -> SourceMeta {
    switch id {
    case .photos:    return .init(titleKey: "source.photos", symbol: "photo.on.rectangle.angled", target: "Immich + Nextcloud")
    case .documents: return .init(titleKey: "source.documents", symbol: "folder", target: "Nextcloud")
    case .calendars: return .init(titleKey: "source.calendars", symbol: "calendar", target: "CalDAV")
    case .contacts:  return .init(titleKey: "source.contacts", symbol: "person.crop.circle", target: "CardDAV")
    case .reminders: return .init(titleKey: "source.reminders", symbol: "checklist", target: "CalDAV")
    case .notes:     return .init(titleKey: "source.notes", symbol: "note.text", target: "Nextcloud")
    case .bookmarks: return .init(titleKey: "source.bookmarks", symbol: "bookmark", target: "Nextcloud")
    case .mail:      return .init(titleKey: "source.mail", symbol: "envelope", target: "maildir")
    case .messages:  return .init(titleKey: "source.messages", symbol: "message", target: "Nextcloud")
    case .health:    return .init(titleKey: "source.health", symbol: "heart", target: "your store")
    }
}

func statusColor(_ s: SourceStatus) -> (fg: Color, bg: Color, key: String) {
    switch s {
    case .healthy:  return (C.ok, C.okSoft, "status.uptodate")
    case .syncing:  return (C.sync, C.syncSoft, "status.syncing")
    case .stale:    return (C.accentDeep, C.accentSoft, "status.stale")
    case .error:    return (C.err, C.errSoft, "status.error")
    case .disabled: return (C.inkFaint, C.line, "status.off")
    }
}

func ago(_ date: Date, now: Date, loc: Localizer) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 3 { return loc.t("ago.now") }
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s/60)m" }
    if s < 86400 { return "\(s/3600)h" }
    return "\(s/86400)d"
}

// ── model: subscribes to the live HealthStore ───────────────────────────────────
final class DashboardModel: ObservableObject {
    @Published var snapshot = HealthSnapshot()
    @Published var events: [Heartbeat] = []
    @Published var tick = Date()                 // drives relative-time refresh
    @Published var enabled: Set<SourceID>        // sources actually wired this session (tiles go live)
    @Published var activity: [Double] = Array(repeating: 0, count: 60)   // per-second item throughput, last 60s
    @Published var entitlement: Entitlement = Entitlement.current()      // free vs Pro (unlocks the Pro tiles)
    @Published var recoveryBackedUp = InstallStore.load().recoveryBackedUp   // false → nudge to write the phrase down
    // Monitor mode (see RemoteFeed): the dashboard is another Mac's. No controls, no permissions, no nudges.
    @Published var readOnly = false
    @Published var watchedHost: String? = nil
    @Published var remoteGeneratedAt: Date? = nil
    @Published var remoteNote: String? = nil      // "waiting" (no report yet) / "offline" (report gone stale)
    @Published var mirroredToday: Int? = nil       // monitor mode: the publishing Mac's count since its midnight
    private var lastActivity = 0
    let store: HealthStore
    var onSyncNow: (() -> Void)?
    var onPauseBackfill: ((SourceID) -> Void)?
    var onResumeBackfill: ((SourceID) -> Void)?
    var onStopBackfill: ((SourceID) -> Void)?
    var onRetryBackfill: ((SourceID) -> Void)?     // "Retry" on the couldn't-be-transferred line
    var onConfirmBackfill: ((SourceID) -> Void)?   // "back up anyway" past the capacity warning
    var onDriveGranted: ((URL) -> Void)?           // permissions card granted the Files folder after launch
    private var token: UUID?
    private var timer: Timer?

    init(store: HealthStore, enabled: Set<SourceID> = []) {
        self.store = store; self.enabled = enabled
        token = store.observe { [weak self] snap in
            let evs = self?.store.recentEvents(40) ?? []
            DispatchQueue.main.async { self?.snapshot = snap; self?.events = evs }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = self.store.activityCount()
            DispatchQueue.main.async {
                self.tick = Date()
                if self.readOnly { return }          // the remote report carries its own activity series
                let delta = max(0, count - self.lastActivity); self.lastActivity = count
                self.activity.append(Double(delta))
                if self.activity.count > 60 { self.activity.removeFirst(self.activity.count - 60) }
            }
        }
    }

    /// The overall pill: worst of the *enabled* sources.
    var overall: SourceStatus {
        let active = enabled.compactMap { snapshot.heartbeats[$0]?.status }.filter { $0 != .disabled }
        if active.contains(.error) { return .error }
        if active.contains(.stale) { return .stale }
        if active.contains(.syncing) { return .syncing }
        return active.isEmpty ? .disabled : .healthy
    }
    var lastChange: Date? { snapshot.heartbeats.values.filter { $0.status != .disabled }.map(\.timestamp).max() }
    /// Items mirrored since midnight: the relay's own persisted count, or (monitor mode) the one it publishes.
    var mirroredTodayCount: Int { readOnly ? (mirroredToday ?? 0) : store.mirroredToday() }

    @MainActor func enable(_ id: SourceID) { enabled.insert(id) }

    /// The user has now written their recovery phrase down — clear the nudge.
    @MainActor func confirmBackedUp() {
        var i = InstallStore.load(); i.recoveryBackedUp = true; InstallStore.save(i); recoveryBackedUp = true
    }

    /// Validate + store a pasted Pro license token. Returns true if it was genuine + unexpired (tiles unlock).
    @MainActor func applyLicense(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ent = Entitlement.store(t) else { return false }
        entitlement = ent
        return true
    }
}

// ── root view ───────────────────────────────────────────────────────────────────
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var backfill: BackfillModel
    @EnvironmentObject var loc: Localizer
    @StateObject private var perms = PermissionsModel()

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model, backfill: backfill)
            if model.readOnly { MonitorBanner(model: model) }
            if !model.recoveryBackedUp && !model.readOnly { BackupNudge(model: model) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Lead(model: model, backfill: backfill)
                    if !model.readOnly {
                        PermissionsCard(model: perms)      // only renders while a grant is still missing
                            .onAppear { perms.onDriveGranted = { model.onDriveGranted?($0) } }
                    }
                    // Two-column layout so the LANE TILES (left) and the ACTIVITY GRAPH + LIVE SYNC LOG
                    // (right rail) are ALL visible at once on a normal window — no scrolling to reach the
                    // graph/log. A direct HStack (not ViewThatFits) because the tiles/hero are width-greedy,
                    // so ViewThatFits would always see the HStack's ideal width as "too big" and fall back.
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            Hero(model: model)
                            TilesGrid(model: model, backfill: backfill)
                            BackfillPanel(model: model, backfill: backfill)
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        VStack(spacing: 14) {
                            ActivityPanel(model: model)
                            LivePanel(model: model)
                        }
                        .frame(width: 300)
                    }
                    Footer()
                }
                .padding(EdgeInsets(top: 16, leading: 22, bottom: 18, trailing: 22))
            }
            .background(C.ground)
        }
        .frame(minWidth: 940, minHeight: 560)
        .background(C.ground)
        .environment(\.layoutDirection, loc.effective.isRTL ? .rightToLeft : .leftToRight)
    }
}

/// Lanes that are healthy on paper but whose source is still holding items back (iCloud has not delivered them
/// yet) — the tiles show these as "Waiting". The headline must never say "everything's protected" while one of
/// them is non-empty: freshness and exceptions beat a blanket healthy line (website design brief, 2026-10-21).
func waitingLanes(_ model: DashboardModel, _ backfill: BackfillModel) -> [SourceID] {
    SourceID.allCases.filter { id in
        model.enabled.contains(id) && model.snapshot.heartbeats[id]?.status == .healthy
            && (backfill.jobs[id]?.progress.deferred?.count ?? 0) > 0
    }
}

private struct HeaderBar: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var backfill: BackfillModel
    @EnvironmentObject var loc: Localizer
    @State private var showLang = false
    @State private var showLicense = false
    var body: some View {
        let waiting = model.overall == .healthy && !waitingLanes(model, backfill).isEmpty
        let sc = statusColor(waiting ? .stale : model.overall)
        let label = waiting ? "header.catchingUp"
                  : model.overall == .healthy ? "header.protected"
                  : model.overall == .syncing ? "header.syncing"
                  : model.overall == .error ? "header.attention" : "header.idle"
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                Text("mi").foregroundColor(.white)
                Text("cloud").foregroundColor(C.accent)
            }.font(.system(size: 16, weight: .semibold)).kerning(-0.2)
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(sc.fg).frame(width: 8, height: 8)
                Text(loc.t(label)).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundColor(sc.fg)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(sc.fg.opacity(0.16))
            .overlay(Capsule().stroke(sc.fg.opacity(0.3), lineWidth: 1))
            .clipShape(Capsule())
            proControl
            Button { showLang.toggle() } label: {
                HStack(spacing: 4) {
                    if loc.language == .system {
                        Image(systemName: "globe").font(.system(size: 11, weight: .semibold))
                    } else {
                        Text(loc.effective.flag).font(.system(size: 12))
                    }
                    Text(loc.language == .system ? "Auto" : loc.effective.code).font(.system(size: 11, weight: .bold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                }
                .foregroundColor(Color(hex: 0xCED7E7))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Color.white.opacity(0.08))
                .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain).help(loc.t("lang.title"))
            .popover(isPresented: $showLang, arrowEdge: .bottom) {
                LanguagePopover(loc: loc, dismiss: { showLang = false })
            }
            if !model.readOnly {
                Button { model.onSyncNow?() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundColor(C.inkFaint.opacity(0.9))
                .help(loc.t("header.syncNow"))
            }
        }
        .padding(.horizontal, 20).frame(height: 52)
        .background(LinearGradient(colors: [C.navy, C.navy2], startPoint: .top, endPoint: .bottom))
        .sheet(isPresented: $showLicense) { LicenseSheet(model: model, dismiss: { showLicense = false }) }
    }

    /// Pro state in the header: a solid PRO badge once unlocked, otherwise an "Unlock Pro" button.
    @ViewBuilder private var proControl: some View {
        if model.entitlement.isPro {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 10, weight: .bold))
                Text(loc.t("pro.badge")).font(.system(size: 10.5, weight: .bold)).kerning(0.4)
            }
            .foregroundColor(C.ok)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(C.ok.opacity(0.16)).overlay(Capsule().stroke(C.ok.opacity(0.35), lineWidth: 1)).clipShape(Capsule())
            .help(model.entitlement.payload?.plan ?? "pro")
        } else {
            Button { showLicense = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                    Text(loc.t("pro.unlock")).font(.system(size: 10.5, weight: .bold)).kerning(0.2)
                }
                .foregroundColor(Color(hex: 0x3A2600))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(C.accent).clipShape(Capsule())
            }.buttonStyle(.plain).help(loc.t("pro.unlock"))
        }
    }
}

/// Paste-a-license-key sheet. The token is verified **on-device** against the embedded Ed25519 public key —
/// no network call — so unlocking works fully offline and can't be spoofed. Links out to buy Pro if needed.
private struct LicenseSheet: View {
    @ObservedObject var model: DashboardModel
    let dismiss: () -> Void
    @EnvironmentObject var loc: Localizer
    @State private var token = ""
    @State private var error = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 40, height: 40).background(C.accent).clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("pro.sheet.title")).font(.system(size: 17, weight: .bold)).foregroundColor(C.ink)
                    Text(loc.t("pro.sheet.body")).font(.system(size: 12)).foregroundColor(C.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TextEditor(text: $token)
                .font(.system(size: 11.5, design: .monospaced)).foregroundColor(C.ink)
                .frame(height: 74).padding(8).scrollContentBackground(.hidden).background(C.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(error ? C.err : C.line, lineWidth: 1))
            if error { Text(loc.t("pro.sheet.invalid")).font(.system(size: 12, weight: .medium)).foregroundColor(C.err) }
            HStack {
                Link(loc.t("pro.sheet.buy"), destination: URL(string: "https://getmicloud.com/pricing")!)
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(C.sync)
                Spacer()
                Button(loc.t("btn.done")) { dismiss() }.buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium)).foregroundColor(C.inkSoft)
                Button {
                    if model.applyLicense(token) { dismiss() } else { error = true }
                } label: {
                    Text(loc.t("pro.sheet.unlock")).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Color(hex: 0x3A2600))
                        .padding(.horizontal, 18).padding(.vertical, 8).background(C.accent).clipShape(Capsule())
                }.buttonStyle(.plain).disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22).frame(width: 420).background(C.ground)
    }
}

private struct Lead: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var backfill: BackfillModel
    @EnvironmentObject var loc: Localizer
    var body: some View {
        let waiting = waitingLanes(model, backfill)
        let catchingUp = model.overall == .syncing || !waiting.isEmpty
        let key = model.overall == .error ? "lead.attention" : catchingUp ? "lead.almost" : "lead.protected"
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(loc.t(key))
                    .font(.system(size: 23, weight: .bold)).kerning(-0.3).foregroundColor(C.ink)
                Spacer()
                if let last = model.lastChange {
                    Text(loc.t("lead.lastChange", ago(last, now: model.tick, loc: loc)))
                        .font(.system(size: 13)).foregroundColor(C.inkSoft)
                }
            }
            // name the exception rather than hide it behind the headline: "Mail is waiting on Apple."
            if !waiting.isEmpty {
                Text(loc.t("lead.waiting", waiting.map { loc.t(meta($0).titleKey) }.joined(separator: ", ")))
                    .font(.system(size: 13)).foregroundColor(C.inkSoft)
            }
        }
    }
}

private struct Hero: View {
    @ObservedObject var model: DashboardModel
    @EnvironmentObject var loc: Localizer
    var body: some View {
        let mirrored = model.mirroredTodayCount
        let photoTotal = model.snapshot.heartbeats[.photos]?.itemCount ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("hero.eyebrow"))
                .font(.system(size: 10.5, weight: .semibold)).kerning(1.1).foregroundColor(C.accent)
            bodyText.font(.system(size: 13)).foregroundColor(Color(hex: 0xC7CEDD))
            HStack(spacing: 16) {
                stat("\(mirrored)", loc.t("hero.stat.mirrored"))
                stat(photoTotal > 0 ? photoTotal.formatted() : "—", loc.t("hero.stat.library"))
                stat(loc.t("hero.stat.oneway"), loc.t("hero.stat.oneway.label"))
            }.padding(.top, 2)
        }
        .padding(EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [C.navy, Color(hex: 0x1B2436)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    private var bodyText: Text {
        if let attr = try? AttributedString(markdown: loc.t("hero.body")) { return Text(attr) }
        return Text(loc.t("hero.body"))
    }
    private func stat(_ big: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(big).font(.system(size: 16, weight: .bold)).foregroundColor(.white).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundColor(Color(hex: 0x8B94AA))
        }
    }
}

private struct TilesGrid: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var backfill: BackfillModel
    // Fixed 3 columns → the 9 lanes form a tidy 3×3 that fits ABOVE the fold next to the activity rail (no
    // scrolling to reach a lane's badge — important once every lane's tile is a demo beat).
    let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    var body: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(SourceID.allCases, id: \.self) { id in
                SourceTile(id: id, hb: model.snapshot.heartbeats[id], job: backfill.jobs[id],
                           enabled: model.enabled.contains(id), isPro: model.entitlement.isPro, now: model.tick)
            }
        }
    }
}

// Persistent nudge shown until the user has written their recovery phrase down (they can defer it during
// onboarding — value first). Tapping opens the phrase again so they can back it up any time.
/// Monitor mode strip under the header: whose dashboard this is, and whether that Mac is still reporting.
private struct MonitorBanner: View {
    @ObservedObject var model: DashboardModel
    @EnvironmentObject var loc: Localizer
    var body: some View {
        let offline = model.remoteNote == "offline"
        let waiting = model.watchedHost == nil
        HStack(spacing: 8) {
            Image(systemName: waiting ? "antenna.radiowaves.left.and.right" : offline ? "exclamationmark.triangle.fill" : "eye")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(offline ? C.accentDeep : C.sync)
            Text(waiting ? loc.t("monitor.waiting")
                 : offline ? loc.t("monitor.offline", model.watchedHost ?? "", model.remoteGeneratedAt.map { ago($0, now: model.tick, loc: loc) + " ago" } ?? "")
                 : loc.t("monitor.watching", model.watchedHost ?? ""))
                .font(.system(size: 12.5, weight: .semibold)).foregroundColor(offline ? C.accentDeep : C.sync)
            Spacer()
            if let g = model.remoteGeneratedAt, !waiting {
                Text(ago(g, now: model.tick, loc: loc)).font(.system(size: 11.5)).monospacedDigit().foregroundColor(C.inkFaint)
            }
        }
        .padding(.horizontal, 20).frame(height: 32)
        .background(offline ? C.accentSoft : C.syncSoft)
    }
}

private struct BackupNudge: View {
    @ObservedObject var model: DashboardModel
    @EnvironmentObject var loc: Localizer
    @State private var show = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 14)).foregroundColor(C.accentDeep)
            Text(loc.t("nudge.backup")).font(.system(size: 12.5, weight: .medium)).foregroundColor(Color(hex: 0x7a4d08))
            Spacer(minLength: 8)
            Button { show = true } label: {
                Text(loc.t("nudge.backupNow")).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Color(hex: 0x3A2600))
                    .padding(.horizontal, 12).padding(.vertical, 5).background(C.accent).clipShape(Capsule())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(C.accentSoft)
        .overlay(Rectangle().frame(height: 1).foregroundColor(C.line), alignment: .bottom)
        .sheet(isPresented: $show) { BackupPhraseSheet(model: model, dismiss: { show = false }) }
    }
}

/// Shows the 12-word recovery phrase again (loaded from the Keychain) so the user can write it down now.
private struct BackupPhraseSheet: View {
    @ObservedObject var model: DashboardModel
    let dismiss: () -> Void
    @EnvironmentObject var loc: Localizer
    private var phrase: [String] { SovereignStore.loadKey()?.recoveryPhrase ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("onb.phrase.title")).font(.system(size: 18, weight: .bold)).foregroundColor(C.ink)
            Text(loc.t("onb.phrase.body")).font(.system(size: 12.5)).foregroundColor(C.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(phrase.enumerated()), id: \.offset) { i, w in
                    HStack(spacing: 6) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundColor(C.inkFaint).frame(width: 16, alignment: .trailing)
                        Text(w).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundColor(C.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6).background(C.card)
                    .clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(C.line, lineWidth: 1))
                }
            }
            HStack {
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(phrase.joined(separator: " "), forType: .string)
                } label: {
                    HStack(spacing: 5) { Image(systemName: "doc.on.doc"); Text(loc.t("onb.phrase.copy")) }
                        .font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.inkSoft)
                        .padding(.horizontal, 12).padding(.vertical, 7).background(C.card).clipShape(Capsule())
                        .overlay(Capsule().stroke(C.line, lineWidth: 1))
                }.buttonStyle(.plain)
                Spacer()
                Button { model.confirmBackedUp(); dismiss() } label: {
                    Text(loc.t("onb.phrase.written")).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Color(hex: 0x3A2600))
                        .padding(.horizontal, 18).padding(.vertical, 8).background(C.accent).clipShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(22).frame(width: 420).background(C.ground)
    }
}

private struct SourceTile: View {
    let id: SourceID; let hb: Heartbeat?; let job: BackfillJob?; let enabled: Bool; let isPro: Bool; let now: Date
    @EnvironmentObject var loc: Localizer
    var body: some View {
        let m = meta(id)
        let status: SourceStatus = enabled ? (hb?.status ?? .syncing) : .disabled
        // "Up to date" is not true while the source is still producing items the copy lacks (Mail's 80,713
        // part-downloaded messages): amber "Waiting", and the line below says on what.
        let waiting = status == .healthy && (job?.progress.deferred?.count ?? 0) > 0
        let sc = waiting ? statusColor(.stale) : statusColor(status)
        let statusText = waiting ? loc.t("status.waiting")
            : (status == .syncing && (hb?.pendingCount ?? 0) > 0) ? loc.t("status.syncingN", hb!.pendingCount) : loc.t(sc.key)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: m.symbol).font(.system(size: 15, weight: .medium))
                    .foregroundColor(enabled ? C.accentDeep : C.inkFaint)
                    .frame(width: 30, height: 30)
                    .background(enabled ? C.accentSoft : C.line).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(loc.t(m.titleKey)).font(.system(size: 13.5, weight: .semibold)).foregroundColor(C.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(hb?.itemCount.map { $0.formatted() } ?? "—")
                .font(.system(size: 19, weight: .bold)).monospacedDigit().kerning(-0.3)
                .foregroundColor(enabled ? C.ink : C.inkFaint).padding(.top, 6)
            HStack(spacing: 6) {
                Circle().fill(sc.fg).frame(width: 6, height: 6)
                Text(statusText).font(.system(size: 11, weight: .semibold)).foregroundColor(sc.fg)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(sc.bg).clipShape(Capsule()).padding(.top, 6)
            Text(subtitle).font(.system(size: 11))
                .foregroundColor(subtitleColor)
                .padding(.top, 5)
                .lineLimit(1).truncationMode(.middle)
            if let d = job?.progress.deferred, enabled {
                Text("\(d.count.formatted()) \(d.reason)").font(.system(size: 11)).foregroundColor(C.accentDeep)
                    .padding(.top, 3).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let k = job?.progress.kept, k > 0, enabled {
                Text(loc.t("tile.kept", k)).font(.system(size: 11)).foregroundColor(C.inkFaint).padding(.top, 3).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.card)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .opacity(enabled ? 1 : 0.72)
    }

    /// The bottom line: where it backs up (enabled), or the gate — "Available in Pro" (locked) vs
    /// "Included in Pro" once the Pro license is present (Pro tiles wire up as their probes ship).
    private var subtitle: String {
        if enabled { return loc.t("tile.target", meta(id).target, hb.map { ago($0.timestamp, now: now, loc: loc) } ?? "") }
        if id.isProOnly { return loc.t(isPro ? "tile.proReady" : "tile.proEdition") }
        return loc.t("tile.notEnabled")
    }
    private var subtitleColor: Color {
        guard !enabled, id.isProOnly else { return C.inkFaint }
        return isPro ? C.ok : C.accentDeep
    }
}

private struct ActivityPanel: View {
    @ObservedObject var model: DashboardModel
    @EnvironmentObject var loc: Localizer
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(loc.t("activity.title")).font(.system(size: 13, weight: .semibold)).foregroundColor(C.ink)
            Text(loc.t("activity.subtitle")).font(.system(size: 12)).foregroundColor(C.inkFaint).padding(.bottom, 6)
            Canvas { ctx, size in
                let data = model.activity
                guard data.count > 1 else { return }
                let maxV = max(data.max() ?? 1, 1)
                let n = data.count
                let pad: CGFloat = 4, W = size.width, H = size.height
                func px(_ i: Int) -> CGFloat { pad + CGFloat(i) * (W - 2 * pad) / CGFloat(n - 1) }
                func py(_ v: Double) -> CGFloat { H - 8 - CGFloat(v / maxV) * (H - 16) }
                // faint baseline grid
                var grid = Path()
                for g in 0...2 { let y = 8 + CGFloat(g) * (H - 16) / 2; grid.move(to: CGPoint(x: pad, y: y)); grid.addLine(to: CGPoint(x: W - pad, y: y)) }
                ctx.stroke(grid, with: .color(Color(hex: 0xEDF0F5)), lineWidth: 1)
                // area
                var area = Path(); area.move(to: CGPoint(x: px(0), y: H - 8))
                for i in 0..<n { area.addLine(to: CGPoint(x: px(i), y: py(data[i]))) }
                area.addLine(to: CGPoint(x: px(n - 1), y: H - 8)); area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [C.accent.opacity(0.28), C.accent.opacity(0)]),
                                                     startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: H)))
                // line
                var line = Path(); line.move(to: CGPoint(x: px(0), y: py(data[0])))
                for i in 1..<n { line.addLine(to: CGPoint(x: px(i), y: py(data[i]))) }
                ctx.stroke(line, with: .color(C.accent), lineWidth: 2)
                // endpoint dot
                let ep = CGPoint(x: px(n - 1), y: py(data[n - 1]))
                ctx.fill(Path(ellipseIn: CGRect(x: ep.x - 3, y: ep.y - 3, width: 6, height: 6)), with: .color(C.accent))
            }.frame(height: 88)
            HStack {
                Text(loc.t("activity.window")).font(.system(size: 10.5)).foregroundColor(C.inkFaint)
                Spacer()
                Text(loc.t("activity.total", Int(model.activity.reduce(0, +)))).font(.system(size: 10.5)).foregroundColor(C.inkFaint).monospacedDigit()
            }.padding(.top, 4)
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 14, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.card)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct LivePanel: View {
    @ObservedObject var model: DashboardModel
    @EnvironmentObject var loc: Localizer
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(loc.t("feed.title")).font(.system(size: 13, weight: .semibold)).foregroundColor(C.ink)
            Text(loc.t("feed.subtitle")).font(.system(size: 12)).foregroundColor(C.inkFaint).padding(.bottom, 8)
            if model.events.isEmpty {
                Text(loc.t("feed.waiting")).font(.system(size: 12.5)).foregroundColor(C.inkFaint).padding(.vertical, 10)
            } else {
                ForEach(Array(model.events.prefix(12).enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(statusColor(e.status).fg).frame(width: 7, height: 7).padding(.top, 5)
                        Text(e.lastItem ?? e.status.rawValue).font(.system(size: 12.5)).foregroundColor(C.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(ago(e.timestamp, now: model.tick, loc: loc)).font(.system(size: 11)).foregroundColor(C.inkFaint).monospacedDigit()
                    }
                    .padding(.vertical, 7)
                    Divider().background(C.line)
                }
            }
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 10, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.card)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct Footer: View {
    @EnvironmentObject var loc: Localizer
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 12)).foregroundColor(C.ok)
            Text(loc.t("footer.text")).font(.system(size: 12)).foregroundColor(C.inkFaint)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
    }
}

// ── backfill panel ──────────────────────────────────────────────────────────────
/// Decimal units (1 GB = 10⁹ B) — what Finder, Nextcloud's quota page, Immich and the iPhone app show. Until
/// 2026-10-18 this divided by 1024 under a "GB" label and read 7 % under the phone for the same lane.
func fmtBytes(_ n: Int64) -> String {
    let u = ["B", "KB", "MB", "GB", "TB"]; var v = Double(max(0, n)); var i = 0
    while v >= 1000 && i < u.count - 1 { v /= 1000; i += 1 }
    return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, u[i])
}
/// Time left at a human scale: seconds, minutes, hours and minutes, then from a day up in half days
/// ("~2½ days", not "~61h 12m" — the operator, 2026-10-15). The leading "~" is what `SpeedTip` drops.
func fmtETA(_ s: Double, loc: Localizer? = nil) -> String {
    guard s.isFinite, s > 0 else { return "—" }
    let m = Int(s / 60), h = m / 60
    if h >= 24 {
        let halves = Int((s / 43_200).rounded())          // half-days, nearest
        let whole = halves / 2, half = halves % 2 == 1
        let n = half ? "\(whole)½" : "\(whole)"
        if halves == 2 { return loc?.t("eta.day") ?? "~1 day" }
        return loc?.t("eta.days", n) ?? "~\(n) days"
    }
    if h > 0 { return "~\(h)h \(m % 60)m" }
    if m > 0 { return "~\(m)m" }
    return "~\(Int(s))s"
}
func phaseStyle(_ p: BackfillJob.Phase) -> (Color, Color, String) {
    switch p {
    case .scanning:     return (C.sync, C.syncSoft, "phase.scanning")
    case .transferring: return (C.sync, C.syncSoft, "phase.transferring")
    case .paused:       return (C.pause, C.pauseSoft, "phase.paused")
    case .done:         return (C.ok, C.okSoft, "phase.done")
    case .blocked:      return (C.err, C.errSoft, "phase.blocked")
    case .stopped:      return (C.inkFaint, C.line, "phase.stopped")
    }
}

private struct BackfillPanel: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject var backfill: BackfillModel
    var body: some View {
        let visible = backfill.jobs.filter { $0.value.isVisible }.sorted { $0.key.rawValue < $1.key.rawValue }
        if !visible.isEmpty {
            VStack(spacing: 10) {
                ForEach(visible, id: \.key) { entry in
                    BackfillCard(id: entry.key, job: entry.value, model: model, onWiFi: backfill.onWiFi)
                }
            }
        }
    }
}

private struct BackfillCard: View {
    let id: SourceID
    let job: BackfillJob
    @ObservedObject var model: DashboardModel
    let onWiFi: Bool
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let m = meta(id)
        let ps = phaseStyle(job.phase)
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Image(systemName: m.symbol).font(.system(size: 14, weight: .medium))
                    .foregroundColor(C.accentDeep).frame(width: 28, height: 28)
                    .background(C.accentSoft).clipShape(RoundedRectangle(cornerRadius: 8))
                Text(loc.t("backfill.title", loc.t(m.titleKey))).font(.system(size: 14, weight: .semibold)).foregroundColor(C.ink)
                HStack(spacing: 5) {
                    Circle().fill(ps.0).frame(width: 6, height: 6)
                    Text(loc.t(ps.2)).font(.system(size: 11.5, weight: .semibold)).foregroundColor(ps.0)
                }.padding(.horizontal, 8).padding(.vertical, 3).background(ps.1).clipShape(Capsule())
                Spacer()
                if job.capacity == nil && !model.readOnly { controls }
            }
            if let cap = job.capacity {
                CapacityWarning(cap: cap, onConfirm: { model.onConfirmBackfill?(id) }, onStop: { model.onStopBackfill?(id) })
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: 0xEAEEF5))
                        Capsule().fill(LinearGradient(colors: [Color(hex: 0xFFC873), C.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * job.fraction))
                    }
                }.frame(height: 10)
                HStack(spacing: 20) {
                    metric("\(job.progress.settled.formatted()) / \(job.progress.total.formatted())", loc.t("metric.files"))
                    metric("\(fmtBytes(job.progress.calibrated(job.progress.confirmedBytes))) / \(fmtBytes(job.progress.calibrated(job.progress.totalBytes)))", loc.t("metric.data"))
                    if job.progress.skipped > 0 { metric(job.progress.skipped.formatted(), loc.t("metric.already")) }
                    if job.phase == .transferring && !job.isStalled {
                        metric("\(fmtBytes(Int64(job.rate)))/s", loc.t("metric.speed"))
                        metric(loc.t("backfill.etaLeft", fmtETA(job.etaSeconds, loc: loc)), loc.t("metric.est"))
                    } else if job.isStalled {
                        metric(loc.t("backfill.stalled"), loc.t("metric.est"))
                    }
                    Spacer(minLength: 0)
                }
                // Fan-out lanes: one row per target. The same library can be all on Immich and half on
                // Nextcloud; the lane bar above is the slowest of them, these say which is which.
                // Not while scanning: until the reconcile has listed each target the rows would all read 0 %.
                if job.progress.targets.count > 1, job.phase != .scanning {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(job.progress.targets, id: \.name) { t in
                            let rem = job.progress.remaining(for: t)
                            // By file count, like the "files" metric above — the byte fraction leans on size
                            // estimates and read 17 % for a target that held 44 % of the files.
                            let f = job.progress.total > 0 ? Double(t.settled) / Double(max(1, job.progress.total - job.progress.quarantined)) : 0
                            HStack(spacing: 9) {
                                Text(t.name).font(.system(size: 11.5, weight: .semibold)).foregroundColor(C.ink)
                                    .frame(width: 72, alignment: .leading)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color(hex: 0xEAEEF5))
                                        Capsule().fill(rem.items == 0 ? C.ok : C.accent).frame(width: max(3, geo.size.width * f))
                                    }
                                }.frame(height: 6)
                                Text(rem.items == 0
                                     ? loc.t("backfill.target.complete", t.settled.formatted())
                                     : loc.t("backfill.target.toGo", "\(Int((f * 100).rounded()))%", rem.items.formatted(), fmtBytes(rem.bytes)))
                                    .font(.system(size: 11)).monospacedDigit().foregroundColor(C.inkSoft)
                                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }
                }
                if onWiFi, !model.readOnly, job.phase == .transferring, job.etaSeconds.isFinite, job.progress.remainingBytes > 0 {
                    SpeedTip(eta: job.etaSeconds)
                }
                // Items whose one attempt failed (iCloud gave nothing, a dropped connection, a 5xx) and that get
                // another go once the pending queue drains — the iPhone card has shown this line since 13 Oct;
                // the Mac card hid 2,710 of them behind a healthy-looking bar (2026-10-18).
                if job.progress.failed > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundColor(C.accentDeep)
                        Text(loc.t("backfill.retrying", job.progress.failed)).font(.system(size: 12)).foregroundColor(C.accentDeep)
                    }
                }
                if let d = job.progress.deferred {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass").font(.system(size: 11)).foregroundColor(C.accentDeep)
                        Text("\(d.count.formatted()) \(d.reason)").font(.system(size: 12)).foregroundColor(C.accentDeep)
                    }
                }
                if job.progress.kept > 0 {
                    Text(loc.t("backfill.kept", job.progress.kept)).font(.system(size: 12)).foregroundColor(C.inkFaint)
                }
                if job.progress.hasUnreadable {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(C.accentDeep)
                        Text(loc.t("backfill.unreadable", job.progress.quarantined))
                            .font(.system(size: 12)).foregroundColor(C.accentDeep)
                        // Give the set-aside items a fresh set of attempts — for when the CAUSE was fixed (a size
                        // ceiling, a late grant), not the items. Until 2026-10-15 this meant editing the ledger by hand.
                        if !model.readOnly { ctl(loc.t("btn.retry"), primary: false) { model.onRetryBackfill?(id) } }
                    }
                }
                if job.isActive {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.shield").font(.system(size: 11)).foregroundColor(C.ok)
                        Text(loc.t("backfill.safeClose")).font(.system(size: 11.5)).foregroundColor(C.ok)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 15, leading: 17, bottom: 15, trailing: 17))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.card)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(C.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 7) {
            if job.phase == .transferring || job.phase == .scanning {
                ctl(loc.t("btn.pause"), primary: false) { model.onPauseBackfill?(id) }
                ctl(loc.t("btn.stop"), primary: false, ghost: true) { model.onStopBackfill?(id) }
            } else if job.phase == .paused {
                ctl(loc.t("btn.resume"), primary: true) { model.onResumeBackfill?(id) }
                ctl(loc.t("btn.stop"), primary: false, ghost: true) { model.onStopBackfill?(id) }
            }
        }
    }

    private func ctl(_ label: String, primary: Bool, ghost: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary ? Color(hex: 0x3A2600) : (ghost ? C.inkSoft : C.ink))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(primary ? C.accent : C.card)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? C.accentDeep : C.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func metric(_ big: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(big).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(C.ink)
            Text(label).font(.system(size: 10.5)).foregroundColor(C.inkFaint)
        }
    }
}

/// The 85%-gate card: "would get tight → back up anyway" (amber) or "won't fit → free up space" (red).
private struct CapacityWarning: View {
    let cap: CapacityReport
    let onConfirm: () -> Void
    let onStop: () -> Void
    @EnvironmentObject var loc: Localizer

    var body: some View {
        let wontFit: Bool = { if case .wontFit = cap.verdict { return true }; return false }()
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: wontFit ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14)).foregroundColor(wontFit ? C.err : C.pause)
                Text(loc.t(wontFit ? "capacity.wontfit.title" : "capacity.tight.title", cap.targetLabel))
                    .font(.system(size: 13.5, weight: .bold)).foregroundColor(wontFit ? C.err : C.pause)
            }
            Text(message(wontFit: wontFit))
                .font(.system(size: 12.5)).foregroundColor(C.inkSoft).fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                let usedFrac = cap.storage.usedFraction
                let addFrac = cap.storage.totalBytes > 0 ? min(max(0, 1 - usedFrac), Double(cap.addBytes) / Double(cap.storage.totalBytes)) : 0
                HStack(spacing: 0) {
                    Rectangle().fill(Color(hex: 0x9AA6BC)).frame(width: geo.size.width * usedFrac)
                    Rectangle().fill(wontFit ? C.err : C.accent).frame(width: geo.size.width * max(0.02, addFrac))
                    Spacer(minLength: 0)
                }
            }.frame(height: 12).background(Color(hex: 0xEAEEF5)).clipShape(Capsule())
            Text(loc.t("capacity.diskline", fmtBytes(cap.storage.totalBytes), fmtBytes(cap.storage.freeBytes), fmtBytes(cap.addBytes)))
                .font(.system(size: 11.5)).foregroundColor(C.inkFaint).monospacedDigit()
            HStack(spacing: 8) {
                if !wontFit { warnBtn(loc.t("btn.backupAnyway"), primary: true, action: onConfirm) }
                warnBtn(loc.t(wontFit ? "btn.ok" : "btn.notNow"), primary: false, action: onStop)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wontFit ? C.errSoft : C.pauseSoft)
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    private func message(wontFit: Bool) -> String {
        if wontFit {
            let shortBy: Int64 = { if case .wontFit(let s) = cap.verdict { return s }; return 0 }()
            return loc.t("capacity.wontfit.msg", fmtBytes(cap.addBytes), fmtBytes(cap.storage.freeBytes), fmtBytes(shortBy))
        }
        let frac: Double = { if case .tight(let f) = cap.verdict { return f }; return 1 }()
        return loc.t("capacity.tight.msg", fmtBytes(cap.addBytes), cap.targetLabel, Int((frac * 100).rounded()))
    }

    private func warnBtn(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: .semibold))
                .foregroundColor(primary ? Color(hex: 0x3A2600) : C.inkSoft)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(primary ? C.accent : Color.white)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? C.accentDeep : C.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

/// Shown only while transferring on Wi-Fi — the quantified "plug in Ethernet" nudge.
private struct SpeedTip: View {
    let eta: Double
    @EnvironmentObject var loc: Localizer
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "bolt.horizontal.fill").font(.system(size: 13)).foregroundColor(C.accentDeep).padding(.top, 1)
            Text(loc.t("tip.wifi", String(fmtETA(eta / 4, loc: loc).dropFirst()), String(fmtETA(eta, loc: loc).dropFirst())))
                .font(.system(size: 12)).foregroundColor(Color(hex: 0x7A4D09)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.accentSoft)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xF6D9A8), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// ── language picker (styled popover) ──────────────────────────────────────────────
private struct LanguagePopover: View {
    @ObservedObject var loc: Localizer
    let dismiss: () -> Void
    private let langs: [AppLanguage] = [.system, .en, .fr, .es, .pt, .de, .it, .nl, .ru, .ja, .ko, .zhHans, .zhHant, .tr, .pl, .hi, .ar]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc.t("lang.title").uppercased())
                .font(.system(size: 10, weight: .bold)).kerning(0.8).foregroundColor(C.inkFaint)
                .padding(.horizontal, 13).padding(.top, 11).padding(.bottom, 5)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(langs) { lang in
                        LangRow(lang: lang, selected: loc.language == lang,
                                title: lang == .system ? loc.t("lang.system") : lang.nativeName) {
                            loc.language = lang; dismiss()
                        }
                    }
                }.padding(.bottom, 7)
            }
            .frame(maxHeight: 340)
        }
        .frame(width: 224)
        .background(C.card)
        .environment(\.layoutDirection, .leftToRight)   // keep the picker itself LTR regardless of app language
    }
}

private struct LangRow: View {
    let lang: AppLanguage
    let selected: Bool
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(lang.flag).font(.system(size: 15))
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundColor(C.ink)
                Spacer(minLength: 8)
                if lang != .system {
                    Text(lang.code).font(.system(size: 10, weight: .semibold)).foregroundColor(C.inkFaint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(C.line.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundColor(C.accentDeep).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? C.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
