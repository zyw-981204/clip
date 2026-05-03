import Foundation

/// Cloud sync orchestrator. Spec §4.1: actor; two background loops
/// (push drainer + 30s pull tick) plus signal-based wakeups.
/// This task adds push-only; pull / enableSync / fetchBlob / backfill /
/// excludeItem follow in T17–T21.
actor SyncEngine {
    let store: HistoryStore
    let dataSource: CloudSyncDataSource
    let blobStore: CloudSyncBlobStore
    let crypto: CryptoBox
    let deviceID: String
    let state: SyncStateStore
    let queue: SyncQueue

    init(store: HistoryStore, dataSource: CloudSyncDataSource,
         blobStore: CloudSyncBlobStore, crypto: CryptoBox,
         deviceID: String, state: SyncStateStore) {
        self.store = store
        self.dataSource = dataSource
        self.blobStore = blobStore
        self.crypto = crypto
        self.deviceID = deviceID
        self.state = state
        self.queue = SyncQueue(store: store)
    }

    // MARK: - public enqueue API

    func enqueueClipPush(itemID: Int64, at: Int64) throws {
        // Spec §10.4 — runtime guard against >2MB images. Backfill SQL also
        // filters but live onChange-fired enqueues need their own check.
        if let item = try store.itemByID(itemID),
           item.kind == .image, let blobID = item.blobID,
           let info = try store.blobInfo(id: blobID),
           info.size > 2 * 1024 * 1024 {
            return
        }
        try queue.enqueue(op: .putClip, targetKey: String(itemID), at: at)
    }

    func enqueueBlobPush(blobID: Int64, at: Int64) throws {
        try queue.enqueue(op: .putBlob, targetKey: String(blobID), at: at)
    }

    // MARK: - push drainer

    /// Drain at most one queue row. Returns true iff a row was attempted.
    @discardableResult
    func pushOnce(now: Int64) async throws -> Bool {
        guard let row = try queue.dequeueDueAt(now: now) else { return false }
        do {
            try await execute(row)
            try queue.delete(id: row.id)
        } catch {
            try queue.recordFailure(id: row.id,
                                    attempts: row.attempts + 1,
                                    error: String(describing: error),
                                    at: now)
        }
        return true
    }

    private func execute(_ row: SyncQueue.Row) async throws {
        switch row.op {
        case .putClip:   try await pushClip(itemID: Int64(row.targetKey)!)
        case .putBlob:   try await pushBlob(blobID: Int64(row.targetKey)!)
        case .putTomb:   try await pushTomb(contentHash: row.targetKey)
        case .putDevice: try await pushDevice()
        }
    }

    private func pushClip(itemID: Int64) async throws {
        guard let item = try store.itemByID(itemID) else { return }

        // Resolve blob_hmac for image items
        var blobKey: String? = nil
        var blobSize: Int? = nil
        if item.kind == .image, let blobID = item.blobID,
           let info = try store.blobInfo(id: blobID) {
            blobKey = CloudKey.blobKey(name: crypto.name(forContentHash: info.sha))
            blobSize = info.size
        }

        let payload = RowPayload(
            v: 1,
            content: item.kind == .text ? item.content : nil,
            thumbB64: nil,    // v3 leaves thumbnail generation to v3.x
            mimeType: item.mimeType,
            blobSize: blobSize,
            truncated: item.truncated,
            sourceBundleId: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            pinned: item.pinned,
            contentHash: item.contentHash)

        let json = try JSONEncoder().encode(payload)
        let sealed = try crypto.seal(json)
        let hmac = crypto.name(forContentHash: item.contentHash)

        // Fix B: hmac dedup includes deleted=1
        let existing = try await dataSource.queryClipByHmac(hmac)
        let cloudID = item.cloudID ?? existing?.id ?? UUID().uuidString.lowercased()

        let row = CloudRow(
            id: cloudID, hmac: hmac, ciphertext: sealed,
            kind: item.kind.rawValue, blobKey: blobKey,
            byteSize: item.byteSize, deviceID: deviceID,
            createdAt: item.createdAt, updatedAt: 0, deleted: false)

        let serverUpdatedAt = try await dataSource.upsertClip(row)
        let now = Int64(Date().timeIntervalSince1970)
        try store.markClipSynced(id: itemID, cloudID: cloudID,
                                 updatedAt: serverUpdatedAt, at: now)
        if let blobKey {
            try store.setItemCloudBlobKey(id: itemID, blobKey: blobKey)
        }
    }

    private func pushBlob(blobID: Int64) async throws {
        guard let bytes = try store.blob(id: blobID),
              let info = try store.blobInfo(id: blobID) else { return }
        let sealed = try crypto.seal(bytes)
        let key = CloudKey.blobKey(name: crypto.name(forContentHash: info.sha))
        try await blobStore.putBlob(key: key, body: sealed)
        let now = Int64(Date().timeIntervalSince1970)
        try store.markBlobSynced(id: blobID, at: now)
    }

    // Implementations in T18 / T20 / T21
    private func pushTomb(contentHash: String) async throws {
        // Implemented in Task 21 (excludeItem).
        _ = contentHash
    }

    private func pushDevice() async throws {
        // Out of scope for v3 — see spec §13. DevicePayload defined so v3.1 can wire.
    }
}
