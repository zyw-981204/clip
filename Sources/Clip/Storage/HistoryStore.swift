import Foundation
import GRDB

final class HistoryStore {
    let pool: DatabasePool

    init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
        }
        self.pool = try DatabasePool(path: path, configuration: config)
        var migrator = DatabaseMigrator()
        Migrations.register(&migrator)
        try migrator.migrate(pool)
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
                 created_at, pinned, byte_size, truncated)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            item.content, item.contentHash, item.sourceBundleID,
            item.sourceAppName, item.createdAt, item.pinned ? 1 : 0,
            item.byteSize, item.truncated ? 1 : 0,
        ])
        return db.lastInsertedRowID
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
            try Row.fetchAll(db, sql: """
                SELECT * FROM items
                WHERE LOWER(content) LIKE ? ESCAPE '\\'
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
        ClipItem(
            id: row["id"],
            content: row["content"],
            contentHash: row["content_hash"],
            sourceBundleID: row["source_bundle_id"],
            sourceAppName: row["source_app_name"],
            createdAt: row["created_at"],
            pinned: (row["pinned"] as Int64) != 0,
            byteSize: row["byte_size"],
            truncated: (row["truncated"] as Int64) != 0
        )
    }
}
