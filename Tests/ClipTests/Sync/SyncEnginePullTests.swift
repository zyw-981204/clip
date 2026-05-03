import XCTest
@testable import Clip

final class SyncEnginePullTests: XCTestCase {
    /// A and B share one DataSource + one BlobStore + one master_key.
    /// A push → B pull → B sees the same content_hash.
    func makePair() throws -> (HistoryStore, SyncEngine, HistoryStore, SyncEngine) {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blobs = LocalDirBlobStore(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 7, count: 32))
        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "A",
                                 state: SyncStateStore(store: storeA))
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "B",
                                 state: SyncStateStore(store: storeB))
        return (storeA, engineA, storeB, engineB)
    }

    func testTextEndToEnd() async throws {
        let (storeA, engineA, storeB, engineB) = try makePair()
        let id = try storeA.insert(ClipItem(
            id: nil, content: "shared!", contentHash: ClipItem.contentHash(of: "shared!"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 7, truncated: false))
        try await engineA.enqueueClipPush(itemID: id, at: 100)
        _ = try await engineA.pushOnce(now: 200)

        try await engineB.pullOnce(now: 300)
        let contents = try storeB.listRecent().map(\.content)
        XCTAssertEqual(contents, ["shared!"])
    }

    func testPullSkipsAlreadyKnownEtagViaLWWAdvancesCursor() async throws {
        let (storeA, engineA, storeB, engineB) = try makePair()
        let id = try storeA.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try await engineA.enqueueClipPush(itemID: id, at: 1)
        _ = try await engineA.pushOnce(now: 1)

        try await engineB.pullOnce(now: 2)
        let count1 = try storeB.listRecent().count
        XCTAssertEqual(count1, 1)
        // Second pull: cursor must have advanced past that row.
        let cursor1 = try SyncStateStore(store: storeB).get("cloud_pull_cursor")
        try await engineB.pullOnce(now: 3)
        let cursor2 = try SyncStateStore(store: storeB).get("cloud_pull_cursor")
        XCTAssertEqual(cursor1, cursor2, "cursor stable when no new rows")
        let count2 = try storeB.listRecent().count
        XCTAssertEqual(count2, 1, "no duplicate inserts")
    }

    func testTombstonePropagatesAndDeletesLocal() async throws {
        let (storeA, engineA, storeB, engineB) = try makePair()
        let hash = ClipItem.contentHash(of: "doomed")
        let id = try storeA.insert(ClipItem(
            id: nil, content: "doomed", contentHash: hash,
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 6, truncated: false))
        try await engineA.enqueueClipPush(itemID: id, at: 100)
        _ = try await engineA.pushOnce(now: 100)
        try await engineB.pullOnce(now: 200)
        let preCount = try storeB.listRecent().count
        XCTAssertEqual(preCount, 1)

        // A deletes
        let cloudID = try storeA.itemByID(id)!.cloudID!
        try storeA.delete(id: id)
        // Manually mark D1 row deleted (excludeItem path, T21, will wrap this)
        let ds = await ds_(engineA: engineA)
        _ = try await ds.setClipDeleted(id: cloudID)

        // B pulls → row gone + tombstone written
        try await engineB.pullOnce(now: 300)
        let postCount = try storeB.listRecent().count
        XCTAssertEqual(postCount, 0)
        let tomb = try storeB.tombstoneAt(contentHash: hash)
        XCTAssertNotNil(tomb)
    }

    private func ds_(engineA: SyncEngine) async -> CloudSyncDataSource {
        await engineA.dataSourceForTesting
    }
}
