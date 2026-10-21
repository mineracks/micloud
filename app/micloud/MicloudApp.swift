import SwiftUI
import Foundation
import EventKit
import Contacts

// micloud dashboard app (M1). Wires the real engine into the SwiftUI dashboard, which renders the live
// HealthStore. Sources come online after launch (via the Coordinator's `.task`): PhotosSource always;
// DriveSource once the user grants a folder (MICLOUD_DRIVE=1). Built with swiftc + ad-hoc codesign — no Xcode.

@main
struct MicloudApp: App {
    @StateObject private var model: DashboardModel
    @StateObject private var backfill: BackfillModel
    @StateObject private var loc = Localizer()
    nonisolated(unsafe) static var loki: LokiSink?
    @StateObject private var onb = OnboardingModel()
    @State private var onboarded = MicloudApp.alreadyConfigured()
    private let coord: Coordinator

    /// Skip the wizard if this install is already set up — either it was onboarded before, or drill/dev
    /// creds are being injected via the environment (the existing test path stays untouched).
    static func alreadyConfigured() -> Bool {
        if ProcessInfo.processInfo.environment["NEXTCLOUD_URL"] != nil { return true }
        return InstallStore.load().onboarded
    }

    init() {
        let store = HealthStore()
        if let u = Production.lokiURL() {   // fleet telemetry: every heartbeat → Loki (+ alive ticks, see Coordinator)
            let sink = LokiSink(url: u, hostLabel: Production.hostLabel)
            store.forward = { sink.push($0) }
            MicloudApp.loki = sink
        }
        // seed every source disabled so all tiles render; each flips to enabled as it actually wires
        for id in SourceID.allCases { store.record(Heartbeat(source: id, status: .disabled)) }
        let coord = Coordinator(store: store)
        self.coord = coord
        _backfill = StateObject(wrappedValue: coord.backfill)
        let m = DashboardModel(store: store)
        m.onSyncNow = { Task { await coord.backfillAll() } }   // "Sync now" = run a full backfill pass
        m.onPauseBackfill = { coord.pauseBackfill($0) }
        m.onResumeBackfill = { coord.resumeBackfill($0) }
        m.onStopBackfill = { coord.stopBackfill($0) }
        m.onRetryBackfill = { coord.retryBackfill($0) }
        m.onConfirmBackfill = { coord.confirmBackfill($0) }
        m.onDriveGranted = { url in Task { await coord.driveGranted(url, model: m) } }   // permissions card, after a dismissed panel
        _model = StateObject(wrappedValue: m)
    }

    var body: some Scene {
        Window("micloud", id: "main") {
            Group {
                if onboarded {
                    DashboardView(model: model, backfill: backfill)
                        .task {
                            // Monitor mode: render another Mac's published dashboard; nothing local starts.
                            if let feed = RemoteFeed(model: model, backfill: backfill) { await feed.run() }
                            else { await coord.start(model: model) }
                        }
                } else {
                    OnboardingView(model: onb)
                        .onAppear { onb.onFinish = { withAnimation { onboarded = true } } }
                }
            }
            .environmentObject(loc)
            .onOpenURL { OAuthCallbacks.deliver($0) }     // app.immich:///oauth-callback?code=… from the browser
        }
        .windowResizability(.contentSize)
    }
}

/// Builds + starts the sync sources and funnels them through one `SyncEngine` into the `HealthStore`.
/// Kept off `App.init` so the folder-grant `NSOpenPanel` runs after the app is active.
final class Coordinator: @unchecked Sendable {
    let store: HealthStore
    private let engine: SyncEngine
    private let session: URLSession
    private let env: [String: String]
    private var driveFolder: URL?                      // set once granted (reused for backfill)
    /// Shared by the live watcher and the backfill so neither touches a file the other is moving.
    private let driveClaims = PathClaims()
    private var ekStore = EKEventStore()
    private let cnStore = CNContactStore()
    private var calendarsOK = false, remindersOK = false, contactsOK = false, photosBridgeOK = false
    private var notesBridgeOK = false, bookmarksBridgeOK = false, mailBridgeOK = false
    private var debounce: [String: DispatchWorkItem] = [:]   // coalesce bursty change notifications
    let backfill = BackfillModel()                     // live backfill state for the panel + tile rings
    private let engLock = NSLock()
    private var engines: [SourceID: BackfillEngine] = [:]
    private var interrupted: Set<SourceID> = []        // paused/stopped by the user (vs finished/blocked)

    init(store: HealthStore) {
        self.store = store
        self.engine = SyncEngine(store: store)
        self.session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        self.env = ProcessInfo.processInfo.environment
    }

