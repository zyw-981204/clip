import XCTest
@testable import Clip

final class LocalSqliteDataSourceTests: XCTestCase {
    func makeDS() throws -> LocalSqliteDataSource {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter()
        Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        return ds
    }

    func testUpsertThenQueryByHmac() async throws {
        let ds = try makeDS()
        let row = CloudRow(id: "id1", hmac: "hmac1", ciphertext: Data([0xAA]),
                           kind: "text", blobKey: nil, byteSize: 5,
                           deviceID: "DEV", createdAt: 100, updatedAt: 0,
                           deleted: false)
        let updatedAt = try await ds.upsertClip(row)
        XCTAssertGreaterThan(updatedAt, 0, "server bumped updated_at")
        let found = try await ds.queryClipByHmac("hmac1")
        XCTAssertEqual(found?.id, "id1")
        XCTAssertEqual(found?.deleted, false)
    }

    func testQueryByHmacReturnsDeleted() async throws {
        let ds = try makeDS()
        let row = CloudRow(id: "x", hmac: "h", ciphertext: Data([0x01]),
                           kind: "text", blobKey: nil, byteSize: 1,
                           deviceID: "D", createdAt: 1, updatedAt: 0, deleted: false)
        _ = try await ds.upsertClip(row)
        _ = try await ds.setClipDeleted(id: "x")
        let found = try await ds.queryClipByHmac("h")
        XCTAssertEqual(found?.id, "x")
        XCTAssertEqual(found?.deleted, true, "deleted rows must be returned (fix B)")
    }

    func testQueryClipsChangedSinceCompositeCursor() async throws {
        let ds = try makeDS()
        // Manually insert two rows with the same updated_at (impossible via
        // upsert which uses unixepoch(); use a direct call for the test).
        try ds.testDirectInsert(
            CloudRow(id: "a", hmac: "ha", ciphertext: Data(), kind: "text",
                     blobKey: nil, byteSize: 0, deviceID: "D",
                     createdAt: 0, updatedAt: 100, deleted: false))
        try ds.testDirectInsert(
            CloudRow(id: "b", hmac: "hb", ciphertext: Data(), kind: "text",
                     blobKey: nil, byteSize: 0, deviceID: "D",
                     createdAt: 0, updatedAt: 100, deleted: false))
        // Cursor at (100, "a") should pick up only "b" — not "a" again.
        let rows = try await ds.queryClipsChangedSince(
            cursor: CloudCursor(updatedAt: 100, id: "a"), limit: 100)
        XCTAssertEqual(rows.map(\.id), ["b"])
    }

    func testPutConfigIfAbsentRaceSemantics() async throws {
        let ds = try makeDS()
        let won1 = try await ds.putConfigIfAbsent(key: "k", value: "v1")
        let won2 = try await ds.putConfigIfAbsent(key: "k", value: "v2")
        XCTAssertTrue(won1)
        XCTAssertFalse(won2)
        let stored = try await ds.getConfig(key: "k")
        XCTAssertEqual(stored, "v1")
    }
}
