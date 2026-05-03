import Foundation

/// Filesystem-backed BlobStore. Each key becomes a nested file under `root`.
/// Used in unit / integration tests so SyncEngine can run without network.
final class LocalDirBlobStore: CloudSyncBlobStore, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root }

    private func url(for key: String) -> URL {
        root.appendingPathComponent(key)
    }

    func putBlob(key: String, body: Data) async throws {
        let u = url(for: key)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: u, options: .atomic)
    }

    func getBlob(key: String) async throws -> Data? {
        let u = url(for: key)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    func deleteBlob(key: String) async throws {
        let u = url(for: key)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }
}