    @MainActor
    func start(model: DashboardModel) async {
        // Liveness first. The alive tick and the status feed must not wait on any lane: on 2026-10-18 the live
        // photo lane's first pass sat 21 minutes in one iCloud fetch (IMG_4634.PNG, a TLS timeout under it) and
        // because `engine.add(photos)` awaited that pass, nothing below ran — no alive tick, no status.json,
        // no backfills; every dashboard read "hasn't reported" and the relay-down rule fired on a relay that
        // was merely waiting on Apple.
        if Production.on, let loki = MicloudApp.loki {
            // Alive at start: a restart must never read as an outage to the relay-down rule. The tick covers the
            // lanes enabled so far, so a second one follows once the lanes below have registered (they all do
            // within a second; 10 s is the margin) — the first tick on a cold start would otherwise be empty.
            loki.tick()
            Task { try? await Task.sleep(nanoseconds: 10_000_000_000); loki.tick() }
            Task { while true { try? await Task.sleep(nanoseconds: UInt64(Production.aliveSecs * 1_000_000_000)); loki.tick() } }
        }
        Task { await statusLoop() }   // publish status.json to the user's Nextcloud for the iOS companion + monitors

        // Photos — always on, unless explicitly disabled (MICLOUD_NO_PHOTOS=1). Disabling skips the Photos
        // permission prompt entirely — used by the driven Files-only demo, where a viewer can't dismiss an
        // OS permission dialog (the pane is view-only, we drive it), so nothing must block on one.
        if !Production.on, let dir = env["MICLOUD_PHOTOS_BRIDGE_DIR"], !dir.isEmpty, !photoTargets().isEmpty {
            // Demo photos bridge: carry image files the orchestrator drops in `dir` → sovereign photo targets,
            // as the .photos lane, through the normal BackfillEngine (badge/graph/log react for real). Replaces
            // the PhotoKit live source, which needs an iCloud library the driven demo Mac lacks.
            photosBridgeOK = true
            enableReady(model, .photos, "watching photos…")
            Task { await backfillOne(.photos) }
        } else if env["MICLOUD_NO_PHOTOS"] != "1" {
            let limit = Production.on ? Production.livePhotosWindow : (Int(env["TEST_LIMIT"] ?? "5") ?? 5)
            let photos = PhotosSource(targets: photoTargets(), limit: limit, heartbeat: { [store] in store.record($0) })
            model.enable(.photos)
            // `engine.add` runs the source's first pass (the newest 50 items, each fetched from iCloud and sent).
            // Off the start path: the lanes below and the Drive lane must not queue behind it.
            Task { [engine] in
                await engine.add(photos)
                // Production: the live window is for instant mirroring; the ledger-backed backfill carries the
                // whole library (resumable, incremental, dedup) — on launch and on every poll.
                if Production.on { await self.backfillOne(.photos) }
            }
        }

        // Calendars + Reminders + Contacts — opt-in (MICLOUD_MORE=1)
        if env["MICLOUD_MORE"] == "1" || Production.on, nextcloudDAV() != nil {
            if await requestEvent(.event)    { calendarsOK = true; enableReady(model, .calendars, "backing up…") }
            if await requestEvent(.reminder) { remindersOK = true; enableReady(model, .reminders, "backing up…") }
            if await requestContacts()       { contactsOK = true; enableReady(model, .contacts, "backing up…") }
            // An EKEventStore created BEFORE access is granted never surfaces calendars/events (the classic
            // "EventKit returns nothing" gotcha — the store caches the not-yet-authorised state at creation).
            // Now that access is settled, recreate + reactivate it, then refresh its sources.
            if calendarsOK || remindersOK {
                ekStore = EKEventStore()
                _ = await requestEvent(.event)          // reactivate the fresh store (already granted → returns at once)
                ekStore.refreshSourcesIfNecessary()
            }
            registerChangeObservers()
            // Initial backfill on launch (like Documents) so existing items sync + the store gets primed for
            // change notifications; then a periodic poll (MICLOUD_POLL_SECS, the driven demo sets it) guarantees
            // newly-created items sync within that window even if the EventKit/Contacts change notifications
            // don't fire in this driven context. The ledger's content-hash detection keeps each pass cheap.
            if calendarsOK { Task { await backfillOne(.calendars) } }
            if remindersOK { Task { await backfillOne(.reminders) } }
            if contactsOK  { Task { await backfillOne(.contacts) } }
            if let secs = env["MICLOUD_POLL_SECS"].flatMap({ Double($0) }), secs > 0 { startMorePoll(secs) }
            else if Production.on { startMorePoll(Production.pollSecs) }
        }

        // Notes — demo bridge (like photos): the orchestrator drops a .md note the visitor jotted on the Mac
        // into MICLOUD_NOTES_BRIDGE_DIR and this uploads it to the Nextcloud Notes folder. No OS permission
        // needed (it never reads Apple Notes — just carries files), so nothing blocks on a dialog the view-only
        // visitor can't dismiss. Picked up by the MICLOUD_MORE poll (which the demo sets) for later notes.
        if !Production.on, let dir = env["MICLOUD_NOTES_BRIDGE_DIR"], !dir.isEmpty, nextcloudDAV() != nil {
            notesBridgeOK = true
            enableReady(model, .notes, "watching notes…")
            Task { await backfillOne(.notes) }
        }

        // Bookmarks — demo bridge (like notes), but the target is the Nextcloud Bookmarks REST API, not files.
        // The orchestrator drops a {url,title} the visitor bookmarked in Safari and this POSTs it. Same no-OS-
        // permission story; picked up by the MICLOUD_MORE poll for later bookmarks.
        if !Production.on, bookmarksBridgeSource() != nil {
            bookmarksBridgeOK = true
            enableReady(model, .bookmarks, "watching bookmarks…")
            Task { await backfillOne(.bookmarks) }
        }

        // Mail — demo bridge: the orchestrator drops an arriving .eml and this IMAP-APPENDs it to the sovereign
        // dovecot maildir Nextcloud Mail reads. No OS permission; picked up by the MICLOUD_MORE poll.
        if !Production.on, mailBridgeSource() != nil {
            mailBridgeOK = true
            enableReady(model, .mail, "watching mail…")
            Task { await backfillOne(.mail) }
        }

        // Production: Bookmarks (Safari), Notes (Apple Notes store) and Messages (chat.db) — real sources,
        // ledger-backed, re-run on every poll (cheap when nothing changed; Messages re-exports at most daily).
        if Production.on, nextcloudDAV() != nil {
            for id in [SourceID.bookmarks, .notes, .messages, .mail] {
                enableReady(model, id, "backing up…")
                Task { await backfillOne(id) }
            }
            Task { await refreshHealthStatus(model) }   // Health is the iPhone's lane; report what it delivered
        }

        // Documents/Drive — opt-in (MICLOUD_DRIVE=1) and needs a Nextcloud target + a granted folder
        guard env["MICLOUD_DRIVE"] == "1" || Production.on, let dav = nextcloudDAV() else { return }
        // Production: the saved security-scoped grant, else prompt ONCE (sandbox) — the panel opens on
        // iCloud Drive so the operator just clicks Open. Until granted, say so on the tile instead of staying silent.
        // Order: a folder the person chose before → the whole iCloud Drive when the build can read it
        // (relay entitlement, no question asked) → Apple's panel, pre-pointed at iCloud Drive.
        let folder = DriveGrant.saved()
            ?? (Production.on && Production.iCloudDriveReadable ? Production.iCloudDrive : nil)
            ?? DriveGrant.prompt(suggested: Production.on ? Production.iCloudDrive : nil)
        guard let folder else {
            if Production.on { store.record(Heartbeat(source: .documents, status: .error, lastItem: "Files: grant the iCloud Drive folder (open panel) once")) }
            return                                     // user cancelled → Documents stays Off (the permissions card re-offers it)
        }
        await startDrive(folder: folder, dav: dav, model: model)
    }

