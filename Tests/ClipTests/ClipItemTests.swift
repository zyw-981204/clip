import XCTest
@testable import Clip

final class ClipItemTests: XCTestCase {
    func testByteSizeUTF8() {
        XCTAssertEqual(ClipItem.byteSize(of: ""), 0)
        XCTAssertEqual(ClipItem.byteSize(of: "abc"), 3)
        XCTAssertEqual(ClipItem.byteSize(of: "你好"), 6)     // 2 CJK × 3 bytes
        XCTAssertEqual(ClipItem.byteSize(of: "😀"), 4)       // 1 emoji × 4 bytes
        XCTAssertEqual(ClipItem.byteSize(of: "a你😀"), 1 + 3 + 4)
    }

    func testTruncateNoOpUnderLimit() {
        let (out, t) = ClipItem.truncateIfNeeded("hello", limit: 256 * 1024)
        XCTAssertEqual(out, "hello")
        XCTAssertFalse(t)
    }

    func testTruncateAt256KBOnASCII() {
        let s = String(repeating: "a", count: 300_000)
        let (out, t) = ClipItem.truncateIfNeeded(s, limit: 256 * 1024)
        XCTAssertTrue(t)
        XCTAssertEqual(out.utf8.count, 256 * 1024)
    }

    func testTruncateRespectsUTF8Boundary() {
        // "你" is 3 bytes; cut limit mid-codepoint must back up to a boundary.
        let s = String(repeating: "你", count: 10) // 30 bytes
        let (out, t) = ClipItem.truncateIfNeeded(s, limit: 8) // mid-codepoint
        XCTAssertTrue(t)
        // Should back up to 6 bytes (2 full CJK chars), never split a codepoint.
        XCTAssertEqual(out.utf8.count, 6)
        XCTAssertEqual(out, "你你")
    }

    func testHashIsHex64Chars() {
        let h = ClipItem.contentHash(of: "hi")
        XCTAssertEqual(h.count, 64)
        XCTAssertTrue(h.allSatisfy { $0.isHexDigit })
    }

    func testHashTrimsLeadingTrailingWhitespace() {
        XCTAssertEqual(
            ClipItem.contentHash(of: "  hi  \n"),
            ClipItem.contentHash(of: "hi")
        )
    }

    func testHashDifferentForDifferentContent() {
        XCTAssertNotEqual(
            ClipItem.contentHash(of: "hello"),
            ClipItem.contentHash(of: "world")
        )
    }
}
