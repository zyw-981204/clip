import Foundation
import GRDB

final class BlacklistService {
    private let store: HistoryStore
    init(store: HistoryStore) { self.store = store }

    func currentSet() throws -> Set<String> {
        try store.pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT bundle_id FROM blacklist"))
        }
    }

    func list() throws -> [(bundleID: String, displayName: String)] {
        try store.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT bundle_id, display_name FROM blacklist
                ORDER BY display_name COLLATE NOCASE
            """).map { (bundleID: $0["bundle_id"], displayName: $0["display_name"]) }
        }
    }

    func add(bundleID: String, displayName: String) throws {
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO blacklist (bundle_id, display_name, added_at)
                VALUES (?, ?, ?)
            """, arguments: [bundleID, displayName, Int64(Date().timeIntervalSince1970)])
        }
    }

    func remove(bundleID: String) throws {
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM blacklist WHERE bundle_id = ?",
                           arguments: [bundleID])
        }
    }
}
