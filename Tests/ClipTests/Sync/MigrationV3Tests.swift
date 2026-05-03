import XCTest
import GRDB
@testable import Clip

final class MigrationV3Tests: XCTestCase {
    func testV3AddsExpectedColumnsToItems() throws {
        let s = try HistoryStore.inMemory()
        try s.pool.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(items)").map { $0["name"] as String }
            XCTAssertTrue(cols.contains("cloud_id"))
            XCTAssertTrue(cols.contains("cloud_updated_at"))
            XCTAssertTrue(cols.contains("cloud_synced_at"))
            XCTAssertTrue(cols.contains("cloud_blob_key"))
            XCTAssertTrue(cols.contains("sync_excluded"))
            XCTAssertTrue(cols.contains("device_id"))
        }
    }

    func testV3CreatesSyncTables() throws {
        let s = try HistoryStore.inMemory()
        try s.pool.read { db in
            let names = try String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            XCTAssertTrue(names.contains("tombstones"))
            XCTAssertTrue(names.contains("sync_queue"))
            XCTAssertTrue(names.contains("sync_state"))
        }
    }

    func testV3UniqueCloudIdIndex() throws {
        let s = try HistoryStore.inMemory()
        try s.pool.read { db in
            let idx = try String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type='index'")
            XCTAssertTrue(idx.contains("idx_items_cloud_id"))
        }
    }

    func testV3DefaultExcludedZero() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try s.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT sync_excluded FROM items LIMIT 1"), 0)
        }
    }
}
