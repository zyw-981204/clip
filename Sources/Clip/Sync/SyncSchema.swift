import Foundation

/// JSON wire format for `clips.ciphertext` after decryption. Spec §5.3.
/// snake_case for cross-language portability.
struct RowPayload: Codable, Equatable, Sendable {
    var v: Int
    var content: String?       // text only
    var thumbB64: String?      // image only — base64 PNG ≤5KB
    var mimeType: String?      // image only
    var blobSize: Int?         // image only — R2 blob byte count
    var truncated: Bool
    var sourceBundleId: String?
    var sourceAppName: String?
    var pinned: Bool
    var contentHash: String    // duplicates the indexed clips.hmac source

    enum CodingKeys: String, CodingKey {
        case v, content, truncated, pinned
        case thumbB64        = "thumb_b64"
        case mimeType        = "mime_type"
        case blobSize        = "blob_size"
        case sourceBundleId  = "source_bundle_id"
        case sourceAppName   = "source_app_name"
        case contentHash     = "content_hash"
    }
}

/// JSON wire format for `devices.ciphertext` after decryption. Spec §5.4.
struct DevicePayload: Codable, Equatable, Sendable {
    var v: Int
    var displayName: String
    var model: String
    var firstSeenAt: Int64

    enum CodingKeys: String, CodingKey {
        case v, model
        case displayName = "display_name"
        case firstSeenAt = "first_seen_at"
    }
}
