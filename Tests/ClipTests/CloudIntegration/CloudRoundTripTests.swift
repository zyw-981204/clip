import XCTest
@testable import Clip

final class CloudRoundTripTests: XCTestCase {
    func env(_ k: String) -> String? {
        ProcessInfo.processInfo.environment[k].flatMap { $0.isEmpty ? nil : $0 }
    }

    func testFullPushPullAgainstRealCloud() async throws {
        guard let endpoint = env("R2_ENDPOINT").flatMap(URL.init),
              let bucket = env("R2_BUCKET"),
              let r2AK = env("R2_ACCESS_KEY_ID"),
              let r2Sec = env("R2_SECRET_ACCESS_KEY"),
              let acct = env("R2_ACCOUNT_ID"),
              let dbID = env("D1_DATABASE_ID"),
              let token = env("CLOUDFLARE_API_TOKEN")
        else { throw XCTSkip("cloud env not set; skipping integration") }

        let crypto = CryptoBox(masterKey: Data(repeating: UInt8.random(in: 0...255), count: 32))
        let ds = D1Backend(accountID: acct, databaseID: dbID, apiToken: token)
        let blobs = R2BlobBackend(endpoint: endpoint, bucket: bucket,
                                  accessKeyID: r2AK, secretAccessKey: r2Sec)

        try await ds.ensureSchema()

        // Push a probe row from "device A"
        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "test-A",
                                 state: SyncStateStore(store: storeA))
        let probe = "clip integration probe \(UUID().uuidString)"
        let id = try storeA.insert(ClipItem(
            id: nil, content: probe, contentHash: ClipItem.contentHash(of: probe),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: probe.utf8.count, truncated: false))
        try await engineA.enqueueClipPush(itemID: id, at: 100)
        _ = try await engineA.pushOnce(now: 200)

        // Pull from a fresh "device B"
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "test-B",
                                 state: SyncStateStore(store: storeB))
        try await engineB.pullOnce(now: 300)
        let recent = try storeB.listRecent()
        XCTAssertTrue(recent.contains(where: { $0.content == probe }))

        // Cleanup: tombstone our probe row so the test bucket stays small
        if let cloudID = try storeA.itemByID(id)?.cloudID {
            _ = try await ds.setClipDeleted(id: cloudID)
        }
    }
}
