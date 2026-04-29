import XCTest
import AppKit
@testable import Clip

final class PrivacyFilterTests: XCTestCase {
    func testAcceptsPlainTextWithNoMarkers() {
        let f = PrivacyFilter()
        let reason = f.reasonToSkip(
            types: [.string],
            content: "hello world",
            sourceBundleID: "com.apple.Safari",
            blacklist: []
        )
        XCTAssertNil(reason)
    }

    func testInternalPasteUTIIsSkipped() {
        let f = PrivacyFilter()
        let reason = f.reasonToSkip(
            types: [.string, PrivacyFilter.internalUTI],
            content: "anything",
            sourceBundleID: "com.zyw.clip",
            blacklist: []
        )
        XCTAssertEqual(reason, "internal-paste")
    }
}
