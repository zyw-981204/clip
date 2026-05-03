import Foundation
import Security

enum SyncError: Error, Equatable {
    case remoteSchemaNewer(remote: String, local: String)
    case decryptionFailed
    case d1(String)
    case r2(String)
}

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

    // MARK: - lazy blob fetch

    /// Spec §7.4 lazy image download. Caller holds a clip_blobs.id whose
    /// `bytes` is empty (sha256 prefixed `lazy:`). Resolves the blob_hmac,
    /// GETs blobs/<hmac>.bin, decrypts, fills local row, returns bytes.
    func fetchBlob(blobID: Int64) async throws -> Data {
        guard let info = try store.lazyBlobHmac(id: blobID) else {
            // Already filled — caller should re-read.
            return (try store.blob(id: blobID)) ?? Data()
        }
        let key = CloudKey.blobKey(name: info.hmac)
        guard let sealed = try await blobStore.getBlob(key: key) else {
            throw SyncError.r2("blob \(info.hmac) not found in cloud")
        }
        let bytes = try crypto.open(sealed)
        let realSha = ClipItem.contentHash(of: bytes)
        try store.fillBlob(id: blobID, bytes: bytes, sha256: realSha,
                           at: Int64(Date().timeIntervalSince1970))
        return bytes
    }

    // MARK: - backfill

    /// Spec §7.6 — enqueue every existing non-excluded, non-yet-synced item
    /// (and its blob if image and ≤2MB). Run once after `enableSync` finishes
    /// AND only on the first device (BootstrapResult.firstDevice).
    func backfill(now: Int64) async throws {
        try await store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
                SELECT 'put_clip', CAST(items.id AS TEXT), 0, ?, ?
                FROM items
                LEFT JOIN clip_blobs ON items.blob_id = clip_blobs.id
                WHERE items.sync_excluded = 0
                  AND items.cloud_id IS NULL
                  AND (items.kind = 'text' OR clip_blobs.byte_size <= 2097152)
                ORDER BY items.created_at DESC
            """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
                SELECT 'put_blob', CAST(clip_blobs.id AS TEXT), 0, ?, ?
                FROM clip_blobs
                JOIN items ON items.blob_id = clip_blobs.id
                WHERE items.sync_excluded = 0
                  AND items.cloud_id IS NULL
                  AND clip_blobs.byte_size <= 2097152
                ORDER BY items.created_at DESC
            """, arguments: [now, now])
        }
    }
}

extension SyncEngine {
    enum BootstrapResult: Equatable {
        case firstDevice
        case joinedExisting
    }

    /// Spec §7.1 first-time enable. Static because it runs before SyncEngine
    /// is instantiated. Bakes in fix C (INSERT OR IGNORE) + fix E (schema_version).
    ///
    /// Side effects:
    ///   - D1 schema present (CREATE IF NOT EXISTS)
    ///   - config { schema_version='3', kdf_iters='200000', kdf_salt_b64=<...> }
    ///   - master_key written to (keychain.service, account)
    ///   - device_id allocated locally if missing
    static func enableSync(
        password: String,
        dataSource: CloudSyncDataSource,
        state: SyncStateStore,
        keychain: KeychainStore,
        account: String
    ) async throws -> BootstrapResult {
        let localSchemaVersion = "3"
        let iters = 200_000

        try await dataSource.ensureSchema()

        // Fix E — schema_version gatekeeping
        let remote = try await dataSource.getConfig(key: "schema_version") ?? localSchemaVersion
        if (Int(remote) ?? 0) > (Int(localSchemaVersion) ?? 0) {
            throw SyncError.remoteSchemaNewer(remote: remote, local: localSchemaVersion)
        }
        // Stamp our version (idempotent)
        _ = try await dataSource.putConfigIfAbsent(key: "schema_version", value: localSchemaVersion)

        // Fix C — idempotent salt + iters bootstrap
        var saltBytes = Data(count: 16)
        _ = saltBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        let saltB64 = saltBytes.base64EncodedString()
        let iWonSalt = try await dataSource.putConfigIfAbsent(
            key: "kdf_salt_b64", value: saltB64)
        _ = try await dataSource.putConfigIfAbsent(
            key: "kdf_iters", value: String(iters))

        // Read authoritative salt (mine if iWon, theirs otherwise)
        guard let authSaltB64 = try await dataSource.getConfig(key: "kdf_salt_b64"),
              let authSalt = Data(base64Encoded: authSaltB64) else {
            throw SyncError.d1("kdf_salt_b64 missing after bootstrap")
        }

        let masterKey = KeyDerivation.pbkdf2_sha256(
            password: password, salt: authSalt,
            iterations: iters, keyLength: 32)
        try keychain.write(account: account, data: masterKey)

        // Allocate local device_id if missing
        if try state.get("device_id") == nil {
            try state.set("device_id", UUID().uuidString.lowercased())
        }

        return iWonSalt ? .firstDevice : .joinedExisting
    }

    /// Spec §5.2 — runs on **every SyncEngine cold start** (not only enable),
    /// so a remote schema bump while this client was offline is caught next
    /// launch. Throws SyncError.remoteSchemaNewer when remote > local.
    /// Idempotent: `ensureSchema` is `CREATE TABLE IF NOT EXISTS`-only.
    static func verifyRemoteSchema(dataSource: CloudSyncDataSource) async throws {
        let localSchemaVersion = "3"
        try await dataSource.ensureSchema()
        let remote = try await dataSource.getConfig(key: "schema_version") ?? localSchemaVersion
        if (Int(remote) ?? 0) > (Int(localSchemaVersion) ?? 0) {
            throw SyncError.remoteSchemaNewer(remote: remote, local: localSchemaVersion)
        }
    }
}
