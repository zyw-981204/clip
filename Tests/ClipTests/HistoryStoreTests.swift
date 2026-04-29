import XCTest
import GRDB
@testable import Clip

final class HistoryStoreTests: XCTestCase {
    // Shared helper used across all HistoryStore tests in this class.
    func makeItem(content: String, at ts: Int64, pinned: Bool = false) -> ClipItem {
        ClipItem(
            id: nil,
            content: content,
            contentHash: ClipItem.contentHash(of: content),
            sourceBundleID: nil,
            sourceAppName: nil,
            createdAt: ts,
            pinned: pinned,
            byteSize: ClipItem.byteSize(of: content),
            truncated: false
        )
    }

    func testInsertAndListRecentPinnedFirst() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(makeItem(content: "a", at: 100, pinned: false))
        try s.insert(makeItem(content: "b", at: 200, pinned: true))
        try s.insert(makeItem(content: "c", at: 300, pinned: false))

        let items = try s.listRecent()
        // Pinned first, then non-pinned by created_at DESC.
        XCTAssertEqual(items.map(\.content), ["b", "c", "a"])
        XCTAssertEqual(items[0].pinned, true)
        XCTAssertEqual(items[1].pinned, false)
        XCTAssertEqual(items[2].pinned, false)
    }

    func testListRecentRespectsLimit() throws {
        let s = try HistoryStore.inMemory()
        for i in 0..<5 {
            try s.insert(makeItem(content: "item\(i)", at: Int64(100 + i)))
        }
        let items = try s.listRecent(limit: 3)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.content), ["item4", "item3", "item2"])
    }

    func testInsertOrPromoteBumpsExistingHash() throws {
        let s = try HistoryStore.inMemory()
        let it = makeItem(content: "hello", at: 100)
        let id1 = try s.insertOrPromote(it, now: 100)
        let id2 = try s.insertOrPromote(it, now: 200)

        XCTAssertEqual(id1, id2, "same content_hash should reuse the row")

        let items = try s.listRecent()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].createdAt, 200, "row should be bumped to now")
    }

    func testInsertOrPromoteIgnoresWhitespaceForDedup() throws {
        let s = try HistoryStore.inMemory()
        let id1 = try s.insertOrPromote(makeItem(content: "hello", at: 100), now: 100)
        let id2 = try s.insertOrPromote(makeItem(content: "  hello  \n", at: 200), now: 200)

        XCTAssertEqual(id1, id2, "trim-equivalent content shares one row")
        XCTAssertEqual(try s.listRecent().count, 1)
    }

    func testInsertOrPromoteInsertsWhenNoMatch() throws {
        let s = try HistoryStore.inMemory()
        _ = try s.insertOrPromote(makeItem(content: "a", at: 100), now: 100)
        _ = try s.insertOrPromote(makeItem(content: "b", at: 200), now: 200)
        XCTAssertEqual(try s.listRecent().count, 2)
    }

    func testSearchSubstringCaseInsensitive() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(makeItem(content: "Hello World", at: 100))
        try s.insert(makeItem(content: "GoodBye",     at: 200))
        try s.insert(makeItem(content: "hello there", at: 300))

        let hits = try s.search(query: "HELLO").map(\.content)
        XCTAssertEqual(Set(hits), Set(["Hello World", "hello there"]))
    }

    func testSearchEmptyQueryReturnsRecent() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(makeItem(content: "a", at: 100))
        try s.insert(makeItem(content: "b", at: 200))
        XCTAssertEqual(try s.search(query: "").map(\.content), ["b", "a"])
    }

    func testSearchEscapesPercentLiteral() throws {
        // "50%" must match the row containing literal "50%", not "50something".
        let s = try HistoryStore.inMemory()
        try s.insert(makeItem(content: "buy 50% off",      at: 100))
        try s.insert(makeItem(content: "version 50.1.0",   at: 200))
        let hits = try s.search(query: "50%").map(\.content)
        XCTAssertEqual(hits, ["buy 50% off"])
    }

    func testSearchEscapesUnderscoreLiteral() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(makeItem(content: "snake_case_id",    at: 100))
        try s.insert(makeItem(content: "snakeXcaseXid",    at: 200))
        let hits = try s.search(query: "snake_case").map(\.content)
        XCTAssertEqual(hits, ["snake_case_id"])
    }

    func testSearchPinnedFirstWithinResults() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(makeItem(content: "hello a", at: 100, pinned: false))
        try s.insert(makeItem(content: "hello b", at: 200, pinned: true))
        try s.insert(makeItem(content: "hello c", at: 300, pinned: false))
        let hits = try s.search(query: "hello").map(\.content)
        XCTAssertEqual(hits, ["hello b", "hello c", "hello a"])
    }

    func testTogglePinFlipsBothDirections() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(makeItem(content: "x", at: 100, pinned: false))

        try s.togglePin(id: id)
        XCTAssertEqual(try s.listRecent().first?.pinned, true)

        try s.togglePin(id: id)
        XCTAssertEqual(try s.listRecent().first?.pinned, false)
    }

    func testTogglePinUnknownIDIsNoOp() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(makeItem(content: "x", at: 100))
        XCTAssertNoThrow(try s.togglePin(id: 9999))
        XCTAssertEqual(try s.listRecent().first?.pinned, false)
    }

    func testDeleteRemovesRow() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(makeItem(content: "delete-me", at: 100))
        try s.insert(makeItem(content: "keep-me", at: 200))

        try s.delete(id: id)

        let remaining = try s.listRecent().map(\.content)
        XCTAssertEqual(remaining, ["keep-me"])
    }

    func testDeleteUnknownIDIsNoOp() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(makeItem(content: "a", at: 100))
        XCTAssertNoThrow(try s.delete(id: 9999))
        XCTAssertEqual(try s.listRecent().count, 1)
    }

    func testPruneByCountKeepsNewestNonPinned() throws {
        let s = try HistoryStore.inMemory()
        // Insert 10 non-pinned items at increasing timestamps.
        for i in 0..<10 {
            try s.insert(makeItem(content: "n\(i)", at: Int64(100 + i)))
        }
        // Keep newest 3, age cap effectively disabled (very large window).
        try s.prune(now: 200, maxCount: 3, maxAgeSeconds: 1_000_000)

        let remaining = try s.listRecent().map(\.content)
        XCTAssertEqual(remaining, ["n9", "n8", "n7"])
    }

    func testPruneByCountExemptsPinned() throws {
        let s = try HistoryStore.inMemory()
        // 5 pinned + 10 non-pinned. Cap non-pinned to 2.
        for i in 0..<5 {
            try s.insert(makeItem(content: "p\(i)", at: Int64(100 + i), pinned: true))
        }
        for i in 0..<10 {
            try s.insert(makeItem(content: "n\(i)", at: Int64(200 + i), pinned: false))
        }
        try s.prune(now: 1000, maxCount: 2, maxAgeSeconds: 1_000_000)

        let remaining = try s.listRecent(limit: 100)
        let pinned = remaining.filter(\.pinned).map(\.content).sorted()
        let nonpinned = remaining.filter { !$0.pinned }.map(\.content)
        XCTAssertEqual(pinned, ["p0", "p1", "p2", "p3", "p4"])
        XCTAssertEqual(nonpinned, ["n9", "n8"])
    }

    func testPruneByAgeDropsOldNonPinned() throws {
        let s = try HistoryStore.inMemory()
        let now: Int64 = 30 * 86_400 + 1_000   // arbitrary "now"
        let day: Int64 = 86_400

        // Boundary cases relative to a 30-day window:
        try s.insert(makeItem(content: "old-31d-non",     at: now - 31 * day, pinned: false))
        try s.insert(makeItem(content: "exactly-30d-non", at: now - 30 * day, pinned: false))
        try s.insert(makeItem(content: "fresh-non",       at: now - 1,        pinned: false))
        try s.insert(makeItem(content: "old-31d-pinned",  at: now - 31 * day, pinned: true))

        try s.prune(now: now, maxCount: 1_000_000, maxAgeSeconds: 30 * day)

        let remaining = try s.listRecent(limit: 100).map(\.content)
        // "old-31d-non" is strictly older than now-30d → dropped.
        // "exactly-30d-non" is at the threshold (created_at == now - cutoff) → kept (uses `<`).
        // pinned old row is exempt → kept.
        XCTAssertEqual(
            Set(remaining),
            Set(["exactly-30d-non", "fresh-non", "old-31d-pinned"])
        )
    }

    func testPruneByAgeWithLargeMaxCountStillExemptsPinned() throws {
        let s = try HistoryStore.inMemory()
        let now: Int64 = 1_000_000
        try s.insert(makeItem(content: "ancient", at: 0, pinned: true))
        try s.prune(now: now, maxCount: 500, maxAgeSeconds: 30 * 86_400)
        XCTAssertEqual(try s.listRecent().map(\.content), ["ancient"])
    }

    func testCorruptedDBIsQuarantinedAndReplaced() throws {
        let dir = NSTemporaryDirectory() + "clip-itest-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let path = dir + "history.sqlite"

        // Write a non-sqlite file at the path.
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: path))

        // Open the store: corruption must be detected, file quarantined,
        // and a fresh empty DB created in its place.
        let s = try HistoryStore(path: path)
        XCTAssertEqual(try s.listRecent().count, 0,
                       "fresh DB should be empty after quarantine")

        // The original file should be renamed with a `.corrupted-<ts>` suffix.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertTrue(
            siblings.contains(where: { $0.hasPrefix("history.sqlite.corrupted-") }),
            "expected a quarantined file in \(dir), got: \(siblings)"
        )
    }

    func testHealthyDBOpensWithoutQuarantine() throws {
        let dir = NSTemporaryDirectory() + "clip-itest-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let path = dir + "history.sqlite"

        // First open: creates valid DB.
        do {
            let s = try HistoryStore(path: path)
            try s.insert(makeItem(content: "keep me", at: 100))
        }
        // Second open: must not quarantine; data must still be there.
        let s2 = try HistoryStore(path: path)
        XCTAssertEqual(try s2.listRecent().map(\.content), ["keep me"])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertFalse(
            siblings.contains(where: { $0.contains(".corrupted-") }),
            "healthy DB must not be quarantined; got: \(siblings)"
        )
    }
}
