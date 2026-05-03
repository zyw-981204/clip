import XCTest
@testable import Clip

final class KeyDerivationTests: XCTestCase {
    func testKnownVector() {
        // PBKDF2-HMAC-SHA256(password="password", salt="salt", iters=1, dkLen=32).
        // Pinned via Python hashlib.
        let key = KeyDerivation.pbkdf2_sha256(
            password: "password", salt: Data("salt".utf8),
            iterations: 1, keyLength: 32)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testDifferentPasswordYieldsDifferentKey() {
        let salt = Data("salt".utf8)
        let a = KeyDerivation.pbkdf2_sha256(password: "a", salt: salt, iterations: 1000, keyLength: 32)
        let b = KeyDerivation.pbkdf2_sha256(password: "b", salt: salt, iterations: 1000, keyLength: 32)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentSaltYieldsDifferentKey() {
        let a = KeyDerivation.pbkdf2_sha256(password: "x", salt: Data("s1".utf8), iterations: 1000, keyLength: 32)
        let b = KeyDerivation.pbkdf2_sha256(password: "x", salt: Data("s2".utf8), iterations: 1000, keyLength: 32)
        XCTAssertNotEqual(a, b)
    }

    func testCustomKeyLength() {
        let k = KeyDerivation.pbkdf2_sha256(password: "x", salt: Data("s".utf8), iterations: 100, keyLength: 16)
        XCTAssertEqual(k.count, 16)
    }
}
