import Foundation
import Security

/// Where the sovereign key and backend secrets physically live on this Mac/iPhone.
///
/// Production (signed) builds put everything in the **Keychain** (`Security.framework`), so the AES key and
/// the Nextcloud app-password are never on disk in the clear. Unsigned dev builds (swiftc + ad-hoc codesign)
/// can't always reach the Keychain, so we transparently fall back to a `0600` file under Application Support.
/// Callers don't care which path is used — `save`/`load` just work.
public enum SovereignStore {
    private static let service = "com.mineracks.micloud"
    private static let keyAccount = "sovereign-key"

    // ── the sovereign key ─────────────────────────────────────────────────────
    public static func save(_ key: SovereignKey) {
        if !keychainSet(keyAccount, key.entropy) { try? fileWrite(keyAccount, key.entropy) }
    }
    public static func loadKey() -> SovereignKey? {
        if let d = keychainGet(keyAccount), let k = SovereignKey(entropy: d) { return k }
        if let d = try? fileRead(keyAccount), let k = SovereignKey(entropy: d) { return k }
        return nil
    }
    public static var hasKey: Bool { loadKey() != nil }

    // ── arbitrary backend secrets (e.g. the Nextcloud app-password) ────────────
    public static func saveSecret(_ account: String, _ value: String) {
        let d = Data(value.utf8)
        if !keychainSet(account, d) { try? fileWrite(account, d) }
    }
    public static func secret(_ account: String) -> String? {
        if let d = keychainGet(account) { return String(data: d, encoding: .utf8) }
        if let d = try? fileRead(account) { return String(data: d, encoding: .utf8) }
        return nil
    }
    public static func deleteSecret(_ account: String) {
        keychainDelete(account); try? FileManager.default.removeItem(at: fileURL(account))
    }

    // ── Keychain (generic password items) ─────────────────────────────────────
    private static func keychainSet(_ account: String, _ data: Data) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    private static func keychainGet(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    private static func keychainDelete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }

    // ── file fallback (0600 under Application Support/micloud/secrets) ─────────
    private static func fileURL(_ account: String) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("micloud/secrets", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent(account)
    }
    private static func fileWrite(_ account: String, _ data: Data) throws {
        let url = fileURL(account)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func fileRead(_ account: String) throws -> Data { try Data(contentsOf: fileURL(account)) }
}
