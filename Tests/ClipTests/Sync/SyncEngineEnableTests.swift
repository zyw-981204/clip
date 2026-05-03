import XCTest
@testable import Clip

final class SyncEngineEnableTests: XCTestCase {
    func makeDS() throws -> LocalSqliteDataSource {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        return ds
    }

    func testFirstDeviceWritesSaltAndDerivesKey() async throws {
        let ds = try makeDS()
        let store = try HistoryStore.inMemory()
        let kc = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")
        defer { try? kc.delete(account: "master") }

        let result = try await SyncEngine.enableSync(
            password: "correct-horse-battery-staple",
            dataSource: ds,
            state: SyncStateStore(store: store),
            keychain: kc, account: "master")

        XCTAssertEqual(result, .firstDevice)
        let salt = try await ds.getConfig(key: "kdf_salt_b64")
        XCTAssertNotNil(salt)
        let iters = try await ds.getConfig(key: "kdf_iters")
        XCTAssertEqual(iters, "200000")
        let schemaV = try await ds.getConfig(key: "schema_version")
        XCTAssertEqual(schemaV, "3")
        let masterKey = try kc.read(account: "master")
        XCTAssertNotNil(masterKey)
    }

    func testSecondDeviceJoinsAndDerivesSameKey() async throws {
        let ds = try makeDS()
        let kcA = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")
        let kcB = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")
        defer { try? kcA.delete(account: "master"); try? kcB.delete(account: "master") }

        _ = try await SyncEngine.enableSync(
            password: "correct-horse-battery-staple",
            dataSource: ds,
            state: SyncStateStore(store: try HistoryStore.inMemory()),
            keychain: kcA, account: "master")
        let masterA = try kcA.read(account: "master")

        let result = try await SyncEngine.enableSync(
            password: "correct-horse-battery-staple",
            dataSource: ds,
            state: SyncStateStore(store: try HistoryStore.inMemory()),
            keychain: kcB, account: "master")

        XCTAssertEqual(result, .joinedExisting)
        let masterB = try kcB.read(account: "master")
        XCTAssertEqual(masterB, masterA, "same password+salt → same key")
    }

    func testSchemaVersionGuardThrowsWhenRemoteNewer() async throws {
        let ds = try makeDS()
        // Manually bump remote schema_version
        _ = try await ds.putConfigIfAbsent(key: "schema_version", value: "999")
        let kc = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")
        defer { try? kc.delete(account: "master") }

        do {
            _ = try await SyncEngine.enableSync(
                password: "x", dataSource: ds,
                state: SyncStateStore(store: try HistoryStore.inMemory()),
                keychain: kc, account: "master")
            XCTFail("expected throw")
        } catch SyncError.remoteSchemaNewer(let r, let l) {
            XCTAssertEqual(r, "999")
            XCTAssertEqual(l, "3")
        }
    }

    func testVerifyRemoteSchemaThrowsWhenRemoteNewer() async throws {
        let ds = try makeDS()
        _ = try await ds.putConfigIfAbsent(key: "schema_version", value: "999")
        do {
            try await SyncEngine.verifyRemoteSchema(dataSource: ds)
            XCTFail("expected throw")
        } catch SyncError.remoteSchemaNewer(let r, let l) {
            XCTAssertEqual(r, "999"); XCTAssertEqual(l, "3")
        }
    }

    func testVerifyRemoteSchemaPassesWhenEqual() async throws {
        let ds = try makeDS()
        _ = try await ds.putConfigIfAbsent(key: "schema_version", value: "3")
        try await SyncEngine.verifyRemoteSchema(dataSource: ds)   // no throw
    }
}