    /// The permissions card granted the folder after launch (the open panel was dismissed the first time) —
    /// start the Files lane now rather than waiting for a relaunch.
    @MainActor func driveGranted(_ folder: URL, model: DashboardModel) async {
        guard let dav = nextcloudDAV() else { return }
        await startDrive(folder: folder, dav: dav, model: model)
    }

    /// Start the Files lane on a granted folder (idempotent — a second grant while one is live is ignored).
    @MainActor private func startDrive(folder: URL, dav: NextcloudWebDAV, model: DashboardModel) async {
        guard driveFolder == nil else { return }
        driveFolder = folder
        // Soft-delete lands here; hidden `micloud/.trash` by default. Override (e.g. a visible
        // `micloud/Documents/Recovered`) via MICLOUD_TRASH_PATH — used by the live demo so the recovery is seen.
        let trashPath = env["MICLOUD_TRASH_PATH"] ?? "micloud/.trash"
        let drive = DriveSource(watchedFolder: folder, remoteDocumentsPath: Self.ncDocumentsPath,
                                trashPath: trashPath, dav: dav,
                                heartbeat: { [store] in store.record($0) })
        drive.skipIf = { [driveClaims] in driveClaims.isClaimed($0) }   // the backfill's downloads are not changes
        // Safety net: every observed change (and any live-upload that fails after its own retry) nudges a
        // debounced, ledger-backed backfill of the Files lane — the SAME resilient path the other live lanes
        // use. The fast inline mirror handles the happy path; the backfill guarantees eventual consistency
        // through a transient WebDAV outage (retry/requeue/quarantine), so a file can never be silently lost.
        drive.onActivity = { [weak self] in
            DispatchQueue.main.async { self?.schedule("drive") { Task { [weak self] in await self?.backfillOne(.documents) } } }
        }
        model.enable(.documents)
        await engine.add(drive)                        // start() emits "watching <folder>" healthy
        // Catch anything left pending from a previous session (e.g. files that arrived while the server was
        // briefly unreachable): one ledger-backed pass on launch. Idempotent — already-mirrored files are skipped.
        Task { await backfillOne(.documents) }
    }

