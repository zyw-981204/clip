import XCTest
@testable import Clip

final class SyncEngineBackfillTests: XCTestCase {
    func makeEngine(_ store: HistoryStore) async throws -> SyncEngine {
        let ds = try LocalSqliteDataSource()
        try await ds.ensureSchema()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SyncEngine(store: store, dataSource: ds,
                          blobStore: LocalDirBlobStore(root: dir),
                          crypto: CryptoBox(masterKey: Data(repeating: 1, count: 32)),
                          deviceID: "DEV",
                          state: SyncStateStore(store: store))
    }

    func testBackfillEnqueuesNewestFirst() async throws {
        let store = try HistoryStore.inMemory()
        let engine = try await makeEngine(store)
        for (i, c) in ["old", "mid", "new"].enumerated() {
            try store.insert(ClipItem(
                id: nil, content: c, contentHash: ClipItem.contentHash(of: c),
                sourceBundleID: nil, sourceAppName: nil, createdAt: Int64(100 + i),
                pinned: false, byteSize: c.utf8.count, truncated: false))
        }
        try await engine.backfill(now: 1000)
        let q = SyncQueue(store: store)
        guard let r = try q.dequeueDueAt(now: 2000) else { XCTFail(); return }
        XCTAssertEqual(r.op, .putClip)
        guard let item = try store.itemByID(Int64(r.targetKey)!) else { XCTFail(); return }
        XCTAssertEqual(item.content, "new", "newest first")
    }

    func testBackfillSkipsExcluded() async throws {
        let store = try HistoryStore.inMemory()
        let engine = try await makeEngine(store)
        let id = try store.insert(ClipItem(
            id: nil, content: "secret", contentHash: ClipItem.contentHash(of: "secret"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 6, truncated: false))
        try store.setSyncExcluded(id: id, excluded: true)
        try await engine.backfill(now: 1000)
        XCTAssertEqual(try SyncQueue(store: store).peekAll().count, 0)
    }

    func testBackfillSkipsAlreadySyncedItems() async throws {
        let store = try HistoryStore.inMemory()
        let engine = try await makeEngine(store)
        let id = try store.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try store.markClipSynced(id: id, cloudID: "c", updatedAt: 1, at: 1)
        try await engine.backfill(now: 1000)
        XCTAssertEqual(try SyncQueue(store: store).peekAll().count, 0,
                       "synced items not re-enqueued")
    }
}
