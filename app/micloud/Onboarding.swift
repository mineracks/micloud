import SwiftUI
import AppKit

// First-run wizard: generate the sovereign key, make the user back up the 24-word recovery phrase, prove
// they saved it, then pick + connect a backend. On finish it persists the key (SovereignStore) and the
// install record (InstallStore) and unlocks the dashboard. Reuses the same C palette + Localizer as Dashboard.

@MainActor final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, phrase, confirm, backend, diy, hosted, done, monitor }

    @Published var step: Step = .welcome
    @Published var key: SovereignKey
    @Published var phrase: [String]

    // confirm: 3 word positions to re-enter, each with 4 tappable options
    @Published var challenge: [Int] = []
    @Published var options: [Int: [String]] = [:]
    @Published var picked: [Int: String] = [:]
    @Published var confirmError = false

    // backend choice + DIY credential entry
    @Published var backend: Install.Backend = .none
    @Published var ncURL = ""
    @Published var ncUser = ""
    @Published var ncPass = ""
    @Published var immichURL = ""
    @Published var immichKey = ""
    @Published var verifying = false
    @Published var verifyError: String? = nil
    @Published var verifyFreeBytes: Int64? = nil
    // The no-copy-paste paths: Nextcloud Login Flow v2 (browser sign-in hands us an app password) and an
    // Immich email/password sign-in that mints a dedicated API key. The typed-credential fields stay as the
    // fallback behind a disclosure for servers where neither works.
    @Published var ncSigningIn = false
    @Published var ncLinked = false
    @Published var ncManual = false
    @Published var immichEmail = ""
    @Published var immichPassword = ""
    @Published var immichSigningIn = false
    @Published var immichLinked = false
    @Published var immichManual = false        // "use email and password instead"
    @Published var immichHaveKey = false       // "I already have an API key"
    @Published var immichError: String? = nil
    private var ncFlowTask: Task<Void, Never>?
    private var immichFlowTask: Task<Void, Never>?
    private var immichCallback: CheckedContinuation<URL, Error>?
    @Published var existingChildren: Int? = nil     // preflight: how many items already under `micloud/` (nil = none)

    var onFinish: () -> Void = {}
    private let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)

    init() {
        let k = SovereignStore.loadKey() ?? SovereignKey.generate()
        key = k; phrase = k.recoveryPhrase
        makeChallenge()
        restoreLinks()
    }

    /// A sign-in that succeeded is saved immediately (see `signInWithNextcloud` / `linkImmich`), so quitting
    /// or relaunching mid-wizard never makes the person approve in the browser twice. Pick it back up here.
    private func restoreLinks() {
        let inst = InstallStore.load()
        guard !inst.onboarded, inst.backend == .diy else { return }
        if let url = inst.nextcloudURL, let user = inst.nextcloudUser, let pw = SovereignStore.secret("nextcloud:\(user)") {
            ncURL = url; ncUser = user; ncPass = pw; ncLinked = true; backend = .diy; step = .diy
        }
        if let im = inst.immichURL, let host = URL(string: im)?.host, let key = SovereignStore.secret("immich:\(host)") {
            immichURL = im; immichKey = key; immichLinked = true
        }
    }

    /// Persist what is linked so far WITHOUT marking the install onboarded (the wizard still has to finish).
    private func saveLinks() {
        var inst = InstallStore.load()
        inst.backend = .diy
        inst.nextcloudURL = ncLinked ? ncURL : inst.nextcloudURL
        inst.nextcloudUser = ncLinked ? ncUser : inst.nextcloudUser
        inst.immichURL = immichLinked ? immichURL : inst.immichURL
        InstallStore.save(inst)
    }

    func regenerate() { let k = SovereignKey.generate(); key = k; phrase = k.recoveryPhrase; makeChallenge() }

    /// Pick 3 distinct word positions, each with the correct word + 3 decoys from the BIP39 list.
    private func makeChallenge() {
        challenge = Array(0..<phrase.count).shuffled().prefix(3).sorted()
        picked = [:]; confirmError = false
        options = Dictionary(uniqueKeysWithValues: challenge.map { pos in
            var opts = Set([phrase[pos]])
            while opts.count < 4 { opts.insert(bip39Words.randomElement()!) }
            return (pos, Array(opts).shuffled())
        })
    }

    var confirmComplete: Bool { challenge.allSatisfy { picked[$0] != nil } }
    /// On a correct confirm the phrase is backed up → record it + finish. (Backend was already saved at connect.)
    func checkConfirm() -> Bool {
        let ok = challenge.allSatisfy { picked[$0] == phrase[$0] }
        if ok { markBackedUp(true); advance(to: .done) } else { confirmError = true }
        return ok
    }
    /// "Remind me later" on the phrase step — finish without forcing the backup (dashboard nudges later).
    func deferBackup() { markBackedUp(false); advance(to: .done) }

    func advance(to s: Step) { withAnimation(.easeInOut(duration: 0.22)) { step = s } }

    /// A readable name for the token / API key this install leaves behind on the person's servers.
    static var clientName: String { "micloud on " + (Host.current().localizedName ?? "this Mac") }

    /// Nextcloud Login Flow v2: open the server's sign-in page in the default browser and wait for the
    /// approval. The server returns the canonical URL, login name and a fresh app password — the person
    /// never sees or types the password. Cancelling the Task abandons the flow (it expires server-side).
    func signInWithNextcloud() {
        guard let server = NextcloudLoginFlow.normalise(ncURL) else { verifyError = "fields"; return }
        ncURL = server.absoluteString; verifyError = nil; ncSigningIn = true; ncLinked = false
        ncFlowTask?.cancel()
        ncFlowTask = Task { @MainActor in
            do {
                let started = try await NextcloudLoginFlow.start(server: server, clientName: Self.clientName, session: session)
                NSWorkspace.shared.open(started.loginURL)
                let creds = try await NextcloudLoginFlow.waitForApproval(started, session: session)
                ncURL = creds.server.absoluteString; ncUser = creds.loginName; ncPass = creds.appPassword
                ncLinked = true; ncSigningIn = false
                SovereignStore.saveSecret("nextcloud:\(ncUser)", ncPass); saveLinks()   // survives a relaunch
            } catch is CancellationError {
                ncSigningIn = false
            } catch {
                ncSigningIn = false; verifyError = "connect"
            }
        }
    }
    func cancelNextcloudSignIn() { ncFlowTask?.cancel(); ncFlowTask = nil; ncSigningIn = false }

    /// Monitor mode: this Mac only WATCHES. Same Nextcloud sign-in as a syncing install (the dashboard lives
    /// at `micloud/status.json` on that server); no recovery phrase, no Immich, no permissions — nothing on
    /// this Mac is read, so there is nothing to protect or grant.
    func finishMonitor() {
        guard ncLinked, !ncUser.isEmpty, !ncPass.isEmpty else { verifyError = "fields"; return }
        SovereignStore.saveSecret("nextcloud:\(ncUser)", ncPass)
        InstallStore.save(Install(onboarded: true, backend: .diy, nextcloudURL: ncURL, nextcloudUser: ncUser,
                                  immichURL: nil, recoveryBackedUp: true, monitor: true))
        onFinish()
    }

    /// Immich browser sign-in — mirrors the Nextcloud button. Opens the server's OAuth page, waits for the
    /// browser to hand the code back through the `app.immich://` URL scheme (see `OAuthCallbacks`), trades it
    /// for a session, mints this Mac's API key, ends the session. Servers without OAuth fall back to the
    /// email/password fields.
    func signInWithImmich() {
        guard let base = NextcloudLoginFlow.normalise(immichURL) else { immichError = "fields"; return }
        immichURL = base.absoluteString; immichError = nil; immichSigningIn = true; immichLinked = false
        let api = base.appendingPathComponent("api")
        immichFlowTask?.cancel()
        immichFlowTask = Task { @MainActor in
            do {
                guard await ImmichClient.oauthAvailable(apiRoot: api, session: session) else {
                    immichSigningIn = false; immichError = "nooauth"; immichManual = true; return
                }
                let start = try await ImmichClient.oauthStart(apiRoot: api, session: session)
                NSWorkspace.shared.open(start.url)
                let callback: URL = try await withCheckedThrowingContinuation { c in
                    immichCallback = c
                    OAuthCallbacks.pending = { [weak self] url in
                        guard let self, let c = self.immichCallback else { return }
                        self.immichCallback = nil; c.resume(returning: url)
                    }
                }
                let token = try await ImmichClient.oauthFinish(apiRoot: api, callback: callback, start: start, session: session)
                let key = try await ImmichClient.mintAPIKey(apiRoot: api, accessToken: token, name: Self.clientName, session: session)
                immichKey = key; immichLinked = true; immichSigningIn = false
                if let host = base.host { SovereignStore.saveSecret("immich:\(host)", key) }; saveLinks()
            } catch is CancellationError {
                immichSigningIn = false
            } catch {
                immichSigningIn = false; immichError = "connect"; immichManual = true
            }
            OAuthCallbacks.pending = nil
        }
    }
    func cancelImmichSignIn() {
        if let c = immichCallback { immichCallback = nil; c.resume(throwing: CancellationError()) }
        immichFlowTask?.cancel(); immichFlowTask = nil; immichSigningIn = false; OAuthCallbacks.pending = nil
    }

    /// Immich: sign in once with email + password, mint an API key named after this Mac, forget the password.
    func linkImmich() {
        guard let base = NextcloudLoginFlow.normalise(immichURL), !immichEmail.isEmpty, !immichPassword.isEmpty else { immichError = "fields"; return }
        immichURL = base.absoluteString
        immichSigningIn = true; immichError = nil
        Task { @MainActor in
            do {
                let key = try await ImmichClient.createAPIKey(apiRoot: base.appendingPathComponent("api"), email: immichEmail,
                                                              password: immichPassword, keyName: Self.clientName, session: session)
                immichKey = key; immichPassword = ""; immichLinked = true; immichSigningIn = false
                if let host = base.host { SovereignStore.saveSecret("immich:\(host)", key) }; saveLinks()
            } catch {
                immichSigningIn = false; immichError = "connect"; immichHaveKey = true   // SSO users land here: show the key path
            }
        }
    }

    /// Live-verify the DIY Nextcloud credentials (a quota PROPFIND) — proves the URL + app password work,
    /// shows free space, and runs a **preflight** on the `micloud/` namespace so we can reassure the user
    /// their other files are untouched. On success we persist the backend and move to the (deferrable)
    /// recovery-phrase backup — value first, scary step last.
    func verifyAndFinish() {
        if let u = NextcloudLoginFlow.normalise(ncURL) { ncURL = u.absoluteString }
        if let u = NextcloudLoginFlow.normalise(immichURL) { immichURL = u.absoluteString } else { immichURL = "" }
        guard let base = URL(string: ncURL), !ncUser.isEmpty, !ncPass.isEmpty else {
            verifyError = "fields"; return
        }
        verifying = true; verifyError = nil
        let filesRoot = base.appendingPathComponent("remote.php/dav/files").appendingPathComponent(ncUser)
        let dav = NextcloudWebDAV(filesRoot: filesRoot, username: ncUser, appPassword: ncPass, session: session)
        Task { @MainActor in
            do {
                let s = try await dav.storage()
                verifyFreeBytes = s.freeBytes
                // preflight: micloud only ever reads/writes under `micloud/` — never the user's existing files.
                if let inv = try? await dav.inventory("micloud"), inv.exists, inv.children > 0 { existingChildren = inv.children }
                verifying = false
                // Default is server-readable (a usable copy you own) — nothing to write down. The recovery
                // phrase only matters when the user turns on end-to-end encryption (a Pro opt-in), so the
                // common path goes straight to done. `recoveryBackedUp: true` = no backup nudge.
                persist(backend: .diy, backedUp: true)
                advance(to: .done)
            } catch {
                verifying = false; verifyError = "connect"
            }
        }
    }

    /// Persist the sovereign key + secrets + install record. Called once a backend is confirmed (before backup).
    private func persist(backend: Install.Backend, backedUp: Bool) {
        SovereignStore.save(key)
        if backend == .diy {
            SovereignStore.saveSecret("nextcloud:\(ncUser)", ncPass)
            if !immichKey.isEmpty, let host = URL(string: immichURL)?.host { SovereignStore.saveSecret("immich:\(host)", immichKey) }
        }
        InstallStore.save(Install(onboarded: true, backend: backend,
                                  nextcloudURL: backend == .diy ? ncURL : nil,
                                  nextcloudUser: backend == .diy ? ncUser : nil,
                                  immichURL: (backend == .diy && !immichURL.isEmpty) ? immichURL : nil,
                                  recoveryBackedUp: backedUp))
    }
    /// Update just the "phrase written down" flag on the persisted install record.
    private func markBackedUp(_ v: Bool) {
        var inst = InstallStore.load(); inst.recoveryBackedUp = v; InstallStore.save(inst)
    }
}

