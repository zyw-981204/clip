import Foundation

/// R2 blob abstraction — only PUT/GET/DELETE (no list, no head).
/// Spec §4.4. Implementations: R2BlobBackend (production),
/// LocalDirBlobStore (tests).
protocol CloudSyncBlobStore: Sendable {
    func putBlob(key: String, body: Data) async throws
    func getBlob(key: String) async throws -> Data?    // nil = 404
    func deleteBlob(key: String) async throws           // idempotent
}