    /// "Sync now" — run a full, resumable backfill pass on each live source (concurrently) through the shared
    /// BackfillEngine. Skips a source already backfilling; resumes any paused one from its ledger. Photos is
    /// bounded by BACKFILL_LIMIT (test-safe default) so a run doesn't push the whole library.
    private func config(for id: SourceID? = nil) -> BackfillConfig {
        let thr = Double(env["CAPACITY_THRESHOLD"] ?? "") ?? 0.85    // override to demo the warning card
        // Photos is round-trip bound (iCloud fetch → checksum → HEAD → PUT, each through the edge) and ran
        // ~40 items/min on three workers at under 2 MB/s of wire — far from the link. Five workers for it;
        // the failure brake still catches a PhotoKit burst.
        let workers = id == .photos ? (Int(env["MICLOUD_PHOTOS_CONCURRENCY"] ?? "") ?? 5) : 3
        return BackfillConfig(concurrency: workers, capacityThreshold: thr)
    }

    func backfillAll() async {
        let sink: @Sendable (Heartbeat) -> Void = { [store] in store.record($0) }
        let sources = [photosBackfillSource(), driveBackfillSource(),
                       calendarsBackfillSource(), remindersBackfillSource(), contactsBackfillSource(),
                       notesBridgeSource(), bookmarksBridgeSource(), mailBridgeSource()].compactMap { $0 }
        await withTaskGroup(of: Void.self) { group in
            for (src, name) in sources {
                group.addTask { [self] in await runBackfill(source: src, name: name, sink: sink, cfg: config(for: src.id), confirmTight: false) }
            }
        }
    }

