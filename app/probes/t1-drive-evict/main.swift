import AppKit
import Foundation

// ── micloud T1 sandbox probe ────────────────────────────────────────────────
// The thin-cache linchpin (ROADMAP / mas-background-sync-spike.md, T1):
// Can a SANDBOXED app force-evict an iCloud Drive file (make it dataless) and
// then re-download it on demand? If yes, the Drive thin-cache works in the App
// Store build; if no, that capability lives only in the power build.
//
// Flow: user picks a downloaded iCloud Drive file → evictUbiquitousItem → confirm
// it goes dataless → startDownloadingUbiquitousItem → confirm it re-materialises.
// Everything is logged to ~/Desktop/micloud-t1-result.txt so it can be read over ssh.

// Under the sandbox, ~/Desktop is blocked without an entitlement — write to the container
// Data root (NSHomeDirectory()), which is always writable. Read it back over ssh from
// ~/Library/Containers/com.mineracks.micloud.t1probe/Data/micloud-t1-result.txt
let resultPath = NSHomeDirectory() + "/micloud-t1-result.txt"
var logText = ""
func log(_ s: String) {
    logText += s + "\n"
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    try? logText.write(toFile: resultPath, atomically: true, encoding: .utf8)
}

func snapshot(_ url: URL) -> String {
    let vals = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .fileSizeKey])
    let st: String
    switch vals?.ubiquitousItemDownloadingStatus {
    case .some(.current):      st = "current(fully-downloaded)"
    case .some(.downloaded):   st = "downloaded"
    case .some(.notDownloaded):st = "notDownloaded(DATALESS)"
    default:                   st = "unknown/not-ubiquitous"
    }
    var sb = stat()
    let diskBytes = (stat(url.path, &sb) == 0) ? Int(sb.st_blocks) * 512 : -1
    return "status=\(st) logicalSize=\(vals?.fileSize ?? -1) diskBytes=\(diskBytes)"
}

func poll(_ url: URL, until pass: @escaping (URLUbiquitousItemDownloadingStatus) -> Bool,
          label: String, timeout: TimeInterval = 25) {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if let st = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus, pass(st) {
            log("  \(label): REACHED after \(Int(Date().timeIntervalSince(start)))s — \(snapshot(url))")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    log("  \(label): TIMEOUT (\(Int(timeout))s) — \(snapshot(url))")
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        log("=== micloud T1 probe ===")
        log("home (container path ⇒ sandboxed): \(NSHomeDirectory())")

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a DOWNLOADED file that lives in iCloud Drive (e.g. in ~/Library/Mobile Documents)."
        panel.prompt = "Run T1"
        guard panel.runModal() == .OK, let url = panel.url else { log("cancelled by user"); return finish() }

        log("file: \(url.path)")
        let scoped = url.startAccessingSecurityScopedResource()
        log("startAccessingSecurityScopedResource: \(scoped)")
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        log("initial: \(snapshot(url))")

        // ── T1a — force-evict (the linchpin) ──
        do {
            try FileManager.default.evictUbiquitousItem(at: url)
            log("evictUbiquitousItem(at:): OK ✅")
        } catch {
            log("evictUbiquitousItem(at:): FAILED ❌ — \(error)")
            log(">>> VERDICT: T1 FAILS under sandbox — Drive thin-cache would live only in the power build.")
            return finish()
        }
        poll(url, until: { $0 == .notDownloaded }, label: "after evict (want DATALESS)")

        // ── T1b — re-download on demand ──
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            log("startDownloadingUbiquitousItem(at:): OK ✅")
        } catch {
            log("startDownloadingUbiquitousItem(at:): FAILED ❌ — \(error)")
        }
        poll(url, until: { $0 == .current || $0 == .downloaded }, label: "after download (want re-materialised)")

        let final = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        log(">>> VERDICT: T1 \(final == .current || final == .downloaded ? "PASSES ✅ — sandboxed evict+download round-trip works" : "INCONCLUSIVE — check log")")
        finish()
    }

    func finish() {
        log("=== done — result at \(resultPath) ===")
        let a = NSAlert()
        a.messageText = "T1 probe complete"
        a.informativeText = "Full result written to:\n\(resultPath)"
        a.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
