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
}
