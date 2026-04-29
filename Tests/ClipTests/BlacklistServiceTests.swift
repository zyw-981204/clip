import XCTest
@testable import Clip

final class BlacklistServiceTests: XCTestCase {
    func testCurrentSetIsEmptyOnFreshStore() throws {
        let store = try HistoryStore.inMemory()
        let svc = BlacklistService(store: store)
        XCTAssertEqual(try svc.currentSet(), [])
    }
}