// ── the wizard view ─────────────────────────────────────────────────────────────
struct OnboardingView: View {
    @StateObject var model: OnboardingModel
    @EnvironmentObject var loc: Localizer

    var body: some View {
        ZStack {
            LinearGradient(colors: [C.navy, C.navy2], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                brand
                card
            }
            .frame(maxWidth: 560)
            .padding(28)
        }
        .environment(\.layoutDirection, loc.effective.isRTL ? .rightToLeft : .leftToRight)
        .frame(minWidth: 640, minHeight: 640)
    }

    private var brand: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                Text("mi").foregroundColor(.white); Text("cloud").foregroundColor(C.accent)
            }.font(.system(size: 26, weight: .bold))
            if let n = stepNumber {
                Text(loc.t("onb.step", "\(n)", "3"))
                    .font(.system(size: 11, weight: .semibold)).tracking(1).foregroundColor(C.inkFaint)
            }
        }.padding(.bottom, 18)
    }

    /// User-facing step number (welcome & the two backend branches don't all count as separate numbered steps).
    private var stepNumber: Int? {
        switch model.step {
        // Default flow is 3 steps (welcome → connect → done); the phrase/confirm sub-steps only appear on
        // the Pro end-to-end-encryption path, grouped under step 2.
        case .welcome: return 1; case .backend, .diy, .hosted, .phrase, .confirm, .monitor: return 2
        case .done: return 3
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.step {
            case .welcome: welcome
            case .phrase:  phraseStep
            case .confirm: confirmStep
            case .backend: backendStep
            case .diy:     diyStep
            case .hosted:  hostedStep
            case .done:    doneStep
            case .monitor: monitorStep
            }
        }
        .padding(26)
        .background(C.ground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }

    // 1 — welcome
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            icon("lock.shield.fill", C.accent)
            Text(loc.t("onb.welcome.title")).font(.system(size: 23, weight: .bold)).foregroundColor(C.ink)
            Text(loc.t("onb.welcome.body")).font(.system(size: 14)).foregroundColor(C.inkSoft).lineSpacing(3)
            primary(loc.t("onb.welcome.begin")) { model.advance(to: .backend) }
            // A second Mac that should only WATCH a backup already running elsewhere (a laptop checking on the
            // Mac in the rack). Same sign-in, no sync, no permissions.
            Button { model.advance(to: .monitor) } label: {
                Text(loc.t("onb.welcome.monitor")).font(.system(size: 13, weight: .medium)).foregroundColor(C.inkSoft)
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.plain).padding(.top, 2)
        }
    }

    private var monitorStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(loc.t("onb.monitor.title"))
            Text(loc.t("onb.monitor.body")).font(.system(size: 13)).foregroundColor(C.inkSoft).lineSpacing(2)
            field(loc.t("onb.diy.url"), text: $model.ncURL, prompt: "https://cloud.example.com")
            if model.ncLinked {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(C.ok)
                    Text(loc.t("onb.diy.signin.as", model.ncUser)).font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.ok)
                    Spacer()
                    ghost("arrow.clockwise", loc.t("onb.diy.signin.again")) { model.signInWithNextcloud() }
                }
            } else if model.ncSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("onb.diy.signin.waiting")).font(.system(size: 12.5)).foregroundColor(C.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    ghost("xmark", loc.t("onb.diy.signin.cancel")) { model.cancelNextcloudSignIn() }
                }.padding(10).background(C.syncSoft).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                primary(loc.t("onb.diy.signin")) { model.signInWithNextcloud() }
            }
            if let e = model.verifyError, e == "connect" {
                Text(loc.t("onb.diy.fail")).font(.system(size: 12, weight: .medium)).foregroundColor(C.err)
            }
            if model.ncLinked { primary(loc.t("onb.monitor.start")) { model.finishMonitor() } }
            Button { model.advance(to: .welcome) } label: {
                Text(loc.t("onb.monitor.back")).font(.system(size: 13, weight: .medium)).foregroundColor(C.inkSoft)
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.plain).padding(.top, 2)
        }
    }

    // recovery phrase — shown AFTER the backend is connected (value first). Backup is deferrable.
    private var phraseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(loc.t("onb.phrase.title"))
            Text(loc.t("onb.phrase.body")).font(.system(size: 13)).foregroundColor(C.inkSoft).lineSpacing(2)
            if let n = model.existingChildren {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").font(.system(size: 12)).foregroundColor(C.ok)
                    Text(loc.t("onb.preflight", "\(n)")).font(.system(size: 12)).foregroundColor(C.ok)
                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                 .background(C.okSoft).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            wordGrid
            HStack(spacing: 10) {
                ghost("doc.on.doc", loc.t("onb.phrase.copy")) {
                    let s = model.phrase.joined(separator: " ")
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                }
                ghost("arrow.clockwise", loc.t("onb.phrase.regen")) { model.regenerate() }
                Spacer()
            }
            primary(loc.t("onb.phrase.written")) { model.advance(to: .confirm) }
            Button { model.deferBackup() } label: {
                Text(loc.t("onb.phrase.later")).font(.system(size: 13, weight: .medium)).foregroundColor(C.inkSoft)
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.plain).padding(.top, 2)
        }
    }

    private var wordGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Array(model.phrase.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundColor(C.inkFaint).frame(width: 18, alignment: .trailing)
                    Text(w).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(C.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(C.card).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.line, lineWidth: 1))
            }
        }
    }

    // 3 — confirm
    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(loc.t("onb.confirm.title"))
            Text(loc.t("onb.confirm.body")).font(.system(size: 13)).foregroundColor(C.inkSoft)
            ForEach(model.challenge, id: \.self) { pos in
                VStack(alignment: .leading, spacing: 7) {
                    Text(loc.t("onb.confirm.word", "\(pos + 1)")).font(.system(size: 12, weight: .semibold)).foregroundColor(C.inkSoft)
                    HStack(spacing: 8) {
                        ForEach(model.options[pos] ?? [], id: \.self) { w in
                            let sel = model.picked[pos] == w
                            Button { model.picked[pos] = w; model.confirmError = false } label: {
                                Text(w).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(sel ? Color(hex: 0x3A2600) : C.ink)
                                    .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity)
                                    .background(sel ? C.accent : C.card)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? C.accent : C.line, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            if model.confirmError {
                Text(loc.t("onb.confirm.wrong")).font(.system(size: 12.5, weight: .medium)).foregroundColor(C.err)
            }
            navRow(back: { model.advance(to: .phrase) }, next: loc.t("onb.continue"),
                   enabled: model.confirmComplete) { _ = model.checkConfirm() }
        }
    }

    // 4 — backend choice
    private var backendStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title(loc.t("onb.backend.title"))
            Text(loc.t("onb.backend.body")).font(.system(size: 13)).foregroundColor(C.inkSoft)
            choice("externaldrive.connected.to.line.below", loc.t("onb.backend.diy.title"),
                   loc.t("onb.backend.diy.body"), badge: nil) { model.backend = .diy; model.advance(to: .diy) }
            choice("cloud.fill", loc.t("onb.backend.hosted.title"),
                   loc.t("onb.backend.hosted.body"), badge: loc.t("onb.backend.hosted.badge")) { model.backend = .hosted; model.advance(to: .hosted) }
            Button { model.advance(to: .welcome) } label: {
                Text(loc.t("onb.back")).font(.system(size: 13, weight: .medium)).foregroundColor(C.inkSoft)
            }.buttonStyle(.plain).padding(.top, 2)
        }
    }

    // 4a — DIY credentials
    private var diyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(loc.t("onb.diy.title"))
            Text(loc.t("onb.diy.body")).font(.system(size: 13)).foregroundColor(C.inkSoft)
            field(loc.t("onb.diy.url"), text: $model.ncURL, prompt: "https://cloud.example.com")
            // Sign in with the browser (Login Flow v2) — the default. Typed app password behind a disclosure.
            if model.ncLinked {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(C.ok)
                    Text(loc.t("onb.diy.signin.as", model.ncUser)).font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.ok)
                    Spacer()
                    ghost("arrow.clockwise", loc.t("onb.diy.signin.again")) { model.signInWithNextcloud() }
                }
            } else if model.ncSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc.t("onb.diy.signin.waiting")).font(.system(size: 12.5)).foregroundColor(C.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    ghost("xmark", loc.t("onb.diy.signin.cancel")) { model.cancelNextcloudSignIn() }
                }.padding(10).background(C.syncSoft).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                primary(loc.t("onb.diy.signin")) { model.signInWithNextcloud() }
            }
            DisclosureGroup(isExpanded: $model.ncManual) {
                HStack(spacing: 10) {
                    field(loc.t("onb.diy.user"), text: $model.ncUser, prompt: "you")
                    secure(loc.t("onb.diy.pass"), text: $model.ncPass)
                }.padding(.top, 6)
            } label: {
                Text(loc.t("onb.diy.manual")).font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.inkSoft)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    field(loc.t("onb.diy.immich"), text: $model.immichURL, prompt: "https://photos.example.com")
                    if model.immichLinked {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(C.ok)
                            Text(loc.t("onb.diy.immichLinked")).font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.ok)
                            Spacer()
                            ghost("arrow.clockwise", loc.t("onb.diy.signin.again")) { model.signInWithImmich() }
                        }
                    } else {
                        // Same shape as Nextcloud: one button, the browser does the rest.
                        if model.immichSigningIn {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(loc.t("onb.diy.immichSignin.waiting")).font(.system(size: 12.5)).foregroundColor(C.inkSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                ghost("xmark", loc.t("onb.diy.signin.cancel")) { model.cancelImmichSignIn() }
                            }.padding(10).background(C.syncSoft).clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            primary(loc.t("onb.diy.immichSignin")) { model.signInWithImmich() }
                        }
                        if let e = model.immichError {
                            Text(loc.t(e == "connect" ? "onb.diy.immichFail" : e == "nooauth" ? "onb.diy.immichNoOAuth" : "onb.diy.immichFields"))
                                .font(.system(size: 12, weight: .medium)).foregroundColor(C.err)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DisclosureGroup(isExpanded: $model.immichManual) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    field(loc.t("onb.diy.immichEmail"), text: $model.immichEmail, prompt: "you@example.com")
                                    secure(loc.t("onb.diy.immichPassword"), text: $model.immichPassword)
                                }
                                ghost("key.fill", loc.t("onb.diy.immichLink")) { model.linkImmich() }
                            }.padding(.top, 6)
                        } label: {
                            Text(loc.t("onb.diy.immichManual")).font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.inkSoft)
                        }
                        DisclosureGroup(isExpanded: $model.immichHaveKey) {
                            VStack(alignment: .leading, spacing: 6) {
                                secure(loc.t("onb.diy.immichKey"), text: $model.immichKey)
                                // SSO / Google accounts have no Immich password — the key page is the way in.
                                if let base = NextcloudLoginFlow.normalise(model.immichURL),
                                   let page = URL(string: base.absoluteString + "/user-settings?isOpen=api-keys") {
                                    Link(loc.t("onb.diy.immichKeyPage"), destination: page)
                                        .font(.system(size: 12, weight: .medium)).foregroundColor(C.sync)
                                }
                            }.padding(.top, 6)
                        } label: {
                            Text(loc.t("onb.diy.immichHaveKey")).font(.system(size: 12, weight: .medium)).foregroundColor(C.inkFaint)
                        }
                    }
                }.padding(.top, 6)
            } label: {
                Text(loc.t("onb.diy.immich")).font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.inkSoft)
            }
            if let e = model.verifyError {
                Text(loc.t(e == "connect" ? "onb.diy.fail" : "onb.diy.fields"))
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(C.err)
            }
            HStack(spacing: 14) {
                Link(loc.t("onb.diy.guide"), destination: URL(string: "https://getmicloud.com/guides/back-up-icloud-to-immich")!)
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(C.sync)
                Link(loc.t("onb.diy.help"), destination: URL(string: "https://getmicloud.com/onboarding")!)
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(C.sync)
            }.padding(.top, 2)
            navRow(back: { model.advance(to: .backend) },
                   next: model.verifying ? loc.t("onb.diy.verifying") : loc.t("onb.diy.verify"),
                   enabled: !model.verifying) { model.verifyAndFinish() }
        }
    }

    // 4b — hosted trial (provisioning API is a follow-on build; this states the offer + falls back to DIY)
    private var hostedStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            icon("cloud.fill", C.sync)
            title(loc.t("onb.hosted.title"))
            Text(loc.t("onb.hosted.body")).font(.system(size: 13.5)).foregroundColor(C.inkSoft).lineSpacing(3)
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 12)).foregroundColor(C.pause)
                Text(loc.t("onb.hosted.soon")).font(.system(size: 12.5)).foregroundColor(C.pause)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
             .background(C.pauseSoft).clipShape(RoundedRectangle(cornerRadius: 10))
            primary(loc.t("onb.hosted.useDiy")) { model.backend = .diy; model.advance(to: .diy) }
            Button { model.advance(to: .backend) } label: {
                Text(loc.t("onb.back")).font(.system(size: 13, weight: .medium)).foregroundColor(C.inkSoft)
            }.buttonStyle(.plain)
        }
    }

    // 5 — done
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            icon("checkmark.seal.fill", C.ok)
            Text(loc.t("onb.done.title")).font(.system(size: 23, weight: .bold)).foregroundColor(C.ink)
            Text(loc.t("onb.done.body")).font(.system(size: 14)).foregroundColor(C.inkSoft).lineSpacing(3)
            if let free = model.verifyFreeBytes {
                Text(loc.t("onb.diy.ok", ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))
                    .font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.ok)
            }
            if let n = model.existingChildren {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").font(.system(size: 12)).foregroundColor(C.ok)
                    Text(loc.t("onb.preflight", "\(n)")).font(.system(size: 12)).foregroundColor(C.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            primary(loc.t("onb.done.finish")) { model.onFinish() }
        }
    }

    // ── shared bits ──────────────────────────────────────────────────────────────
    private func title(_ s: String) -> some View { Text(s).font(.system(size: 20, weight: .bold)).foregroundColor(C.ink) }
    private func icon(_ sym: String, _ col: Color) -> some View {
        Image(systemName: sym).font(.system(size: 22, weight: .semibold)).foregroundColor(.white)
            .frame(width: 46, height: 46).background(col).clipShape(RoundedRectangle(cornerRadius: 13))
    }
    private func primary(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14.5, weight: .semibold)).foregroundColor(Color(hex: 0x3A2600))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(C.accent).clipShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).padding(.top, 4)
    }
    private func ghost(_ sym: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: sym); Text(label) }
                .font(.system(size: 12.5, weight: .semibold)).foregroundColor(C.inkSoft)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(C.card).clipShape(Capsule()).overlay(Capsule().stroke(C.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func navRow(back: @escaping () -> Void, next: String, enabled: Bool = true, go: @escaping () -> Void) -> some View {
        HStack {
            Button(action: back) { Text(loc.t("onb.back")).font(.system(size: 13.5, weight: .medium)).foregroundColor(C.inkSoft) }
                .buttonStyle(.plain)
            Spacer()
            Button(action: go) {
                Text(next).font(.system(size: 14, weight: .semibold)).foregroundColor(Color(hex: 0x3A2600))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(enabled ? C.accent : C.accent.opacity(0.4)).clipShape(Capsule())
            }.buttonStyle(.plain).disabled(!enabled)
        }.padding(.top, 6)
    }
    private func choice(_ sym: String, _ t: String, _ body: String, badge: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: sym).font(.system(size: 16, weight: .semibold)).foregroundColor(C.accentDeep)
                    .frame(width: 34, height: 34).background(C.accentSoft).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(t).font(.system(size: 14.5, weight: .semibold)).foregroundColor(C.ink)
                        if let b = badge {
                            Text(b).font(.system(size: 10, weight: .bold)).foregroundColor(C.ok)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(C.okSoft).clipShape(Capsule())
                        }
                    }
                    Text(body).font(.system(size: 12.5)).foregroundColor(C.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(C.inkFaint)
            }
            .padding(13).background(C.card).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(C.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundColor(C.inkFaint)
            TextField(prompt, text: text).textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(C.ink)
                .padding(.horizontal, 10).padding(.vertical, 8).background(C.card)
                .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(C.line, lineWidth: 1))
                .autocorrectionDisabled(true)
        }
    }
    private func secure(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundColor(C.inkFaint)
            SecureField("••••••••", text: text).textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(C.ink)
                .padding(.horizontal, 10).padding(.vertical, 8).background(C.card)
                .clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(C.line, lineWidth: 1))
        }
    }
}
