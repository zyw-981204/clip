import XCTest
@testable import Clip

final class SyncQueueTests: XCTestCase {
    func testEnqueueDequeueOrderByNextTryAt() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putClip, targetKey: "1", at: 100)
        try q.enqueue(op: .putClip, targetKey: "2", at: 50)
        try q.enqueue(op: .putClip, targetKey: "3", at: 200)
        let r1 = try XCTUnwrap(try q.dequeueDueAt(now: 1000))
        XCTAssertEqual(r1.targetKey, "2")
        try q.delete(id: r1.id)
        let r2 = try XCTUnwrap(try q.dequeueDueAt(now: 1000))
        XCTAssertEqual(r2.targetKey, "1")
    }

    func testDequeueRespectsNextTryAt() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putClip, targetKey: "future", at: 1000)
        XCTAssertNil(try q.dequeueDueAt(now: 500))
        XCTAssertNotNil(try q.dequeueDueAt(now: 1500))
    }

    func testRecordFailureExponentialBackoff() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putClip, targetKey: "x", at: 100)
        let r = try XCTUnwrap(try q.dequeueDueAt(now: 1000))
        try q.recordFailure(id: r.id, attempts: 1, error: "boom", at: 1000)
        // attempts=1 → backoff 2s
        XCTAssertNil(try q.dequeueDueAt(now: 1001))
        XCTAssertNotNil(try q.dequeueDueAt(now: 1002))
    }

    func testBackoffCappedAt900() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putClip, targetKey: "x", at: 0)
        let r = try XCTUnwrap(try q.dequeueDueAt(now: 1000))
        try q.recordFailure(id: r.id, attempts: 20, error: "boom", at: 1000)
        XCTAssertNil(try q.dequeueDueAt(now: 1899))
        XCTAssertNotNil(try q.dequeueDueAt(now: 1900))
    }

    func testDeleteAllForItem() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putClip, targetKey: "5", at: 0)
        try q.enqueue(op: .putBlob, targetKey: "5", at: 0)
        try q.enqueue(op: .putTomb, targetKey: "x", at: 0)
        try q.deleteAllForItem(itemID: 5)
        XCTAssertEqual(try q.peekAll().count, 1)
        XCTAssertEqual(try q.peekAll().first?.op, .putTomb)
    }
}
