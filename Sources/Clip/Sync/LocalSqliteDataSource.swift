import Foundation
import GRDB

/// In-memory SQLite that mirrors the D1 schema exactly. Used by tests so
/// SyncEngine can exercise the full push/pull pipeline without network.
/// Production uses D1Backend — same protocol, same SQL semantics.
final class LocalSqliteDataSource: CloudSyncDataSource, @unchecked Sendable {
    let pool: DatabasePool

    init() throws {
        let tmp = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        var cfg = Configuration()
        cfg.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode=WAL") }
        self.pool = try DatabasePool(path: tmp, configuration: cfg)
    }

    func ensureSchema() async throws {
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clips (
                    id           TEXT PRIMARY KEY,
                    hmac         TEXT NOT NULL,
                    ciphertext   BLOB NOT NULL,
                    kind         TEXT NOT NULL,
                    blob_key     TEXT,
                    byte_size    INTEGER NOT NULL,
                    device_id    TEXT NOT NULL,
                    created_at   INTEGER NOT NULL,
                    updated_at   INTEGER NOT NULL,
                    deleted      INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_clips_updated_at ON clips(updated_at);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_clips_hmac ON clips(hmac);")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS devices (
                    device_id    TEXT PRIMARY KEY,
                    ciphertext   BLOB NOT NULL,
                    last_seen_at INTEGER NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS config (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
            """)
        }
    }

    func upsertClip(_ row: CloudRow) async throws -> Int64 {
        try await pool.write { db in
            // Enforce strict monotonic updated_at: spec §5.2 requires a
            // monotonic pull cursor, but unixepoch() returns seconds so two
            // updates within one second would collide and be missed by the
            // composite cursor. Bump table-wide max+1 when wall clock hasn't
            // advanced past it.
            try db.execute(sql: """
                INSERT INTO clips (id, hmac, ciphertext, kind, blob_key, byte_size,
                                   device_id, created_at, updated_at, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?,
                        MAX(unixepoch(), COALESCE((SELECT MAX(updated_at) FROM clips), 0) + 1),
                        0)
                ON CONFLICT(id) DO UPDATE SET
                  hmac=excluded.hmac, ciphertext=excluded.ciphertext,
                  kind=excluded.kind, blob_key=excluded.blob_key,
                  byte_size=excluded.byte_size, device_id=excluded.device_id,
                  updated_at=MAX(unixepoch(), (SELECT MAX(updated_at) FROM clips) + 1),
                  deleted=0
            """, arguments: [row.id, row.hmac, row.ciphertext, row.kind,
                             row.blobKey, row.byteSize, row.deviceID,
                             row.createdAt])
            return try Int64.fetchOne(db,
                sql: "SELECT updated_at FROM clips WHERE id = ?",
                arguments: [row.id]) ?? 0
        }
    }

    func queryClipByHmac(_ hmac: String) async throws -> (id: String, deleted: Bool)? {
        try await pool.read { db in
            try Row.fetchOne(db,
                sql: "SELECT id, deleted FROM clips WHERE hmac = ? LIMIT 1",
                arguments: [hmac]).map { (id: $0["id"], deleted: ($0["deleted"] as Int64) != 0) }
        }
    }

    func queryClipsChangedSince(cursor: CloudCursor, limit: Int) async throws -> [CloudRow] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM clips
                WHERE updated_at > ? OR (updated_at = ? AND id > ?)
                ORDER BY updated_at, id
                LIMIT ?
            """, arguments: [cursor.updatedAt, cursor.updatedAt, cursor.id, limit])
            .map(Self.cloudRowFromRow)
        }
    }

    func setClipDeleted(id: String) async throws -> Int64 {
        try await pool.write { db in
            // Same monotonic-bump as upsertClip — pull cursor depends on it.
            try db.execute(sql: """
                UPDATE clips SET deleted = 1,
                    updated_at = MAX(unixepoch(), (SELECT MAX(updated_at) FROM clips) + 1)
                WHERE id = ?
            """, arguments: [id])
            return try Int64.fetchOne(db,
                sql: "SELECT updated_at FROM clips WHERE id = ?",
                arguments: [id]) ?? 0
        }
    }

    func upsertDevice(_ row: DeviceRow) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO devices (device_id, ciphertext, last_seen_at)
                VALUES (?, ?, unixepoch())
                ON CONFLICT(device_id) DO UPDATE SET
                  ciphertext = excluded.ciphertext,
                  last_seen_at = unixepoch()
            """, arguments: [row.deviceID, row.ciphertext])
        }
    }

    func listDevices() async throws -> [DeviceRow] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM devices ORDER BY last_seen_at DESC")
                .map { DeviceRow(deviceID: $0["device_id"],
                                 ciphertext: $0["ciphertext"],
                                 lastSeenAt: $0["last_seen_at"]) }
        }
    }

    func getConfig(key: String) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM config WHERE key = ?", arguments: [key])
        }
    }

    func putConfigIfAbsent(key: String, value: String) async throws -> Bool {
        try await pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO config (key, value) VALUES (?, ?)",
                           arguments: [key, value])
            return db.changesCount == 1
        }
    }

    // Test-only direct insert for cursor / LWW tests where unixepoch() can't help.
    func testDirectInsert(_ row: CloudRow) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO clips (id, hmac, ciphertext, kind, blob_key, byte_size,
                                   device_id, created_at, updated_at, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [row.id, row.hmac, row.ciphertext, row.kind,
                             row.blobKey, row.byteSize, row.deviceID,
                             row.createdAt, row.updatedAt, row.deleted ? 1 : 0])
        }
    }

    static func cloudRowFromRow(_ r: Row) -> CloudRow {
        CloudRow(id: r["id"], hmac: r["hmac"], ciphertext: r["ciphertext"],
                 kind: r["kind"], blobKey: r["blob_key"], byteSize: r["byte_size"],
                 deviceID: r["device_id"], createdAt: r["created_at"],
                 updatedAt: r["updated_at"], deleted: (r["deleted"] as Int64) != 0)
    }
}
