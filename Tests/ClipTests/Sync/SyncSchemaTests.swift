import XCTest
@testable import Clip

final class SyncSchemaTests: XCTestCase {
    func testRowPayloadTextRoundTrip() throws {
        let p = RowPayload(
            v: 1, content: "hello", thumbB64: nil, mimeType: nil, blobSize: nil,
            truncated: false, sourceBundleId: "com.apple.Safari", sourceAppName: "Safari",
            pinned: false, contentHash: "abc")
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(RowPayload.self, from: data), p)
    }

    func testRowPayloadImageRoundTrip() throws {
        let p = RowPayload(
            v: 1, content: nil, thumbB64: "AAAA", mimeType: "image/png",
            blobSize: 12345, truncated: false, sourceBundleId: nil, sourceAppName: nil,
            pinned: true, contentHash: "def")
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(RowPayload.self, from: data), p)
    }

    func testDevicePayloadRoundTrip() throws {
        let d = DevicePayload(v: 1, displayName: "Mac-Mini-7", model: "Mac15,12",
                              firstSeenAt: 1)
        let back = try JSONDecoder().decode(DevicePayload.self,
                                            from: try JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
    }
}
