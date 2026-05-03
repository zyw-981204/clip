import XCTest
@testable import Clip

final class SyncEnginePushTests: XCTestCase {
    func makePair() throws -> (HistoryStore, SyncEngine, LocalSqliteDataSource, LocalDirBlobStore) {
        let store = try HistoryStore.inMemory()
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blobs = LocalDirBlobStore(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let state = SyncStateStore(store: store)
        let engine = SyncEngine(store: store, dataSource: ds, blobStore: blobs,
                                crypto: crypto, deviceID: "DEV", state: state)
        return (store, engine, ds, blobs)
    }

    func testPushTextRoundTripsToD1() async throws {
        let (store, engine, ds, _) = try makePair()
        let id = try store.insert(ClipItem(
            id: nil, content: "hello", contentHash: ClipItem.contentHash(of: "hello"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 5, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 100)
        let did = try await engine.pushOnce(now: 200)
        XCTAssertTrue(did)

        // Item now marked synced
        guard let item = try store.itemByID(id) else {
            XCTFail("item missing"); return
        }
        XCTAssertNotNil(item.cloudID)
        XCTAssertNotNil(item.cloudUpdatedAt)

        // D1 has the row
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let hmac = crypto.name(forContentHash: item.contentHash)
        let found = try await ds.queryClipByHmac(hmac)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.deleted, false)
    }

    func testPushImageDoesR2ThenD1() async throws {
        let (store, engine, ds, blobs) = try makePair()
        let bytes = Data(repeating: 0xFF, count: 1024)
        let id = try store.insertImage(
            bytes: bytes, mimeType: "image/png",
            sourceBundleID: nil, sourceAppName: nil, now: 100)
        try await engine.enqueueClipPush(itemID: id, at: 100)
        guard let blobID = try store.itemByID(id)?.blobID else {
            XCTFail("blobID missing"); return
        }
        try await engine.enqueueBlobPush(blobID: blobID, at: 100)

        // Two queue rows: drain both
        _ = try await engine.pushOnce(now: 200)
        _ = try await engine.pushOnce(now: 201)

        guard let item = try store.itemByID(id) else {
            XCTFail("item missing"); return
        }
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let blobHmac = crypto.name(forContentHash: item.contentHash)
        // R2 has the encrypted blob
        let blob = try await blobs.getBlob(key: "blobs/\(blobHmac).bin")
        XCTAssertNotNil(blob)
        // D1 has the row with blob_key
        let row = try await ds.queryClipByHmac(crypto.name(forContentHash: item.contentHash))
        XCTAssertNotNil(row)
    }

    func testHmacDedupReusesCloudIDIncludingDeleted() async throws {
        // Prime: existing D1 row with hmac H, deleted=1
        let (store, engine, ds, _) = try makePair()
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let hash = ClipItem.contentHash(of: "foo")
        let hmac = crypto.name(forContentHash: hash)
        // Insert pre-existing tombstoned row directly into DS
        try ds.testDirectInsert(CloudRow(
            id: "EXISTING-CLOUD-ID",
            hmac: hmac, ciphertext: Data([0x00]),
            kind: "text", blobKey: nil, byteSize: 3,
            deviceID: "OTHER", createdAt: 50, updatedAt: 100, deleted: true))

        // Local capture of same content
        let id = try store.insert(ClipItem(
            id: nil, content: "foo", contentHash: hash,
            sourceBundleID: nil, sourceAppName: nil, createdAt: 200,
            pinned: false, byteSize: 3, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 200)
        _ = try await engine.pushOnce(now: 300)

        // Local row should now be synced with the EXISTING cloud_id (reused)
        guard let item = try store.itemByID(id) else {
            XCTFail("item missing"); return
        }
        XCTAssertEqual(item.cloudID, "EXISTING-CLOUD-ID")

        // D1 should have ONE row at hmac, deleted flipped to 0
        let row = try await ds.queryClipByHmac(hmac)
        XCTAssertEqual(row?.id, "EXISTING-CLOUD-ID")
        XCTAssertEqual(row?.deleted, false, "upsert revives deleted=1 → 0")
    }

    func testFailureAppliesBackoff() async throws {
        let store = try HistoryStore.inMemory()
        let ds = AlwaysFailDataSource()
        let blobs = AlwaysFailBlobStore()
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let engine = SyncEngine(store: store, dataSource: ds, blobStore: blobs,
                                crypto: crypto, deviceID: "DEV",
                                state: SyncStateStore(store: store))

        let id = try store.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 1, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 100)
        let attempted1 = try await engine.pushOnce(now: 200)
        XCTAssertTrue(attempted1)   // attempted, failed
        let attempted2 = try await engine.pushOnce(now: 201)
        XCTAssertFalse(attempted2)  // backed off
        let attempted3 = try await engine.pushOnce(now: 202)
        XCTAssertTrue(attempted3)   // due again
    }
}

// Stub that throws on every operation
final class AlwaysFailDataSource: CloudSyncDataSource, @unchecked Sendable {
    struct E: Error {}
    func ensureSchema() async throws { throw E() }
    func upsertClip(_ row: CloudRow) async throws -> Int64 { throw E() }
    func queryClipByHmac(_ hmac: String) async throws -> (id: String, deleted: Bool)? { throw E() }
    func queryClipsChangedSince(cursor: CloudCursor, limit: Int) async throws -> [CloudRow] { throw E() }
    func setClipDeleted(id: String) async throws -> Int64 { throw E() }
    func upsertDevice(_ row: DeviceRow) async throws { throw E() }
    func listDevices() async throws -> [DeviceRow] { throw E() }
    func getConfig(key: String) async throws -> String? { throw E() }
    func putConfigIfAbsent(key: String, value: String) async throws -> Bool { throw E() }
}

final class AlwaysFailBlobStore: CloudSyncBlobStore, @unchecked Sendable {
    struct E: Error {}
    func putBlob(key: String, body: Data) async throws { throw E() }
    func getBlob(key: String) async throws -> Data? { throw E() }
    func deleteBlob(key: String) async throws { throw E() }
}
