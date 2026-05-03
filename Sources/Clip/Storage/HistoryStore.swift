import Foundation
import GRDB

enum HistoryStoreChange: Sendable {
    case inserted(itemID: Int64)
    case deleted(itemID: Int64, contentHash: String)
    case pinToggled(itemID: Int64)
    case excludedToggled(itemID: Int64)
}

/// Thread-safety: the only stored state is `pool`, a GRDB `DatabasePool`
/// which is documented as safe to share across threads. WAL journal mode
/// (set in init) lets readers and writers proceed concurrently.
final class HistoryStore: @unchecked Sendable {
    let pool: DatabasePool

    /// Fires after every successful mutation (insert/delete/pin/exclude).
    /// SyncEngine subscribes here in T25 to enqueue push work.
    var onChange: (@Sendable (HistoryStoreChange) -> Void)?

    init(path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            try Self.checkOrQuarantine(path: path)
        }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        self.pool = try DatabasePool(path: path, configuration: config)
        var migrator = DatabaseMigrator()
        Migrations.register(&migrator)
        try migrator.migrate(pool)
    }

    private static func checkOrQuarantine(path: String) throws {
        let ok: Bool
        do {
            let q = try DatabaseQueue(path: path)
            let result = try q.read { db in
                try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "fail"
            }
            ok = (result == "ok")
        } catch {
            ok = false
        }
        guard !ok else { return }

        let ts = Int64(Date().timeIntervalSince1970)
        let dest = path + ".corrupted-\(ts)"
        let fm = FileManager.default
        try? fm.moveItem(atPath: path, toPath: dest)
        for suffix in ["-wal", "-shm"] {
            let src = path + suffix
            if fm.fileExists(atPath: src) {
                try? fm.moveItem(atPath: src, toPath: dest + suffix)
            }
        }
    }

    /// Test helper: backs onto a fresh temp-file DB so DatabasePool's file-only
    /// requirement is satisfied. Caller is responsible for not relying on the
    /// file path being stable across runs.
    static func inMemory() throws -> HistoryStore {
        let tmp = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        return try HistoryStore(path: tmp)
    }

    @discardableResult
    func insert(_ item: ClipItem) throws -> Int64 {
        let id = try pool.write { db in
            try Self._insert(db, item: item)
        }
        onChange?(.inserted(itemID: id))
        return id
    }

    fileprivate static func _insert(_ db: Database, item: ClipItem) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO items
                (content, content_hash, source_bundle_id, source_app_name,
                 created_at, pinned, byte_size, truncated,
                 kind, blob_id, mime_type,
                 cloud_id, cloud_updated_at, cloud_synced_at, cloud_blob_key,
                 sync_excluded, device_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            item.content, item.contentHash, item.sourceBundleID,
            item.sourceAppName, item.createdAt, item.pinned ? 1 : 0,
            item.byteSize, item.truncated ? 1 : 0,
            item.kind.rawValue, item.blobID, item.mimeType,
            item.cloudID, item.cloudUpdatedAt, item.cloudSyncedAt, item.cloudBlobKey,
            item.syncExcluded ? 1 : 0, item.deviceID,
        ])
        return db.lastInsertedRowID
    }

    /// Insert an image clip. Dedups via the blob's SHA-256:
    /// - if a blob with the same hash exists, reuse its `id`
    /// - if an `items` row references that blob, treat it as a `insertOrPromote`-
    ///   style hit and just update `created_at`
    /// - otherwise insert a fresh `items` row
    /// Returns the resulting items.id.
    @discardableResult
    func insertImage(
        bytes: Data,
        mimeType: String,
        sourceBundleID: String?,
        sourceAppName: String?,
        now: Int64
    ) throws -> Int64 {
        let sha = ClipItem.contentHash(of: bytes)
        let result: (id: Int64, isNew: Bool) = try pool.write { db in
            // 1. Find or create the blob.
            let blobID: Int64
            if let existing = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM clip_blobs WHERE sha256 = ? LIMIT 1",
                arguments: [sha]
            ) {
                blobID = existing
            } else {
                try db.execute(sql: """
                    INSERT INTO clip_blobs (sha256, bytes, byte_size, created_at)
                    VALUES (?, ?, ?, ?)
                """, arguments: [sha, bytes, bytes.count, now])
                blobID = db.lastInsertedRowID
            }

            // 2. If an items row already points at this blob, promote it.
            if let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM items WHERE blob_id = ? LIMIT 1",
                arguments: [blobID]
            ) {
                try db.execute(
                    sql: "UPDATE items SET created_at = ? WHERE id = ?",
                    arguments: [now, id]
                )
                return (id, false)
            }

            // 3. Fresh insert.
            let item = ClipItem(
                content: "",
                contentHash: sha,
                sourceBundleID: sourceBundleID,
                sourceAppName: sourceAppName,
                createdAt: now,
                pinned: false,
                byteSize: bytes.count,
                truncated: false,
                kind: .image,
                blobID: blobID,
                mimeType: mimeType
            )
            let newID = try Self._insert(db, item: item)
            return (newID, true)
        }
        if result.isNew {
            onChange?(.inserted(itemID: result.id))
        }
        return result.id
    }

    /// Fetch raw bytes for a blob (used by ThumbnailCache + PasteInjector).
    func blob(id: Int64) throws -> Data? {
        try pool.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT bytes FROM clip_blobs WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Lightweight metadata read — avoids loading the full blob bytes when
    /// rendering rows that haven't been thumbnail-decoded yet.
    func blobInfo(id: Int64) throws -> (size: Int, sha: String)? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT byte_size, sha256 FROM clip_blobs WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return (row["byte_size"], row["sha256"])
        }
    }

    func listRecent(limit: Int = 50) throws -> [ClipItem] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM items
                ORDER BY pinned DESC, created_at DESC, id DESC
                LIMIT ?
            """, arguments: [limit]).map(Self.itemFromRow)
        }
    }

    /// Remove non-pinned items beyond per-kind caps and older than the age
    /// cut. Pinned rows are exempt from both. Text and image have separate
    /// count caps because images dominate disk usage at very different
    /// scales than text. After items are pruned, sweep any blobs that no
    /// row references.
    func prune(now: Int64, maxText: Int, maxImage: Int, maxAgeSeconds: Int64) throws {
        try pool.write { db in
            // Per-kind count cap.
            try db.execute(sql: """
                DELETE FROM items
                WHERE pinned = 0
                  AND kind = 'text'
                  AND id NOT IN (
                      SELECT id FROM items
                      WHERE pinned = 0 AND kind = 'text'
                      ORDER BY created_at DESC, id DESC
                      LIMIT ?
                  )
            """, arguments: [maxText])
            try db.execute(sql: """
                DELETE FROM items
                WHERE pinned = 0
                  AND kind = 'image'
                  AND id NOT IN (
                      SELECT id FROM items
                      WHERE pinned = 0 AND kind = 'image'
                      ORDER BY created_at DESC, id DESC
                      LIMIT ?
                  )
            """, arguments: [maxImage])

            // Age cap (applies to both kinds).
            try db.execute(
                sql: "DELETE FROM items WHERE pinned = 0 AND created_at < ?",
                arguments: [now - maxAgeSeconds]
            )

            // Blob sweep: any blob no row points at is dead weight.
            try db.execute(sql: """
                DELETE FROM clip_blobs
                WHERE id NOT IN (
                    SELECT blob_id FROM items
                    WHERE blob_id IS NOT NULL
                )
            """)
        }
    }

    func delete(id: Int64) throws {
        // Capture content_hash BEFORE the delete so SyncEngine can write a
        // tombstone with the correct hash.
        let hash = try pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT content_hash FROM items WHERE id = ?",
                arguments: [id]
            )
        }
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM items WHERE id = ?",
                arguments: [id]
            )
        }
        if let hash {
            onChange?(.deleted(itemID: id, contentHash: hash))
        }
    }

    func togglePin(id: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE items SET pinned = 1 - pinned WHERE id = ?",
                arguments: [id]
            )
        }
        onChange?(.pinToggled(itemID: id))
    }

    func search(query: String, limit: Int = 50) throws -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return try listRecent(limit: limit)
        }
        let escaped = LikeEscape.escape(q.lowercased())
        let pattern = "%\(escaped)%"
        return try pool.read { db in
            // Image rows have empty `content` so they never match a non-empty
            // query — but be explicit so future search-tweaking doesn't trip.
            try Row.fetchAll(db, sql: """
                SELECT * FROM items
                WHERE kind = 'text' AND LOWER(content) LIKE ? ESCAPE '\\'
                ORDER BY pinned DESC, created_at DESC, id DESC
                LIMIT ?
            """, arguments: [pattern, limit]).map(Self.itemFromRow)
        }
    }

    @discardableResult
    func insertOrPromote(_ item: ClipItem, now: Int64) throws -> Int64 {
        let result: (id: Int64, isNew: Bool) = try pool.write { db in
            if let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM items WHERE content_hash = ? LIMIT 1",
                arguments: [item.contentHash]
            ) {
                try db.execute(
                    sql: "UPDATE items SET created_at = ? WHERE id = ?",
                    arguments: [now, id]
                )
                return (id, false)
            }
            let newID = try Self._insert(db, item: item)
            return (newID, true)
        }
        if result.isNew {
            onChange?(.inserted(itemID: result.id))
        }
        return result.id
    }

    static func itemFromRow(_ row: Row) -> ClipItem {
        // `kind`, `blob_id`, `mime_type` are nullable in the schema only for
        // back-compat: rows inserted before v2 have NULL `kind`. We migrate
        // the column with `DEFAULT 'text'` so post-v2 reads always see a
        // value, but be defensive.
        let kindStr = (row["kind"] as String?) ?? "text"
        let kind = ClipKind(rawValue: kindStr) ?? .text
        return ClipItem(
            id: row["id"],
            content: row["content"],
            contentHash: row["content_hash"],
            sourceBundleID: row["source_bundle_id"],
            sourceAppName: row["source_app_name"],
            createdAt: row["created_at"],
            pinned: (row["pinned"] as Int64) != 0,
            byteSize: row["byte_size"],
            truncated: (row["truncated"] as Int64) != 0,
            kind: kind,
            blobID: row["blob_id"],
            mimeType: row["mime_type"],
            cloudID: row["cloud_id"],
            cloudUpdatedAt: row["cloud_updated_at"],
            cloudSyncedAt: row["cloud_synced_at"],
            cloudBlobKey: row["cloud_blob_key"],
            syncExcluded: ((row["sync_excluded"] as Int64?) ?? 0) != 0,
            deviceID: row["device_id"]
        )
    }

    // MARK: - Sync helpers (Migration v3)

    func itemByID(_ id: Int64) throws -> ClipItem? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id])
                .map(Self.itemFromRow)
        }
    }

    func itemByCloudID(_ cloudID: String) throws -> ClipItem? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM items WHERE cloud_id = ? LIMIT 1",
                             arguments: [cloudID]).map(Self.itemFromRow)
        }
    }

    func itemByContentHash(_ hash: String) throws -> ClipItem? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM items WHERE content_hash = ? LIMIT 1",
                             arguments: [hash]).map(Self.itemFromRow)
        }
    }

    func markClipSynced(id: Int64, cloudID: String, updatedAt: Int64, at: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE items SET cloud_id = ?, cloud_updated_at = ?, cloud_synced_at = ?
                WHERE id = ?
            """, arguments: [cloudID, updatedAt, at, id])
        }
    }

    /// Per spec §5.1, clip_blobs has no new columns — "synced" for a blob is
    /// implicit (sha256 no longer carries the `"lazy:"` prefix). This helper
    /// is a no-op kept for SyncEngine API symmetry; callers may use it as a
    /// hook point if a future migration adds explicit per-blob sync state.
    func markBlobSynced(id: Int64, at: Int64) throws {
        _ = id; _ = at
    }

    func setItemCloudBlobKey(id: Int64, blobKey: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE items SET cloud_blob_key = ? WHERE id = ?",
                           arguments: [blobKey, id])
        }
    }

    func setSyncExcluded(id: Int64, excluded: Bool) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE items SET sync_excluded = ? WHERE id = ?",
                           arguments: [excluded ? 1 : 0, id])
        }
        onChange?(.excludedToggled(itemID: id))
    }

    // MARK: - Tombstones (local; prevents capture-side resurrection)

    func upsertTombstone(contentHash: String, cloudID: String,
                         tombstonedAt: Int64, cloudUpdatedAt: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO tombstones (content_hash, cloud_id, tombstoned_at, cloud_updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                  tombstoned_at = excluded.tombstoned_at,
                  cloud_updated_at = excluded.cloud_updated_at
            """, arguments: [contentHash, cloudID, tombstonedAt, cloudUpdatedAt])
        }
    }

    func tombstoneAt(contentHash: String) throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(db,
                sql: "SELECT tombstoned_at FROM tombstones WHERE content_hash = ?",
                arguments: [contentHash])
        }
    }

    func deleteItemsByContentHashOlderThan(_ contentHash: String, _ tombstonedAt: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                DELETE FROM items WHERE content_hash = ? AND created_at <= ?
            """, arguments: [contentHash, tombstonedAt])
        }
    }

    // MARK: - Lazy blob (image rows pulled before bytes downloaded)

    func insertLazyBlob(blobHmac: String, byteSize: Int, now: Int64) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO clip_blobs (sha256, bytes, byte_size, created_at)
                VALUES (?, ?, ?, ?)
            """, arguments: ["lazy:" + blobHmac, Data(), byteSize, now])
            return db.lastInsertedRowID
        }
    }

    func lazyBlobHmac(id: Int64) throws -> (hmac: String, byteSize: Int)? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT sha256, byte_size FROM clip_blobs WHERE id = ?",
                arguments: [id]) else { return nil }
            let sha: String = row["sha256"]
            guard sha.hasPrefix("lazy:") else { return nil }
            return (String(sha.dropFirst("lazy:".count)), row["byte_size"])
        }
    }

    /// `at` is the wall-clock time of the fill; not stored on clip_blobs (per
    /// spec §5.1 the table has no sync timestamp), but kept in the signature
    /// so SyncEngine code can pass it without conditional plumbing if a future
    /// migration adds the column.
    func fillBlob(id: Int64, bytes: Data, sha256: String, at: Int64) throws {
        _ = at
        try pool.write { db in
            try db.execute(sql: """
                UPDATE clip_blobs SET bytes = ?, sha256 = ?
                WHERE id = ?
            """, arguments: [bytes, sha256, id])
        }
    }
}
