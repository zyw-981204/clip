import Foundation

/// One row in `sync_queue.op`.
enum SyncOp: String, CaseIterable, Sendable {
    case putClip   = "put_clip"
    case putBlob   = "put_blob"
    case putTomb   = "put_tomb"
    case putDevice = "put_device"
}

/// Mirrors a row in the D1 `clips` table.
struct CloudRow: Sendable, Equatable {
    var id: String              // UUID, primary key (plaintext)
    var hmac: String            // HMAC(content_hash, kName) (plaintext, indexed)
    var ciphertext: Data        // ChaChaPoly sealed JSON of RowPayload
    var kind: String            // "text" | "image"
    var blobKey: String?        // R2 object key for image; nil for text
    var byteSize: Int           // plaintext content size
    var deviceID: String        // last writer
    var createdAt: Int64
    var updatedAt: Int64        // server-side bumped on UPSERT
    var deleted: Bool           // tombstone flag
}

/// Mirrors a row in the D1 `devices` table.
struct DeviceRow: Sendable, Equatable {
    var deviceID: String
    var ciphertext: Data        // sealed JSON of DevicePayload
    var lastSeenAt: Int64
}

/// Composite pull cursor (spec §7.3 "fix A"). Encodes as
/// "<unix_sec>:<id_uuid>"; deserialize tolerates garbage by returning .zero.
struct CloudCursor: Sendable, Equatable {
    var updatedAt: Int64
    var id: String

    static let zero = CloudCursor(updatedAt: 0, id: "")

    var serialized: String { "\(updatedAt):\(id)" }

    init(updatedAt: Int64, id: String) {
        self.updatedAt = updatedAt
        self.id = id
    }

    init(serialized: String) {
        guard let colon = serialized.firstIndex(of: ":"),
              let ts = Int64(serialized[..<colon])
        else {
            self = .zero
            return
        }
        self.updatedAt = ts
        self.id = String(serialized[serialized.index(after: colon)...])
    }
}

/// Cloud object key construction (R2 side only — D1 uses table/column names).
enum CloudKey {
    static let blobsPrefix = "blobs/"
    static func blobKey(name: String) -> String { blobsPrefix + name + ".bin" }
}
