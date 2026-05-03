import XCTest
@testable import Clip

final class SyncEngineLazyBlobTests: XCTestCase {
    private func makeDataSource() throws -> LocalSqliteDataSource {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        return ds
    }

    func testFetchBlobDecryptsAndFillsLocalRow() async throws {
        let ds = try makeDataSource()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blobs = LocalDirBlobStore(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xEE, count: 32))
        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "A",
                                 state: SyncStateStore(store: storeA))
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "B",
                                 state: SyncStateStore(store: storeB))

        // A inserts and pushes
        let bytes = Data(repeating: 0x42, count: 1024)
        let aID = try storeA.insertImage(
            bytes: bytes, mimeType: "image/png",
            sourceBundleID: nil, sourceAppName: nil, now: 100)
        guard let aBlobID = try storeA.itemByID(aID)?.blobID else { XCTFail(); return }
        try await engineA.enqueueClipPush(itemID: aID, at: 100)
        try await engineA.enqueueBlobPush(blobID: aBlobID, at: 100)
        _ = try await engineA.pushOnce(now: 100)
        _ = try await engineA.pushOnce(now: 101)

        // B pulls — has lazy ref
        try await engineB.pullOnce(now: 200)
        guard let bItem = try storeB.listRecent().first else { XCTFail(); return }
        guard let bBlobID = bItem.blobID else { XCTFail(); return }
        let beforeBytes = (try storeB.blob(id: bBlobID)) ?? Data()
        XCTAssertTrue(beforeBytes.isEmpty, "lazy row starts empty")

        // B fetches: hits backend, decrypts, fills local
        let got = try await engineB.fetchBlob(blobID: bBlobID)
        XCTAssertEqual(got, bytes)
        let after = try storeB.blob(id: bBlobID)
        XCTAssertEqual(after, bytes, "row now filled")
    }
}
