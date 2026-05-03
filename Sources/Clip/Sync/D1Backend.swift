import Foundation

/// CloudSyncDataSource implementation over the Cloudflare D1 REST API.
/// All requests: POST {accountID}/d1/database/{databaseID}/query with
/// Bearer auth. SQL is sent as JSON body { sql, params }.
///
/// Bakes in fixes A (composite cursor SQL), B (hmac dedup includes deleted=1),
/// C (INSERT OR IGNORE on config), E (schema_version row in ensureSchema).
final class D1Backend: CloudSyncDataSource, @unchecked Sendable {
    enum Error: Swift.Error {
        case http(status: Int, body: String)
        case d1(messages: [String])
        case decode(String)
    }

    let accountID: String
    let databaseID: String
    let apiToken: String
    let session: URLSession

    init(accountID: String, databaseID: String, apiToken: String,
         session: URLSession = .shared) {
        self.accountID = accountID
        self.databaseID = databaseID
        self.apiToken = apiToken
        self.session = session
    }

    private var endpoint: URL {
        URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/d1/database/\(databaseID)/query")!
    }

    // MARK: - Generic SQL execution

    private struct ResultEnvelope: Decodable {
        struct Inner: Decodable {
            var results: [[String: AnyCodable]]?
            var success: Bool
            var meta: Meta?
        }
        struct Meta: Decodable {
            var rows_read: Int?
            var rows_written: Int?
            var changes: Int?
            var last_row_id: Int?
        }
        struct ApiMessage: Decodable { var code: Int?; var message: String? }
        var result: [Inner]?
        var success: Bool
        var errors: [ApiMessage]?
        var messages: [ApiMessage]?
    }

