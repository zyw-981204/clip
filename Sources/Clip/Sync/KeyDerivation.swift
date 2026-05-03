import Foundation
import CommonCrypto

/// PBKDF2-HMAC-SHA256 wrapper. Spec §6.1 pins iters=200_000, dkLen=32 for
/// cloud master-key derivation. CryptoKit doesn't expose PBKDF2; CommonCrypto's
/// CCKeyDerivationPBKDF is the canonical Apple-platform implementation.
enum KeyDerivation {
    static func pbkdf2_sha256(
        password: String,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        let pwBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        var out = Data(count: keyLength)
        let status = out.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pwBytes, pwBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                outPtr.bindMemory(to: UInt8.self).baseAddress, keyLength
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 failed (status=\(status))")
        return out
    }
}
