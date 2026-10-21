import AppKit
import Foundation
import CoreServices

// ── micloud DriveApp — full DriveSource end-to-end, sandboxed ────────────────
// The victory-lap integration: run the real DriveSource (from MicloudKit, compiled in) inside the
// App Sandbox. Grant an iCloud Drive folder; a file that lands there (synced from another device)
// is watched (T2) → materialised if dataless (T1) → uploaded to Nextcloud (WebDAV) → evicted (T1).
//
// Creds come from the env (NEXTCLOUD_URL/USER/PASS) — never baked in. Self-signed drill cert is
// accepted by a test-only permissive URLSession. Log → container root, read over ssh from
// ~/Library/Containers/com.mineracks.micloud.driveapp/Data/micloud-driveapp.log

let resultPath = NSHomeDirectory() + "/micloud-driveapp.log"
let logQ = DispatchQueue(label: "log")
var logText = ""
func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    logQ.sync {
        logText += "[\(ts)] \(s)\n"
        FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
        try? logText.write(toFile: resultPath, atomically: true, encoding: .utf8)
    }
}

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) } else { h(.performDefaultHandling, nil) }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var source: DriveSource?
    func applicationDidFinishLaunching(_ note: Notification) {
        log("=== micloud DriveApp — full DriveSource integration ===")
        log("home (container ⇒ sandboxed): \(NSHomeDirectory())")

        let env = ProcessInfo.processInfo.environment
        guard let urlStr = env["NEXTCLOUD_URL"], let root = URL(string: urlStr),
              let user = env["NEXTCLOUD_USER"], let pass = env["NEXTCLOUD_PASS"] else {
            log("MISSING env NEXTCLOUD_URL / NEXTCLOUD_USER / NEXTCLOUD_PASS — relaunch via the launcher."); return
        }
        log("target: \(root.absoluteString)  user: \(user)")

        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Pick the iCloud Drive folder to MIRROR to Nextcloud, then leave this running."
        panel.prompt = "Mirror"
        guard panel.runModal() == .OK, let folder = panel.url else { log("cancelled"); return NSApp.terminate(nil) }
        let scoped = folder.startAccessingSecurityScopedResource()
        log("folder: \(folder.path)  (scoped: \(scoped))")

        let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
        let dav = NextcloudWebDAV(filesRoot: root, username: user, appPassword: pass, session: session)
        let src = DriveSource(watchedFolder: folder, remoteDocumentsPath: "micloud-drive-test",
                              trashPath: ".trash/micloud", dav: dav) { hb in
            log("  ↳ [\(hb.source.rawValue)] \(hb.status.rawValue): \(hb.lastItem ?? "")")
        }
        source = src
        Task {
            do { try await src.start(); log(">>> DriveSource started — watching. Drop a file into that folder from the MacBook; leave running.") }
            catch { log("DriveSource.start FAILED: \(error)") }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in log("… alive") }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
