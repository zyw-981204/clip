import Foundation
import GRDB

/// DB-backed retry queue (sync_queue, created in Migration v3). On failure
/// applies exponential backoff capped at 900s.
struct SyncQueue: Sendable {
    let store: HistoryStore

    struct Row: Sendable {
        var id: Int64
        var op: SyncOp
        var targetKey: String
        var attempts: Int
        var nextTryAt: Int64
        var lastError: String?
        var enqueuedAt: Int64
    }

    func enqueue(op: SyncOp, targetKey: String, at time: Int64) throws {
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
                VALUES (?, ?, 0, ?, ?)
            """, arguments: [op.rawValue, targetKey, time, time])
        }
    }

    func dequeueDueAt(now: Int64) throws -> Row? {
        try store.pool.read { db in
            try GRDB.Row.fetchOne(db, sql: """
                SELECT * FROM sync_queue
                WHERE next_try_at <= ?
                ORDER BY next_try_at ASC, id ASC
                LIMIT 1
            """, arguments: [now]).map(Self.fromRow)
        }
    }

    func delete(id: Int64) throws {
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM sync_queue WHERE id = ?", arguments: [id])
        }
    }

    func recordFailure(id: Int64, attempts: Int, error: String, at now: Int64) throws {
        let backoff = min(900, Int(truncatingIfNeeded: 1 &<< min(attempts, 20)))
        try store.pool.write { db in
            try db.execute(sql: """
                UPDATE sync_queue SET attempts = ?, last_error = ?, next_try_at = ?
                WHERE id = ?
            """, arguments: [attempts, error, now + Int64(backoff), id])
        }
    }

    func deleteAllForItem(itemID: Int64) throws {
        let target = String(itemID)
        try store.pool.write { db in
            try db.execute(sql: """
                DELETE FROM sync_queue
                WHERE op IN ('put_clip', 'put_blob') AND target_key = ?
            """, arguments: [target])
        }
    }

    func peekAll() throws -> [Row] {
        try store.pool.read { db in
            try GRDB.Row.fetchAll(db, sql: "SELECT * FROM sync_queue ORDER BY id")
                .map(Self.fromRow)
        }
    }

    private static func fromRow(_ r: GRDB.Row) -> Row {
        Row(id: r["id"],
            op: SyncOp(rawValue: r["op"]) ?? .putClip,
            targetKey: r["target_key"],
            attempts: r["attempts"],
            nextTryAt: r["next_try_at"],
            lastError: r["last_error"],
            enqueuedAt: r["enqueued_at"])
    }
}
