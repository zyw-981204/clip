import XCTest
@testable import Clip

final class SyncEngineExcludeTests: XCTestCase {
    func makePair() throws -> (HistoryStore, SyncEngine, LocalSqliteDataSource) {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try HistoryStore.inMemory()
        let engine = SyncEngine(
            store: store, dataSource: ds,
            blobStore: LocalDirBlobStore(root: dir),
            crypto: CryptoBox(masterKey: Data(repeating: 0xCC, count: 32)),
            deviceID: "DEV", state: SyncStateStore(store: store))
        return (store, engine, ds)
    }

    func testExcludeSyncedItemDeletesQueueAndMarksRemote() async throws {
        let (store, engine, ds) = try makePair()
        let id = try store.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 1, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 100)
        _ = try await engine.pushOnce(now: 100)

        // Verify D1 has it (deleted=0)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xCC, count: 32))
        let hmac = crypto.name(forContentHash: ClipItem.contentHash(of: "x"))
        let preDel = try await ds.queryClipByHmac(hmac)
        XCTAssertEqual(preDel?.deleted, false)

        try await engine.excludeItem(id: id, at: 200)

        // Local: sync_excluded set + tombstone written
        XCTAssertEqual(try store.itemByID(id)?.syncExcluded, true)
        XCTAssertNotNil(try store.tombstoneAt(contentHash: ClipItem.contentHash(of: "x")))
        // Local sync_queue: no put_clip; one put_tomb (drained next pushOnce)
        let q = try SyncQueue(store: store).peekAll()
        XCTAssertEqual(q.filter { $0.op == .putClip }.count, 0)
        XCTAssertEqual(q.filter { $0.op == .putTomb }.count, 1)

        // Drain the tomb push → D1 row.deleted = 1
        _ = try await engine.pushOnce(now: 300)
        let postDel = try await ds.queryClipByHmac(hmac)
        XCTAssertEqual(postDel?.deleted, true)
    }

    func testExcludeUnsyncedItemOnlyClearsQueue() async throws {
        let (store, engine, _) = try makePair()
        let id = try store.insert(ClipItem(
            id: nil, content: "y", contentHash: ClipItem.contentHash(of: "y"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 1, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 100)

        try await engine.excludeItem(id: id, at: 200)

        XCTAssertEqual(try store.itemByID(id)?.syncExcluded, true)
        XCTAssertEqual(try SyncQueue(store: store).peekAll().count, 0,
                       "no put_tomb (never reached cloud) + put_clip cleared")
    }
}
