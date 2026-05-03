import XCTest
import CryptoKit
@testable import Clip

final class CryptoBoxTests: XCTestCase {
    func makeBox() -> CryptoBox {
        CryptoBox(masterKey: Data(repeating: 0xAB, count: 32))
    }

    func testSealOpenRoundTrip() throws {
        let box = makeBox()
        let plain = Data("hello, world".utf8)
        let sealed = try box.seal(plain)
        XCTAssertEqual(try box.open(sealed), plain)
        XCTAssertGreaterThan(sealed.count, plain.count)
    }

    func testOpenWrongKeyFails() throws {
        let a = makeBox()
        let b = CryptoBox(masterKey: Data(repeating: 0xCD, count: 32))
        let sealed = try a.seal(Data("x".utf8))
        XCTAssertThrowsError(try b.open(sealed))
    }

    func testOpenTamperedFails() throws {
        let box = makeBox()
        var sealed = try box.seal(Data("hello".utf8))
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try box.open(sealed))
    }

    func testNonceUniqueness() throws {
        let box = makeBox()
        var nonces = Set<Data>()
        for _ in 0..<5000 {
            let sealed = try box.seal(Data("same".utf8))
            nonces.insert(sealed.prefix(12))
        }
        XCTAssertEqual(nonces.count, 5000)
    }

    func testNameDeterministic() {
        let box = makeBox()
        XCTAssertEqual(box.name(forContentHash: "abc"), box.name(forContentHash: "abc"))
        XCTAssertNotEqual(box.name(forContentHash: "abc"), box.name(forContentHash: "def"))
        XCTAssertEqual(box.name(forContentHash: "abc").count, 64)
    }

    func testDifferentMasterKeysProduceDifferentNames() {
        let a = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let b = CryptoBox(masterKey: Data(repeating: 0xBB, count: 32))
        XCTAssertNotEqual(a.name(forContentHash: "x"), b.name(forContentHash: "x"))
    }
}
