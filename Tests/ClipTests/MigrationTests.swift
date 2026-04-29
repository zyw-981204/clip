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
}
