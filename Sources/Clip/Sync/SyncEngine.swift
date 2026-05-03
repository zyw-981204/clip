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

    // Test escape hatch — read-only access to dataSource for assertions.
    var dataSourceForTesting: CloudSyncDataSource { dataSource }

    // MARK: - pull

    /// One pass: query D1 for changes since cursor, reconcile each row into
    /// local store. Spec §7.3 with fix A (composite cursor).
    func pullOnce(now: Int64) async throws {
        var cursor = CloudCursor(serialized: try state.get("cloud_pull_cursor") ?? "0:")
        while true {
            let rows = try await dataSource.queryClipsChangedSince(
                cursor: cursor, limit: 100)
            if rows.isEmpty { break }
            for row in rows {
                // LWW skip — but still advance cursor to avoid re-fetching
                if let local = try store.itemByCloudID(row.id),
                   (local.cloudUpdatedAt ?? 0) >= row.updatedAt {
                    cursor = CloudCursor(updatedAt: row.updatedAt, id: row.id)
                    continue
                }
                try await reconcile(row: row)
                cursor = CloudCursor(updatedAt: row.updatedAt, id: row.id)
            }
            try state.set("cloud_pull_cursor", cursor.serialized)
            // If the page came back full, loop for another. If short, stop.
            if rows.count < 100 { break }
        }
        try state.set("cloud_pull_at", String(now))
    }

    private func reconcile(row: CloudRow) async throws {
        // Decrypt payload
        let plain: Data
        do {
            plain = try crypto.open(row.ciphertext)
        } catch {
            // Decryption failure — likely wrong password. Don't delete local.
            return
        }
        let payload: RowPayload
        do {
            payload = try JSONDecoder().decode(RowPayload.self, from: plain)
        } catch {
            return
        }

        // Tombstone branch
        if row.deleted {
            try store.upsertTombstone(contentHash: payload.contentHash,
                                      cloudID: row.id,
                                      tombstonedAt: row.updatedAt,
                                      cloudUpdatedAt: row.updatedAt)
            try store.deleteItemsByContentHashOlderThan(payload.contentHash, row.updatedAt)
            return
        }

        // Resurrection guard: if local tombstone is newer than this row's
        // created_at, the row represents a stale resurrection — drop it.
        if let tombAt = try store.tombstoneAt(contentHash: payload.contentHash),
           tombAt >= row.createdAt {
            return
        }

        // Existing local row by content_hash → update mutable fields (pin)
        if let local = try store.itemByContentHash(payload.contentHash),
           let localID = local.id {
            try store.markClipSynced(id: localID, cloudID: row.id,
                                     updatedAt: row.updatedAt,
                                     at: Int64(Date().timeIntervalSince1970))
            // Pin LWW: server side wins (we trust D1 as truth)
            if local.pinned != payload.pinned {
                try await store.pool.write { db in
                    try db.execute(
                        sql: "UPDATE items SET pinned = ? WHERE id = ?",
                        arguments: [payload.pinned ? 1 : 0, localID])
                }
            }
            return
        }

        // Fresh INSERT
        let now = Int64(Date().timeIntervalSince1970)
        var item = ClipItem(
            id: nil,
            content: payload.content ?? "",
            contentHash: payload.contentHash,
            sourceBundleID: payload.sourceBundleId,
            sourceAppName: payload.sourceAppName,
            createdAt: row.createdAt,
            pinned: payload.pinned,
            byteSize: row.byteSize,
            truncated: payload.truncated,
            kind: ClipKind(rawValue: row.kind) ?? .text,
            blobID: nil,
            mimeType: payload.mimeType,
            cloudID: row.id,
            cloudUpdatedAt: row.updatedAt,
            cloudSyncedAt: now,
            cloudBlobKey: row.blobKey,
            syncExcluded: false,
            deviceID: row.deviceID)

        if item.kind == .image, let blobKey = row.blobKey, let blobSize = payload.blobSize {
            // Extract hmac from "blobs/<hmac>.bin"
            let hmac = String(blobKey.dropFirst(CloudKey.blobsPrefix.count).dropLast(".bin".count))
            let blobID = try store.insertLazyBlob(blobHmac: hmac, byteSize: blobSize, now: now)
            item.blobID = blobID
        }
        _ = try store.insert(item)
    }
}
