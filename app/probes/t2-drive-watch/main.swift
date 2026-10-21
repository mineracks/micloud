import AppKit
import Foundation
import CoreServices   // FSEvents

// ── micloud T2 sandbox probe ────────────────────────────────────────────────
// Spike T2: can a SANDBOXED app watch a user-granted iCloud Drive folder for
// changes — including files created/edited on ANOTHER device that iCloud syncs
// down — within seconds, WITHOUT listing the tree (the dataless-dir readdir
// deadlock the power-build agent hit)?
//
// Approach: FSEventStream on the security-scoped folder (primary — the callback
// reports only the changed paths, so we never walk the tree), plus an
// NSMetadataQuery for comparison (secondary — likely needs an iCloud-container
// entitlement we don't have when ad-hoc signed; logged either way).
//
// Runs continuously. Result appended to the container root; read over ssh from
// ~/Library/Containers/com.mineracks.micloud.t2probe/Data/micloud-t2-result.txt

let resultPath = NSHomeDirectory() + "/micloud-t2-result.txt"
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

// Top-level (non-capturing) closure ⇒ valid C function pointer for FSEvents.
let fsCallback: FSEventStreamCallback = { _, _, numEvents, eventPaths, eventFlags, _ in
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    for i in 0..<numEvents {
        let f = eventFlags[i]
        var kinds: [String] = []
        if f & UInt32(kFSEventStreamEventFlagItemCreated)  != 0 { kinds.append("created") }
        if f & UInt32(kFSEventStreamEventFlagItemModified) != 0 { kinds.append("modified") }
        if f & UInt32(kFSEventStreamEventFlagItemRemoved)  != 0 { kinds.append("removed") }
        if f & UInt32(kFSEventStreamEventFlagItemRenamed)  != 0 { kinds.append("renamed") }
        let name = i < paths.count ? (paths[i] as NSString).lastPathComponent : "?"
        log("FSEVENT ✅ \(kinds.isEmpty ? "flags=\(f)" : kinds.joined(separator: "+"))  \(name)")
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var stream: FSEventStreamRef?
    var query: NSMetadataQuery?

    func applicationDidFinishLaunching(_ note: Notification) {
        log("=== micloud T2 probe — whole-Drive change watching under sandbox ===")
        log("home (container ⇒ sandboxed): \(NSHomeDirectory())")

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick the iCloud Drive folder to WATCH (e.g. micloud-t2). Then leave this running."
        panel.prompt = "Watch"
        guard panel.runModal() == .OK, let url = panel.url else { log("cancelled"); return NSApp.terminate(nil) }
        let scoped = url.startAccessingSecurityScopedResource()
        log("folder: \(url.path)")
        log("startAccessingSecurityScopedResource: \(scoped)")

        // ── FSEvents (primary): reports changed paths only — no tree walk ──
        var ctx = FSEventStreamContext()
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                         | kFSEventStreamCreateFlagUseCFTypes
                         | kFSEventStreamCreateFlagNoDefer)
        if let s = FSEventStreamCreate(kCFAllocatorDefault, fsCallback, &ctx,
                                       [url.path] as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                       0.3, flags) {
            stream = s
            FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
            let ok = FSEventStreamStart(s)
            log("FSEventStream start: \(ok ? "OK ✅" : "FAILED ❌")  (watching recursively, no tree listing)")
        } else {
            log("FSEventStreamCreate: FAILED ❌")
        }

        // ── NSMetadataQuery (secondary): iCloud-native; ad-hoc has no iCloud entitlement, so expect little ──
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(value: true)
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
            log("MDQUERY gathered: \(q.resultCount) items in ubiquitous-documents scope")
        }
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { _ in
            log("MDQUERY ✅ update: \(q.resultCount) items")
        }
        query = q
        log("NSMetadataQuery start: \(q.start())")

        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in log("… still watching (heartbeat)") }
        log(">>> WATCHING. Now create/edit files in that folder from another device (or the MacBook). Leave running; quit with Cmd-Q when told.")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
