import AppKit
import Foundation

// ── micloud power-build probe: Notes + Bookmarks → Nextcloud ────────────────────────────────────
// The two sources the App Store sandbox can't reach. This UNSANDBOXED build captures them the way the
// original agent recipe did, using Apple's own permission gates:
//   • Safari bookmarks — read ~/Library/Safari/Bookmarks.plist   (needs FULL DISK ACCESS)
//   • Apple Notes      — AppleScript automation of Notes.app     (needs AUTOMATION consent)
// Both are user-granted, revocable TCC permissions — legitimate, not a hack. Ships only in the notarized
// open-source power build, never the sandboxed App Store app.
// Creds from env (NEXTCLOUD_URL/USER/PASS); nothing secret printed.

let logPath = NSHomeDirectory() + "/micloud-notesbookmarks.log"
var logText = ""
func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    logText += "[\(ts)] \(s)\n"
    FileHandle.standardError.write("[\(ts)] \(s)\n".data(using: .utf8)!)
    try? logText.write(toFile: logPath, atomically: true, encoding: .utf8)
}

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge,
                    completionHandler h: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = c.protectionSpace.serverTrust { h(.useCredential, URLCredential(trust: t)) } else { h(.performDefaultHandling, nil) }
    }
}

let env = ProcessInfo.processInfo.environment
guard let urlStr = env["NEXTCLOUD_URL"], let root = URL(string: urlStr),
      let user = env["NEXTCLOUD_USER"], let pass = env["NEXTCLOUD_PASS"] else {
    log("MISSING env NEXTCLOUD_URL / NEXTCLOUD_USER / NEXTCLOUD_PASS"); exit(2)
}
let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
let dav = NextcloudWebDAV(filesRoot: root, username: user, appPassword: pass, session: session)

func safe(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
    let cleaned = String(s.unicodeScalars.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
    return String((cleaned.isEmpty ? "untitled" : cleaned).prefix(80))
}
func shortHash(_ s: String) -> String { String(format: "%08x", UInt32(truncatingIfNeeded: s.hashValue)) }

func uploadData(_ data: Data, to rel: String) async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try data.write(to: tmp)
    try await dav.ensureParents(of: rel)
    try await dav.upload(localFile: tmp, to: rel)
}

// ── Bookmarks (Full Disk Access) ────────────────────────────────────────────────────────────────
struct BM { let path: [String]; let title: String; let url: String }
func collect(_ node: [String: Any], path: [String], into: inout [BM]) {
    let type = node["WebBookmarkType"] as? String
    if type == "WebBookmarkTypeLeaf", let url = node["URLString"] as? String {
        let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
        into.append(BM(path: path, title: title, url: url))
    } else if let children = node["Children"] as? [[String: Any]] {
        // a folder — append its title (skip the unnamed root + the special proxies)
        let title = node["Title"] as? String
        let next = (title != nil && !(title!.isEmpty)) ? path + [title!] : path
        for c in children { collect(c, path: next, into: &into) }
    }
}
func webloc(_ url: String) -> Data {
    Data(#"<?xml version="1.0" encoding="UTF-8"?>\#n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\#n<plist version="1.0"><dict><key>URL</key><string>\#(url)</string></dict></plist>\#n"#.utf8)
}
func exportBookmarks() async {
    let bmPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
    guard let data = FileManager.default.contents(atPath: bmPath) else {
        log("BOOKMARKS: can't read \(bmPath) — grant micloud FULL DISK ACCESS (System Settings › Privacy › Full Disk Access)")
        return
    }
    guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
        log("BOOKMARKS: unreadable plist"); return
    }
    var bms: [BM] = []
    collect(plist, path: [], into: &bms)
    log("BOOKMARKS: found \(bms.count)")
    var ok = 0
    for b in bms {
        let folder = b.path.isEmpty ? "" : b.path.map(safe).joined(separator: "/") + "/"
        let rel = "Bookmarks/\(folder)\(safe(b.title))-\(shortHash(b.url)).webloc"
        do { try await uploadData(webloc(b.url), to: rel); ok += 1 }
        catch { log("  bookmark failed \(b.title): \(error)") }
    }
    log("BOOKMARKS: uploaded \(ok)/\(bms.count) → Nextcloud Bookmarks/")
}

// ── Notes (Automation of Notes.app) ───────────────────────────────────────────────────────────────
func exportNotes() async {
    let limit = Int(env["NOTES_LIMIT"] ?? "25") ?? 25
    let script = """
    tell application "Notes"
      set cnt to count of notes
      set lim to cnt
      if lim > \(limit) then set lim to \(limit)
      set out to ""
      repeat with i from 1 to lim
        set n to note i
        set out to out & (name of n) & "\\n---MICLOUD-BODY---\\n" & (body of n) & "\\n===MICLOUD-NOTE===\\n"
      end repeat
      return out
    end tell
    """
    var err: NSDictionary?
    guard let result = NSAppleScript(source: script)?.executeAndReturnError(&err) else {
        log("NOTES: AppleScript failed — grant micloud AUTOMATION access to Notes when prompted. \(err ?? [:])")
        return
    }
    if let err { log("NOTES: \(err)"); return }
    let text = result.stringValue ?? ""
    let records = text.components(separatedBy: "===MICLOUD-NOTE===").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    log("NOTES: exported \(records.count) (limit \(limit))")
    var ok = 0
    for rec in records {
        let parts = rec.components(separatedBy: "---MICLOUD-BODY---")
        let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "note"
        let body = parts.count > 1 ? parts[1] : ""
        let html = "<!doctype html><meta charset=\"utf-8\"><title>\(name)</title>\n\(body)\n"
        let rel = "Notes/\(safe(name))-\(shortHash(name + body)).html"
        do { try await uploadData(Data(html.utf8), to: rel); ok += 1 }
        catch { log("  note failed \(name): \(error)") }
    }
    log("NOTES: uploaded \(ok)/\(records.count) → Nextcloud Notes/")
}

Task {
    log("=== micloud power-build probe — Notes + Bookmarks → \(root.absoluteString) ===")
    log("home (unsandboxed ⇒ real): \(NSHomeDirectory())")
    await exportBookmarks()
    await exportNotes()
    log(">>> done. Verify Nextcloud Bookmarks/ and Notes/ folders.")
    exit(0)
}
RunLoop.main.run()
