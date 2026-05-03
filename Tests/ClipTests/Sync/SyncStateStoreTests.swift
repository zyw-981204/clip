import XCTest
@testable import Clip

final class SyncStateStoreTests: XCTestCase {
    func testGetMissingReturnsNil() throws {
        let s = try HistoryStore.inMemory()
        XCTAssertNil(try SyncStateStore(store: s).get("device_id"))
    }

    func testSetThenGet() throws {
        let s = try HistoryStore.inMemory()
        let kv = SyncStateStore(store: s)
        try kv.set("device_id", "ABC-123")
        XCTAssertEqual(try kv.get("device_id"), "ABC-123")
    }

    func testOverwrite() throws {
        let s = try HistoryStore.inMemory()
        let kv = SyncStateStore(store: s)
        try kv.set("k", "v1")
        try kv.set("k", "v2")
        XCTAssertEqual(try kv.get("k"), "v2")
    }
}
