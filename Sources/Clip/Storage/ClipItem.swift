import Foundation
import CryptoKit

/// What's stored in a single history row.
/// - `text`:  `content` holds the captured string. `blobID` / `mimeType` nil.
/// - `image`: `content` holds the empty string. `blobID` references the bytes
///            in `clip_blobs`; `mimeType` records the original pasteboard type
///            ("image/png", "image/tiff", "application/pdf") so paste-back
///            can write the same UTI.
enum ClipKind: String, Equatable {
    case text
    case image
}

struct ClipItem: Identifiable, Equatable {
    var id: Int64?
    var content: String
    var contentHash: String
    var sourceBundleID: String?
    var sourceAppName: String?
    var createdAt: Int64
    var pinned: Bool
    var byteSize: Int
    var truncated: Bool
    var kind: ClipKind = .text
    var blobID: Int64? = nil
    var mimeType: String? = nil

    static func byteSize(of s: String) -> Int {
        s.utf8.count
    }

    static func truncateIfNeeded(_ s: String, limit: Int) -> (String, Bool) {
        let bytes = Array(s.utf8)
        guard bytes.count > limit else { return (s, false) }
        var cut = limit
        // UTF-8 continuation bytes are 10xxxxxx (0x80..0xBF). Back up until cut
        // points at a leading byte so we never split a codepoint.
        while cut > 0 && (bytes[cut] & 0xC0) == 0x80 {
            cut -= 1
        }
        let out = String(decoding: bytes.prefix(cut), as: UTF8.self)
        return (out, true)
    }

    static func contentHash(of s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 over raw bytes — used for blob dedup.
    static func contentHash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
