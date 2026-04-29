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
        fatalError("implemented in Task 5")
    }

    static func contentHash(of s: String) -> String {
        fatalError("implemented in Task 6")
    }
}
