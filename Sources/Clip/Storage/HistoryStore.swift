import Foundation
import GRDB

/// Thread-safety: the only stored state is `pool`, a GRDB `DatabasePool`
/// which is documented as safe to share across threads. WAL journal mode
/// (set in init) lets readers and writers proceed concurrently.
final class HistoryStore: @unchecked Sendable {
    let pool: DatabasePool

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
        try pool.write { db in
            try Self._insert(db, item: item)
        }
    }

    fileprivate static func _insert(_ db: Database, item: ClipItem) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO items
                (content, content_hash, source_bundle_id, source_app_name,
                 created_at, pinned, byte_size, truncated,
                 kind, blob_id, mime_type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            item.content, item.contentHash, item.sourceBundleID,
            item.sourceAppName, item.createdAt, item.pinned ? 1 : 0,
            item.byteSize, item.truncated ? 1 : 0,
            item.kind.rawValue, item.blobID, item.mimeType,
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
        return try pool.write { db in
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
                return id
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
            return try Self._insert(db, item: item)
        }
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
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM items WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func togglePin(id: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE items SET pinned = 1 - pinned WHERE id = ?",
                arguments: [id]
            )
        }
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
        try pool.write { db in
            if let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM items WHERE content_hash = ? LIMIT 1",
                arguments: [item.contentHash]
            ) {
                try db.execute(
                    sql: "UPDATE items SET created_at = ? WHERE id = ?",
                    arguments: [now, id]
                )
                return id
            }
            return try Self._insert(db, item: item)
        }
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
            mimeType: row["mime_type"]
        )
    }
}
