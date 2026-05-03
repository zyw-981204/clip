import XCTest
@testable import Clip

final class LocalDirBlobStoreTests: XCTestCase {
    var dir: URL!
    var store: LocalDirBlobStore!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LocalDirBlobStore(root: dir)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testPutGetRoundTrip() async throws {
        let body = Data("hello".utf8)
        try await store.putBlob(key: "blobs/abc.bin", body: body)
        let got = try await store.getBlob(key: "blobs/abc.bin")
        XCTAssertEqual(got, body)
    }

    func testGetMissingReturnsNil() async throws {
        let got = try await store.getBlob(key: "nope.bin")
        XCTAssertNil(got)
    }

    func testDeleteIdempotent() async throws {
        try await store.putBlob(key: "k.bin", body: Data([0x01]))
        try await store.deleteBlob(key: "k.bin")
        try await store.deleteBlob(key: "k.bin")  // again, must not throw
        let got = try await store.getBlob(key: "k.bin")
        XCTAssertNil(got)
    }
}
