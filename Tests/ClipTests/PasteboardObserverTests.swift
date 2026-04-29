import XCTest
import AppKit
@testable import Clip

// MARK: - FakePasteboardSource behavioural tests (Task 25)

final class FakePasteboardSourceTests: XCTestCase {
    func testPushIncrementsChangeCountAndStoresPayload() {
        let fake = FakePasteboardSource()
        XCTAssertEqual(fake.changeCount, 0)

        fake.push(string: "hello")
        XCTAssertEqual(fake.changeCount, 1)
        XCTAssertEqual(fake.string(forType: .string), "hello")
        XCTAssertEqual(fake.types(), [.string])
        XCTAssertEqual(fake.data(forType: .string), Data("hello".utf8))

        fake.push(string: "world", types: [.string, PrivacyFilter.concealedUTI])
        XCTAssertEqual(fake.changeCount, 2)
        XCTAssertEqual(fake.string(forType: .string), "world")
        XCTAssertTrue(fake.types().contains(PrivacyFilter.concealedUTI))
    }
}

// MARK: - PasteboardObserver tests (Tasks 26-32)

final class PasteboardObserverTests: XCTestCase {

    // Task 26: basic tick inserts one row
    func testTickInsertsOneItemForNewPasteboardChange() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: "com.apple.Safari", name: "Safari") }
        )

        fake.push(string: "hello")
        let inserted = try observer.tick(now: 1_700_000_000)
        XCTAssertTrue(inserted)

        let items = try store.listRecent()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].content, "hello")
        XCTAssertEqual(items[0].sourceBundleID, "com.apple.Safari")
        XCTAssertEqual(items[0].sourceAppName, "Safari")
        XCTAssertEqual(items[0].createdAt, 1_700_000_000)
    }

    func testTickWithNoChangeReturnsFalse() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        // No push -> changeCount unchanged.
        XCTAssertFalse(try observer.tick(now: 1))
        XCTAssertEqual(try store.listRecent().count, 0)
    }

    // Task 27: privacy filter integration
    func testTickSkipsConcealedUTI() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: "com.x", name: "X") }
        )
        fake.push(string: "secret-password",
                  types: [.string, PrivacyFilter.concealedUTI])
        XCTAssertFalse(try observer.tick(now: 100))
        XCTAssertEqual(try store.listRecent().count, 0)
    }

    func testTickSkipsEmptyContent() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        fake.push(string: "   \n  ")
        XCTAssertFalse(try observer.tick(now: 1))
        XCTAssertEqual(try store.listRecent().count, 0)
    }

    // Task 28: internal-paste UTI self-loop guard
    func testTickSkipsInternalPasteUTIToPreventSelfLoop() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: "com.zyw.clip", name: "Clip") }
        )
        fake.push(string: "we just pasted this ourselves",
                  types: [.string, PrivacyFilter.internalUTI])
        XCTAssertFalse(try observer.tick(now: 1))
        XCTAssertEqual(try store.listRecent().count, 0)
    }

    // Task 29: blacklist integration
    func testTickSkipsWhenFrontmostBundleIsBlacklisted() throws {
        let store = try HistoryStore.inMemory()
        let svc = BlacklistService(store: store)
        try svc.add(bundleID: "com.agilebits.onepassword7", displayName: "1Password")
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { (try? svc.currentSet()) ?? [] },
            frontmost: { (bundleID: "com.agilebits.onepassword7", name: "1Password") }
        )
        fake.push(string: "hunter2")
        XCTAssertFalse(try observer.tick(now: 1))
        XCTAssertEqual(try store.listRecent().count, 0)
    }

    func testTickAcceptsWhenFrontmostBundleIsNotBlacklisted() throws {
        let store = try HistoryStore.inMemory()
        let svc = BlacklistService(store: store)
        try svc.add(bundleID: "com.agilebits.onepassword7", displayName: "1Password")
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { (try? svc.currentSet()) ?? [] },
            frontmost: { (bundleID: "com.apple.Safari", name: "Safari") }
        )
        fake.push(string: "ok-content")
        XCTAssertTrue(try observer.tick(now: 1))
        XCTAssertEqual(try store.listRecent().count, 1)
    }

    // Task 30: 256KB truncate
    func testTick300KStringTruncatesAt256KB() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        let big = String(repeating: "a", count: 300_000)
        fake.push(string: big)
        XCTAssertTrue(try observer.tick(now: 1))

        let items = try store.listRecent()
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].truncated)
        XCTAssertEqual(items[0].byteSize, 256 * 1024)
        XCTAssertEqual(items[0].content.utf8.count, 256 * 1024)
    }

    // Task 31: 5MB hard skip
    func testTickSkipsOversizedDataWithoutReadingString() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        var stringWasRead = false

        // Subclass-style hook: wrap the fake to record string reads.
        final class ProbeFake: PasteboardSource {
            let inner: FakePasteboardSource
            var onStringRead: () -> Void = {}
            init(_ inner: FakePasteboardSource) { self.inner = inner }
            var changeCount: Int { inner.changeCount }
            func types() -> [NSPasteboard.PasteboardType] { inner.types() }
            func string(forType t: NSPasteboard.PasteboardType) -> String? {
                onStringRead(); return inner.string(forType: t)
            }
            func data(forType t: NSPasteboard.PasteboardType) -> Data? { inner.data(forType: t) }
        }
        let probe = ProbeFake(fake)
        probe.onStringRead = { stringWasRead = true }

        let observer = PasteboardObserver(
            source: probe, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        let huge = Data(repeating: 0x61, count: 6 * 1024 * 1024) // 6 MB > 5 MB cap
        fake.pushDataOnly(data: huge, types: [.string])

        XCTAssertFalse(try observer.tick(now: 1))
        XCTAssertEqual(try store.listRecent().count, 0)
        XCTAssertFalse(stringWasRead, "observer must skip via data size before reading string")
    }

    // Task 32: dedup via insertOrPromote
    func testRepeatedSameContentBumpsCreatedAtAndKeepsOneRow() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        fake.push(string: "hello")
        XCTAssertTrue(try observer.tick(now: 100))
        fake.push(string: "hello")  // changeCount bumps but content_hash matches
        XCTAssertTrue(try observer.tick(now: 200))

        let items = try store.listRecent()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].createdAt, 200)
    }

    // MARK: - Image branch (v2)

    /// PNG bytes on the pasteboard → image row + new clip_blobs entry.
    func testPngImageInsertsImageRowAndBlob() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: "com.app", name: "App") }
        )
        let bytes = Data((0..<512).map { UInt8($0 % 256) })
        fake.pushImage(bytes: bytes, type: .png)

        XCTAssertTrue(try observer.tick(now: 100))

        let items = try store.listRecent()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .image)
        XCTAssertEqual(items[0].mimeType, "image/png")
        XCTAssertEqual(items[0].byteSize, bytes.count)
        XCTAssertEqual(items[0].sourceBundleID, "com.app")
    }

    /// Same image bytes copied twice → single blob, items row promoted.
    func testRepeatedImageBumpsCreatedAtAndDedupsBlob() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        let bytes = Data(repeating: 0xAB, count: 256)

        fake.pushImage(bytes: bytes, type: .png)
        XCTAssertTrue(try observer.tick(now: 100))
        fake.pushImage(bytes: bytes, type: .png)
        XCTAssertTrue(try observer.tick(now: 200))

        let items = try store.listRecent()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].createdAt, 200)
        let blobCount = try store.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_blobs") ?? -1
        }
        XCTAssertEqual(blobCount, 1)
    }

    /// Image > 5MB is silently dropped (no items row, no blob).
    func testImageLargerThanHardSkipIsDropped() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        let bytes = Data(count: PasteboardObserver.hardSkipBytes + 1)
        fake.pushImage(bytes: bytes, type: .png)

        XCTAssertFalse(try observer.tick(now: 100))
        XCTAssertEqual(try store.listRecent().count, 0)
    }

    /// When both text and image are on the pasteboard, text wins (most
    /// "copy from web page" scenarios).
    func testTextWinsWhenBothPresent() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        // Manually wire a multi-type push.
        fake.changeCount += 1
        fake.typesByCount[fake.changeCount] = [.string, .png]
        fake.stringByCount[fake.changeCount] = "hello"
        fake.dataByCountType[fake.changeCount] = [
            .string: Data("hello".utf8),
            .png:    Data(repeating: 0xCC, count: 64),
        ]

        XCTAssertTrue(try observer.tick(now: 100))

        let items = try store.listRecent()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .text)
        XCTAssertEqual(items[0].content, "hello")
    }

    /// concealed/transient/auto-gen markers must skip image clips just like
    /// text clips.
    func testConcealedMarkerSkipsImageToo() throws {
        let store = try HistoryStore.inMemory()
        let fake = FakePasteboardSource()
        let observer = PasteboardObserver(
            source: fake, store: store,
            filter: { PrivacyFilter() },
            blacklist: { [] },
            frontmost: { (bundleID: nil, name: nil) }
        )
        let bytes = Data((0..<32).map { UInt8($0) })
        fake.changeCount += 1
        fake.typesByCount[fake.changeCount] = [.png, PrivacyFilter.concealedUTI]
        fake.dataByCountType[fake.changeCount] = [.png: bytes]

        XCTAssertFalse(try observer.tick(now: 100))
        XCTAssertEqual(try store.listRecent().count, 0)
    }
}
