import Foundation
import CryptoKit

/// The user's sovereign encryption key — sealed data **on-device** before it ever reaches Nextcloud/Immich,
/// so even a hosting micloud only ever holds ciphertext. Backed up as a **BIP39 recovery phrase** (the same
/// "write down your words" model a Bitcoin wallet uses): the phrase *is* the key; micloud stores it nowhere
/// and cannot reset it. Portable (CryptoKit + Foundation) → Mac + iOS.
///
/// **128-bit** entropy → a **12-word** phrase (128 entropy bits + 4 checksum bits = 132 = 12 × 11). 128-bit
/// is already computationally unbreakable — it's the Bitcoin-wallet default — and halves the writing burden
/// vs 24 words. The 16-byte seed is stretched to the 32-byte AES-256 key via **HKDF-SHA256** (so we still get
/// a full-width AES key; the seed is just the recoverable secret). Not an HD wallet — a recoverable symmetric key.
public struct SovereignKey: Sendable, Equatable {
    public let entropy: Data                       // 16 bytes = the 128-bit recoverable seed
    private static let hkdfInfo = Data("micloud/aes-256-gcm/v1".utf8)
    private var symmetric: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: entropy),
                               info: Self.hkdfInfo, outputByteCount: 32)
    }

    public init?(entropy: Data) { guard entropy.count == 16 else { return nil }; self.entropy = entropy }

    /// Fresh key from the system CSPRNG (CryptoKit's secure generator).
    public static func generate() -> SovereignKey {
        SovereignKey(entropy: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })!
    }

    /// Master fingerprint — the first 4 bytes of SHA-256(entropy), lowercase hex (8 chars). Stable per key,
    /// reveals nothing about it. Used to name a hosted trial (`mic<fingerprint>.getmicloud.com`).
    public var fingerprint: String {
        Data(SHA256.hash(data: entropy)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    // ── BIP39 recovery phrase (12 words) ──────────────────────────────────────
    /// The 12-word phrase to write down. 128 entropy bits + 4 checksum bits, 11 bits per word.
    public var recoveryPhrase: [String] {
        var bits = entropy.flatMap(Self.bits)                              // 128
        let cs = Data(SHA256.hash(data: entropy)).first!                   // first byte of the hash
        bits.append(contentsOf: Self.bits(cs).prefix(4))                   // +4 checksum → 132
        return stride(from: 0, to: bits.count, by: 11).map { i in
            bip39Words[bits[i..<i+11].reduce(0) { ($0 << 1) | Int($1) }]
        }
    }

    /// Recover a key from its phrase; nil if any word is unknown or the checksum fails.
    public init?(recoveryPhrase words: [String]) {
        guard words.count == 12 else { return nil }
        var bits: [UInt8] = []
        for w in words {
            guard let idx = Self.wordIndex[w.lowercased()] else { return nil }
            for shift in stride(from: 10, through: 0, by: -1) { bits.append(UInt8((idx >> shift) & 1)) }
        }
        var ent = Data()
        for i in stride(from: 0, to: 128, by: 8) { ent.append(bits[i..<i+8].reduce(0) { ($0 << 1) | $1 }) }
        let expected = Array(Self.bits(Data(SHA256.hash(data: ent)).first!).prefix(4))
        guard expected == Array(bits.suffix(4)) else { return nil }        // checksum
        self.entropy = ent
    }

    // ── seal / open (AES-256-GCM: confidentiality + integrity) ────────────────
    /// Encrypt `plaintext` → self-contained ciphertext (nonce + ciphertext + tag). Safe to upload.
    public func seal(_ plaintext: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: symmetric).combined else {
            throw SovereignKeyError.seal
        }
        return combined
    }
    /// Decrypt what `seal` produced; throws if tampered or the key is wrong.
    public func open(_ ciphertext: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: symmetric)
    }

    /// The BIP39 English list (public data) — lets a test build a phrase with a known-bad checksum.
    public static var wordlist: [String] { bip39Words }

    // ── helpers ───────────────────────────────────────────────────────────────
    private static func bits(_ b: UInt8) -> [UInt8] { (0..<8).map { (b >> (7 - $0)) & 1 } }
    private static let wordIndex: [String: Int] =
        Dictionary(uniqueKeysWithValues: bip39Words.enumerated().map { ($1, $0) })
}

public enum SovereignKeyError: Error { case seal }
