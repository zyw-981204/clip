import Foundation
import CryptoKit

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
        fatalError("implemented in Task 6")
    }
}
