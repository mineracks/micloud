import Foundation
import Network

/// Demo bridge for the **Mail** lane. The sovereign mail store is a dovecot maildir (the same one Nextcloud Mail
/// reads); micloud carries mail into it by **IMAP APPEND**. The orchestrator drops the raw RFC822 message the
/// visitor just received/sent in Apple Mail as an `.eml` in `MICLOUD_MAIL_BRIDGE_DIR`, and this appends it to the
/// INBOX over a plain-IMAP connection (dovecot here is `ssl = no`, LAN-only), through the normal `BackfillEngine`
/// so the Mail badge / activity graph / live log react for real and it shows up in Nextcloud Mail. `nil` in
/// production (env unset). Idempotent: each file uploads once (ledger content-hash).
final class MailBridgeSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .mail
    private let dir: String
    private let host: String
    private let port: UInt16
    private let user: String
    private let pass: String
    private let mailbox: String
    private let capacity: BackfillTarget

    struct MailError: Error { let msg: String }

    init(dir: String, host: String, port: UInt16, user: String, pass: String, mailbox: String,
         capacity: BackfillTarget) {
        self.dir = dir; self.host = host; self.port = port; self.user = user; self.pass = pass
        self.mailbox = mailbox; self.capacity = capacity
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        var out: [BackfillEntry] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            guard name.lowercased().hasSuffix(".eml") else { continue }
            let path = (dir as NSString).appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            out.append(BackfillEntry(key: "mailbridge:\(name)", relativePath: name, bytes: size,
                                     contentHash: "\(size)-\(Int(mtime))"))
        }
        return out
    }

    func process(_ entry: BackfillEntry) async throws {
        let path = (dir as NSString).appendingPathComponent(entry.relativePath)
        var raw = try Data(contentsOf: URL(fileURLWithPath: path))
        // IMAP APPEND wants CRLF line endings.
        if !raw.contains(0x0D) { raw = normalizeCRLF(raw) }
        try await appendIMAP(raw)
    }

    func capacityTargets() -> [BackfillTarget] { [capacity] }

    private func normalizeCRLF(_ d: Data) -> Data {
        var out = Data(); out.reserveCapacity(d.count + d.count / 20)
        for b in d { if b == 0x0A { out.append(0x0D) }; out.append(b) }
        return out
    }

    /// Minimal plain-IMAP APPEND: greeting → LOGIN → APPEND INBOX {n} literal → LOGOUT. Strict request/response
    /// (we wait for each tagged reply before the next command), so a per-command buffer reset is safe.
    private func appendIMAP(_ message: Data) async throws {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? 143, using: .tcp)
        let q = DispatchQueue(label: "micloud.imap")
        defer { conn.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: if !resumed { resumed = true; c.resume() }
                case .failed(let e): if !resumed { resumed = true; c.resume(throwing: e) }
                case .cancelled: if !resumed { resumed = true; c.resume(throwing: MailError(msg: "cancelled")) }
                default: break
                }
            }
            conn.start(queue: q)
        }

        func send(_ d: Data) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                conn.send(content: d, completion: .contentProcessed { e in
                    if let e = e { c.resume(throwing: e) } else { c.resume() }
                })
            }
        }
        func send(_ s: String) async throws { try await send(Data(s.utf8)) }
        func recv() async throws -> Data {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, err in
                    if let err = err { c.resume(throwing: err) } else { c.resume(returning: data ?? Data()) }
                }
            }
        }
        func waitFor(_ needle: String) async throws {
            var buf = ""
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if buf.contains(needle) { return }
                if buf.contains(" NO ") || buf.contains(" BAD ") { throw MailError(msg: buf) }
                let chunk = try await recv()
                if chunk.isEmpty { throw MailError(msg: "connection closed") }
                buf += String(decoding: chunk, as: UTF8.self)
            }
            throw MailError(msg: "timeout waiting for \(needle)")
        }

        try await waitFor("OK")                                   // * OK … Dovecot ready.
        try await send("a1 LOGIN \"\(user)\" \"\(pass)\"\r\n")
        try await waitFor("a1 OK")
        try await send("a2 APPEND \(mailbox) {\(message.count)}\r\n")
        try await waitFor("+")                                    // continuation request
        try await send(message)
        try await send("\r\n")
        try await waitFor("a2 OK")
        try? await send("a3 LOGOUT\r\n")
    }
}
