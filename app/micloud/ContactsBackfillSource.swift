import Foundation
import Contacts

/// `BackfillSource` for Contacts: enumerate every contact, serialise each to a `.vcf` (vCard, via Apple's
/// `CNContactVCardSerialization`), and upload to a Nextcloud folder. Per-contact, so progress / quarantine /
/// resume all work at contact granularity.
final class ContactsBackfillSource: BackfillSource, @unchecked Sendable {
    let id: SourceID = .contacts
    private let store: CNContactStore
    private let dav: NextcloudWebDAV
    private let folder: String
    private let lock = NSLock()
    private var content: [String: Data] = [:]

    init(store: CNContactStore, dav: NextcloudWebDAV, folder: String) {
        self.store = store; self.dav = dav; self.folder = folder
    }

    func enumerateItems() async throws -> [BackfillEntry] {
        var entries: [BackfillEntry] = []
        var cache: [String: Data] = [:]
        let req = CNContactFetchRequest(keysToFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()])
        try store.enumerateContacts(with: req) { contact, _ in
            guard let data = try? CNContactVCardSerialization.data(with: [contact]) else { return }
            cache[contact.identifier] = data
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "contact"
            entries.append(BackfillEntry(key: contact.identifier,
                                         relativePath: "\(self.safe(name))-\(self.shortHash(contact.identifier)).vcf",
                                         bytes: Int64(data.count), contentHash: stableHash(data)))
        }
        lock.lock(); content = cache; lock.unlock()
        return entries
    }

    func process(_ entry: BackfillEntry) async throws {
        lock.lock(); let data = content[entry.key]; lock.unlock()
        guard let data else { throw NSError(domain: "micloud.contacts", code: 1, userInfo: [NSLocalizedDescriptionKey: "no cached contact"]) }
        // Land the vCard in the CardDAV addressbook (`folder` = addressbook name, e.g. "contacts")
        // → it shows up as a real, editable contact in the Nextcloud Contacts app.
        try await dav.putContact(addressbook: folder, filename: entry.relativePath, vcard: data)
    }

    func capacityTargets() -> [BackfillTarget] { [dav] }

    private func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let cleaned = String(s.unicodeScalars.filter { !bad.contains($0) }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "contact" : String(cleaned.prefix(60))
    }
    private func shortHash(_ s: String) -> String { String(format: "%08x", UInt32(truncatingIfNeeded: s.hashValue)) }
}
