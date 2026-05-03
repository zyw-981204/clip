import XCTest
@testable import Clip

final class KeychainStoreTests: XCTestCase {
    var service: String!
    var store: KeychainStore!

    override func setUp() {
        super.setUp()
        service = "com.zyw.clip.test.\(UUID().uuidString)"
        store = KeychainStore(service: service)
    }
    override func tearDown() {
        try? store.delete(account: "master")
        super.tearDown()
    }

    func testReadMissingReturnsNil() throws {
        XCTAssertNil(try store.read(account: "master"))
    }

    func testWriteThenRead() throws {
        let data = Data(repeating: 0x42, count: 32)
        try store.write(account: "master", data: data)
        XCTAssertEqual(try store.read(account: "master"), data)
    }

    func testOverwriteUpdates() throws {
        try store.write(account: "master", data: Data([0x01, 0x02]))
        try store.write(account: "master", data: Data([0x03, 0x04, 0x05]))
        XCTAssertEqual(try store.read(account: "master"), Data([0x03, 0x04, 0x05]))
    }

    func testDelete() throws {
        try store.write(account: "master", data: Data([0xFF]))
        try store.delete(account: "master")
        XCTAssertNil(try store.read(account: "master"))
    }
}
