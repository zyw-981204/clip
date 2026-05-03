import Foundation
import GRDB

/// Tiny KV wrapper around the sync_state table.
struct SyncStateStore: Sendable {
    let store: HistoryStore

    func get(_ key: String) throws -> String? {
        try store.pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                arguments: [key])
        }
    }

    func set(_ key: String, _ value: String) throws {
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [key, value])
        }
    }

    func delete(_ key: String) throws {
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [key])
        }
    }
}
