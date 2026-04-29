import XCTest
@testable import Clip

final class BlacklistServiceTests: XCTestCase {
    func testCurrentSetIsEmptyOnFreshStore() throws {
        let store = try HistoryStore.inMemory()
        let svc = BlacklistService(store: store)
        XCTAssertEqual(try svc.currentSet(), [])
    }

    func testAddThenListAndCurrentSet() throws {
        let store = try HistoryStore.inMemory()
        let svc = BlacklistService(store: store)
        try svc.add(bundleID: "com.agilebits.onepassword7", displayName: "1Password")
        try svc.add(bundleID: "com.bitwarden.desktop", displayName: "Bitwarden")

        XCTAssertEqual(try svc.currentSet(),
                       ["com.agilebits.onepassword7", "com.bitwarden.desktop"])

        let rows = try svc.list()
        XCTAssertEqual(rows.map(\.bundleID),
                       ["com.agilebits.onepassword7", "com.bitwarden.desktop"])
        XCTAssertEqual(rows.map(\.displayName), ["1Password", "Bitwarden"])
    }

    func testAddIsIdempotent() throws {
        let store = try HistoryStore.inMemory()
        let svc = BlacklistService(store: store)
        try svc.add(bundleID: "com.x.app", displayName: "X")
        try svc.add(bundleID: "com.x.app", displayName: "X-renamed")
        XCTAssertEqual(try svc.list().count, 1)
    }

    func testRemoveDeletesEntry() throws {
        let store = try HistoryStore.inMemory()
        let svc = BlacklistService(store: store)
        try svc.add(bundleID: "com.a", displayName: "A")
        try svc.add(bundleID: "com.b", displayName: "B")
        try svc.remove(bundleID: "com.a")
        XCTAssertEqual(try svc.currentSet(), ["com.b"])
    }

    func testRemoveMissingBundleIDIsNoOp() throws {
        let store = try HistoryStore.inMemory()
        let svc = BlacklistService(store: store)
        try svc.add(bundleID: "com.a", displayName: "A")
        XCTAssertNoThrow(try svc.remove(bundleID: "com.never-added"))
        XCTAssertEqual(try svc.currentSet(), ["com.a"])
    }
}