    @MainActor private func enableReady(_ model: DashboardModel, _ id: SourceID, _ msg: String) {
        model.enable(id); store.record(Heartbeat(source: id, status: .healthy, lastItem: msg))
    }
    private func requestEvent(_ type: EKEntityType) async -> Bool {
        // macOS 14+ split calendar access into full vs write-only. The old requestAccess(to: .event) grants
        // only WRITE-ONLY for events, so store.events(matching:) returns nothing — the app could never read
        // (let alone back up) calendar events. Must request FULL access on 14+. (Reminders are unaffected but
        // use the matching full-access API for consistency.)
        if #available(macOS 14.0, *) {
            return await withCheckedContinuation { c in
                let done: (Bool, Error?) -> Void = { granted, _ in c.resume(returning: granted) }
                if type == .reminder { ekStore.requestFullAccessToReminders(completion: done) }
                else { ekStore.requestFullAccessToEvents(completion: done) }
            }
        }
        return await withCheckedContinuation { c in ekStore.requestAccess(to: type) { granted, _ in c.resume(returning: granted) } }
    }
    private func requestContacts() async -> Bool {
        await withCheckedContinuation { c in cnStore.requestAccess(for: .contacts) { granted, _ in c.resume(returning: granted) } }
    }

    /// Live change-watchers for Calendars/Reminders/Contacts. EventKit + Contacts fire bursty notifications,
    /// so each is DEBOUNCED (coalesce ~4s) before re-running that source's backfill — which, thanks to the
    /// ledger's content-hash detection, re-uploads only the items that actually changed.
    private func registerChangeObservers() {
        let nc = NotificationCenter.default
        if calendarsOK || remindersOK {
            nc.addObserver(forName: .EKEventStoreChanged, object: ekStore, queue: .main) { [weak self] _ in
                self?.schedule("eventkit") {
                    Task { [weak self] in
                        if self?.calendarsOK == true { await self?.backfillOne(.calendars) }
                        if self?.remindersOK == true { await self?.backfillOne(.reminders) }
                    }
                }
            }
        }
        if contactsOK {
            nc.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
                self?.schedule("contacts") { Task { [weak self] in await self?.backfillOne(.contacts) } }
            }
        }
    }
    private func schedule(_ key: String, after: TimeInterval = 4, _ block: @escaping () -> Void) {
        debounce[key]?.cancel()
        let item = DispatchWorkItem(block: block)
        debounce[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: item)
    }
    private func backfillOne(_ id: SourceID) async {
        guard let (src, name) = backfillSource(for: id) else { return }
        let sink: @Sendable (Heartbeat) -> Void = { [store] in store.record($0) }
        await runBackfill(source: src, name: name, sink: sink, cfg: config(for: src.id), confirmTight: false)
    }

    /// Robustness/demo net: periodically re-backfill the Calendars/Reminders/Contacts lanes so newly-created
    /// items reach the server within `secs`, even when EventKit/Contacts change notifications don't fire in a
    /// driven session. Cheap — the ledger's content-hash detection means only new/changed items upload.
    private func startMorePoll(_ secs: Double) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                guard let self else { return }
                if self.calendarsOK { await self.backfillOne(.calendars) }
                if self.remindersOK { await self.backfillOne(.reminders) }
                if self.contactsOK  { await self.backfillOne(.contacts) }
                if Production.on {   // ledger-backed, cheap when idle
                    for id in [SourceID.photos, .documents, .bookmarks, .notes, .messages, .mail] { await self.backfillOne(id) }
                    if let m = self.healthModel { await self.refreshHealthStatus(m) }
                }
                if self.photosBridgeOK { await self.backfillOne(.photos) }   // pick up newly-dropped demo photos
                if self.notesBridgeOK  { await self.backfillOne(.notes) }    // pick up newly-dropped demo notes
                if self.bookmarksBridgeOK { await self.backfillOne(.bookmarks) }  // …and demo bookmarks
                if self.mailBridgeOK   { await self.backfillOne(.mail) }     // …and demo mail
            }
        }
    }

    /// Publish `status.json` to the user's Nextcloud so the iPhone app and a Mac in monitor mode can show this
    /// dashboard remotely: every 5 s while a lane is moving, every 30 s when idle. The report carries the same
    /// numbers the local cards render (lane progress, rates, ETA, activity graph, live log), so a remote view
    /// is the same dashboard, not a summary of it.
    private func statusLoop() async {
        guard let dav = nextcloudDAV() else { return }
        let host = Host.current().localizedName ?? "Mac"
        var lastPublished: Data?
        while true {
            let active = await MainActor.run { backfill.anyActive }
            let cadence: Double = active ? 5 : 30
            let lanes = await MainActor.run { () -> [SourceID: LaneReport] in
                var out: [SourceID: LaneReport] = [:]
                for (id, j) in backfill.jobs {
                    let p = j.progress
                    let eta = j.etaSeconds
                    out[id] = LaneReport(phase: LaneReport.Phase(rawValue: "\(j.phase)") ?? .scanning,
                                         total: p.total, done: p.done, skipped: p.skipped, failed: p.failed, pending: p.pending,
                                         inFlight: p.inFlight, quarantined: p.quarantined,
                                         // calibrated: the remote card shows the bytes the Mac's card shows, not raw estimates
                                         totalBytes: p.calibrated(p.totalBytes), confirmedBytes: p.calibrated(p.confirmedBytes), quarantinedBytes: p.calibrated(p.quarantinedBytes),
                                         rate: j.rate, itemRate: j.itemRate, etaSeconds: eta.isFinite ? eta : nil,
                                         lastItem: j.lastItem, capacityNote: j.capacity.map { "\($0.verdict)" }, stalled: j.isStalled,
                                         // calibrated like totalBytes above: raw per-target bytes next to a calibrated total
                                         // read "100 % · 3 files · 200.7 GB to go" on the monitor (2026-10-19)
                                         targets: p.targets.isEmpty ? nil : p.targets.map {
                                             TargetProgress(name: $0.name, settled: $0.settled, sent: $0.sent, settledBytes: p.calibrated($0.settledBytes)) },
                                         kept: p.kept > 0 ? p.kept : nil, deferred: p.deferred)
                }
                return out
            }
            let activity = await MainActor.run { healthModel?.activity }
            let report = StatusReport(host: host, appVersion: Production.appVersion, snapshot: store.current(),
                                      lanes: lanes, activity: activity, events: store.recentEvents(40), refreshSeconds: cadence,
                                      mirroredToday: store.mirroredToday())
            // Skip the PUT when nothing but the timestamp moved (idle Mac, idle network).
            let body = try? report.encoded()
            if body != lastPublished || !active {
                try? await report.publish(via: dav)
                lastPublished = body
            }
            try? await Task.sleep(nanoseconds: UInt64(cadence * 1_000_000_000))
        }
    }
    // NB: `folder` here is now a CardDAV/CalDAV COLLECTION name (not a Files path) — these lanes land in
    // Nextcloud's native Contacts/Calendar/Tasks apps. Calendar events + reminders share the "micloud"
    // calendar (Calendar app shows the events, Tasks app shows the VTODOs); contacts use the default
    // "contacts" addressbook. Override the collection names via env for other deployments.
    private func calendarsBackfillSource() -> (BackfillSource, String)? {
        guard calendarsOK, let dav = nextcloudDAV() else { return nil }
        let cal = env["MICLOUD_CALDAV_CALENDAR"] ?? "micloud"
        return (EventKitBackfillSource(id: .calendars, entity: .event, store: ekStore, dav: dav, folder: cal,
                                       bridgeDir: env["MICLOUD_CAL_BRIDGE_DIR"]), "calendars")
    }
    private func remindersBackfillSource() -> (BackfillSource, String)? {
        guard remindersOK, let dav = nextcloudDAV() else { return nil }
        let cal = env["MICLOUD_CALDAV_CALENDAR"] ?? "micloud"
        return (EventKitBackfillSource(id: .reminders, entity: .reminder, store: ekStore, dav: dav, folder: cal), "reminders")
    }
    private func contactsBackfillSource() -> (BackfillSource, String)? {
        guard contactsOK, let dav = nextcloudDAV() else { return nil }
        let book = env["MICLOUD_CARDDAV_ADDRESSBOOK"] ?? "contacts"
        return (ContactsBackfillSource(store: cnStore, dav: dav, folder: book), "contacts")
    }

    func pauseBackfill(_ id: SourceID)  { engLock.lock(); interrupted.insert(id); engines[id]?.pause(); engLock.unlock(); backfill.setPhase(id, .paused) }
    func stopBackfill(_ id: SourceID)   { engLock.lock(); interrupted.insert(id); engines[id]?.stop();  engLock.unlock(); backfill.setPhase(id, .stopped) }
    func resumeBackfill(_ id: SourceID) { engLock.lock(); interrupted.remove(id); engLock.unlock(); backfill.setPhase(id, .transferring); Task { await backfillAll() } }

    /// "Back up anyway" from the capacity-warning card — re-run this source past the >threshold gate.
    /// "Retry" on the "N couldn't be transferred" line: the quarantined rows get a clean attempt count and the job
    /// runs again. If the job is still running, its drain picks the rows up as ordinary pending work.
    func retryBackfill(_ id: SourceID) {
        guard let (src, name) = backfillSource(for: id) else { return }
        do { try BackfillLedger(path: ledgerURL(name)).retryQuarantined() } catch { return }
        backfill.setPhase(id, .transferring)
        let sink: @Sendable (Heartbeat) -> Void = { [store] in store.record($0) }
        Task { await runBackfill(source: src, name: name, sink: sink, cfg: config(for: src.id), confirmTight: true) }
    }

    func confirmBackfill(_ id: SourceID) {
        backfill.setCapacity(id, nil); backfill.setPhase(id, .transferring)
        let sink: @Sendable (Heartbeat) -> Void = { [store] in store.record($0) }
        guard let (src, name) = backfillSource(for: id) else { return }
        Task { await runBackfill(source: src, name: name, sink: sink, cfg: config(for: src.id), confirmTight: true) }
    }

    private func backfillSource(for id: SourceID) -> (BackfillSource, String)? {
        switch id {
        case .photos:    return photosBackfillSource()
        case .documents: return driveBackfillSource()
        case .calendars: return calendarsBackfillSource()
        case .reminders: return remindersBackfillSource()
        case .contacts:  return contactsBackfillSource()
        case .notes:     return Production.on ? notesProductionSource() : notesBridgeSource()
        case .bookmarks: return Production.on ? bookmarksProductionSource() : bookmarksBridgeSource()
        case .messages:  return Production.on ? messagesProductionSource() : nil
        case .mail:      return Production.on ? mailProductionSource() : mailBridgeSource()
        default:         return nil
        }
    }

    // ── production ("pro edition") lanes — read other apps' stores on this Mac; need the relay entitlements + FDA ──
    private func bookmarksProductionSource() -> (BackfillSource, String)? {
        guard let dav = nextcloudDAV() else { return nil }
        return (SafariBookmarksSource(dav: dav, session: session), "bookmarks")
    }
    private func notesProductionSource() -> (BackfillSource, String)? {
        guard let dav = nextcloudDAV() else { return nil }
        return (AppleNotesSource(dav: dav, session: session), "notes")
    }
    private func mailProductionSource() -> (BackfillSource, String)? {
        guard let dav = nextcloudDAV() else { return nil }
        return (MailSource(dav: dav), "mail")
    }
    /// Health has no Mac source — the iPhone app archives HealthKit to `Health/` on the same Nextcloud. The
    /// Mac tile reports that archive: fresh (≤ 48 h), stale, or not paired yet.
    private var healthModel: DashboardModel?
    @MainActor private func refreshHealthStatus(_ model: DashboardModel) async {
        healthModel = model
        guard let dav = nextcloudDAV() else { return }
        if let latest = await dav.latestModified("Health") {
            let age = Date().timeIntervalSince(latest)
            let when = RelativeDateTimeFormatter().localizedString(for: latest, relativeTo: Date())
            model.enable(.health)
            // The iPhone keeps `Health/manifest.json` (per-type counts + cursors). Read it for the record count
            // and whether the historical walk is still running; the folder mtime alone says only "something landed".
            var label = "iPhone archive · last data \(when)"
            var count: Int? = nil
            if let data = try? await dav.fetch("Health/manifest.json"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let types = json["types"] as? [String: [String: Any]] {
                let samples = types.values.reduce(0) { $0 + (($1["samples"] as? Int) ?? 0) }
                let walking = types.values.filter { ($0["backfillDone"] as? Bool) != true }.count
                count = samples
                let device = (json["device"] as? String).map { " from \($0)" } ?? ""
                label = walking > 0 ? "\(samples.formatted()) records\(device) · still archiving history · last data \(when)"
                                    : "\(samples.formatted()) records\(device) · last data \(when)"
            }
            store.record(Heartbeat(source: .health, status: age > 48 * 3600 ? .stale : .healthy, lastItem: label, itemCount: count))
        } else {
            store.record(Heartbeat(source: .health, status: .disabled, lastItem: "pair your iPhone (micloud for iOS) to archive Health"))
        }
    }
    private func messagesProductionSource() -> (BackfillSource, String)? {
        guard let dav = nextcloudDAV() else { return nil }
        return (MessagesSource(dav: dav), "messages")
    }

    /// Demo Notes bridge → Nextcloud Notes folder. Built only when the orchestrator's notes-bridge env is set
    /// (nil in production). NC Notes reads plain .md/.txt files from `Notes/`, so we upload straight there.
    private func notesBridgeSource() -> (BackfillSource, String)? {
        guard let dir = env["MICLOUD_NOTES_BRIDGE_DIR"], !dir.isEmpty, let dav = nextcloudDAV() else { return nil }
        return (NotesBridgeSource(dir: dir, dav: dav, remotePrefix: env["MICLOUD_NOTES_FOLDER"] ?? "Notes"), "notes")
    }

    /// Demo Bookmarks bridge → Nextcloud Bookmarks REST API. Built only when the orchestrator's bookmarks-bridge
    /// env is set + we have NC creds (nil in production). Derives the NC base URL from the env files-root.
    private func bookmarksBridgeSource() -> (BackfillSource, String)? {
        guard let dir = env["MICLOUD_BOOKMARKS_BRIDGE_DIR"], !dir.isEmpty, let dav = nextcloudDAV() else { return nil }
        return (BookmarksBridgeSource(dir: dir, dav: dav, session: session), "bookmarks")
    }

    /// Demo Mail bridge → the sovereign dovecot maildir over IMAP APPEND. Built only when the orchestrator's
    /// mail-bridge env + IMAP settings are present (nil in production). Reuses the WebDAV target for capacity.
    private func mailBridgeSource() -> (BackfillSource, String)? {
        guard let dir = env["MICLOUD_MAIL_BRIDGE_DIR"], !dir.isEmpty,
              let host = env["MICLOUD_MAIL_IMAP_HOST"], !host.isEmpty,
              let user = env["MICLOUD_MAIL_IMAP_USER"], let pass = env["MICLOUD_MAIL_IMAP_PASS"],
              let dav = nextcloudDAV() else { return nil }
        let port = UInt16(env["MICLOUD_MAIL_IMAP_PORT"] ?? "143") ?? 143
        let mailbox = env["MICLOUD_MAIL_MAILBOX"] ?? "INBOX"
        return (MailBridgeSource(dir: dir, host: host, port: port, user: user, pass: pass, mailbox: mailbox,
                                 capacity: dav), "mail")
    }

    /// Per-source caps for this install — hosted trial caps the heavy types (see SyncCaps); an env override
    /// (BACKFILL_LIMIT) still wins for drills/testing.
    private func caps() -> SyncCaps { SyncCaps.forBackend(InstallStore.load().backend) }

    private func photosBackfillSource() -> (BackfillSource, String)? {
        let t = photoTargets(); guard !t.isEmpty else { return nil }
        if let dir = env["MICLOUD_PHOTOS_BRIDGE_DIR"], !dir.isEmpty {   // demo: carry dropped image files, not PhotoKit
            return (PhotosFolderBridgeSource(dir: dir, targets: t, capacityTargets: photoCapacityTargets()), "photos")
        }
        guard env["MICLOUD_NO_PHOTOS"] != "1" else { return nil }   // demo (no bridge): never touch Photos
        let limit = env["BACKFILL_LIMIT"].flatMap { Int($0) } ?? caps().photos    // trial caps to newest N; 0 = whole library
        return (PhotosBackfillSource(targets: t, capacityTargets: photoCapacityTargets(), limit: limit), "photos")
    }
    private func driveBackfillSource() -> (BackfillSource, String)? {
        guard let folder = driveFolder, let dav = nextcloudDAV() else { return nil }
        let limit = env["BACKFILL_LIMIT"].flatMap { Int($0) } ?? caps().documents
        return (DriveBackfillSource(root: folder, dav: dav, remotePrefix: Self.ncDocumentsPath, evictAfterUpload: true,
                                    limit: limit, claims: driveClaims), "drive")
    }

    private func runBackfill(source: BackfillSource, name: String,
                             sink: @escaping @Sendable (Heartbeat) -> Void, cfg: BackfillConfig, confirmTight: Bool) async {
        engLock.lock(); if engines[source.id] != nil { engLock.unlock(); return }; engLock.unlock()   // already running
        do {
            let ledger = try BackfillLedger(path: ledgerURL(name))
            let engine = BackfillEngine(source: source, ledger: ledger, exclusions: ExclusionRules(), config: cfg, heartbeat: sink)
            engine.onProgress = { [backfill] prog, rate, item, stage in backfill.update(source.id, progress: prog, rate: rate, item: item, stage: stage) }
            engine.onCapacity = { [backfill] report in backfill.setCapacity(source.id, report) }
            engLock.lock(); engines[source.id] = engine; engLock.unlock()
            backfill.setPhase(source.id, .scanning)
            let final = await engine.run(confirmTight: confirmTight)
            engLock.lock(); let intended = interrupted.contains(source.id); engines[source.id] = nil
            if final.isComplete { interrupted.remove(source.id) }; engLock.unlock()
            if final.isComplete { backfill.setPhase(source.id, .done) }
            else if !intended { backfill.setPhase(source.id, .blocked) }   // capacity gate (paused/stopped keep their phase)
        } catch {
            engLock.lock(); engines[source.id] = nil; engLock.unlock()
            sink(Heartbeat(source: source.id, status: .error, lastItem: "backfill \(name): \(error)"))
            backfill.setPhase(source.id, .blocked)
        }
    }

    // ── config from env (the same drill creds the probe uses) ─────────────────
    private func nextcloudDAV() -> NextcloudWebDAV? {
        // drill/dev: env injects the full DAV files root directly
        if let s = env["NEXTCLOUD_URL"], let root = URL(string: s),
           let u = env["NEXTCLOUD_USER"], let p = env["NEXTCLOUD_PASS"] {
            return NextcloudWebDAV(filesRoot: root, username: u, appPassword: p, session: session)
        }
        // onboarded install: base URL in install.json, app-password in the Keychain
        let inst = InstallStore.load()
        if inst.backend == .diy, let s = inst.nextcloudURL, let base = URL(string: s),
           let u = inst.nextcloudUser, let p = SovereignStore.secret("nextcloud:\(u)") {
            let filesRoot = base.appendingPathComponent("remote.php/dav/files").appendingPathComponent(u)
            return NextcloudWebDAV(filesRoot: filesRoot, username: u, appPassword: p, session: session)
        }
        return nil
    }

    private func immichClient() -> ImmichClient? {
        if let s = env["IMMICH_URL"], let base = URL(string: s), let k = env["IMMICH_KEY"] {
            return ImmichClient(apiRoot: base.appendingPathComponent("api"), apiKey: k, deviceId: "micloud-dashboard", session: session)
        }
        let inst = InstallStore.load()
        if let s = inst.immichURL, let base = URL(string: s), let host = base.host {
            // The key is the same Immich whichever address reaches it. It was stored per host, so pointing the
            // relay at Immich's tailnet address (to get the 100 MB-capped, 60 s-stalling Cloudflare path out of
            // the way of 200 MB videos, 2026-10-19) would have meant creating a new key in the Immich UI. A copy
            // under the host-less name travels with the URL; the per-host item stays for the older code path.
            if let k = SovereignStore.secret("immich:\(host)") {
                if SovereignStore.secret("immich") == nil { SovereignStore.saveSecret("immich", k) }
                return ImmichClient(apiRoot: base.appendingPathComponent("api"), apiKey: k, deviceId: "micloud-dashboard", session: session)
            }
            if let k = SovereignStore.secret("immich") {
                return ImmichClient(apiRoot: base.appendingPathComponent("api"), apiKey: k, deviceId: "micloud-dashboard", session: session)
            }
        }
        return nil
    }

    private func photoTargets() -> [PhotoTarget] {
        var targets: [PhotoTarget] = []
        if Self.ncPhotosCopy, let dav = nextcloudDAV() { targets.append(NextcloudPhotoTarget(dav: dav, photosPath: Self.ncPhotosPath)) }
        if let immich = immichClient() { targets.append(immich) }
        return targets
    }

    /// The concrete clients (as BackfillTarget) that photos land on, for the capacity preflight.
    private func photoCapacityTargets() -> [BackfillTarget] {
        var t: [BackfillTarget] = []
        if let immich = immichClient() { t.append(immich) }
        if Self.ncPhotosCopy, let dav = nextcloudDAV() { t.append(NextcloudFolderTarget(dav: dav, path: Self.ncPhotosPath)) }
        return t
    }
    /// `MICLOUD_NC_PHOTOS=0` keeps photos out of Nextcloud when Immich is the photo store (a second full copy
    /// of a 400 GB library is rarely what a self-hoster wants). Default: both, as onboarding promises.
    static let ncPhotosCopy = ProcessInfo.processInfo.environment["MICLOUD_NC_PHOTOS"] != "0"

    /// Where things land on Nextcloud. Defaults are micloud's own tree; a relay that is taking over from an
    /// earlier mirror sets these (launch agent env) to the EXISTING folders so nothing is uploaded twice.
    /// Documents path "" = the files root (iCloud Drive's Documents/ and Desktop/ map onto the same names).
    static let ncDocumentsPath = ProcessInfo.processInfo.environment["MICLOUD_NC_DOCUMENTS_PATH"] ?? "micloud/Documents"
    static let ncPhotosPath    = ProcessInfo.processInfo.environment["MICLOUD_NC_PHOTOS_PATH"] ?? "micloud/Photos"

    /// Per-source backfill ledger under the app's Application Support (its sandbox container).
    private func ledgerURL(_ name: String) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("micloud", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("backfill-\(name).sqlite")
    }
}

/// TEST-ONLY: accept the drill's self-signed cert. The production build uses default TLS validation.
final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) }
        else { h(.performDefaultHandling, nil) }
    }
}
