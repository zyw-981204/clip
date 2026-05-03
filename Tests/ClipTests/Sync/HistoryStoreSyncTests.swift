import XCTest
@testable import Clip

/// Sendable mutable container so the `@Sendable` onChange closure can capture
/// it by reference without tripping Swift 6 closure-capture checks.
final class ChangeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HistoryStoreChange] = []
    func append(_ c: HistoryStoreChange) {
        lock.lock(); defer { lock.unlock() }
        items.append(c)
    }
    func snapshot() -> [HistoryStoreChange] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

final class HistoryStoreSyncTests: XCTestCase {
    func mkItem(_ s: String, at: Int64 = 1) -> ClipItem {
        ClipItem(id: nil, content: s, contentHash: ClipItem.contentHash(of: s),
                 sourceBundleID: nil, sourceAppName: nil, createdAt: at,
                 pinned: false, byteSize: s.utf8.count, truncated: false)
    }

    func testNewItemDefaultsAreUnsynced() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(mkItem("x"))
        let item = try XCTUnwrap(try s.itemByID(id))
        XCTAssertEqual(item.syncExcluded, false)
        XCTAssertNil(item.cloudID)
        XCTAssertNil(item.cloudUpdatedAt)
        XCTAssertNil(item.cloudSyncedAt)
        XCTAssertNil(item.cloudBlobKey)
        XCTAssertNil(item.deviceID)
    }

    func testMarkClipSyncedWritesCloudFields() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(mkItem("y"))
        try s.markClipSynced(id: id, cloudID: "uuid-123", updatedAt: 99, at: 100)
        let item = try XCTUnwrap(try s.itemByID(id))
        XCTAssertEqual(item.cloudID, "uuid-123")
        XCTAssertEqual(item.cloudUpdatedAt, 99)
        XCTAssertEqual(item.cloudSyncedAt, 100)
    }

    func testItemByCloudID() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(mkItem("z"))
        try s.markClipSynced(id: id, cloudID: "abc", updatedAt: 1, at: 2)
        let found = try XCTUnwrap(try s.itemByCloudID("abc"))
        XCTAssertEqual(found.id, id)
        XCTAssertNil(try s.itemByCloudID("missing"))
    }

    func testSetSyncExcludedToggles() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(mkItem("a"))
        try s.setSyncExcluded(id: id, excluded: true)
        XCTAssertEqual(try s.itemByID(id)?.syncExcluded, true)
        try s.setSyncExcluded(id: id, excluded: false)
        XCTAssertEqual(try s.itemByID(id)?.syncExcluded, false)
    }

    func testOnChangeFiresOnInsertAndDelete() throws {
        let s = try HistoryStore.inMemory()
        let collector = ChangeCollector()
        s.onChange = { collector.append($0) }
        let id = try s.insert(mkItem("c"))
        try s.delete(id: id)
        let calls = collector.snapshot()
        XCTAssertEqual(calls.count, 2)
        if case .inserted = calls[0] {} else { XCTFail() }
        if case .deleted = calls[1] {} else { XCTFail() }
    }

    func testTombstoneRoundTrip() throws {
        let s = try HistoryStore.inMemory()
        try s.upsertTombstone(contentHash: "h", cloudID: "id1",
                              tombstonedAt: 100, cloudUpdatedAt: 100)
        XCTAssertEqual(try s.tombstoneAt(contentHash: "h"), 100)
        try s.upsertTombstone(contentHash: "h", cloudID: "id1",
                              tombstonedAt: 200, cloudUpdatedAt: 200)
        XCTAssertEqual(try s.tombstoneAt(contentHash: "h"), 200)
    }

    func testLazyBlobInsertAndFill() throws {
        let s = try HistoryStore.inMemory()
        let blobID = try s.insertLazyBlob(blobHmac: "hash1", byteSize: 1024, now: 1)
        let lazy = try XCTUnwrap(try s.lazyBlobHmac(id: blobID))
        XCTAssertEqual(lazy.hmac, "hash1")
        XCTAssertEqual(lazy.byteSize, 1024)
        let bytes = Data(repeating: 0xFF, count: 1024)
        try s.fillBlob(id: blobID, bytes: bytes, sha256: "real-sha", at: 2)
        XCTAssertEqual(try s.blob(id: blobID), bytes)
        XCTAssertNil(try s.lazyBlobHmac(id: blobID))
    }
}
