import XCTest
@testable import Clip

final class SyncSettingsTests: XCTestCase {
    var defaults: UserDefaults!
    var s: SyncSettings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        s = SyncSettings(defaults: defaults)
    }

    func testDefaultsAreEmpty() {
        XCTAssertFalse(s.enabled)
        XCTAssertNil(s.r2Endpoint)
        XCTAssertNil(s.r2Bucket)
        XCTAssertNil(s.r2AccessKeyID)
        XCTAssertNil(s.d1AccountID)
        XCTAssertNil(s.d1DatabaseID)
    }

    func testRoundTrip() {
        s.enabled = true
        s.r2Endpoint = "https://x.r2.cloudflarestorage.com"
        s.r2Bucket = "clip-sync"
        s.r2AccessKeyID = "AK"
        s.d1AccountID = "ACCT"
        s.d1DatabaseID = "DB-UUID"
        let s2 = SyncSettings(defaults: defaults)
        XCTAssertTrue(s2.enabled)
        XCTAssertEqual(s2.r2Endpoint, "https://x.r2.cloudflarestorage.com")
        XCTAssertEqual(s2.r2Bucket, "clip-sync")
        XCTAssertEqual(s2.r2AccessKeyID, "AK")
        XCTAssertEqual(s2.d1AccountID, "ACCT")
        XCTAssertEqual(s2.d1DatabaseID, "DB-UUID")
    }
}
