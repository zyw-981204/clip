import XCTest
@testable import Clip

final class SyncTypesTests: XCTestCase {
    func testSyncOpRawValueRoundTrip() {
        for op in SyncOp.allCases {
            XCTAssertEqual(SyncOp(rawValue: op.rawValue), op)
        }
    }

    func testCloudCursorZero() {
        let c = CloudCursor.zero
        XCTAssertEqual(c.serialized, "0:")
        XCTAssertEqual(c.updatedAt, 0)
        XCTAssertEqual(c.id, "")
    }

    func testCloudCursorSerializeRoundTrip() {
        let c = CloudCursor(updatedAt: 1735689600, id: "abc-123")
        XCTAssertEqual(c.serialized, "1735689600:abc-123")
        XCTAssertEqual(CloudCursor(serialized: c.serialized), c)
    }

    func testCloudCursorParseInvalidReturnsZero() {
        XCTAssertEqual(CloudCursor(serialized: "garbage"), CloudCursor.zero)
        XCTAssertEqual(CloudCursor(serialized: ""), CloudCursor.zero)
    }

    func testCloudKeyHelpers() {
        XCTAssertEqual(CloudKey.blobKey(name: "abc"), "blobs/abc.bin")
        XCTAssertEqual(CloudKey.blobsPrefix, "blobs/")
    }

    func testCloudRowEquality() {
        let a = CloudRow(id: "1", hmac: "h", ciphertext: Data([0x01]),
                         kind: "text", blobKey: nil, byteSize: 1,
                         deviceID: "D", createdAt: 0, updatedAt: 0, deleted: false)
        var b = a
        XCTAssertEqual(a, b)
        b.deleted = true
        XCTAssertNotEqual(a, b)
    }
}