    // Minimal Codable-any for deserializing result rows
    struct AnyCodable: Decodable {
        let value: Any?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = nil; return }
            if let i = try? c.decode(Int64.self) { value = i; return }
            if let d = try? c.decode(Double.self) { value = d; return }
            if let s = try? c.decode(String.self) { value = s; return }
            if let b = try? c.decode(Bool.self) { value = b; return }
            value = nil
        }
    }

    private func runSQL(_ sql: String, params: [Any?] = []) async throws -> ResultEnvelope.Inner {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "sql": sql,
            "params": params.map { $0 ?? NSNull() }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
        let env = try JSONDecoder().decode(ResultEnvelope.self, from: data)
        guard env.success, let inner = env.result?.first else {
            let msgs = (env.errors ?? []).compactMap(\.message)
            throw Error.d1(messages: msgs)
        }
        return inner
    }

    // MARK: - ensureSchema (fix C + fix E)

    func ensureSchema() async throws {
        let stmts = [
            """
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
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_clips_updated_at ON clips(updated_at)",
            "CREATE INDEX IF NOT EXISTS idx_clips_hmac ON clips(hmac)",
            """
            CREATE TABLE IF NOT EXISTS devices (
                device_id    TEXT PRIMARY KEY,
                ciphertext   BLOB NOT NULL,
                last_seen_at INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS config (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """,
        ]
        for s in stmts { _ = try await runSQL(s) }
        // schema_version stamp (fix E). INSERT OR IGNORE: only first device sets it.
        _ = try await runSQL(
            "INSERT OR IGNORE INTO config (key, value) VALUES (?, ?)",
            params: ["schema_version", "3"])
    }

    // MARK: - Clips

    func upsertClip(_ row: CloudRow) async throws -> Int64 {
        // Single round trip via SQLite RETURNING (supported by D1).
        let inner = try await runSQL("""
            INSERT INTO clips (id, hmac, ciphertext, kind, blob_key, byte_size,
                               device_id, created_at, updated_at, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, unixepoch(), 0)
            ON CONFLICT(id) DO UPDATE SET
              hmac=excluded.hmac, ciphertext=excluded.ciphertext,
              kind=excluded.kind, blob_key=excluded.blob_key,
              byte_size=excluded.byte_size, device_id=excluded.device_id,
              updated_at=unixepoch(), deleted=0
            RETURNING updated_at
            """,
            params: [row.id, row.hmac, row.ciphertext.base64EncodedString(),
                     row.kind, row.blobKey, row.byteSize,
                     row.deviceID, row.createdAt])
        return (inner.results?.first?["updated_at"]?.value as? Int64) ?? 0
    }

    func queryClipByHmac(_ hmac: String) async throws -> (id: String, deleted: Bool)? {
        // Fix B: do NOT filter deleted=0 here.
        let inner = try await runSQL(
            "SELECT id, deleted FROM clips WHERE hmac = ? LIMIT 1", params: [hmac])
        guard let row = inner.results?.first else { return nil }
        let id = (row["id"]?.value as? String) ?? ""
        let del = ((row["deleted"]?.value as? Int64) ?? 0) != 0
        return (id, del)
    }

    func queryClipsChangedSince(cursor: CloudCursor, limit: Int) async throws -> [CloudRow] {
        // Fix A: composite (updated_at, id) cursor.
        let inner = try await runSQL("""
            SELECT id, hmac, ciphertext, kind, blob_key, byte_size,
                   device_id, created_at, updated_at, deleted
            FROM clips
            WHERE updated_at > ? OR (updated_at = ? AND id > ?)
            ORDER BY updated_at, id
            LIMIT ?
            """,
            params: [cursor.updatedAt, cursor.updatedAt, cursor.id, limit])
        return (inner.results ?? []).map(Self.cloudRowFrom)
    }

    func setClipDeleted(id: String) async throws -> Int64 {
        let inner = try await runSQL("""
            UPDATE clips SET deleted = 1, updated_at = unixepoch()
            WHERE id = ?
            RETURNING updated_at
            """,
            params: [id])
        return (inner.results?.first?["updated_at"]?.value as? Int64) ?? 0
    }

    // MARK: - Devices

    func upsertDevice(_ row: DeviceRow) async throws {
        _ = try await runSQL("""
            INSERT INTO devices (device_id, ciphertext, last_seen_at)
            VALUES (?, ?, unixepoch())
            ON CONFLICT(device_id) DO UPDATE SET
              ciphertext = excluded.ciphertext,
              last_seen_at = unixepoch()
            """,
            params: [row.deviceID, row.ciphertext.base64EncodedString()])
    }

    func listDevices() async throws -> [DeviceRow] {
        let inner = try await runSQL(
            "SELECT device_id, ciphertext, last_seen_at FROM devices ORDER BY last_seen_at DESC")
        return (inner.results ?? []).map { row in
            let ciphertext = (row["ciphertext"]?.value as? String)
                .flatMap { Data(base64Encoded: $0) } ?? Data()
            return DeviceRow(deviceID: (row["device_id"]?.value as? String) ?? "",
                             ciphertext: ciphertext,
                             lastSeenAt: (row["last_seen_at"]?.value as? Int64) ?? 0)
        }
    }

    // MARK: - Config

    func getConfig(key: String) async throws -> String? {
        let inner = try await runSQL(
            "SELECT value FROM config WHERE key = ?", params: [key])
        return inner.results?.first?["value"]?.value as? String
    }

    func putConfigIfAbsent(key: String, value: String) async throws -> Bool {
        // Fix C: idempotent.
        let inner = try await runSQL(
            "INSERT OR IGNORE INTO config (key, value) VALUES (?, ?)",
            params: [key, value])
        return (inner.meta?.rows_written ?? 0) > 0
    }

    // MARK: - Helpers

    static func cloudRowFrom(_ row: [String: AnyCodable]) -> CloudRow {
        let ciphertext = (row["ciphertext"]?.value as? String)
            .flatMap { Data(base64Encoded: $0) } ?? Data()
        return CloudRow(
            id: (row["id"]?.value as? String) ?? "",
            hmac: (row["hmac"]?.value as? String) ?? "",
            ciphertext: ciphertext,
            kind: (row["kind"]?.value as? String) ?? "text",
            blobKey: row["blob_key"]?.value as? String,
            byteSize: Int((row["byte_size"]?.value as? Int64) ?? 0),
            deviceID: (row["device_id"]?.value as? String) ?? "",
            createdAt: (row["created_at"]?.value as? Int64) ?? 0,
            updatedAt: (row["updated_at"]?.value as? Int64) ?? 0,
            deleted: ((row["deleted"]?.value as? Int64) ?? 0) != 0
        )
    }
}
