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
}
