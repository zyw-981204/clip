import Foundation

/// D1 abstraction. Spec §4.2. Two-table model (clips + devices) plus a
/// generic config KV. Implementations: D1Backend (production),
/// LocalSqliteDataSource (tests).
protocol CloudSyncDataSource: Sendable {
    /// Idempotent: `CREATE TABLE IF NOT EXISTS` for clips/devices/config
    /// + indices. Run on every SyncEngine cold start.
    func ensureSchema() async throws

    // Clips
    /// UPSERT (INSERT ... ON CONFLICT(id) DO UPDATE). Returns server-side
    /// `updated_at` from RETURNING clause.
    func upsertClip(_ row: CloudRow) async throws -> Int64

    /// Lookup for hmac-based dedup. **Returns even deleted=1 rows** so that
    /// re-toggling exclude reuses the same cloud_id (spec §6.3 fix B).
    func queryClipByHmac(_ hmac: String) async throws -> (id: String, deleted: Bool)?

    /// Composite-cursor pull (spec §7.3 fix A).
    func queryClipsChangedSince(cursor: CloudCursor, limit: Int) async throws -> [CloudRow]

    /// Soft-delete: UPDATE deleted=1, updated_at=unixepoch() WHERE id=?
    /// Returns the new updated_at.
    func setClipDeleted(id: String) async throws -> Int64

    // Devices
    func upsertDevice(_ row: DeviceRow) async throws
    func listDevices() async throws -> [DeviceRow]

    // Config (KDF salt, schema_version, etc.)
    func getConfig(key: String) async throws -> String?
    /// Returns true iff the row was INSERTed (we won the race);
    /// false if it already existed (someone else won).
    func putConfigIfAbsent(key: String, value: String) async throws -> Bool
}
