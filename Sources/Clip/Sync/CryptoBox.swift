import Foundation
import CryptoKit

/// AEAD seal/open + content-hash → cloud filename mapping.
/// Spec §6.1: master_key HKDF-split into:
///   k_encrypt — ChaChaPoly seal/open of row payloads + blob bytes
///   k_name    — HMAC-SHA256(content_hash) → blob filename + cross-device dedup hmac
struct CryptoBox: Sendable {
    enum Error: Swift.Error, Equatable { case decryptionFailed }

    private let kEncrypt: SymmetricKey
    private let kName: SymmetricKey

    init(masterKey: Data) {
        precondition(masterKey.count == 32, "master key must be 32 bytes")
        let masterSym = SymmetricKey(data: masterKey)
        self.kEncrypt = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterSym,
            info: Data("clip.encrypt.v1".utf8),
            outputByteCount: 32)
        self.kName = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterSym,
            info: Data("clip.name.v1".utf8),
            outputByteCount: 32)
    }

    func seal(_ plaintext: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: kEncrypt).combined
    }

    func open(_ sealed: Data) throws -> Data {
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            return try ChaChaPoly.open(box, using: kEncrypt)
        } catch {
            throw Error.decryptionFailed
        }
    }

    /// Hex-encoded HMAC-SHA256(kName, content_hash). 64 chars. Used for both:
    ///   - the D1 `clips.hmac` indexed column (cross-device dedup)
    ///   - the R2 blob key suffix `blobs/<hmac>.bin`
    func name(forContentHash contentHash: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(contentHash.utf8), using: kName)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}
