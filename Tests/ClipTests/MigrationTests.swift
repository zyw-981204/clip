import XCTest
import GRDB
@testable import Clip

final class MigrationTests: XCTestCase {
    func testV1CreatesTablesAndIndexes() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(&migrator)
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.tableExists("items"))
            XCTAssertTrue(try db.tableExists("blacklist"))

            let itemCols = try db.columns(in: "items").map(\.name)
            for col in ["id", "content", "content_hash", "source_bundle_id",
                        "source_app_name", "created_at", "pinned",
                        "byte_size", "truncated"] {
                XCTAssertTrue(itemCols.contains(col), "missing items.\(col)")
            }

            let idxNames = try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='items'"
            ).compactMap { $0["name"] as String? }
            XCTAssertTrue(idxNames.contains("idx_items_created"))
            XCTAssertTrue(idxNames.contains("idx_items_hash"))
            XCTAssertTrue(idxNames.contains("idx_items_pinned"))
        }
    }

    func testV2AddsKindBlobIDMimeAndClipBlobsTable() throws {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        Migrations.register(&migrator)
        try migrator.migrate(queue)

        try queue.read { db in
            let itemCols = try db.columns(in: "items").map(\.name)
            for col in ["kind", "blob_id", "mime_type"] {
                XCTAssertTrue(itemCols.contains(col), "missing items.\(col)")
            }
            XCTAssertTrue(try db.tableExists("clip_blobs"))
            let blobCols = try db.columns(in: "clip_blobs").map(\.name)
            for col in ["id", "sha256", "bytes", "byte_size", "created_at"] {
                XCTAssertTrue(blobCols.contains(col), "missing clip_blobs.\(col)")
            }
            let idxs = try Row.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='index'"
            ).compactMap { $0["name"] as String? }
            XCTAssertTrue(idxs.contains("idx_blobs_sha256"))
            XCTAssertTrue(idxs.contains("idx_items_kind"))
        }
    }

    /// v1-era data must survive the v2 migration intact, including default
    /// `kind = 'text'` so existing rows render as text.
    func testV2PreservesV1RowsWithKindDefaultingToText() throws {
        let queue = try DatabaseQueue()
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    content TEXT NOT NULL, content_hash TEXT NOT NULL,
                    source_bundle_id TEXT, source_app_name TEXT,
                    created_at INTEGER NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    byte_size INTEGER NOT NULL,
                    truncated INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(sql: "CREATE TABLE blacklist (bundle_id TEXT PRIMARY KEY, display_name TEXT NOT NULL, added_at INTEGER NOT NULL);")
        }
        try v1Only.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO items
                    (content, content_hash, created_at, pinned, byte_size, truncated)
                VALUES (?, ?, ?, 0, ?, 0)
                """,
                arguments: ["legacy", "h1", 100, 6]
            )
        }

        // Now run the full migrator (v1 already applied → only v2 runs).
        var migrator = DatabaseMigrator()
        Migrations.register(&migrator)
        try migrator.migrate(queue)

        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM items WHERE content_hash = 'h1'")
            XCTAssertNotNil(row)
            XCTAssertEqual(row?["kind"] as String?, "text")
            XCTAssertNil(row?["blob_id"] as Int64?)
            XCTAssertNil(row?["mime_type"] as String?)
        }
    }
}
