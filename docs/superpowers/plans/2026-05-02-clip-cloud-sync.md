# Clip Cloud Sync (v3) Implementation Plan — v2 architecture (D1 + R2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add E2E-encrypted cross-Mac clipboard history sync. Cloud uses **Cloudflare D1 + R2**: D1 stores per-row encrypted metadata (text content, mime, pin, etc. inside one ChaChaPoly sealed BLOB column) plus plaintext index columns (id, hmac, kind, blob_key, created_at, updated_at, deleted); R2 stores image blobs only as content-addressed encrypted objects.

**Architecture (paragraph form):** All sync code lives under `Sources/Clip/Sync/` (pure Foundation + CryptoKit, no AppKit) so a future `ClipKit` extraction for an iOS client is mechanical. The cloud side has two separate protocols — `CloudSyncDataSource` (D1 SQL via REST) and `CloudSyncBlobStore` (R2 PUT/GET via S3v4). Pull is a single SQL query each tick: `SELECT * FROM clips WHERE updated_at > ?ts OR (updated_at = ?ts AND id > ?id) ORDER BY updated_at, id LIMIT 100` — composite cursor (updated_at, id) prevents same-second misses (spec §7.3 "fix A"). Push is per-row UPSERT with cloud_id reuse via hmac lookup that includes `deleted=1` rows (spec §6.3 "fix B"), so re-toggling "do not sync" doesn't create cloud duplicates. Encryption is `ChaChaPoly` with a `PBKDF2-HMAC-SHA256` (200k rounds) derived master key, HKDF-split into separate `kEncrypt` and `kName` subkeys; master key in macOS Keychain (`kSecAttrSynchronizable=false`). Schema bootstrap is fully idempotent (`CREATE TABLE IF NOT EXISTS` + `INSERT OR IGNORE` for config rows including `schema_version='3'`; spec §7.1 "fix C"). `SyncEngine.start` reads `schema_version` and refuses to run if remote > local with a clear UI prompt (spec §10.3 "fix E"). Half-completed pushes (R2 PUT succeeds, D1 UPSERT fails) leave a transient orphan blob accepted as known cruft (spec §10.4 "fix D"); retry covers all cases via idempotent same-hmac PUT.

**Tech Stack:** Swift 6.0 / macOS 13+ / SwiftPM single executable. `CryptoKit` (ChaChaPoly, HMAC, HKDF), `CommonCrypto` (PBKDF2 only), `Network.framework` (NWPathMonitor), `GRDB` (existing). New tests live under `Tests/ClipTests/Sync/` inside the existing test target. R2+D1 integration tests live under `Tests/ClipTests/CloudIntegration/` and self-skip when `CLOUDFLARE_API_TOKEN` env is unset.

**Files created (new) — quick map:**

```
Sources/Clip/Sync/
├── KeyDerivation.swift           — PBKDF2 wrapper (CommonCrypto)
├── CryptoBox.swift               — ChaChaPoly seal/open + HMAC namer
├── KeychainStore.swift           — read/write versioned master_key
├── SyncTypes.swift               — CloudRow, DeviceRow, ListPage,
│                                    SyncOp, CloudKey, CloudCursor
├── SyncSchema.swift              — RowPayload / DevicePayload Codable
├── CloudSyncDataSource.swift     — protocol (D1 abstraction)
├── CloudSyncBlobStore.swift      — protocol (R2 blob abstraction)
├── LocalSqliteDataSource.swift   — in-memory SQLite impl for tests
├── LocalDirBlobStore.swift       — filesystem impl for tests
├── S3SignerV4.swift              — AWS Sig V4 (used by R2BlobBackend)
├── R2BlobBackend.swift           — URLSession + Sig V4 (PUT/GET/DELETE only)
├── D1Backend.swift               — Cloudflare REST API client (ensureSchema,
│                                    upsert with hmac dedup, queryChangesSince
│                                    with composite cursor, schema-version check)
├── SyncQueue.swift               — DB-backed retry queue
├── SyncStateStore.swift          — KV wrapper over local sync_state table
├── SyncEngine.swift              — actor; push + pull + enable + fetchBlob +
│                                    backfill + excludeItem
└── SyncSettings.swift            — UserDefaults wrapper for R2/D1 config

Sources/Clip/Preferences/
└── CloudSyncView.swift           — "云同步" preferences tab
                                    (parallel test-connection — fix F)

Tests/ClipTests/Sync/             — unit + LocalSqlite/LocalDir integration
Tests/ClipTests/CloudIntegration/ — opt-in real-D1+R2 round-trip
```

**Files modified:**
- `Sources/Clip/Storage/Migrations.swift` — add v3 migration
- `Sources/Clip/Storage/HistoryStore.swift` — sync columns + hooks + new helpers
- `Sources/Clip/Storage/ClipItem.swift` — 6 new properties
- `Sources/Clip/Preferences/PreferencesWindow.swift` — add "云同步" tab
- `Sources/Clip/Panel/PanelView.swift` — sync status icon
- `Sources/Clip/Panel/PanelModel.swift` — `toggleExcludeSelected()` action
- `Sources/Clip/Panel/PanelWindow.swift` — wire ⌘N
- `Sources/Clip/ClipApp.swift` — wire `SyncEngine` into `AppDelegate`

**TDD discipline:** every task starts with a failing test, then minimal impl, then verify pass, then commit. Don't batch features.

**Commit convention:** `sync: <component> — <one-line summary>`.

**Build / test commands:**

```bash
swift test                                          # full suite
swift test --filter ClipTests.<TestClass>           # single file
swift test --filter ClipTests.CloudIntegration      # opt-in real cloud (needs env)
swift build -c release --product Clip               # release sanity (CI)
```

**Self-review fixes baked in (referenced by ID throughout):**
- **fix A** — composite (updated_at, id) cursor (T13 + T17)
- **fix B** — hmac dedup includes `deleted=1` rows (T13 + T16)
- **fix C** — `INSERT OR IGNORE` config bootstrap (T13 + T18)
- **fix D** — orphan-blob acceptance (T16 — documented; no code work)
- **fix E** — `schema_version` gatekeeping (T13 + T18)
- **fix F** — parallel "test connection" with three-checkmark UI (T24)

---

## Phase P1 — Foundations (storage + crypto)

### Task 1: Migration v3 — local schema additions

**Files:**
- Modify: `Sources/Clip/Storage/Migrations.swift`
- Create: `Tests/ClipTests/Sync/MigrationV3Tests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/MigrationV3Tests.swift
import XCTest
import GRDB
@testable import Clip

final class MigrationV3Tests: XCTestCase {
    func testV3AddsExpectedColumnsToItems() throws {
        let s = try HistoryStore.inMemory()
        try s.pool.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(items)").map { $0["name"] as String }
            XCTAssertTrue(cols.contains("cloud_id"))
            XCTAssertTrue(cols.contains("cloud_updated_at"))
            XCTAssertTrue(cols.contains("cloud_synced_at"))
            XCTAssertTrue(cols.contains("cloud_blob_key"))
            XCTAssertTrue(cols.contains("sync_excluded"))
            XCTAssertTrue(cols.contains("device_id"))
        }
    }

    func testV3CreatesSyncTables() throws {
        let s = try HistoryStore.inMemory()
        try s.pool.read { db in
            let names = try String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            XCTAssertTrue(names.contains("tombstones"))
            XCTAssertTrue(names.contains("sync_queue"))
            XCTAssertTrue(names.contains("sync_state"))
        }
    }

    func testV3UniqueCloudIdIndex() throws {
        let s = try HistoryStore.inMemory()
        try s.pool.read { db in
            let idx = try String.fetchAll(db,
                sql: "SELECT name FROM sqlite_master WHERE type='index'")
            XCTAssertTrue(idx.contains("idx_items_cloud_id"))
        }
    }

    func testV3DefaultExcludedZero() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try s.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT sync_excluded FROM items LIMIT 1"), 0)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.MigrationV3Tests
```

Expected: compile error (no migration v3) or test failure.

- [ ] **Step 3: Append v3 migration block**

In `Sources/Clip/Storage/Migrations.swift`, after the v2 block:

```swift
        // v3: cloud sync columns + tables.
        // Spec: docs/superpowers/specs/2026-05-02-clip-cloud-sync.md §5.1
        migrator.registerMigration("v3") { db in
            // items: 6 new columns
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_id TEXT;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_updated_at INTEGER;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_synced_at INTEGER;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_blob_key TEXT;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN sync_excluded INTEGER NOT NULL DEFAULT 0;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN device_id TEXT;")

            // Partial unique index: enforce 1 cloud_id per row, but allow many NULL
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_items_cloud_id ON items(cloud_id) WHERE cloud_id IS NOT NULL;
            """)

            // tombstones (local-side; prevents capture-side resurrection)
            try db.execute(sql: """
                CREATE TABLE tombstones (
                    content_hash      TEXT PRIMARY KEY,
                    cloud_id          TEXT NOT NULL,
                    tombstoned_at     INTEGER NOT NULL,
                    cloud_updated_at  INTEGER NOT NULL
                );
            """)

            // sync_queue
            try db.execute(sql: """
                CREATE TABLE sync_queue (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    op          TEXT NOT NULL,
                    target_key  TEXT NOT NULL,
                    attempts    INTEGER NOT NULL DEFAULT 0,
                    next_try_at INTEGER NOT NULL,
                    last_error  TEXT,
                    enqueued_at INTEGER NOT NULL
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_sync_queue_next ON sync_queue(next_try_at);")

            // sync_state — generic kv (device_id, cloud_pull_cursor, kdf_*, etc.)
            try db.execute(sql: """
                CREATE TABLE sync_state (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
            """)
        }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.MigrationV3Tests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Storage/Migrations.swift Tests/ClipTests/Sync/MigrationV3Tests.swift
git commit -m "sync: Migration v3 — local schema for D1+R2 cloud sync"
```

---

### Task 2: KeyDerivation — PBKDF2-HMAC-SHA256 wrapper

**Files:**
- Create: `Sources/Clip/Sync/KeyDerivation.swift`
- Create: `Tests/ClipTests/Sync/KeyDerivationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/KeyDerivationTests.swift
import XCTest
@testable import Clip

final class KeyDerivationTests: XCTestCase {
    func testKnownVector() {
        // PBKDF2-HMAC-SHA256(password="password", salt="salt", iters=1, dkLen=32).
        // Pinned via Python hashlib.
        let key = KeyDerivation.pbkdf2_sha256(
            password: "password", salt: Data("salt".utf8),
            iterations: 1, keyLength: 32)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    func testDifferentPasswordYieldsDifferentKey() {
        let salt = Data("salt".utf8)
        let a = KeyDerivation.pbkdf2_sha256(password: "a", salt: salt, iterations: 1000, keyLength: 32)
        let b = KeyDerivation.pbkdf2_sha256(password: "b", salt: salt, iterations: 1000, keyLength: 32)
        XCTAssertNotEqual(a, b)
    }

    func testDifferentSaltYieldsDifferentKey() {
        let a = KeyDerivation.pbkdf2_sha256(password: "x", salt: Data("s1".utf8), iterations: 1000, keyLength: 32)
        let b = KeyDerivation.pbkdf2_sha256(password: "x", salt: Data("s2".utf8), iterations: 1000, keyLength: 32)
        XCTAssertNotEqual(a, b)
    }

    func testCustomKeyLength() {
        let k = KeyDerivation.pbkdf2_sha256(password: "x", salt: Data("s".utf8), iterations: 100, keyLength: 16)
        XCTAssertEqual(k.count, 16)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.KeyDerivationTests
```

Expected: compile error.

- [ ] **Step 3: Implement KeyDerivation**

```swift
// Sources/Clip/Sync/KeyDerivation.swift
import Foundation
import CommonCrypto

/// PBKDF2-HMAC-SHA256 wrapper. Spec §6.1 pins iters=200_000, dkLen=32 for
/// cloud master-key derivation. CryptoKit doesn't expose PBKDF2; CommonCrypto's
/// CCKeyDerivationPBKDF is the canonical Apple-platform implementation.
enum KeyDerivation {
    static func pbkdf2_sha256(
        password: String,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) -> Data {
        let pwBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
        var out = Data(count: keyLength)
        let status = out.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pwBytes, pwBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                outPtr.bindMemory(to: UInt8.self).baseAddress, keyLength
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 failed (status=\(status))")
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.KeyDerivationTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/KeyDerivation.swift Tests/ClipTests/Sync/KeyDerivationTests.swift
git commit -m "sync: KeyDerivation — PBKDF2-HMAC-SHA256 wrapper over CommonCrypto"
```

---

### Task 3: CryptoBox — ChaChaPoly seal/open + HMAC name

**Files:**
- Create: `Sources/Clip/Sync/CryptoBox.swift`
- Create: `Tests/ClipTests/Sync/CryptoBoxTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/CryptoBoxTests.swift
import XCTest
import CryptoKit
@testable import Clip

final class CryptoBoxTests: XCTestCase {
    func makeBox() -> CryptoBox {
        CryptoBox(masterKey: Data(repeating: 0xAB, count: 32))
    }

    func testSealOpenRoundTrip() throws {
        let box = makeBox()
        let plain = Data("hello, world".utf8)
        let sealed = try box.seal(plain)
        XCTAssertEqual(try box.open(sealed), plain)
        XCTAssertGreaterThan(sealed.count, plain.count)
    }

    func testOpenWrongKeyFails() throws {
        let a = makeBox()
        let b = CryptoBox(masterKey: Data(repeating: 0xCD, count: 32))
        let sealed = try a.seal(Data("x".utf8))
        XCTAssertThrowsError(try b.open(sealed))
    }

    func testOpenTamperedFails() throws {
        let box = makeBox()
        var sealed = try box.seal(Data("hello".utf8))
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try box.open(sealed))
    }

    func testNonceUniqueness() throws {
        let box = makeBox()
        var nonces = Set<Data>()
        for _ in 0..<5000 {
            let sealed = try box.seal(Data("same".utf8))
            nonces.insert(sealed.prefix(12))
        }
        XCTAssertEqual(nonces.count, 5000)
    }

    func testNameDeterministic() {
        let box = makeBox()
        XCTAssertEqual(box.name(forContentHash: "abc"), box.name(forContentHash: "abc"))
        XCTAssertNotEqual(box.name(forContentHash: "abc"), box.name(forContentHash: "def"))
        XCTAssertEqual(box.name(forContentHash: "abc").count, 64)
    }

    func testDifferentMasterKeysProduceDifferentNames() {
        let a = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let b = CryptoBox(masterKey: Data(repeating: 0xBB, count: 32))
        XCTAssertNotEqual(a.name(forContentHash: "x"), b.name(forContentHash: "x"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.CryptoBoxTests
```

- [ ] **Step 3: Implement CryptoBox**

```swift
// Sources/Clip/Sync/CryptoBox.swift
import Foundation
import CryptoKit

/// AEAD seal/open + content-hash → cloud filename mapping.
/// Spec §6.1: master_key HKDF-split into:
///   k_encrypt — ChaChaPoly seal/open of row payloads + blob bytes
///   k_name    — HMAC-SHA256(content_hash) → blob filename + cross-device dedup hmac
struct CryptoBox: Sendable {
    enum Error: Swift.Error, Equatable { case decryptionFailed }

    private let kEncrypt: SymmetricKey
    private let kName: SymmetricKey

    init(masterKey: Data) {
        precondition(masterKey.count == 32, "master key must be 32 bytes")
        let masterSym = SymmetricKey(data: masterKey)
        self.kEncrypt = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterSym,
            info: Data("clip.encrypt.v1".utf8),
            outputByteCount: 32)
        self.kName = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterSym,
            info: Data("clip.name.v1".utf8),
            outputByteCount: 32)
    }

    func seal(_ plaintext: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: kEncrypt).combined
    }

    func open(_ sealed: Data) throws -> Data {
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            return try ChaChaPoly.open(box, using: kEncrypt)
        } catch {
            throw Error.decryptionFailed
        }
    }

    /// Hex-encoded HMAC-SHA256(kName, content_hash). 64 chars. Used for both:
    ///   - the D1 `clips.hmac` indexed column (cross-device dedup)
    ///   - the R2 blob key suffix `blobs/<hmac>.bin`
    func name(forContentHash contentHash: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(contentHash.utf8), using: kName)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.CryptoBoxTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/CryptoBox.swift Tests/ClipTests/Sync/CryptoBoxTests.swift
git commit -m "sync: CryptoBox — ChaChaPoly seal/open + HMAC content-hash naming"
```

---

### Task 4: KeychainStore — versioned master_key persistence

**Files:**
- Create: `Sources/Clip/Sync/KeychainStore.swift`
- Create: `Tests/ClipTests/Sync/KeychainStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/KeychainStoreTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.KeychainStoreTests
```

- [ ] **Step 3: Implement KeychainStore**

```swift
// Sources/Clip/Sync/KeychainStore.swift
import Foundation
import Security

/// Wrapper around macOS Keychain `kSecClassGenericPassword`. Spec §6.1
/// mandates `kSecAttrSynchronizable=false` — must NOT sync master key
/// through iCloud Keychain (would put Apple in the trust path).
struct KeychainStore: Sendable {
    let service: String
    init(service: String) { self.service = service }

    enum Error: Swift.Error { case keychain(OSStatus) }

    func read(account: String) throws -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Error.keychain(status) }
        return out as? Data
    }

    func write(account: String, data: Data) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let upd = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if upd == errSecSuccess { return }
        if upd != errSecItemNotFound { throw Error.keychain(upd) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw Error.keychain(st) }
    }

    func delete(account: String) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let st = SecItemDelete(q as CFDictionary)
        if st == errSecItemNotFound || st == errSecSuccess { return }
        throw Error.keychain(st)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.KeychainStoreTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/KeychainStore.swift Tests/ClipTests/Sync/KeychainStoreTests.swift
git commit -m "sync: KeychainStore — generic-password wrapper, sync disabled"
```

---

### Task 5: SyncTypes — value types + cloud key constants + composite cursor

**Files:**
- Create: `Sources/Clip/Sync/SyncTypes.swift`
- Create: `Tests/ClipTests/Sync/SyncTypesTests.swift`

This is where **fix A** (composite cursor) lives as a parseable type.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncTypesTests.swift
import XCTest
@testable import Clip

final class SyncTypesTests: XCTestCase {
    func testSyncOpRawValueRoundTrip() {
        for op in SyncOp.allCases {
            XCTAssertEqual(SyncOp(rawValue: op.rawValue), op)
        }
    }

    func testCloudCursorZero() {
        let c = CloudCursor.zero
        XCTAssertEqual(c.serialized, "0:")
        XCTAssertEqual(c.updatedAt, 0)
        XCTAssertEqual(c.id, "")
    }

    func testCloudCursorSerializeRoundTrip() {
        let c = CloudCursor(updatedAt: 1735689600, id: "abc-123")
        XCTAssertEqual(c.serialized, "1735689600:abc-123")
        XCTAssertEqual(CloudCursor(serialized: c.serialized), c)
    }

    func testCloudCursorParseInvalidReturnsZero() {
        XCTAssertEqual(CloudCursor(serialized: "garbage"), CloudCursor.zero)
        XCTAssertEqual(CloudCursor(serialized: ""), CloudCursor.zero)
    }

    func testCloudKeyHelpers() {
        XCTAssertEqual(CloudKey.blobKey(name: "abc"), "blobs/abc.bin")
        XCTAssertEqual(CloudKey.blobsPrefix, "blobs/")
    }

    func testCloudRowEquality() {
        let a = CloudRow(id: "1", hmac: "h", ciphertext: Data([0x01]),
                         kind: "text", blobKey: nil, byteSize: 1,
                         deviceID: "D", createdAt: 0, updatedAt: 0, deleted: false)
        var b = a
        XCTAssertEqual(a, b)
        b.deleted = true
        XCTAssertNotEqual(a, b)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncTypesTests
```

- [ ] **Step 3: Implement SyncTypes**

```swift
// Sources/Clip/Sync/SyncTypes.swift
import Foundation

/// One row in `sync_queue.op`.
enum SyncOp: String, CaseIterable, Sendable {
    case putClip   = "put_clip"
    case putBlob   = "put_blob"
    case putTomb   = "put_tomb"
    case putDevice = "put_device"
}

/// Mirrors a row in the D1 `clips` table.
struct CloudRow: Sendable, Equatable {
    var id: String              // UUID, primary key (plaintext)
    var hmac: String            // HMAC(content_hash, kName) (plaintext, indexed)
    var ciphertext: Data        // ChaChaPoly sealed JSON of RowPayload
    var kind: String            // "text" | "image"
    var blobKey: String?        // R2 object key for image; nil for text
    var byteSize: Int           // plaintext content size
    var deviceID: String        // last writer
    var createdAt: Int64
    var updatedAt: Int64        // server-side bumped on UPSERT
    var deleted: Bool           // tombstone flag
}

/// Mirrors a row in the D1 `devices` table.
struct DeviceRow: Sendable, Equatable {
    var deviceID: String
    var ciphertext: Data        // sealed JSON of DevicePayload
    var lastSeenAt: Int64
}

/// Composite pull cursor (spec §7.3 "fix A"). Encodes as
/// "<unix_sec>:<id_uuid>"; deserialize tolerates garbage by returning .zero.
struct CloudCursor: Sendable, Equatable {
    var updatedAt: Int64
    var id: String

    static let zero = CloudCursor(updatedAt: 0, id: "")

    var serialized: String { "\(updatedAt):\(id)" }

    init(updatedAt: Int64, id: String) {
        self.updatedAt = updatedAt
        self.id = id
    }

    init(serialized: String) {
        guard let colon = serialized.firstIndex(of: ":"),
              let ts = Int64(serialized[..<colon])
        else {
            self = .zero
            return
        }
        self.updatedAt = ts
        self.id = String(serialized[serialized.index(after: colon)...])
    }
}

/// Cloud object key construction (R2 side only — D1 uses table/column names).
enum CloudKey {
    static let blobsPrefix = "blobs/"
    static func blobKey(name: String) -> String { blobsPrefix + name + ".bin" }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncTypesTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncTypes.swift Tests/ClipTests/Sync/SyncTypesTests.swift
git commit -m "sync: SyncTypes — CloudRow/DeviceRow/CloudCursor (composite, fix A)"
```

---

### Task 6: SyncSchema — Codable payloads

**Files:**
- Create: `Sources/Clip/Sync/SyncSchema.swift`
- Create: `Tests/ClipTests/Sync/SyncSchemaTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncSchemaTests.swift
import XCTest
@testable import Clip

final class SyncSchemaTests: XCTestCase {
    func testRowPayloadTextRoundTrip() throws {
        let p = RowPayload(
            v: 1, content: "hello", thumbB64: nil, mimeType: nil, blobSize: nil,
            truncated: false, sourceBundleId: "com.apple.Safari", sourceAppName: "Safari",
            pinned: false, contentHash: "abc")
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(RowPayload.self, from: data), p)
    }

    func testRowPayloadImageRoundTrip() throws {
        let p = RowPayload(
            v: 1, content: nil, thumbB64: "AAAA", mimeType: "image/png",
            blobSize: 12345, truncated: false, sourceBundleId: nil, sourceAppName: nil,
            pinned: true, contentHash: "def")
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(RowPayload.self, from: data), p)
    }

    func testDevicePayloadRoundTrip() throws {
        let d = DevicePayload(v: 1, displayName: "Mac-Mini-7", model: "Mac15,12",
                              firstSeenAt: 1)
        let back = try JSONDecoder().decode(DevicePayload.self,
                                            from: try JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncSchemaTests
```

- [ ] **Step 3: Implement SyncSchema**

```swift
// Sources/Clip/Sync/SyncSchema.swift
import Foundation

/// JSON wire format for `clips.ciphertext` after decryption. Spec §5.3.
/// snake_case for cross-language portability.
struct RowPayload: Codable, Equatable, Sendable {
    var v: Int
    var content: String?       // text only
    var thumbB64: String?      // image only — base64 PNG ≤5KB
    var mimeType: String?      // image only
    var blobSize: Int?         // image only — R2 blob byte count
    var truncated: Bool
    var sourceBundleId: String?
    var sourceAppName: String?
    var pinned: Bool
    var contentHash: String    // duplicates the indexed clips.hmac source

    enum CodingKeys: String, CodingKey {
        case v, content, truncated, pinned
        case thumbB64        = "thumb_b64"
        case mimeType        = "mime_type"
        case blobSize        = "blob_size"
        case sourceBundleId  = "source_bundle_id"
        case sourceAppName   = "source_app_name"
        case contentHash     = "content_hash"
    }
}

/// JSON wire format for `devices.ciphertext` after decryption. Spec §5.4.
struct DevicePayload: Codable, Equatable, Sendable {
    var v: Int
    var displayName: String
    var model: String
    var firstSeenAt: Int64

    enum CodingKeys: String, CodingKey {
        case v, model
        case displayName = "display_name"
        case firstSeenAt = "first_seen_at"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncSchemaTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncSchema.swift Tests/ClipTests/Sync/SyncSchemaTests.swift
git commit -m "sync: SyncSchema — Codable RowPayload + DevicePayload"
```

---

### Task 7: HistoryStore additions — sync columns + hooks + new helpers

**Files:**
- Modify: `Sources/Clip/Storage/ClipItem.swift`
- Modify: `Sources/Clip/Storage/HistoryStore.swift`
- Create: `Tests/ClipTests/Sync/HistoryStoreSyncTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/HistoryStoreSyncTests.swift
import XCTest
@testable import Clip

final class HistoryStoreSyncTests: XCTestCase {
    func mkItem(_ s: String, at: Int64 = 1) -> ClipItem {
        ClipItem(id: nil, content: s, contentHash: ClipItem.contentHash(of: s),
                 sourceBundleID: nil, sourceAppName: nil, createdAt: at,
                 pinned: false, byteSize: s.utf8.count, truncated: false)
    }

    func testNewItemDefaultsAreUnsynced() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(mkItem("x"))
        let item = try XCTUnwrap(try s.itemByID(id))
        XCTAssertEqual(item.syncExcluded, false)
        XCTAssertNil(item.cloudID)
        XCTAssertNil(item.cloudUpdatedAt)
        XCTAssertNil(item.cloudSyncedAt)
        XCTAssertNil(item.cloudBlobKey)
        XCTAssertNil(item.deviceID)
    }

    func testMarkClipSyncedWritesCloudFields() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(mkItem("y"))
        try s.markClipSynced(id: id, cloudID: "uuid-123", updatedAt: 99, at: 100)
        let item = try XCTUnwrap(try s.itemByID(id))
        XCTAssertEqual(item.cloudID, "uuid-123")
        XCTAssertEqual(item.cloudUpdatedAt, 99)
        XCTAssertEqual(item.cloudSyncedAt, 100)
    }

    func testItemByCloudID() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(mkItem("z"))
        try s.markClipSynced(id: id, cloudID: "abc", updatedAt: 1, at: 2)
        let found = try XCTUnwrap(try s.itemByCloudID("abc"))
        XCTAssertEqual(found.id, id)
        XCTAssertNil(try s.itemByCloudID("missing"))
    }

    func testSetSyncExcludedToggles() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(mkItem("a"))
        try s.setSyncExcluded(id: id, excluded: true)
        XCTAssertEqual(try s.itemByID(id)?.syncExcluded, true)
        try s.setSyncExcluded(id: id, excluded: false)
        XCTAssertEqual(try s.itemByID(id)?.syncExcluded, false)
    }

    func testOnChangeFiresOnInsertAndDelete() throws {
        let s = try HistoryStore.inMemory()
        var calls: [HistoryStoreChange] = []
        s.onChange = { calls.append($0) }
        let id = try s.insert(mkItem("c"))
        try s.delete(id: id)
        XCTAssertEqual(calls.count, 2)
        if case .inserted = calls[0] {} else { XCTFail() }
        if case .deleted = calls[1] {} else { XCTFail() }
    }

    func testTombstoneRoundTrip() throws {
        let s = try HistoryStore.inMemory()
        try s.upsertTombstone(contentHash: "h", cloudID: "id1",
                              tombstonedAt: 100, cloudUpdatedAt: 100)
        XCTAssertEqual(try s.tombstoneAt(contentHash: "h"), 100)
        // re-upsert with newer time → updates
        try s.upsertTombstone(contentHash: "h", cloudID: "id1",
                              tombstonedAt: 200, cloudUpdatedAt: 200)
        XCTAssertEqual(try s.tombstoneAt(contentHash: "h"), 200)
    }

    func testLazyBlobInsertAndFill() throws {
        let s = try HistoryStore.inMemory()
        let blobID = try s.insertLazyBlob(blobHmac: "hash1", byteSize: 1024, now: 1)
        let lazy = try XCTUnwrap(try s.lazyBlobHmac(id: blobID))
        XCTAssertEqual(lazy.hmac, "hash1")
        XCTAssertEqual(lazy.byteSize, 1024)
        let bytes = Data(repeating: 0xFF, count: 1024)
        try s.fillBlob(id: blobID, bytes: bytes, sha256: "real-sha", at: 2)
        XCTAssertEqual(try s.blob(id: blobID), bytes)
        XCTAssertNil(try s.lazyBlobHmac(id: blobID))   // no longer lazy
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.HistoryStoreSyncTests
```

- [ ] **Step 3: Extend ClipItem (add 6 properties)**

In `Sources/Clip/Storage/ClipItem.swift`, replace the `ClipItem` struct:

```swift
struct ClipItem: Identifiable, Equatable {
    var id: Int64?
    var content: String
    var contentHash: String
    var sourceBundleID: String?
    var sourceAppName: String?
    var createdAt: Int64
    var pinned: Bool
    var byteSize: Int
    var truncated: Bool
    var kind: ClipKind = .text
    var blobID: Int64? = nil
    var mimeType: String? = nil
    // v3 cloud sync columns (Migration v3) — all default-nil so callsites
    // that never touch sync don't break.
    var cloudID: String? = nil
    var cloudUpdatedAt: Int64? = nil
    var cloudSyncedAt: Int64? = nil
    var cloudBlobKey: String? = nil
    var syncExcluded: Bool = false
    var deviceID: String? = nil

    static func byteSize(of s: String) -> Int { s.utf8.count }
    static func truncateIfNeeded(_ s: String, limit: Int) -> (String, Bool) {
        let bytes = Array(s.utf8)
        guard bytes.count > limit else { return (s, false) }
        var cut = limit
        while cut > 0 && (bytes[cut] & 0xC0) == 0x80 { cut -= 1 }
        return (String(decoding: bytes.prefix(cut), as: UTF8.self), true)
    }
    static func contentHash(of s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func contentHash(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Add HistoryStoreChange + extend HistoryStore**

In `Sources/Clip/Storage/HistoryStore.swift`, before the class:

```swift
enum HistoryStoreChange: Sendable {
    case inserted(itemID: Int64)
    case deleted(itemID: Int64, contentHash: String)
    case pinToggled(itemID: Int64)
    case excludedToggled(itemID: Int64)
}
```

Add to the class:

```swift
    var onChange: (@Sendable (HistoryStoreChange) -> Void)?
```

Update `itemFromRow`:

```swift
    static func itemFromRow(_ row: Row) -> ClipItem {
        let kindStr = (row["kind"] as String?) ?? "text"
        let kind = ClipKind(rawValue: kindStr) ?? .text
        return ClipItem(
            id: row["id"],
            content: row["content"],
            contentHash: row["content_hash"],
            sourceBundleID: row["source_bundle_id"],
            sourceAppName: row["source_app_name"],
            createdAt: row["created_at"],
            pinned: (row["pinned"] as Int64) != 0,
            byteSize: row["byte_size"],
            truncated: (row["truncated"] as Int64) != 0,
            kind: kind,
            blobID: row["blob_id"],
            mimeType: row["mime_type"],
            cloudID: row["cloud_id"],
            cloudUpdatedAt: row["cloud_updated_at"],
            cloudSyncedAt: row["cloud_synced_at"],
            cloudBlobKey: row["cloud_blob_key"],
            syncExcluded: ((row["sync_excluded"] as Int64?) ?? 0) != 0,
            deviceID: row["device_id"]
        )
    }
```

Wrap mutations to fire `onChange`. Replace `insert`, `insertOrPromote`, `insertImage`, `delete`, `togglePin`. Example for `insert`:

```swift
    @discardableResult
    func insert(_ item: ClipItem) throws -> Int64 {
        let id = try pool.write { db in try Self._insert(db, item: item) }
        onChange?(.inserted(itemID: id))
        return id
    }
```

For `delete` capture the hash before removing:

```swift
    func delete(id: Int64) throws {
        let hash = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT content_hash FROM items WHERE id = ?", arguments: [id])
        }
        try pool.write { db in
            try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
        }
        if let hash {
            onChange?(.deleted(itemID: id, contentHash: hash))
        }
    }
```

Apply parallel patterns to `insertOrPromote`/`insertImage` (`.inserted`) and `togglePin` (`.pinToggled`).

Add new methods:

```swift
    // MARK: - Sync helpers (Migration v3)

    func itemByID(_ id: Int64) throws -> ClipItem? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id])
                .map(Self.itemFromRow)
        }
    }

    func itemByCloudID(_ cloudID: String) throws -> ClipItem? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM items WHERE cloud_id = ? LIMIT 1",
                             arguments: [cloudID]).map(Self.itemFromRow)
        }
    }

    func itemByContentHash(_ hash: String) throws -> ClipItem? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM items WHERE content_hash = ? LIMIT 1",
                             arguments: [hash]).map(Self.itemFromRow)
        }
    }

    func markClipSynced(id: Int64, cloudID: String, updatedAt: Int64, at: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE items SET cloud_id = ?, cloud_updated_at = ?, cloud_synced_at = ?
                WHERE id = ?
            """, arguments: [cloudID, updatedAt, at, id])
        }
    }

    func markBlobSynced(id: Int64, at: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE clip_blobs SET cloud_synced_at = ? WHERE id = ?
            """, arguments: [at, id])
        }
    }

    func setItemCloudBlobKey(id: Int64, blobKey: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE items SET cloud_blob_key = ? WHERE id = ?",
                           arguments: [blobKey, id])
        }
    }

    func setSyncExcluded(id: Int64, excluded: Bool) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE items SET sync_excluded = ? WHERE id = ?",
                           arguments: [excluded ? 1 : 0, id])
        }
        onChange?(.excludedToggled(itemID: id))
    }

    // MARK: - Tombstones (local; prevents capture-side resurrection)

    func upsertTombstone(contentHash: String, cloudID: String,
                         tombstonedAt: Int64, cloudUpdatedAt: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO tombstones (content_hash, cloud_id, tombstoned_at, cloud_updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET
                  tombstoned_at = excluded.tombstoned_at,
                  cloud_updated_at = excluded.cloud_updated_at
            """, arguments: [contentHash, cloudID, tombstonedAt, cloudUpdatedAt])
        }
    }

    func tombstoneAt(contentHash: String) throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(db,
                sql: "SELECT tombstoned_at FROM tombstones WHERE content_hash = ?",
                arguments: [contentHash])
        }
    }

    func deleteItemsByContentHashOlderThan(_ contentHash: String, _ tombstonedAt: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                DELETE FROM items WHERE content_hash = ? AND created_at <= ?
            """, arguments: [contentHash, tombstonedAt])
        }
    }

    // MARK: - Lazy blob (image rows pulled before bytes downloaded)

    func insertLazyBlob(blobHmac: String, byteSize: Int, now: Int64) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO clip_blobs (sha256, bytes, byte_size, created_at)
                VALUES (?, ?, ?, ?)
            """, arguments: ["lazy:" + blobHmac, Data(), byteSize, now])
            return db.lastInsertedRowID
        }
    }

    func lazyBlobHmac(id: Int64) throws -> (hmac: String, byteSize: Int)? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT sha256, byte_size FROM clip_blobs WHERE id = ?",
                arguments: [id]) else { return nil }
            let sha: String = row["sha256"]
            guard sha.hasPrefix("lazy:") else { return nil }
            return (String(sha.dropFirst("lazy:".count)), row["byte_size"])
        }
    }

    func fillBlob(id: Int64, bytes: Data, sha256: String, at: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE clip_blobs SET bytes = ?, sha256 = ?, cloud_synced_at = ?
                WHERE id = ?
            """, arguments: [bytes, sha256, at, id])
        }
    }
```

Update `_insert` to write the 6 new columns. Adjust the SQL:

```swift
    fileprivate static func _insert(_ db: Database, item: ClipItem) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO items
                (content, content_hash, source_bundle_id, source_app_name,
                 created_at, pinned, byte_size, truncated,
                 kind, blob_id, mime_type,
                 cloud_id, cloud_updated_at, cloud_synced_at, cloud_blob_key,
                 sync_excluded, device_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [
            item.content, item.contentHash, item.sourceBundleID,
            item.sourceAppName, item.createdAt, item.pinned ? 1 : 0,
            item.byteSize, item.truncated ? 1 : 0,
            item.kind.rawValue, item.blobID, item.mimeType,
            item.cloudID, item.cloudUpdatedAt, item.cloudSyncedAt, item.cloudBlobKey,
            item.syncExcluded ? 1 : 0, item.deviceID,
        ])
        return db.lastInsertedRowID
    }
```

- [ ] **Step 5: Run test + full suite**

```bash
swift test --filter ClipTests.HistoryStoreSyncTests
swift test
```

Both must pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Clip/Storage/ClipItem.swift Sources/Clip/Storage/HistoryStore.swift Tests/ClipTests/Sync/HistoryStoreSyncTests.swift
git commit -m "sync: HistoryStore — sync columns + onChange + tombstones + lazy blob helpers"
```

---

## Phase P2 — Backend (protocols + impls)

### Task 8: CloudSyncDataSource + CloudSyncBlobStore protocols

**Files:**
- Create: `Sources/Clip/Sync/CloudSyncDataSource.swift`
- Create: `Sources/Clip/Sync/CloudSyncBlobStore.swift`

(No test for protocols themselves — exercised via implementations.)

- [ ] **Step 1: Write the protocols**

```swift
// Sources/Clip/Sync/CloudSyncDataSource.swift
import Foundation

/// D1 abstraction. Spec §4.2. Two-table model (clips + devices) plus a
/// generic config KV. Implementations: D1Backend (production),
/// LocalSqliteDataSource (tests).
protocol CloudSyncDataSource: Sendable {
    /// Idempotent: `CREATE TABLE IF NOT EXISTS` for clips/devices/config
    /// + indices. Run on every SyncEngine cold start.
    func ensureSchema() async throws

    // Clips
    /// UPSERT (INSERT ... ON CONFLICT(id) DO UPDATE). Returns server-side
    /// `updated_at` from RETURNING clause.
    func upsertClip(_ row: CloudRow) async throws -> Int64

    /// Lookup for hmac-based dedup. **Returns even deleted=1 rows** so that
    /// re-toggling exclude reuses the same cloud_id (spec §6.3 fix B).
    func queryClipByHmac(_ hmac: String) async throws -> (id: String, deleted: Bool)?

    /// Composite-cursor pull (spec §7.3 fix A).
    func queryClipsChangedSince(cursor: CloudCursor, limit: Int) async throws -> [CloudRow]

    /// Soft-delete: UPDATE deleted=1, updated_at=unixepoch() WHERE id=?
    /// Returns the new updated_at.
    func setClipDeleted(id: String) async throws -> Int64

    // Devices
    func upsertDevice(_ row: DeviceRow) async throws
    func listDevices() async throws -> [DeviceRow]

    // Config (KDF salt, schema_version, etc.)
    func getConfig(key: String) async throws -> String?
    /// Returns true iff the row was INSERTed (we won the race);
    /// false if it already existed (someone else won).
    func putConfigIfAbsent(key: String, value: String) async throws -> Bool
}
```

```swift
// Sources/Clip/Sync/CloudSyncBlobStore.swift
import Foundation

/// R2 blob abstraction — only PUT/GET/DELETE (no list, no head).
/// Spec §4.4. Implementations: R2BlobBackend (production),
/// LocalDirBlobStore (tests).
protocol CloudSyncBlobStore: Sendable {
    func putBlob(key: String, body: Data) async throws
    func getBlob(key: String) async throws -> Data?    // nil = 404
    func deleteBlob(key: String) async throws           // idempotent
}
```

- [ ] **Step 2: Build to verify compiles**

```bash
swift build
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Clip/Sync/CloudSyncDataSource.swift Sources/Clip/Sync/CloudSyncBlobStore.swift
git commit -m "sync: CloudSyncDataSource + CloudSyncBlobStore protocols (D1+R2 split)"
```

---

### Task 9: LocalSqliteDataSource — in-memory SQLite for tests

**Files:**
- Create: `Sources/Clip/Sync/LocalSqliteDataSource.swift`
- Create: `Tests/ClipTests/Sync/LocalSqliteDataSourceTests.swift`

In-memory backed by a fresh GRDB DatabasePool per instance. Mirrors the D1 schema exactly (so SQL semantics match production).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/LocalSqliteDataSourceTests.swift
import XCTest
@testable import Clip

final class LocalSqliteDataSourceTests: XCTestCase {
    func makeDS() throws -> LocalSqliteDataSource {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter()
        Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        return ds
    }

    func testUpsertThenQueryByHmac() async throws {
        let ds = try makeDS()
        let row = CloudRow(id: "id1", hmac: "hmac1", ciphertext: Data([0xAA]),
                           kind: "text", blobKey: nil, byteSize: 5,
                           deviceID: "DEV", createdAt: 100, updatedAt: 0,
                           deleted: false)
        let updatedAt = try await ds.upsertClip(row)
        XCTAssertGreaterThan(updatedAt, 0, "server bumped updated_at")
        let found = try await ds.queryClipByHmac("hmac1")
        XCTAssertEqual(found?.id, "id1")
        XCTAssertEqual(found?.deleted, false)
    }

    func testQueryByHmacReturnsDeleted() async throws {
        let ds = try makeDS()
        let row = CloudRow(id: "x", hmac: "h", ciphertext: Data([0x01]),
                           kind: "text", blobKey: nil, byteSize: 1,
                           deviceID: "D", createdAt: 1, updatedAt: 0, deleted: false)
        _ = try await ds.upsertClip(row)
        _ = try await ds.setClipDeleted(id: "x")
        let found = try await ds.queryClipByHmac("h")
        XCTAssertEqual(found?.id, "x")
        XCTAssertEqual(found?.deleted, true, "deleted rows must be returned (fix B)")
    }

    func testQueryClipsChangedSinceCompositeCursor() async throws {
        let ds = try makeDS()
        // Manually insert two rows with the same updated_at (impossible via
        // upsert which uses unixepoch(); use a direct call for the test).
        try ds.testDirectInsert(
            CloudRow(id: "a", hmac: "ha", ciphertext: Data(), kind: "text",
                     blobKey: nil, byteSize: 0, deviceID: "D",
                     createdAt: 0, updatedAt: 100, deleted: false))
        try ds.testDirectInsert(
            CloudRow(id: "b", hmac: "hb", ciphertext: Data(), kind: "text",
                     blobKey: nil, byteSize: 0, deviceID: "D",
                     createdAt: 0, updatedAt: 100, deleted: false))
        // Cursor at (100, "a") should pick up only "b" — not "a" again.
        let rows = try await ds.queryClipsChangedSince(
            cursor: CloudCursor(updatedAt: 100, id: "a"), limit: 100)
        XCTAssertEqual(rows.map(\.id), ["b"])
    }

    func testPutConfigIfAbsentRaceSemantics() async throws {
        let ds = try makeDS()
        let won1 = try await ds.putConfigIfAbsent(key: "k", value: "v1")
        let won2 = try await ds.putConfigIfAbsent(key: "k", value: "v2")
        XCTAssertTrue(won1)
        XCTAssertFalse(won2)
        XCTAssertEqual(try await ds.getConfig(key: "k"), "v1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.LocalSqliteDataSourceTests
```

- [ ] **Step 3: Implement LocalSqliteDataSource**

```swift
// Sources/Clip/Sync/LocalSqliteDataSource.swift
import Foundation
import GRDB

/// In-memory SQLite that mirrors the D1 schema exactly. Used by tests so
/// SyncEngine can exercise the full push/pull pipeline without network.
/// Production uses D1Backend — same protocol, same SQL semantics.
final class LocalSqliteDataSource: CloudSyncDataSource, @unchecked Sendable {
    let pool: DatabasePool

    init() throws {
        let tmp = NSTemporaryDirectory() + UUID().uuidString + ".sqlite"
        var cfg = Configuration()
        cfg.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode=WAL") }
        self.pool = try DatabasePool(path: tmp, configuration: cfg)
    }

    func ensureSchema() async throws {
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clips (
                    id           TEXT PRIMARY KEY,
                    hmac         TEXT NOT NULL,
                    ciphertext   BLOB NOT NULL,
                    kind         TEXT NOT NULL,
                    blob_key     TEXT,
                    byte_size    INTEGER NOT NULL,
                    device_id    TEXT NOT NULL,
                    created_at   INTEGER NOT NULL,
                    updated_at   INTEGER NOT NULL,
                    deleted      INTEGER NOT NULL DEFAULT 0
                );
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_clips_updated_at ON clips(updated_at);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_clips_hmac ON clips(hmac);")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS devices (
                    device_id    TEXT PRIMARY KEY,
                    ciphertext   BLOB NOT NULL,
                    last_seen_at INTEGER NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS config (
                    key   TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
            """)
        }
    }

    func upsertClip(_ row: CloudRow) async throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO clips (id, hmac, ciphertext, kind, blob_key, byte_size,
                                   device_id, created_at, updated_at, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, unixepoch(), 0)
                ON CONFLICT(id) DO UPDATE SET
                  hmac=excluded.hmac, ciphertext=excluded.ciphertext,
                  kind=excluded.kind, blob_key=excluded.blob_key,
                  byte_size=excluded.byte_size, device_id=excluded.device_id,
                  updated_at=unixepoch(), deleted=0
            """, arguments: [row.id, row.hmac, row.ciphertext, row.kind,
                             row.blobKey, row.byteSize, row.deviceID,
                             row.createdAt])
            return try Int64.fetchOne(db,
                sql: "SELECT updated_at FROM clips WHERE id = ?",
                arguments: [row.id]) ?? 0
        }
    }

    func queryClipByHmac(_ hmac: String) async throws -> (id: String, deleted: Bool)? {
        try pool.read { db in
            try Row.fetchOne(db,
                sql: "SELECT id, deleted FROM clips WHERE hmac = ? LIMIT 1",
                arguments: [hmac]).map { (id: $0["id"], deleted: ($0["deleted"] as Int64) != 0) }
        }
    }

    func queryClipsChangedSince(cursor: CloudCursor, limit: Int) async throws -> [CloudRow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM clips
                WHERE updated_at > ? OR (updated_at = ? AND id > ?)
                ORDER BY updated_at, id
                LIMIT ?
            """, arguments: [cursor.updatedAt, cursor.updatedAt, cursor.id, limit])
            .map(Self.cloudRowFromRow)
        }
    }

    func setClipDeleted(id: String) async throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE clips SET deleted = 1, updated_at = unixepoch() WHERE id = ?
            """, arguments: [id])
            return try Int64.fetchOne(db,
                sql: "SELECT updated_at FROM clips WHERE id = ?",
                arguments: [id]) ?? 0
        }
    }

    func upsertDevice(_ row: DeviceRow) async throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO devices (device_id, ciphertext, last_seen_at)
                VALUES (?, ?, unixepoch())
                ON CONFLICT(device_id) DO UPDATE SET
                  ciphertext = excluded.ciphertext,
                  last_seen_at = unixepoch()
            """, arguments: [row.deviceID, row.ciphertext])
        }
    }

    func listDevices() async throws -> [DeviceRow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM devices ORDER BY last_seen_at DESC")
                .map { DeviceRow(deviceID: $0["device_id"],
                                 ciphertext: $0["ciphertext"],
                                 lastSeenAt: $0["last_seen_at"]) }
        }
    }

    func getConfig(key: String) async throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM config WHERE key = ?", arguments: [key])
        }
    }

    func putConfigIfAbsent(key: String, value: String) async throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO config (key, value) VALUES (?, ?)",
                           arguments: [key, value])
            return db.changesCount == 1
        }
    }

    // Test-only direct insert for cursor / LWW tests where unixepoch() can't help.
    func testDirectInsert(_ row: CloudRow) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO clips (id, hmac, ciphertext, kind, blob_key, byte_size,
                                   device_id, created_at, updated_at, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [row.id, row.hmac, row.ciphertext, row.kind,
                             row.blobKey, row.byteSize, row.deviceID,
                             row.createdAt, row.updatedAt, row.deleted ? 1 : 0])
        }
    }

    static func cloudRowFromRow(_ r: Row) -> CloudRow {
        CloudRow(id: r["id"], hmac: r["hmac"], ciphertext: r["ciphertext"],
                 kind: r["kind"], blobKey: r["blob_key"], byteSize: r["byte_size"],
                 deviceID: r["device_id"], createdAt: r["created_at"],
                 updatedAt: r["updated_at"], deleted: (r["deleted"] as Int64) != 0)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.LocalSqliteDataSourceTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/LocalSqliteDataSource.swift Tests/ClipTests/Sync/LocalSqliteDataSourceTests.swift
git commit -m "sync: LocalSqliteDataSource — in-memory CloudSyncDataSource for tests"
```

---

### Task 10: LocalDirBlobStore — filesystem CloudSyncBlobStore for tests

**Files:**
- Create: `Sources/Clip/Sync/LocalDirBlobStore.swift`
- Create: `Tests/ClipTests/Sync/LocalDirBlobStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/LocalDirBlobStoreTests.swift
import XCTest
@testable import Clip

final class LocalDirBlobStoreTests: XCTestCase {
    var dir: URL!
    var store: LocalDirBlobStore!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LocalDirBlobStore(root: dir)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testPutGetRoundTrip() async throws {
        let body = Data("hello".utf8)
        try await store.putBlob(key: "blobs/abc.bin", body: body)
        XCTAssertEqual(try await store.getBlob(key: "blobs/abc.bin"), body)
    }

    func testGetMissingReturnsNil() async throws {
        XCTAssertNil(try await store.getBlob(key: "nope.bin"))
    }

    func testDeleteIdempotent() async throws {
        try await store.putBlob(key: "k.bin", body: Data([0x01]))
        try await store.deleteBlob(key: "k.bin")
        try await store.deleteBlob(key: "k.bin")  // again, must not throw
        XCTAssertNil(try await store.getBlob(key: "k.bin"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.LocalDirBlobStoreTests
```

- [ ] **Step 3: Implement LocalDirBlobStore**

```swift
// Sources/Clip/Sync/LocalDirBlobStore.swift
import Foundation

/// Filesystem-backed BlobStore. Each key becomes a nested file under `root`.
/// Used in unit / integration tests so SyncEngine can run without network.
final class LocalDirBlobStore: CloudSyncBlobStore, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root }

    private func url(for key: String) -> URL {
        root.appendingPathComponent(key)
    }

    func putBlob(key: String, body: Data) async throws {
        let u = url(for: key)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: u, options: .atomic)
    }

    func getBlob(key: String) async throws -> Data? {
        let u = url(for: key)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    func deleteBlob(key: String) async throws {
        let u = url(for: key)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.LocalDirBlobStoreTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/LocalDirBlobStore.swift Tests/ClipTests/Sync/LocalDirBlobStoreTests.swift
git commit -m "sync: LocalDirBlobStore — filesystem CloudSyncBlobStore for tests"
```

---

### Task 11: S3SignerV4 — AWS Sig V4 implementation

**Files:**
- Create: `Sources/Clip/Sync/S3SignerV4.swift`
- Create: `Tests/ClipTests/Sync/S3SignerV4Tests.swift`

(Used only by R2BlobBackend; D1Backend uses Bearer auth.)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/S3SignerV4Tests.swift
import XCTest
@testable import Clip

final class S3SignerV4Tests: XCTestCase {
    func testSignReturnsExpectedHeaderShape() {
        let signer = S3SignerV4(accessKeyID: "AKIDEXAMPLE",
                                secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                                region: "auto", service: "s3")
        var req = URLRequest(url: URL(string: "https://x.r2.cloudflarestorage.com/clip-sync/blobs/abc.bin")!)
        req.httpMethod = "PUT"
        let date = ISO8601DateFormatter().date(from: "2026-05-02T12:00:00Z")!
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD", date: date)

        XCTAssertEqual(signed.value(forHTTPHeaderField: "x-amz-date"), "20260502T120000Z")
        XCTAssertEqual(signed.value(forHTTPHeaderField: "x-amz-content-sha256"), "UNSIGNED-PAYLOAD")
        let auth = try XCTUnwrap(signed.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260502/auto/s3/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        XCTAssertTrue(auth.contains("Signature="))
    }

    func testSignaturesDifferByDate() {
        let s = S3SignerV4(accessKeyID: "AK", secretAccessKey: "SK", region: "auto", service: "s3")
        let req = URLRequest(url: URL(string: "https://x/k")!)
        let r1 = s.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD",
                        date: Date(timeIntervalSince1970: 1_700_000_000))
        let r2 = s.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD",
                        date: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertNotEqual(r1.value(forHTTPHeaderField: "Authorization"),
                          r2.value(forHTTPHeaderField: "Authorization"))
    }

    func testCanonicalUriPreservesSlashes() {
        let s = S3SignerV4(accessKeyID: "AK", secretAccessKey: "SK", region: "auto", service: "s3")
        let url = URL(string: "https://x.r2.cloudflarestorage.com/clip-sync/blobs/abc.bin")!
        let signed = s.sign(request: URLRequest(url: url),
                            payloadSha256: "UNSIGNED-PAYLOAD", date: Date())
        XCTAssertEqual(signed.url?.path, "/clip-sync/blobs/abc.bin")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.S3SignerV4Tests
```

- [ ] **Step 3: Implement S3SignerV4**

```swift
// Sources/Clip/Sync/S3SignerV4.swift
import Foundation
import CryptoKit

/// AWS Signature V4 signer for S3-compatible APIs (used against R2).
/// Spec §6.5: path-style URLs, region "auto" for R2, UNSIGNED-PAYLOAD mode.
/// No third-party SDK — Foundation + CryptoKit only.
struct S3SignerV4: Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let region: String
    let service: String

    func sign(request: URLRequest, payloadSha256: String, date: Date = Date()) -> URLRequest {
        var req = request
        let amzDate = Self.amzDateFormatter.string(from: date)
        let dateStamp = String(amzDate.prefix(8))

        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadSha256, forHTTPHeaderField: "x-amz-content-sha256")

        let method = req.httpMethod ?? "GET"
        let url = req.url!
        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalQuery = Self.canonicalQuery(url: url)
        let host = url.host ?? ""

        let headerPairs: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadSha256),
            ("x-amz-date", amzDate),
        ].sorted { $0.0 < $1.0 }
        let canonicalHeaders = headerPairs.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headerPairs.map { $0.0 }.joined(separator: ";")

        let canonicalRequest = [
            method, canonicalURI, canonicalQuery,
            canonicalHeaders, signedHeaders, payloadSha256,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let crSha = Self.sha256Hex(Data(canonicalRequest.utf8))
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, credentialScope, crSha]
            .joined(separator: "\n")

        let kDate    = Self.hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion  = Self.hmac(key: kDate, data: Data(region.utf8))
        let kService = Self.hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmac(key: kService, data: Data("aws4_request".utf8))
        let signature = Self.hmac(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        req.setValue("AWS4-HMAC-SHA256 " +
                     "Credential=\(accessKeyID)/\(credentialScope), " +
                     "SignedHeaders=\(signedHeaders), " +
                     "Signature=\(signature)",
                     forHTTPHeaderField: "Authorization")
        return req
    }

    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static func canonicalQuery(url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        return items.sorted(by: { $0.name < $1.name }).map { item in
            "\(rfc3986Encode(item.name))=\(rfc3986Encode(item.value ?? ""))"
        }.joined(separator: "&")
    }

    private static let unreserved: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return s
    }()
    static func rfc3986Encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.S3SignerV4Tests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/S3SignerV4.swift Tests/ClipTests/Sync/S3SignerV4Tests.swift
git commit -m "sync: S3SignerV4 — pure-Swift AWS Sig V4 (UNSIGNED-PAYLOAD mode)"
```

---

### Task 12: R2BlobBackend — URLSession + S3SignerV4 (PUT/GET/DELETE only)

**Files:**
- Create: `Sources/Clip/Sync/R2BlobBackend.swift`
- Create: `Tests/ClipTests/Sync/R2BlobBackendTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/R2BlobBackendTests.swift
import XCTest
@testable import Clip

final class StubProto: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data?))?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        guard let h = StubProto.handler else { return }
        let (resp, body) = h(self.request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class R2BlobBackendTests: XCTestCase {
    var session: URLSession!
    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProto.self]
        session = URLSession(configuration: cfg)
    }
    override func tearDown() { StubProto.handler = nil; super.tearDown() }

    func makeBackend() -> R2BlobBackend {
        R2BlobBackend(
            endpoint: URL(string: "https://account.r2.cloudflarestorage.com")!,
            bucket: "clip-sync",
            accessKeyID: "AK",
            secretAccessKey: "SK",
            session: session)
    }

    func testPutBuildsExpectedRequest() async throws {
        var captured: URLRequest?
        StubProto.handler = { req in
            captured = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, nil)
        }
        try await makeBackend().putBlob(key: "blobs/abc.bin", body: Data([0xAA]))
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://account.r2.cloudflarestorage.com/clip-sync/blobs/abc.bin")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testGetReturnsBodyOn200() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("payload".utf8))
        }
        let body = try await makeBackend().getBlob(key: "k.bin")
        XCTAssertEqual(body, Data("payload".utf8))
    }

    func testGetReturnsNilOn404() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        XCTAssertNil(try await makeBackend().getBlob(key: "missing.bin"))
    }

    func testDeleteIdempotentOn404() async throws {
        StubProto.handler = { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, nil)
        }
        try await makeBackend().deleteBlob(key: "x.bin")  // no throw on 404
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.R2BlobBackendTests
```

- [ ] **Step 3: Implement R2BlobBackend**

```swift
// Sources/Clip/Sync/R2BlobBackend.swift
import Foundation

/// CloudSyncBlobStore implementation against Cloudflare R2 over the S3 API.
/// Only PUT / GET / DELETE blobs/<key>. No list / no head — D1 row drives
/// "what blobs exist".
final class R2BlobBackend: CloudSyncBlobStore, @unchecked Sendable {
    enum Error: Swift.Error {
        case http(status: Int, body: String)
    }

    let endpoint: URL
    let bucket: String
    let signer: S3SignerV4
    let session: URLSession

    init(endpoint: URL, bucket: String, accessKeyID: String,
         secretAccessKey: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.signer = S3SignerV4(accessKeyID: accessKeyID,
                                 secretAccessKey: secretAccessKey,
                                 region: "auto", service: "s3")
        self.session = session
    }

    private func url(for key: String) -> URL {
        endpoint.appendingPathComponent(bucket).appendingPathComponent(key)
    }

    func putBlob(key: String, body: Data) async throws {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "PUT"
        req.httpBody = body
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    func getBlob(key: String) async throws -> Data? {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "GET"
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func deleteBlob(key: String) async throws {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "DELETE"
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 404 { return }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.R2BlobBackendTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/R2BlobBackend.swift Tests/ClipTests/Sync/R2BlobBackendTests.swift
git commit -m "sync: R2BlobBackend — PUT/GET/DELETE blobs only via Sig V4"
```

---

### Task 13: D1Backend — Cloudflare REST API client

**Files:**
- Create: `Sources/Clip/Sync/D1Backend.swift`
- Create: `Tests/ClipTests/Sync/D1BackendTests.swift`

This is the **biggest task in P2**. Implements all `CloudSyncDataSource` methods over Cloudflare's D1 REST API. Uses Bearer auth (no Sig V4). Bakes in fixes A (composite cursor SQL), B (hmac dedup includes deleted=1), C (INSERT OR IGNORE), E (schema_version row in ensureSchema).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/D1BackendTests.swift
import XCTest
@testable import Clip

final class D1BackendTests: XCTestCase {
    var session: URLSession!
    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProto.self]
        session = URLSession(configuration: cfg)
    }
    override func tearDown() { StubProto.handler = nil; super.tearDown() }

    func makeBackend() -> D1Backend {
        D1Backend(accountID: "acct", databaseID: "db",
                  apiToken: "tok", session: session)
    }

    /// Helper: wrap a SQL response in the D1 REST envelope.
    func wrapResults(_ rows: [[String: Any]], rowsWritten: Int = 0) -> Data {
        let env: [String: Any] = [
            "result": [[
                "results": rows,
                "success": true,
                "meta": ["rows_read": rows.count, "rows_written": rowsWritten,
                         "changes": rowsWritten, "last_row_id": 0]
            ]],
            "errors": [], "messages": [], "success": true
        ]
        return try! JSONSerialization.data(withJSONObject: env)
    }

    func testQueryClipByHmacReturnsDeleted() async throws {
        StubProto.handler = { req in
            let body = self.wrapResults([["id": "uuid1", "deleted": 1]])
            return (HTTPURLResponse(url: req.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!, body)
        }
        let r = try await makeBackend().queryClipByHmac("hmac1")
        XCTAssertEqual(r?.id, "uuid1")
        XCTAssertEqual(r?.deleted, true)
    }

    func testQueryClipByHmacReturnsNilOnEmpty() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             self.wrapResults([]))
        }
        XCTAssertNil(try await makeBackend().queryClipByHmac("nope"))
    }

    func testUpsertClipReturnsServerUpdatedAt() async throws {
        var captured: URLRequest?
        var body: Data?
        StubProto.handler = { req in
            captured = req
            // Capture sent body for assertions
            if let s = req.httpBodyStream {
                let buf = NSMutableData()
                s.open(); defer { s.close() }
                var b = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable {
                    let n = s.read(&b, maxLength: b.count)
                    if n > 0 { buf.append(b, length: n) }
                    if n <= 0 { break }
                }
                body = buf as Data
            } else { body = req.httpBody }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.wrapResults([["updated_at": 12345]], rowsWritten: 1))
        }
        let row = CloudRow(id: "id1", hmac: "h1", ciphertext: Data([0x01]),
                           kind: "text", blobKey: nil, byteSize: 5,
                           deviceID: "DEV", createdAt: 100, updatedAt: 0,
                           deleted: false)
        let updated = try await makeBackend().upsertClip(row)
        XCTAssertEqual(updated, 12345)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertTrue(captured?.url?.absoluteString.contains("/d1/database/db/query") ?? false)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        // Body must reference INSERT ... ON CONFLICT and unixepoch()
        let s = String(data: body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("INSERT INTO clips"))
        XCTAssertTrue(s.contains("ON CONFLICT(id)"))
        XCTAssertTrue(s.contains("unixepoch()"))
    }

    func testQueryClipsChangedSinceCompositeCursorSQL() async throws {
        var bodyStr = ""
        StubProto.handler = { req in
            if let b = req.httpBody {
                bodyStr = String(data: b, encoding: .utf8) ?? ""
            } else if let s = req.httpBodyStream {
                let buf = NSMutableData()
                s.open(); defer { s.close() }
                var b = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable {
                    let n = s.read(&b, maxLength: b.count)
                    if n > 0 { buf.append(b, length: n) }
                    if n <= 0 { break }
                }
                bodyStr = String(data: buf as Data, encoding: .utf8) ?? ""
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    self.wrapResults([]))
        }
        _ = try await makeBackend().queryClipsChangedSince(
            cursor: CloudCursor(updatedAt: 100, id: "abc"), limit: 50)
        // SQL must contain composite WHERE (fix A) + ORDER BY updated_at, id
        XCTAssertTrue(bodyStr.contains("WHERE updated_at > "))
        XCTAssertTrue(bodyStr.contains("OR (updated_at = "))
        XCTAssertTrue(bodyStr.contains("ORDER BY updated_at, id"))
    }

    func testPutConfigIfAbsentReportsRowsWritten() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             self.wrapResults([], rowsWritten: 1))
        }
        let won = try await makeBackend().putConfigIfAbsent(key: "k", value: "v")
        XCTAssertTrue(won)
    }

    func testPutConfigIfAbsentReportsExisting() async throws {
        StubProto.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             self.wrapResults([], rowsWritten: 0))
        }
        let won = try await makeBackend().putConfigIfAbsent(key: "k", value: "v")
        XCTAssertFalse(won)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.D1BackendTests
```

- [ ] **Step 3: Implement D1Backend**

```swift
// Sources/Clip/Sync/D1Backend.swift
import Foundation

/// CloudSyncDataSource implementation over the Cloudflare D1 REST API.
/// All requests: POST {accountID}/d1/database/{databaseID}/query with
/// Bearer auth. SQL is sent as JSON body { sql, params }.
///
/// Bakes in fixes A (composite cursor SQL), B (hmac dedup includes deleted=1),
/// C (INSERT OR IGNORE on config), E (schema_version row in ensureSchema).
final class D1Backend: CloudSyncDataSource, @unchecked Sendable {
    enum Error: Swift.Error {
        case http(status: Int, body: String)
        case d1(messages: [String])
        case decode(String)
    }

    let accountID: String
    let databaseID: String
    let apiToken: String
    let session: URLSession

    init(accountID: String, databaseID: String, apiToken: String,
         session: URLSession = .shared) {
        self.accountID = accountID
        self.databaseID = databaseID
        self.apiToken = apiToken
        self.session = session
    }

    private var endpoint: URL {
        URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/d1/database/\(databaseID)/query")!
    }

    // MARK: - Generic SQL execution

    private struct ResultEnvelope: Decodable {
        struct Inner: Decodable {
            var results: [[String: AnyCodable]]?
            var success: Bool
            var meta: Meta?
        }
        struct Meta: Decodable {
            var rows_read: Int?
            var rows_written: Int?
            var changes: Int?
            var last_row_id: Int?
        }
        struct ApiMessage: Decodable { var code: Int?; var message: String? }
        var result: [Inner]?
        var success: Bool
        var errors: [ApiMessage]?
        var messages: [ApiMessage]?
    }

    // Minimal Codable-any for deserializing result rows
    struct AnyCodable: Decodable {
        let value: Any?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = nil; return }
            if let i = try? c.decode(Int64.self) { value = i; return }
            if let d = try? c.decode(Double.self) { value = d; return }
            if let s = try? c.decode(String.self) { value = s; return }
            if let b = try? c.decode(Bool.self) { value = b; return }
            value = nil
        }
    }

    private func runSQL(_ sql: String, params: [Any?] = []) async throws -> ResultEnvelope.Inner {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "sql": sql,
            "params": params.map { $0 ?? NSNull() }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
        let env = try JSONDecoder().decode(ResultEnvelope.self, from: data)
        guard env.success, let inner = env.result?.first else {
            let msgs = (env.errors ?? []).compactMap(\.message)
            throw Error.d1(messages: msgs)
        }
        return inner
    }

    // MARK: - ensureSchema (fix C + fix E)

    func ensureSchema() async throws {
        let stmts = [
            """
            CREATE TABLE IF NOT EXISTS clips (
                id           TEXT PRIMARY KEY,
                hmac         TEXT NOT NULL,
                ciphertext   BLOB NOT NULL,
                kind         TEXT NOT NULL,
                blob_key     TEXT,
                byte_size    INTEGER NOT NULL,
                device_id    TEXT NOT NULL,
                created_at   INTEGER NOT NULL,
                updated_at   INTEGER NOT NULL,
                deleted      INTEGER NOT NULL DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_clips_updated_at ON clips(updated_at)",
            "CREATE INDEX IF NOT EXISTS idx_clips_hmac ON clips(hmac)",
            """
            CREATE TABLE IF NOT EXISTS devices (
                device_id    TEXT PRIMARY KEY,
                ciphertext   BLOB NOT NULL,
                last_seen_at INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS config (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """,
        ]
        for s in stmts { _ = try await runSQL(s) }
        // schema_version stamp (fix E). INSERT OR IGNORE: only first device sets it.
        _ = try await runSQL(
            "INSERT OR IGNORE INTO config (key, value) VALUES (?, ?)",
            params: ["schema_version", "3"])
    }

    // MARK: - Clips

    func upsertClip(_ row: CloudRow) async throws -> Int64 {
        // INSERT/UPDATE in one round trip; RETURNING-style follow-up SELECT
        // because D1 REST doesn't expose RETURNING values.
        _ = try await runSQL("""
            INSERT INTO clips (id, hmac, ciphertext, kind, blob_key, byte_size,
                               device_id, created_at, updated_at, deleted)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, unixepoch(), 0)
            ON CONFLICT(id) DO UPDATE SET
              hmac=excluded.hmac, ciphertext=excluded.ciphertext,
              kind=excluded.kind, blob_key=excluded.blob_key,
              byte_size=excluded.byte_size, device_id=excluded.device_id,
              updated_at=unixepoch(), deleted=0
            """,
            params: [row.id, row.hmac, row.ciphertext.base64EncodedString(),
                     row.kind, row.blobKey, row.byteSize,
                     row.deviceID, row.createdAt])
        let inner = try await runSQL(
            "SELECT updated_at FROM clips WHERE id = ?", params: [row.id])
        let n = (inner.results?.first?["updated_at"]?.value as? Int64) ?? 0
        return n
    }

    func queryClipByHmac(_ hmac: String) async throws -> (id: String, deleted: Bool)? {
        // Fix B: do NOT filter deleted=0 here.
        let inner = try await runSQL(
            "SELECT id, deleted FROM clips WHERE hmac = ? LIMIT 1", params: [hmac])
        guard let row = inner.results?.first else { return nil }
        let id = (row["id"]?.value as? String) ?? ""
        let del = ((row["deleted"]?.value as? Int64) ?? 0) != 0
        return (id, del)
    }

    func queryClipsChangedSince(cursor: CloudCursor, limit: Int) async throws -> [CloudRow] {
        // Fix A: composite (updated_at, id) cursor.
        let inner = try await runSQL("""
            SELECT id, hmac, ciphertext, kind, blob_key, byte_size,
                   device_id, created_at, updated_at, deleted
            FROM clips
            WHERE updated_at > ? OR (updated_at = ? AND id > ?)
            ORDER BY updated_at, id
            LIMIT ?
            """,
            params: [cursor.updatedAt, cursor.updatedAt, cursor.id, limit])
        return (inner.results ?? []).map(Self.cloudRowFrom)
    }

    func setClipDeleted(id: String) async throws -> Int64 {
        _ = try await runSQL(
            "UPDATE clips SET deleted = 1, updated_at = unixepoch() WHERE id = ?",
            params: [id])
        let inner = try await runSQL(
            "SELECT updated_at FROM clips WHERE id = ?", params: [id])
        return (inner.results?.first?["updated_at"]?.value as? Int64) ?? 0
    }

    // MARK: - Devices

    func upsertDevice(_ row: DeviceRow) async throws {
        _ = try await runSQL("""
            INSERT INTO devices (device_id, ciphertext, last_seen_at)
            VALUES (?, ?, unixepoch())
            ON CONFLICT(device_id) DO UPDATE SET
              ciphertext = excluded.ciphertext,
              last_seen_at = unixepoch()
            """,
            params: [row.deviceID, row.ciphertext.base64EncodedString()])
    }

    func listDevices() async throws -> [DeviceRow] {
        let inner = try await runSQL(
            "SELECT device_id, ciphertext, last_seen_at FROM devices ORDER BY last_seen_at DESC")
        return (inner.results ?? []).map { row in
            let ciphertext = (row["ciphertext"]?.value as? String)
                .flatMap { Data(base64Encoded: $0) } ?? Data()
            return DeviceRow(deviceID: (row["device_id"]?.value as? String) ?? "",
                             ciphertext: ciphertext,
                             lastSeenAt: (row["last_seen_at"]?.value as? Int64) ?? 0)
        }
    }

    // MARK: - Config

    func getConfig(key: String) async throws -> String? {
        let inner = try await runSQL(
            "SELECT value FROM config WHERE key = ?", params: [key])
        return inner.results?.first?["value"]?.value as? String
    }

    func putConfigIfAbsent(key: String, value: String) async throws -> Bool {
        // Fix C: idempotent.
        let inner = try await runSQL(
            "INSERT OR IGNORE INTO config (key, value) VALUES (?, ?)",
            params: [key, value])
        return (inner.meta?.rows_written ?? 0) > 0
    }

    // MARK: - Helpers

    static func cloudRowFrom(_ row: [String: AnyCodable]) -> CloudRow {
        let ciphertext = (row["ciphertext"]?.value as? String)
            .flatMap { Data(base64Encoded: $0) } ?? Data()
        return CloudRow(
            id: (row["id"]?.value as? String) ?? "",
            hmac: (row["hmac"]?.value as? String) ?? "",
            ciphertext: ciphertext,
            kind: (row["kind"]?.value as? String) ?? "text",
            blobKey: row["blob_key"]?.value as? String,
            byteSize: Int((row["byte_size"]?.value as? Int64) ?? 0),
            deviceID: (row["device_id"]?.value as? String) ?? "",
            createdAt: (row["created_at"]?.value as? Int64) ?? 0,
            updatedAt: (row["updated_at"]?.value as? Int64) ?? 0,
            deleted: ((row["deleted"]?.value as? Int64) ?? 0) != 0
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.D1BackendTests
```

Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/D1Backend.swift Tests/ClipTests/Sync/D1BackendTests.swift
git commit -m "sync: D1Backend — REST API client w/ fixes A+B+C+E baked in"
```

---

## Phase P3 — Engine

### Task 14: SyncQueue — DB-backed retry queue with backoff

**Files:**
- Create: `Sources/Clip/Sync/SyncQueue.swift`
- Create: `Tests/ClipTests/Sync/SyncQueueTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncQueueTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncQueueTests
```

- [ ] **Step 3: Implement SyncQueue**

```swift
// Sources/Clip/Sync/SyncQueue.swift
import Foundation
import GRDB

/// DB-backed retry queue (sync_queue, created in Migration v3). On failure
/// applies exponential backoff capped at 900s.
struct SyncQueue: Sendable {
    let store: HistoryStore

    struct Row: Sendable {
        var id: Int64
        var op: SyncOp
        var targetKey: String
        var attempts: Int
        var nextTryAt: Int64
        var lastError: String?
        var enqueuedAt: Int64
    }

    func enqueue(op: SyncOp, targetKey: String, at time: Int64) throws {
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
                VALUES (?, ?, 0, ?, ?)
            """, arguments: [op.rawValue, targetKey, time, time])
        }
    }

    func dequeueDueAt(now: Int64) throws -> Row? {
        try store.pool.read { db in
            try GRDB.Row.fetchOne(db, sql: """
                SELECT * FROM sync_queue
                WHERE next_try_at <= ?
                ORDER BY next_try_at ASC, id ASC
                LIMIT 1
            """, arguments: [now]).map(Self.fromRow)
        }
    }

    func delete(id: Int64) throws {
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM sync_queue WHERE id = ?", arguments: [id])
        }
    }

    func recordFailure(id: Int64, attempts: Int, error: String, at now: Int64) throws {
        let backoff = min(900, Int(truncatingIfNeeded: 1 &<< min(attempts, 20)))
        try store.pool.write { db in
            try db.execute(sql: """
                UPDATE sync_queue SET attempts = ?, last_error = ?, next_try_at = ?
                WHERE id = ?
            """, arguments: [attempts, error, now + Int64(backoff), id])
        }
    }

    func deleteAllForItem(itemID: Int64) throws {
        let target = String(itemID)
        try store.pool.write { db in
            try db.execute(sql: """
                DELETE FROM sync_queue
                WHERE op IN ('put_clip', 'put_blob') AND target_key = ?
            """, arguments: [target])
        }
    }

    func peekAll() throws -> [Row] {
        try store.pool.read { db in
            try GRDB.Row.fetchAll(db, sql: "SELECT * FROM sync_queue ORDER BY id")
                .map(Self.fromRow)
        }
    }

    private static func fromRow(_ r: GRDB.Row) -> Row {
        Row(id: r["id"],
            op: SyncOp(rawValue: r["op"]) ?? .putClip,
            targetKey: r["target_key"],
            attempts: r["attempts"],
            nextTryAt: r["next_try_at"],
            lastError: r["last_error"],
            enqueuedAt: r["enqueued_at"])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncQueueTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncQueue.swift Tests/ClipTests/Sync/SyncQueueTests.swift
git commit -m "sync: SyncQueue — DB-backed retry queue with exponential backoff"
```

---

### Task 15: SyncStateStore — KV wrapper over local sync_state

**Files:**
- Create: `Sources/Clip/Sync/SyncStateStore.swift`
- Create: `Tests/ClipTests/Sync/SyncStateStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncStateStoreTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncStateStoreTests
```

- [ ] **Step 3: Implement SyncStateStore**

```swift
// Sources/Clip/Sync/SyncStateStore.swift
import Foundation
import GRDB

/// Tiny KV wrapper around the sync_state table.
struct SyncStateStore: Sendable {
    let store: HistoryStore

    func get(_ key: String) throws -> String? {
        try store.pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = ?",
                                arguments: [key])
        }
    }

    func set(_ key: String, _ value: String) throws {
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [key, value])
        }
    }

    func delete(_ key: String) throws {
        try store.pool.write { db in
            try db.execute(sql: "DELETE FROM sync_state WHERE key = ?", arguments: [key])
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncStateStoreTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncStateStore.swift Tests/ClipTests/Sync/SyncStateStoreTests.swift
git commit -m "sync: SyncStateStore — kv wrapper over sync_state table"
```

---

### Task 16: SyncEngine push — text + image (R2-then-D1; hmac dedup with deleted=1)

**Files:**
- Create: `Sources/Clip/Sync/SyncEngine.swift` (initial scaffold + pushOnce)
- Create: `Tests/ClipTests/Sync/SyncEnginePushTests.swift`

This task introduces the `actor SyncEngine` skeleton and `pushOnce(now:)`. Pull / enable / fetchBlob / backfill / exclude come in subsequent tasks.

The push path bakes in **fix B** (hmac dedup includes deleted=1; reuses cloud_id) and the **R2-then-D1** ordering from spec §7.2 (so a partial failure leaves an idempotent orphan blob).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEnginePushTests.swift
import XCTest
@testable import Clip

final class SyncEnginePushTests: XCTestCase {
    func makePair() throws -> (HistoryStore, SyncEngine, LocalSqliteDataSource, LocalDirBlobStore) {
        let store = try HistoryStore.inMemory()
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blobs = LocalDirBlobStore(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let state = SyncStateStore(store: store)
        let engine = SyncEngine(store: store, dataSource: ds, blobStore: blobs,
                                crypto: crypto, deviceID: "DEV", state: state)
        return (store, engine, ds, blobs)
    }

    func testPushTextRoundTripsToD1() async throws {
        let (store, engine, ds, _) = try makePair()
        let id = try store.insert(ClipItem(
            id: nil, content: "hello", contentHash: ClipItem.contentHash(of: "hello"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 5, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 100)
        let did = try await engine.pushOnce(now: 200)
        XCTAssertTrue(did)

        // Item now marked synced
        let item = try XCTUnwrap(try store.itemByID(id))
        XCTAssertNotNil(item.cloudID)
        XCTAssertNotNil(item.cloudUpdatedAt)

        // D1 has the row
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let hmac = crypto.name(forContentHash: item.contentHash)
        let found = try await ds.queryClipByHmac(hmac)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.deleted, false)
    }

    func testPushImageDoesR2ThenD1() async throws {
        let (store, engine, ds, blobs) = try makePair()
        let bytes = Data(repeating: 0xFF, count: 1024)
        let id = try store.insertImage(
            bytes: bytes, mimeType: "image/png",
            sourceBundleID: nil, sourceAppName: nil, now: 100)
        try await engine.enqueueClipPush(itemID: id, at: 100)
        try await engine.enqueueBlobPush(blobID: store.itemByID(id)!.blobID!, at: 100)

        // Two queue rows: drain both
        _ = try await engine.pushOnce(now: 200)
        _ = try await engine.pushOnce(now: 201)

        let item = try XCTUnwrap(try store.itemByID(id))
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let blobHmac = crypto.name(forContentHash: item.contentHash)
        // R2 has the encrypted blob
        XCTAssertNotNil(try await blobs.getBlob(key: "blobs/\(blobHmac).bin"))
        // D1 has the row with blob_key
        let row = try await ds.queryClipByHmac(crypto.name(forContentHash: item.contentHash))
        XCTAssertNotNil(row)
    }

    func testHmacDedupReusesCloudIDIncludingDeleted() async throws {
        // Prime: existing D1 row with hmac H, deleted=1
        let (store, engine, ds, _) = try makePair()
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let hash = ClipItem.contentHash(of: "foo")
        let hmac = crypto.name(forContentHash: hash)
        // Insert pre-existing tombstoned row directly into DS
        try ds.testDirectInsert(CloudRow(
            id: "EXISTING-CLOUD-ID",
            hmac: hmac, ciphertext: Data([0x00]),
            kind: "text", blobKey: nil, byteSize: 3,
            deviceID: "OTHER", createdAt: 50, updatedAt: 100, deleted: true))

        // Local capture of same content
        let id = try store.insert(ClipItem(
            id: nil, content: "foo", contentHash: hash,
            sourceBundleID: nil, sourceAppName: nil, createdAt: 200,
            pinned: false, byteSize: 3, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 200)
        _ = try await engine.pushOnce(now: 300)

        // Local row should now be synced with the EXISTING cloud_id (reused)
        let item = try XCTUnwrap(try store.itemByID(id))
        XCTAssertEqual(item.cloudID, "EXISTING-CLOUD-ID")

        // D1 should have ONE row at hmac, deleted flipped to 0
        let row = try await ds.queryClipByHmac(hmac)
        XCTAssertEqual(row?.id, "EXISTING-CLOUD-ID")
        XCTAssertEqual(row?.deleted, false, "upsert revives deleted=1 → 0")
    }

    func testFailureAppliesBackoff() async throws {
        let store = try HistoryStore.inMemory()
        let ds = AlwaysFailDataSource()
        let blobs = AlwaysFailBlobStore()
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let engine = SyncEngine(store: store, dataSource: ds, blobStore: blobs,
                                crypto: crypto, deviceID: "DEV",
                                state: SyncStateStore(store: store))

        let id = try store.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 1, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 100)
        XCTAssertTrue(try await engine.pushOnce(now: 200))   // attempted, failed
        XCTAssertFalse(try await engine.pushOnce(now: 201))  // backed off
        XCTAssertTrue(try await engine.pushOnce(now: 202))   // due again
    }
}

// Stub that throws on every operation
final class AlwaysFailDataSource: CloudSyncDataSource, @unchecked Sendable {
    struct E: Error {}
    func ensureSchema() async throws { throw E() }
    func upsertClip(_ row: CloudRow) async throws -> Int64 { throw E() }
    func queryClipByHmac(_ hmac: String) async throws -> (id: String, deleted: Bool)? { throw E() }
    func queryClipsChangedSince(cursor: CloudCursor, limit: Int) async throws -> [CloudRow] { throw E() }
    func setClipDeleted(id: String) async throws -> Int64 { throw E() }
    func upsertDevice(_ row: DeviceRow) async throws { throw E() }
    func listDevices() async throws -> [DeviceRow] { throw E() }
    func getConfig(key: String) async throws -> String? { throw E() }
    func putConfigIfAbsent(key: String, value: String) async throws -> Bool { throw E() }
}

final class AlwaysFailBlobStore: CloudSyncBlobStore, @unchecked Sendable {
    struct E: Error {}
    func putBlob(key: String, body: Data) async throws { throw E() }
    func getBlob(key: String) async throws -> Data? { throw E() }
    func deleteBlob(key: String) async throws { throw E() }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEnginePushTests
```

- [ ] **Step 3: Implement SyncEngine (init + push half)**

```swift
// Sources/Clip/Sync/SyncEngine.swift
import Foundation

/// Cloud sync orchestrator. Spec §4.1: actor; two background loops
/// (push drainer + 30s pull tick) plus signal-based wakeups.
/// This task adds push-only; pull / enableSync / fetchBlob / backfill /
/// excludeItem follow in T17–T21.
actor SyncEngine {
    let store: HistoryStore
    let dataSource: CloudSyncDataSource
    let blobStore: CloudSyncBlobStore
    let crypto: CryptoBox
    let deviceID: String
    let state: SyncStateStore
    let queue: SyncQueue

    init(store: HistoryStore, dataSource: CloudSyncDataSource,
         blobStore: CloudSyncBlobStore, crypto: CryptoBox,
         deviceID: String, state: SyncStateStore) {
        self.store = store
        self.dataSource = dataSource
        self.blobStore = blobStore
        self.crypto = crypto
        self.deviceID = deviceID
        self.state = state
        self.queue = SyncQueue(store: store)
    }

    // MARK: - public enqueue API

    func enqueueClipPush(itemID: Int64, at: Int64) throws {
        // Spec §10.4 — runtime guard against >2MB images. Backfill SQL also
        // filters but live onChange-fired enqueues need their own check.
        if let item = try store.itemByID(itemID),
           item.kind == .image, let blobID = item.blobID,
           let info = try store.blobInfo(id: blobID),
           info.size > 2 * 1024 * 1024 {
            return
        }
        try queue.enqueue(op: .putClip, targetKey: String(itemID), at: at)
    }

    func enqueueBlobPush(blobID: Int64, at: Int64) throws {
        try queue.enqueue(op: .putBlob, targetKey: String(blobID), at: at)
    }

    // MARK: - push drainer

    /// Drain at most one queue row. Returns true iff a row was attempted.
    @discardableResult
    func pushOnce(now: Int64) async throws -> Bool {
        guard let row = try queue.dequeueDueAt(now: now) else { return false }
        do {
            try await execute(row)
            try queue.delete(id: row.id)
        } catch {
            try queue.recordFailure(id: row.id,
                                    attempts: row.attempts + 1,
                                    error: String(describing: error),
                                    at: now)
        }
        return true
    }

    private func execute(_ row: SyncQueue.Row) async throws {
        switch row.op {
        case .putClip:   try await pushClip(itemID: Int64(row.targetKey)!)
        case .putBlob:   try await pushBlob(blobID: Int64(row.targetKey)!)
        case .putTomb:   try await pushTomb(contentHash: row.targetKey)
        case .putDevice: try await pushDevice()
        }
    }

    private func pushClip(itemID: Int64) async throws {
        guard let item = try store.itemByID(itemID) else { return }

        // Resolve blob_hmac for image items
        var blobKey: String? = nil
        var blobSize: Int? = nil
        if item.kind == .image, let blobID = item.blobID,
           let info = try store.blobInfo(id: blobID) {
            blobKey = CloudKey.blobKey(name: crypto.name(forContentHash: info.sha))
            blobSize = info.size
        }

        let payload = RowPayload(
            v: 1,
            content: item.kind == .text ? item.content : nil,
            thumbB64: nil,    // v3 leaves thumbnail generation to v3.x
            mimeType: item.mimeType,
            blobSize: blobSize,
            truncated: item.truncated,
            sourceBundleId: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            pinned: item.pinned,
            contentHash: item.contentHash)

        let json = try JSONEncoder().encode(payload)
        let sealed = try crypto.seal(json)
        let hmac = crypto.name(forContentHash: item.contentHash)

        // Fix B: hmac dedup includes deleted=1
        let existing = try await dataSource.queryClipByHmac(hmac)
        let cloudID = item.cloudID ?? existing?.id ?? UUID().uuidString.lowercased()

        let row = CloudRow(
            id: cloudID, hmac: hmac, ciphertext: sealed,
            kind: item.kind.rawValue, blobKey: blobKey,
            byteSize: item.byteSize, deviceID: deviceID,
            createdAt: item.createdAt, updatedAt: 0, deleted: false)

        let serverUpdatedAt = try await dataSource.upsertClip(row)
        let now = Int64(Date().timeIntervalSince1970)
        try store.markClipSynced(id: itemID, cloudID: cloudID,
                                 updatedAt: serverUpdatedAt, at: now)
        if let blobKey {
            try store.setItemCloudBlobKey(id: itemID, blobKey: blobKey)
        }
    }

    private func pushBlob(blobID: Int64) async throws {
        guard let bytes = try store.blob(id: blobID),
              let info = try store.blobInfo(id: blobID) else { return }
        let sealed = try crypto.seal(bytes)
        let key = CloudKey.blobKey(name: crypto.name(forContentHash: info.sha))
        try await blobStore.putBlob(key: key, body: sealed)
        let now = Int64(Date().timeIntervalSince1970)
        try store.markBlobSynced(id: blobID, at: now)
    }

    // Implementations in T18 / T20 / T21
    private func pushTomb(contentHash: String) async throws {
        // Implemented in Task 21 (excludeItem).
        _ = contentHash
    }

    private func pushDevice() async throws {
        // Out of scope for v3 — see spec §13. DevicePayload defined so v3.1 can wire.
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEnginePushTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEnginePushTests.swift
git commit -m "sync: SyncEngine push — R2-then-D1 + hmac dedup includes deleted (fix B)"
```

---

### Task 17: SyncEngine pull — composite cursor + tombstone branch + LWW skip

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — append pullOnce + helpers
- Create: `Tests/ClipTests/Sync/SyncEnginePullTests.swift`

Bakes in **fix A** (composite cursor advance even on LWW skip).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEnginePullTests.swift
import XCTest
@testable import Clip

final class SyncEnginePullTests: XCTestCase {
    /// A and B share one DataSource + one BlobStore + one master_key.
    /// A push → B pull → B sees the same content_hash.
    func makePair() throws -> (HistoryStore, SyncEngine, HistoryStore, SyncEngine) {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blobs = LocalDirBlobStore(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 7, count: 32))
        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "A",
                                 state: SyncStateStore(store: storeA))
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "B",
                                 state: SyncStateStore(store: storeB))
        return (storeA, engineA, storeB, engineB)
    }

    func testTextEndToEnd() async throws {
        let (storeA, engineA, storeB, engineB) = try makePair()
        let id = try storeA.insert(ClipItem(
            id: nil, content: "shared!", contentHash: ClipItem.contentHash(of: "shared!"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 7, truncated: false))
        try await engineA.enqueueClipPush(itemID: id, at: 100)
        _ = try await engineA.pushOnce(now: 200)

        try await engineB.pullOnce(now: 300)
        XCTAssertEqual(try storeB.listRecent().map(\.content), ["shared!"])
    }

    func testPullSkipsAlreadyKnownEtagViaLWWAdvancesCursor() async throws {
        let (storeA, engineA, storeB, engineB) = try makePair()
        let id = try storeA.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try await engineA.enqueueClipPush(itemID: id, at: 1)
        _ = try await engineA.pushOnce(now: 1)

        try await engineB.pullOnce(now: 2)
        XCTAssertEqual(try storeB.listRecent().count, 1)
        // Second pull: cursor must have advanced past that row.
        let cursor1 = try SyncStateStore(store: storeB).get("cloud_pull_cursor")
        try await engineB.pullOnce(now: 3)
        let cursor2 = try SyncStateStore(store: storeB).get("cloud_pull_cursor")
        XCTAssertEqual(cursor1, cursor2, "cursor stable when no new rows")
        XCTAssertEqual(try storeB.listRecent().count, 1, "no duplicate inserts")
    }

    func testTombstonePropagatesAndDeletesLocal() async throws {
        let (storeA, engineA, storeB, engineB) = try makePair()
        let hash = ClipItem.contentHash(of: "doomed")
        let id = try storeA.insert(ClipItem(
            id: nil, content: "doomed", contentHash: hash,
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 6, truncated: false))
        try await engineA.enqueueClipPush(itemID: id, at: 100)
        _ = try await engineA.pushOnce(now: 100)
        try await engineB.pullOnce(now: 200)
        XCTAssertEqual(try storeB.listRecent().count, 1)

        // A deletes
        let cloudID = try storeA.itemByID(id)!.cloudID!
        try storeA.delete(id: id)
        // Manually mark D1 row deleted (excludeItem path, T21, will wrap this)
        _ = try await ds_(engineA: engineA).setClipDeleted(id: cloudID)

        // B pulls → row gone + tombstone written
        try await engineB.pullOnce(now: 300)
        XCTAssertEqual(try storeB.listRecent().count, 0)
        XCTAssertNotNil(try storeB.tombstoneAt(contentHash: hash))
    }

    private func ds_(engineA: SyncEngine) async -> CloudSyncDataSource {
        await engineA.dataSourceForTesting
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEnginePullTests
```

- [ ] **Step 3: Add pullOnce + helpers to SyncEngine**

Append inside `actor SyncEngine`:

```swift
    // Test escape hatch — read-only access to dataSource for assertions.
    var dataSourceForTesting: CloudSyncDataSource { dataSource }

    // MARK: - pull

    /// One pass: query D1 for changes since cursor, reconcile each row into
    /// local store. Spec §7.3 with fix A (composite cursor).
    func pullOnce(now: Int64) async throws {
        var cursor = CloudCursor(serialized: try state.get("cloud_pull_cursor") ?? "0:")
        while true {
            let rows = try await dataSource.queryClipsChangedSince(
                cursor: cursor, limit: 100)
            if rows.isEmpty { break }
            for row in rows {
                // LWW skip — but still advance cursor to avoid re-fetching
                if let local = try store.itemByCloudID(row.id),
                   (local.cloudUpdatedAt ?? 0) >= row.updatedAt {
                    cursor = CloudCursor(updatedAt: row.updatedAt, id: row.id)
                    continue
                }
                try await reconcile(row: row)
                cursor = CloudCursor(updatedAt: row.updatedAt, id: row.id)
            }
            try state.set("cloud_pull_cursor", cursor.serialized)
            // If the page came back full, loop for another. If short, stop.
            if rows.count < 100 { break }
        }
        try state.set("cloud_pull_at", String(now))
    }

    private func reconcile(row: CloudRow) async throws {
        // Decrypt payload
        let plain: Data
        do {
            plain = try crypto.open(row.ciphertext)
        } catch {
            // Decryption failure — likely wrong password. Don't delete local.
            return
        }
        let payload: RowPayload
        do {
            payload = try JSONDecoder().decode(RowPayload.self, from: plain)
        } catch {
            return
        }

        // Tombstone branch
        if row.deleted {
            try store.upsertTombstone(contentHash: payload.contentHash,
                                      cloudID: row.id,
                                      tombstonedAt: row.updatedAt,
                                      cloudUpdatedAt: row.updatedAt)
            try store.deleteItemsByContentHashOlderThan(payload.contentHash, row.updatedAt)
            return
        }

        // Resurrection guard: if local tombstone is newer than this row's
        // created_at, the row represents a stale resurrection — drop it.
        if let tombAt = try store.tombstoneAt(contentHash: payload.contentHash),
           tombAt >= row.createdAt {
            return
        }

        // Existing local row by content_hash → update mutable fields (pin)
        if let local = try store.itemByContentHash(payload.contentHash),
           let localID = local.id {
            try store.markClipSynced(id: localID, cloudID: row.id,
                                     updatedAt: row.updatedAt,
                                     at: Int64(Date().timeIntervalSince1970))
            // Pin LWW: server side wins (we trust D1 as truth)
            if local.pinned != payload.pinned {
                try store.pool.write { db in
                    try db.execute(
                        sql: "UPDATE items SET pinned = ? WHERE id = ?",
                        arguments: [payload.pinned ? 1 : 0, localID])
                }
            }
            return
        }

        // Fresh INSERT
        let now = Int64(Date().timeIntervalSince1970)
        var item = ClipItem(
            id: nil,
            content: payload.content ?? "",
            contentHash: payload.contentHash,
            sourceBundleID: payload.sourceBundleId,
            sourceAppName: payload.sourceAppName,
            createdAt: row.createdAt,
            pinned: payload.pinned,
            byteSize: row.byteSize,
            truncated: payload.truncated,
            kind: ClipKind(rawValue: row.kind) ?? .text,
            blobID: nil,
            mimeType: payload.mimeType,
            cloudID: row.id,
            cloudUpdatedAt: row.updatedAt,
            cloudSyncedAt: now,
            cloudBlobKey: row.blobKey,
            syncExcluded: false,
            deviceID: row.deviceID)

        if item.kind == .image, let blobKey = row.blobKey, let blobSize = payload.blobSize {
            // Extract hmac from "blobs/<hmac>.bin"
            let hmac = String(blobKey.dropFirst(CloudKey.blobsPrefix.count).dropLast(".bin".count))
            let blobID = try store.insertLazyBlob(blobHmac: hmac, byteSize: blobSize, now: now)
            item.blobID = blobID
        }
        _ = try store.insert(item)
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEnginePullTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEnginePullTests.swift
git commit -m "sync: SyncEngine pull — composite cursor (fix A) + tomb branch + LWW skip"
```

---

### Task 18: SyncEngine.enableSync — config bootstrap + KDF

Implements **fix C** (idempotent INSERT OR IGNORE) and **fix E** (schema_version gatekeeping).

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — add static `enableSync` + `BootstrapResult` + `SyncError`
- Create: `Tests/ClipTests/Sync/SyncEngineEnableTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineEnableTests.swift
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
        XCTAssertNotNil(try await ds.getConfig(key: "kdf_salt_b64"))
        XCTAssertEqual(try await ds.getConfig(key: "kdf_iters"), "200000")
        XCTAssertEqual(try await ds.getConfig(key: "schema_version"), "3")
        XCTAssertNotNil(try kc.read(account: "master"))
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
        XCTAssertEqual(try kcB.read(account: "master"), masterA,
                       "same password+salt → same key")
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
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineEnableTests
```

- [ ] **Step 3: Add enableSync (static) + SyncError + BootstrapResult**

Add at the top of `SyncEngine.swift` (outside the actor):

```swift
enum SyncError: Error, Equatable {
    case remoteSchemaNewer(remote: String, local: String)
    case decryptionFailed
    case d1(String)
    case r2(String)
}
```

Append to `SyncEngine.swift` as an extension:

```swift
extension SyncEngine {
    enum BootstrapResult: Equatable {
        case firstDevice
        case joinedExisting
    }

    /// Spec §7.1 first-time enable. Static because it runs before SyncEngine
    /// is instantiated. Bakes in fix C (INSERT OR IGNORE) + fix E (schema_version).
    ///
    /// Side effects:
    ///   - D1 schema present (CREATE IF NOT EXISTS)
    ///   - config { schema_version='3', kdf_iters='200000', kdf_salt_b64=<...> }
    ///   - master_key written to (keychain.service, account)
    ///   - device_id allocated locally if missing
    static func enableSync(
        password: String,
        dataSource: CloudSyncDataSource,
        state: SyncStateStore,
        keychain: KeychainStore,
        account: String
    ) async throws -> BootstrapResult {
        let localSchemaVersion = "3"
        let iters = 200_000

        try await dataSource.ensureSchema()

        // Fix E — schema_version gatekeeping
        let remote = try await dataSource.getConfig(key: "schema_version") ?? localSchemaVersion
        if (Int(remote) ?? 0) > (Int(localSchemaVersion) ?? 0) {
            throw SyncError.remoteSchemaNewer(remote: remote, local: localSchemaVersion)
        }
        // Stamp our version (idempotent)
        _ = try await dataSource.putConfigIfAbsent(key: "schema_version", value: localSchemaVersion)

        // Fix C — idempotent salt + iters bootstrap
        var saltBytes = Data(count: 16)
        _ = saltBytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        let saltB64 = saltBytes.base64EncodedString()
        let iWonSalt = try await dataSource.putConfigIfAbsent(
            key: "kdf_salt_b64", value: saltB64)
        _ = try await dataSource.putConfigIfAbsent(
            key: "kdf_iters", value: String(iters))

        // Read authoritative salt (mine if iWon, theirs otherwise)
        guard let authSaltB64 = try await dataSource.getConfig(key: "kdf_salt_b64"),
              let authSalt = Data(base64Encoded: authSaltB64) else {
            throw SyncError.d1("kdf_salt_b64 missing after bootstrap")
        }

        let masterKey = KeyDerivation.pbkdf2_sha256(
            password: password, salt: authSalt,
            iterations: iters, keyLength: 32)
        try keychain.write(account: account, data: masterKey)

        // Allocate local device_id if missing
        if try state.get("device_id") == nil {
            try state.set("device_id", UUID().uuidString.lowercased())
        }

        return iWonSalt ? .firstDevice : .joinedExisting
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineEnableTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEngineEnableTests.swift
git commit -m "sync: SyncEngine.enableSync — idempotent bootstrap + schema-version guard (fix C+E)"
```

---

### Task 19: SyncEngine.fetchBlob — lazy image download

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — add `fetchBlob(blobID:)`
- Create: `Tests/ClipTests/Sync/SyncEngineLazyBlobTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineLazyBlobTests.swift
import XCTest
@testable import Clip

final class SyncEngineLazyBlobTests: XCTestCase {
    func testFetchBlobDecryptsAndFillsLocalRow() async throws {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blobs = LocalDirBlobStore(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xEE, count: 32))
        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "A",
                                 state: SyncStateStore(store: storeA))
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "B",
                                 state: SyncStateStore(store: storeB))

        // A inserts and pushes
        let bytes = Data(repeating: 0x42, count: 1024)
        let aID = try storeA.insertImage(
            bytes: bytes, mimeType: "image/png",
            sourceBundleID: nil, sourceAppName: nil, now: 100)
        let aBlobID = try XCTUnwrap(try storeA.itemByID(aID)?.blobID)
        try await engineA.enqueueClipPush(itemID: aID, at: 100)
        try await engineA.enqueueBlobPush(blobID: aBlobID, at: 100)
        _ = try await engineA.pushOnce(now: 100)
        _ = try await engineA.pushOnce(now: 101)

        // B pulls — has lazy ref
        try await engineB.pullOnce(now: 200)
        let bItem = try XCTUnwrap(try storeB.listRecent().first)
        let bBlobID = try XCTUnwrap(bItem.blobID)
        XCTAssertTrue((try storeB.blob(id: bBlobID) ?? Data()).isEmpty)

        // B fetches: hits backend, decrypts, fills local
        let got = try await engineB.fetchBlob(blobID: bBlobID)
        XCTAssertEqual(got, bytes)
        XCTAssertEqual(try storeB.blob(id: bBlobID), bytes)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineLazyBlobTests
```

- [ ] **Step 3: Implement fetchBlob**

Append inside `actor SyncEngine`:

```swift
    /// Spec §7.4 lazy image download. Caller holds a clip_blobs.id whose
    /// `bytes` is empty (sha256 prefixed `lazy:`). Resolves the blob_hmac,
    /// GETs blobs/<hmac>.bin, decrypts, fills local row, returns bytes.
    func fetchBlob(blobID: Int64) async throws -> Data {
        guard let info = try store.lazyBlobHmac(id: blobID) else {
            // Already filled — caller should re-read.
            return (try store.blob(id: blobID)) ?? Data()
        }
        let key = CloudKey.blobKey(name: info.hmac)
        guard let sealed = try await blobStore.getBlob(key: key) else {
            throw SyncError.r2("blob \(info.hmac) not found in cloud")
        }
        let bytes = try crypto.open(sealed)
        let realSha = ClipItem.contentHash(of: bytes)
        try store.fillBlob(id: blobID, bytes: bytes, sha256: realSha,
                           at: Int64(Date().timeIntervalSince1970))
        return bytes
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineLazyBlobTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEngineLazyBlobTests.swift
git commit -m "sync: SyncEngine.fetchBlob — R2 GET + decrypt + fill local row"
```

---

### Task 20: SyncEngine.backfill — enqueue existing items on enable

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — add `backfill(now:)`
- Create: `Tests/ClipTests/Sync/SyncEngineBackfillTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineBackfillTests.swift
import XCTest
@testable import Clip

final class SyncEngineBackfillTests: XCTestCase {
    func makeEngine(_ store: HistoryStore) async throws -> SyncEngine {
        let ds = try LocalSqliteDataSource()
        try await ds.ensureSchema()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SyncEngine(store: store, dataSource: ds,
                          blobStore: LocalDirBlobStore(root: dir),
                          crypto: CryptoBox(masterKey: Data(repeating: 1, count: 32)),
                          deviceID: "DEV",
                          state: SyncStateStore(store: store))
    }

    func testBackfillEnqueuesNewestFirst() async throws {
        let store = try HistoryStore.inMemory()
        let engine = try await makeEngine(store)
        for (i, c) in ["old", "mid", "new"].enumerated() {
            try store.insert(ClipItem(
                id: nil, content: c, contentHash: ClipItem.contentHash(of: c),
                sourceBundleID: nil, sourceAppName: nil, createdAt: Int64(100 + i),
                pinned: false, byteSize: c.utf8.count, truncated: false))
        }
        try await engine.backfill(now: 1000)
        let q = SyncQueue(store: store)
        let r = try XCTUnwrap(try q.dequeueDueAt(now: 2000))
        let item = try XCTUnwrap(try store.itemByID(Int64(r.targetKey)!))
        XCTAssertEqual(item.content, "new", "newest first")
    }

    func testBackfillSkipsExcluded() async throws {
        let store = try HistoryStore.inMemory()
        let engine = try await makeEngine(store)
        let id = try store.insert(ClipItem(
            id: nil, content: "secret", contentHash: ClipItem.contentHash(of: "secret"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 6, truncated: false))
        try store.setSyncExcluded(id: id, excluded: true)
        try await engine.backfill(now: 1000)
        XCTAssertEqual(try SyncQueue(store: store).peekAll().count, 0)
    }

    func testBackfillSkipsAlreadySyncedItems() async throws {
        let store = try HistoryStore.inMemory()
        let engine = try await makeEngine(store)
        let id = try store.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try store.markClipSynced(id: id, cloudID: "c", updatedAt: 1, at: 1)
        try await engine.backfill(now: 1000)
        XCTAssertEqual(try SyncQueue(store: store).peekAll().count, 0,
                       "synced items not re-enqueued")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineBackfillTests
```

- [ ] **Step 3: Implement backfill**

Append inside `actor SyncEngine`:

```swift
    /// Spec §7.6 — enqueue every existing non-excluded, non-yet-synced item
    /// (and its blob if image and ≤2MB). Run once after `enableSync` finishes
    /// AND only on the first device (BootstrapResult.firstDevice).
    func backfill(now: Int64) async throws {
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
                SELECT 'put_clip', CAST(items.id AS TEXT), 0, ?, ?
                FROM items
                LEFT JOIN clip_blobs ON items.blob_id = clip_blobs.id
                WHERE items.sync_excluded = 0
                  AND items.cloud_id IS NULL
                  AND (items.kind = 'text' OR clip_blobs.byte_size <= 2097152)
                ORDER BY items.created_at DESC
            """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
                SELECT 'put_blob', CAST(clip_blobs.id AS TEXT), 0, ?, ?
                FROM clip_blobs
                JOIN items ON items.blob_id = clip_blobs.id
                WHERE items.sync_excluded = 0
                  AND items.cloud_id IS NULL
                  AND clip_blobs.byte_size <= 2097152
                ORDER BY items.created_at DESC
            """, arguments: [now, now])
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineBackfillTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEngineBackfillTests.swift
git commit -m "sync: SyncEngine.backfill — enqueue existing items newest-first"
```

---

### Task 21: SyncEngine.excludeItem + tomb push

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — implement `excludeItem` + `pushTomb`
- Create: `Tests/ClipTests/Sync/SyncEngineExcludeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineExcludeTests.swift
import XCTest
@testable import Clip

final class SyncEngineExcludeTests: XCTestCase {
    func makePair() throws -> (HistoryStore, SyncEngine, LocalSqliteDataSource) {
        let ds = try LocalSqliteDataSource()
        let group = DispatchGroup()
        group.enter(); Task { try? await ds.ensureSchema(); group.leave() }
        group.wait()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try HistoryStore.inMemory()
        let engine = SyncEngine(
            store: store, dataSource: ds,
            blobStore: LocalDirBlobStore(root: dir),
            crypto: CryptoBox(masterKey: Data(repeating: 0xCC, count: 32)),
            deviceID: "DEV", state: SyncStateStore(store: store))
        return (store, engine, ds)
    }

    func testExcludeSyncedItemDeletesQueueAndMarksRemote() async throws {
        let (store, engine, ds) = try makePair()
        let id = try store.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 1, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 100)
        _ = try await engine.pushOnce(now: 100)

        // Verify D1 has it (deleted=0)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xCC, count: 32))
        let hmac = crypto.name(forContentHash: ClipItem.contentHash(of: "x"))
        XCTAssertEqual(try await ds.queryClipByHmac(hmac)?.deleted, false)

        try await engine.excludeItem(id: id, at: 200)

        // Local: sync_excluded set + tombstone written
        XCTAssertEqual(try store.itemByID(id)?.syncExcluded, true)
        XCTAssertNotNil(try store.tombstoneAt(contentHash: ClipItem.contentHash(of: "x")))
        // Local sync_queue: no put_clip; one put_tomb (drained next pushOnce)
        let q = try SyncQueue(store: store).peekAll()
        XCTAssertEqual(q.filter { $0.op == .putClip }.count, 0)
        XCTAssertEqual(q.filter { $0.op == .putTomb }.count, 1)

        // Drain the tomb push → D1 row.deleted = 1
        _ = try await engine.pushOnce(now: 300)
        XCTAssertEqual(try await ds.queryClipByHmac(hmac)?.deleted, true)
    }

    func testExcludeUnsyncedItemOnlyClearsQueue() async throws {
        let (store, engine, _) = try makePair()
        let id = try store.insert(ClipItem(
            id: nil, content: "y", contentHash: ClipItem.contentHash(of: "y"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 1, truncated: false))
        try await engine.enqueueClipPush(itemID: id, at: 100)

        try await engine.excludeItem(id: id, at: 200)

        XCTAssertEqual(try store.itemByID(id)?.syncExcluded, true)
        XCTAssertEqual(try SyncQueue(store: store).peekAll().count, 0,
                       "no put_tomb (never reached cloud) + put_clip cleared")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineExcludeTests
```

- [ ] **Step 3: Implement excludeItem + pushTomb**

Replace the placeholder `pushTomb` and add `excludeItem`:

```swift
    /// User toggles "do not sync this" on a panel row. Spec §7.5.
    func excludeItem(id: Int64, at: Int64) async throws {
        guard let item = try store.itemByID(id) else { return }
        try store.setSyncExcluded(id: id, excluded: true)
        try queue.deleteAllForItem(itemID: id)
        if let cloudID = item.cloudID {
            // Already on cloud → write local tombstone + enqueue tomb push
            try store.upsertTombstone(contentHash: item.contentHash,
                                      cloudID: cloudID,
                                      tombstonedAt: at,
                                      cloudUpdatedAt: at)
            try queue.enqueue(op: .putTomb, targetKey: item.contentHash, at: at)
        }
        // Else: never reached cloud, no remote action needed.
    }

    private func pushTomb(contentHash: String) async throws {
        // Fetch local tomb to find cloud_id
        let cloudID = try store.pool.read { db in
            try String.fetchOne(db,
                sql: "SELECT cloud_id FROM tombstones WHERE content_hash = ?",
                arguments: [contentHash])
        }
        guard let cloudID else { return }
        let serverUpdatedAt = try await dataSource.setClipDeleted(id: cloudID)
        // Re-stamp local tombstone with server-authoritative updated_at
        try store.upsertTombstone(contentHash: contentHash,
                                  cloudID: cloudID,
                                  tombstonedAt: serverUpdatedAt,
                                  cloudUpdatedAt: serverUpdatedAt)
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineExcludeTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEngineExcludeTests.swift
git commit -m "sync: SyncEngine.excludeItem + pushTomb (tomb writes UPDATE deleted=1)"
```

---

## Phase P4 — UI + wire-in

### Task 22: SyncSettings — UserDefaults config wrapper

**Files:**
- Create: `Sources/Clip/Sync/SyncSettings.swift`
- Create: `Tests/ClipTests/Sync/SyncSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncSettingsTests.swift
import XCTest
@testable import Clip

final class SyncSettingsTests: XCTestCase {
    var defaults: UserDefaults!
    var s: SyncSettings!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        s = SyncSettings(defaults: defaults)
    }

    func testDefaultsAreEmpty() {
        XCTAssertFalse(s.enabled)
        XCTAssertNil(s.r2Endpoint)
        XCTAssertNil(s.r2Bucket)
        XCTAssertNil(s.r2AccessKeyID)
        XCTAssertNil(s.d1AccountID)
        XCTAssertNil(s.d1DatabaseID)
    }

    func testRoundTrip() {
        s.enabled = true
        s.r2Endpoint = "https://x.r2.cloudflarestorage.com"
        s.r2Bucket = "clip-sync"
        s.r2AccessKeyID = "AK"
        s.d1AccountID = "ACCT"
        s.d1DatabaseID = "DB-UUID"
        let s2 = SyncSettings(defaults: defaults)
        XCTAssertTrue(s2.enabled)
        XCTAssertEqual(s2.r2Endpoint, "https://x.r2.cloudflarestorage.com")
        XCTAssertEqual(s2.r2Bucket, "clip-sync")
        XCTAssertEqual(s2.r2AccessKeyID, "AK")
        XCTAssertEqual(s2.d1AccountID, "ACCT")
        XCTAssertEqual(s2.d1DatabaseID, "DB-UUID")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncSettingsTests
```

- [ ] **Step 3: Implement SyncSettings**

```swift
// Sources/Clip/Sync/SyncSettings.swift
import Foundation

/// User-facing sync configuration. Non-secrets in UserDefaults; secret R2
/// access key + D1 API token + master key in Keychain (separate stores).
final class SyncSettings: Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let enabled       = "clip.cloud.enabled"
        static let r2Endpoint    = "clip.cloud.r2.endpoint"
        static let r2Bucket      = "clip.cloud.r2.bucket"
        static let r2AccessKeyID = "clip.cloud.r2.access_key_id"
        static let d1AccountID   = "clip.cloud.d1.account_id"
        static let d1DatabaseID  = "clip.cloud.d1.database_id"
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }
    var r2Endpoint: String? {
        get { defaults.string(forKey: Key.r2Endpoint) }
        set { defaults.set(newValue, forKey: Key.r2Endpoint) }
    }
    var r2Bucket: String? {
        get { defaults.string(forKey: Key.r2Bucket) }
        set { defaults.set(newValue, forKey: Key.r2Bucket) }
    }
    var r2AccessKeyID: String? {
        get { defaults.string(forKey: Key.r2AccessKeyID) }
        set { defaults.set(newValue, forKey: Key.r2AccessKeyID) }
    }
    var d1AccountID: String? {
        get { defaults.string(forKey: Key.d1AccountID) }
        set { defaults.set(newValue, forKey: Key.d1AccountID) }
    }
    var d1DatabaseID: String? {
        get { defaults.string(forKey: Key.d1DatabaseID) }
        set { defaults.set(newValue, forKey: Key.d1DatabaseID) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncSettingsTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncSettings.swift Tests/ClipTests/Sync/SyncSettingsTests.swift
git commit -m "sync: SyncSettings — UserDefaults wrapper for R2+D1 non-secret config"
```

---

### Task 23: PanelView — sync icon + ⌘N exclude shortcut

**Files:**
- Modify: `Sources/Clip/Panel/PanelView.swift` — add icon column
- Modify: `Sources/Clip/Panel/PanelModel.swift` — `toggleExcludeSelected()` action + `onExclude` callback
- Modify: `Sources/Clip/Panel/PanelWindow.swift` — wire ⌘N

(No automated test; AppKit / SwiftUI integration. Manually verifiable via T26 checklist.)

- [ ] **Step 1: Add `toggleExcludeSelected` to PanelModel**

In `Sources/Clip/Panel/PanelModel.swift`, append:

```swift
    /// User pressed ⌘N to mark the selected item as not-syncing.
    /// AppDelegate wires this to engine.excludeItem(id:at:).
    var onExclude: ((Int64) -> Void)?

    func toggleExcludeSelected() {
        guard let id = selectedItem()?.id else { return }
        onExclude?(id)
    }
```

- [ ] **Step 2: Wire ⌘N in PanelWindow**

In `Sources/Clip/Panel/PanelWindow.swift`, add to `KeyHandlers`:

```swift
    var onExclude: () -> Void = {}
```

In the key-handling switch (near the existing ⌘P / ⌘D handling), add:

```swift
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "n" {
            keyHandlers.onExclude()
            return nil
        }
```

- [ ] **Step 3: Add sync icon column to PanelView row**

In `Sources/Clip/Panel/PanelView.swift`, in the row-rendering view (search for "📌"), append after existing trailing metadata:

```swift
            if let icon = syncIcon(for: item) {
                Text(icon)
                    .frame(width: 14, alignment: .center)
                    .help(syncTooltip(for: item))
            }
```

Add helpers at file scope:

```swift
private func syncIcon(for item: ClipItem) -> String? {
    if item.syncExcluded { return "🚫" }
    if item.cloudSyncedAt != nil { return "☁️" }
    // ⏳ / ⚠️ / 📤 deferred to v3.x (spec §13)
    return nil
}

private func syncTooltip(for item: ClipItem) -> String {
    if item.syncExcluded { return "已标记为不同步 (⌘N 取消)" }
    if item.cloudSyncedAt != nil { return "已同步到云端" }
    return ""
}
```

- [ ] **Step 4: Build to verify it compiles**

```bash
swift build
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Panel/PanelView.swift Sources/Clip/Panel/PanelModel.swift Sources/Clip/Panel/PanelWindow.swift
git commit -m "sync: PanelView — ⌘N exclude + ☁️/🚫 sync status icon"
```

---

### Task 24: CloudSyncView — Preferences "云同步" tab (parallel test-connection)

**Files:**
- Create: `Sources/Clip/Preferences/CloudSyncView.swift`
- Modify: `Sources/Clip/Preferences/PreferencesWindow.swift` — add tab
- Modify: `PreferencesContainer` — add `syncSettings`

This is **fix F** — parallel ping with three checkmarks.

(No automated test; SwiftUI. Manually verified via T26.)

- [ ] **Step 1: Create CloudSyncView**

```swift
// Sources/Clip/Preferences/CloudSyncView.swift
import SwiftUI

@MainActor
struct CloudSyncView: View {
    @State private var enabled = false
    @State private var r2Endpoint = ""
    @State private var r2Bucket = "clip-sync"
    @State private var r2AccessKeyID = ""
    @State private var r2Secret = ""
    @State private var d1AccountID = ""
    @State private var d1DatabaseID = ""
    @State private var apiToken = ""
    @State private var syncPassword = ""

    @State private var r2Status: TestStatus = .idle
    @State private var d1Status: TestStatus = .idle
    @State private var tokenStatus: TestStatus = .idle
    @State private var bootstrapping = false
    @State private var statusMessage = ""

    enum TestStatus: Equatable {
        case idle, pending, ok, fail(String)
    }

    private var settings: SyncSettings { PreferencesContainer.shared.syncSettings }

    var body: some View {
        Form {
            Toggle("启用云同步", isOn: $enabled)
                .onChange(of: enabled) { _, new in settings.enabled = new }

            if enabled {
                Section("R2（图片字节）") {
                    TextField("Endpoint", text: $r2Endpoint)
                        .help("形如 https://<account>.r2.cloudflarestorage.com")
                    TextField("Bucket", text: $r2Bucket)
                    TextField("Access Key ID", text: $r2AccessKeyID)
                    SecureField("Secret Access Key", text: $r2Secret)
                }

                Section("D1（条目元数据）") {
                    TextField("Account ID", text: $d1AccountID)
                    TextField("Database ID", text: $d1DatabaseID)
                    SecureField("API Token", text: $apiToken)
                        .help("Account → R2:Edit + D1:Edit")
                }

                Section("测试连接") {
                    HStack { statusIcon(r2Status); Text("R2 (blob 上下传)") }
                    HStack { statusIcon(d1Status); Text("D1 (条目同步)") }
                    HStack { statusIcon(tokenStatus); Text("API Token (有效性)") }
                    Button("并行测试") { testConnection() }
                        .disabled(testButtonDisabled)
                }

                Section("同步密码 (E2E)") {
                    SecureField("同步密码 (≥12 字符)", text: $syncPassword)
                    Button(bootstrapping ? "正在初始化…" : "初始化 / 加入云端") { bootstrap() }
                        .disabled(bootstrapButtonDisabled)
                    Text("剪贴板内容在上传前用你的同步密码做端到端加密 (ChaCha20-Poly1305)，云端永远拿不到明文。\n\n⚠️ 密码丢失 = 云端数据全部不可恢复，请使用密码管理器保存。")
                        .font(.caption).foregroundColor(.secondary)
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage).foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func statusIcon(_ s: TestStatus) -> some View {
        switch s {
        case .idle:    Text("·").frame(width: 14)
        case .pending: ProgressView().controlSize(.small).frame(width: 14)
        case .ok:      Text("✓").foregroundColor(.green).frame(width: 14)
        case .fail(let msg):
            Text("✗").foregroundColor(.red).frame(width: 14)
                .help(msg)
        }
    }

    private var testButtonDisabled: Bool {
        r2Endpoint.isEmpty || r2Bucket.isEmpty || r2AccessKeyID.isEmpty
        || r2Secret.isEmpty || d1AccountID.isEmpty || d1DatabaseID.isEmpty
        || apiToken.isEmpty
        || r2Status == .pending || d1Status == .pending || tokenStatus == .pending
    }

    private var bootstrapButtonDisabled: Bool {
        bootstrapping || syncPassword.count < 12 || testButtonDisabled
    }

    private func load() {
        enabled = settings.enabled
        r2Endpoint = settings.r2Endpoint ?? ""
        r2Bucket = settings.r2Bucket ?? "clip-sync"
        r2AccessKeyID = settings.r2AccessKeyID ?? ""
        d1AccountID = settings.d1AccountID ?? ""
        d1DatabaseID = settings.d1DatabaseID ?? ""
    }

    /// Fix F — three pings in parallel; status updates as each completes.
    private func testConnection() {
        r2Status = .pending; d1Status = .pending; tokenStatus = .pending
        let r2 = makeR2()
        let d1 = makeD1()
        let token = apiToken
        Task {
            async let rR: TestStatus = pingR2(r2)
            async let rD: TestStatus = pingD1(d1)
            async let rT: TestStatus = pingToken(token: token, account: d1AccountID)
            let (a, b, c) = await (rR, rD, rT)
            await MainActor.run {
                r2Status = a; d1Status = b; tokenStatus = c
                if a == .ok && b == .ok && c == .ok { persistOnSuccess() }
            }
        }
    }

    private func makeR2() -> R2BlobBackend? {
        guard let url = URL(string: r2Endpoint) else { return nil }
        return R2BlobBackend(endpoint: url, bucket: r2Bucket,
                             accessKeyID: r2AccessKeyID, secretAccessKey: r2Secret)
    }

    private func makeD1() -> D1Backend {
        D1Backend(accountID: d1AccountID, databaseID: d1DatabaseID,
                  apiToken: apiToken)
    }

    private func pingR2(_ b: R2BlobBackend?) async -> TestStatus {
        guard let b else { return .fail("R2 endpoint URL 无效") }
        do {
            // GET a key that's almost certainly absent → 404 is success
            _ = try await b.getBlob(key: "_probe/handshake.bin")
            return .ok
        } catch {
            return .fail("\(error)")
        }
    }

    private func pingD1(_ d: D1Backend) async -> TestStatus {
        do {
            _ = try await d.getConfig(key: "schema_version")  // SELECT works → token + DB OK
            return .ok
        } catch {
            return .fail("\(error)")
        }
    }

    private func pingToken(token: String, account: String) async -> TestStatus {
        var req = URLRequest(url: URL(string: "https://api.cloudflare.com/client/v4/user/tokens/verify")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as! HTTPURLResponse
            guard http.statusCode == 200 else { return .fail("\(http.statusCode)") }
            // Body must contain "active"
            if let s = String(data: data, encoding: .utf8), s.contains("active") {
                return .ok
            }
            return .fail("token not active")
        } catch {
            return .fail("\(error)")
        }
    }

    @MainActor
    private func persistOnSuccess() {
        settings.r2Endpoint = r2Endpoint
        settings.r2Bucket = r2Bucket
        settings.r2AccessKeyID = r2AccessKeyID
        settings.d1AccountID = d1AccountID
        settings.d1DatabaseID = d1DatabaseID
        try? KeychainStore(service: "com.zyw.clip.cloud-r2-secret-v1")
            .write(account: "current", data: Data(r2Secret.utf8))
        try? KeychainStore(service: "com.zyw.clip.cloud-d1-token-v1")
            .write(account: "current", data: Data(apiToken.utf8))
    }

    /// Spec §7.1 — call SyncEngine.enableSync.
    private func bootstrap() {
        bootstrapping = true
        let pwd = syncPassword
        let d1 = makeD1()
        Task {
            defer { Task { @MainActor in bootstrapping = false } }
            let store = PreferencesContainer.shared.store!
            let state = SyncStateStore(store: store)
            let masterKC = KeychainStore(service: "com.zyw.clip.cloud-master-v1")
            do {
                let result = try await SyncEngine.enableSync(
                    password: pwd, dataSource: d1, state: state,
                    keychain: masterKC, account: "current")
                await MainActor.run {
                    settings.enabled = true
                    statusMessage = result == .firstDevice
                        ? "✓ 已初始化新云端 profile"
                        : "✓ 已加入现有云端"
                }
                NotificationCenter.default.post(name: .clipCloudSyncDidEnable, object: nil)
            } catch {
                await MainActor.run { statusMessage = "✗ 初始化失败: \(error)" }
            }
        }
    }
}

extension Notification.Name {
    static let clipCloudSyncDidEnable = Notification.Name("clip.cloud.didEnable")
}
```

- [ ] **Step 2: Add tab + container field**

In `Sources/Clip/Preferences/PreferencesWindow.swift`, find the `TabView { ... }` and append:

```swift
            CloudSyncView()
                .tabItem { Label("云同步", systemImage: "cloud") }
                .tag("cloud")
```

In whichever file declares `PreferencesContainer.shared`, add:

```swift
    var syncSettings: SyncSettings = SyncSettings()
```

- [ ] **Step 3: Build to verify it compiles**

```bash
swift build
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Clip/Preferences/CloudSyncView.swift Sources/Clip/Preferences/PreferencesWindow.swift
git commit -m "sync: CloudSyncView — Preferences tab w/ parallel test-connection (fix F)"
```

---

### Task 25: AppDelegate wire-in — instantiate SyncEngine when enabled

**Files:**
- Modify: `Sources/Clip/ClipApp.swift` — instantiate engine + start background loops + wire panel exclude + handle bootstrap notification + lazy blob wire-up

- [ ] **Step 1: Add engine fields + startup hook**

In `AppDelegate`, after `observer.start()`:

```swift
        // 7.5 Cloud sync (v3, D1+R2). Spec §4.1.
        startCloudSyncIfEnabled()
        NotificationCenter.default.addObserver(
            forName: .clipCloudSyncDidEnable, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.startCloudSyncIfEnabled()
            // First-device backfill on cold-start of engine
            if let engine = self.syncEngine {
                Task { try? await engine.backfill(now: Int64(Date().timeIntervalSince1970)) }
            }
        }
```

Add at bottom of `AppDelegate`:

```swift
    var syncEngine: SyncEngine?
    private var pushLoopTask: Task<Void, Never>?
    private var pullLoopTask: Task<Void, Never>?

    func startCloudSyncIfEnabled() {
        let settings = PreferencesContainer.shared.syncSettings
        guard settings.enabled,
              let endpoint = settings.r2Endpoint.flatMap(URL.init),
              let bucket = settings.r2Bucket,
              let r2AK = settings.r2AccessKeyID,
              let r2Secret = (try? KeychainStore(service: "com.zyw.clip.cloud-r2-secret-v1")
                              .read(account: "current")).flatMap({ String(data: $0, encoding: .utf8) }),
              let d1AccountID = settings.d1AccountID,
              let d1DatabaseID = settings.d1DatabaseID,
              let d1Token = (try? KeychainStore(service: "com.zyw.clip.cloud-d1-token-v1")
                             .read(account: "current")).flatMap({ String(data: $0, encoding: .utf8) }),
              let masterKey = try? KeychainStore(service: "com.zyw.clip.cloud-master-v1")
                                  .read(account: "current")
        else { return }

        let crypto = CryptoBox(masterKey: masterKey)
        let blobs = R2BlobBackend(endpoint: endpoint, bucket: bucket,
                                  accessKeyID: r2AK, secretAccessKey: r2Secret)
        let ds = D1Backend(accountID: d1AccountID, databaseID: d1DatabaseID,
                           apiToken: d1Token)
        let state = SyncStateStore(store: store)
        let deviceID = (try? state.get("device_id")) ?? UUID().uuidString.lowercased()
        try? state.set("device_id", deviceID)

        let engine = SyncEngine(store: store, dataSource: ds, blobStore: blobs,
                                crypto: crypto, deviceID: deviceID, state: state)
        self.syncEngine = engine

        // Wire HistoryStore.onChange → engine.enqueue
        store.onChange = { [weak self] change in
            guard let engine = self?.syncEngine else { return }
            let now = Int64(Date().timeIntervalSince1970)
            Task {
                switch change {
                case .inserted(let id):
                    try? await engine.enqueueClipPush(itemID: id, at: now)
                    // Image case: also enqueue blob push
                    if let item = try? engine.store.itemByID(id),
                       let blobID = item.blobID {
                        try? await engine.enqueueBlobPush(blobID: blobID, at: now)
                    }
                case .deleted(_, let hash):
                    try? await engine.excludeItemByHash(contentHash: hash, at: now)
                case .pinToggled(let id):
                    try? await engine.enqueueClipPush(itemID: id, at: now)
                case .excludedToggled:
                    break  // handled by engine.excludeItem directly
                }
            }
        }

        // Wire panel ⌘N
        panelModel.onExclude = { [weak self] id in
            guard let engine = self?.syncEngine else { return }
            let now = Int64(Date().timeIntervalSince1970)
            Task { try? await engine.excludeItem(id: id, at: now) }
        }

        // Lazy blob fetch wire-up: replace panelModel paste closure for
        // image kind so empty bytes trigger engine.fetchBlob first.
        let originalPaste = panelModel.pasteCallback
        panelModel.pasteCallback = { [weak self] item in
            guard let self else { return }
            if item.kind == .image, let blobID = item.blobID {
                Task {
                    var bytes = (try? self.store.blob(id: blobID)) ?? Data()
                    if bytes.isEmpty, let engine = self.syncEngine {
                        bytes = (try? await engine.fetchBlob(blobID: blobID)) ?? Data()
                    }
                    if !bytes.isEmpty {
                        await MainActor.run {
                            self.injector.pasteImage(
                                bytes: bytes,
                                mimeType: item.mimeType ?? "image/png"
                            ) { self.panel.close() }
                        }
                    } else {
                        await MainActor.run { self.panel.close() }
                    }
                }
            } else {
                originalPaste?(item)
            }
        }

        // Background push drainer + 30s pull tick
        pushLoopTask = Task { [weak engine] in
            while !Task.isCancelled, let engine {
                let did = (try? await engine.pushOnce(now: Int64(Date().timeIntervalSince1970))) ?? false
                if !did { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        pullLoopTask = Task { [weak engine] in
            while !Task.isCancelled, let engine {
                _ = try? await engine.pullOnce(now: Int64(Date().timeIntervalSince1970))
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
```

> **Note**: this assumes `PanelModel` exposes a settable `pasteCallback`. If it doesn't, refactor to expose it as part of T23, or rebuild `panelModel` here with the lazy-aware closure.

> **Note**: `engine.excludeItemByHash` is a small helper — add to SyncEngine if not present:
> ```swift
> func excludeItemByHash(contentHash: String, at: Int64) async throws {
>     if let item = try store.itemByContentHash(contentHash), let id = item.id {
>         try await excludeItem(id: id, at: at)
>     } else {
>         // Local row already deleted — write tombstone directly + push tomb
>         try store.upsertTombstone(contentHash: contentHash, cloudID: "",
>                                   tombstonedAt: at, cloudUpdatedAt: at)
>         try queue.enqueue(op: .putTomb, targetKey: contentHash, at: at)
>     }
> }
> ```

- [ ] **Step 2: Build to verify it compiles**

```bash
swift build
```

- [ ] **Step 3: Run full test suite (regression guard)**

```bash
swift test
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Clip/ClipApp.swift Sources/Clip/Sync/SyncEngine.swift
git commit -m "sync: AppDelegate wire-in — engine + onChange + ⌘N + lazy blob + 30s pull"
```

---

### Task 26: Manual smoke checklist

**Files:**
- Modify: `docs/MANUAL_TEST.md` — add cloud-sync section

- [ ] **Step 1: Append to docs/MANUAL_TEST.md**

```markdown
## 云同步 (v3, D1+R2)

需要两台 Mac (A, B) + 都装了同 build + 一个 Cloudflare 账号上同时配好的 R2 bucket + D1 database + R2:Edit/D1:Edit token。

**首次启用 (A)**
- [ ] Preferences > 云同步 → 输入 R2 endpoint / bucket / access key / secret + D1 account ID / database ID + API token
- [ ] "并行测试" → 三个 ✓ 同时出现 (✓ R2 / ✓ D1 / ✓ Token)
- [ ] 输入同步密码 (≥12 字符) → "初始化 / 加入云端" → 显示"已初始化新云端 profile"
- [ ] backfill 进度可观察（sync_queue 行数下降）

**加入设备 (B)**
- [ ] 同样配置 + 同密码 → "并行测试" 通过 → 初始化 → 显示"已加入现有云端"
- [ ] B 启动 30 秒内拉到 A 已有的所有条目（行尾 ☁️）

**正常使用**
- [ ] A 复制一段文字 → ≤ 60 秒 B 唤起面板能看到该条目
- [ ] A 删一条 → B 上消失
- [ ] A pin 一条 → B 上 pin 状态同步
- [ ] A 复制一张 1MB 图 → B 看到行（lazy 占位）→ 点开预览 spinner → 解密渲染
- [ ] A 复制一张 3MB 图 → A 行尾 📤（v3 暂用 ☁️ 替代）；B 永远看不到这条
- [ ] A 在面板按 ⌘N 标记不同步一条已有 → B 上消失（行尾 🚫 在 A 出现）
- [ ] 重启两台 Mac → 历史保留 + 后续复制仍同步
- [ ] 输错密码 → 不删本地数据；statusMessage 显示密码错

**边角**
- [ ] A 排除一条 → B 删 → A 重新复制相同文字 → push 命中现有 cloud_id → D1 行 deleted 翻 0（fix B）
- [ ] 网络断开 → 复制内容入 sync_queue → 网络恢复后自动 drain
- [ ] 把同步密码改错重启 app → SyncEngine.start 期间所有 GET 都解密失败 → 本地数据无损（无静默删除）
```

- [ ] **Step 2: Commit**

```bash
git add docs/MANUAL_TEST.md
git commit -m "sync: manual smoke checklist — D1+R2 cross-Mac sync"
```

---

## Phase P5 — Real-cloud integration test

### Task 27: D1+R2 round-trip integration test (opt-in)

**Files:**
- Create: `Tests/ClipTests/CloudIntegration/CloudRoundTripTests.swift`

Self-skips when env unset; CI stays green without secrets. Local: source `~/.wrangler/clip.env` then run.

- [ ] **Step 1: Create the test**

```swift
// Tests/ClipTests/CloudIntegration/CloudRoundTripTests.swift
import XCTest
@testable import Clip

final class CloudRoundTripTests: XCTestCase {
    func env(_ k: String) -> String? {
        ProcessInfo.processInfo.environment[k].flatMap { $0.isEmpty ? nil : $0 }
    }

    func testFullPushPullAgainstRealCloud() async throws {
        guard let endpoint = env("R2_ENDPOINT").flatMap(URL.init),
              let bucket = env("R2_BUCKET"),
              let r2AK = env("R2_ACCESS_KEY_ID"),
              let r2Sec = env("R2_SECRET_ACCESS_KEY"),
              let acct = env("R2_ACCOUNT_ID"),
              let dbID = env("D1_DATABASE_ID"),
              let token = env("CLOUDFLARE_API_TOKEN")
        else { throw XCTSkip("cloud env not set; skipping integration") }

        let crypto = CryptoBox(masterKey: Data(repeating: UInt8.random(in: 0...255), count: 32))
        let ds = D1Backend(accountID: acct, databaseID: dbID, apiToken: token)
        let blobs = R2BlobBackend(endpoint: endpoint, bucket: bucket,
                                  accessKeyID: r2AK, secretAccessKey: r2Sec)

        try await ds.ensureSchema()

        // Push a probe row from "device A"
        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "test-A",
                                 state: SyncStateStore(store: storeA))
        let probe = "clip integration probe \(UUID().uuidString)"
        let id = try storeA.insert(ClipItem(
            id: nil, content: probe, contentHash: ClipItem.contentHash(of: probe),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: probe.utf8.count, truncated: false))
        try await engineA.enqueueClipPush(itemID: id, at: 100)
        _ = try await engineA.pushOnce(now: 200)

        // Pull from a fresh "device B"
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, dataSource: ds, blobStore: blobs,
                                 crypto: crypto, deviceID: "test-B",
                                 state: SyncStateStore(store: storeB))
        try await engineB.pullOnce(now: 300)
        XCTAssertTrue(try storeB.listRecent().contains(where: { $0.content == probe }))

        // Cleanup: tombstone our probe row so the test bucket stays small
        let cloudID = try storeA.itemByID(id)!.cloudID!
        _ = try await ds.setClipDeleted(id: cloudID)
    }
}
```

- [ ] **Step 2: Run the test**

```bash
set -a; source ~/.wrangler/clip.env; set +a
swift test --filter ClipTests.CloudRoundTripTests
```

Expected: 1 test passes (or SKIPPED if env not sourced).

- [ ] **Step 3: Commit**

```bash
git add Tests/ClipTests/CloudIntegration/CloudRoundTripTests.swift
git commit -m "sync: cloud integration test — D1+R2 push/pull round-trip (opt-in)"
```

---

## Final sweep

- [ ] **Step 1: Run full test suite**

```bash
swift test
```

Expected: all green; CloudRoundTripTests passes if env sourced, otherwise SKIPPED.

- [ ] **Step 2: Release build**

```bash
swift build -c release --product Clip
```

- [ ] **Step 3: Manual smoke (optional but recommended)**

```bash
./package-app.sh
open dist/Clip.app
# walk through docs/MANUAL_TEST.md "云同步" section
```

- [ ] **Step 4: File map sanity check**

```bash
ls Sources/Clip/Sync/
ls Tests/ClipTests/Sync/
ls Tests/ClipTests/CloudIntegration/
```

Should match the "Files created" map at the top of this plan.

---

## Self-review (post-write checklist)

**Spec coverage:**
- §3 decisions 1-20 → mapped to T1, T8, T9, T11-T13, T17, T15-T20 (push/pull/enable etc.)
- §4 modules → P1+P2 tasks
- §5 schema → T1 (local v3) + T8/T9/T13 (D1 schema in ensureSchema)
- §6 crypto + naming → T2/T3/T11
- §6.3 hmac dedup with deleted=1 (fix B) → T13 + T16
- §6.5 S3v4 → T11
- §7.1 enable → T18 (idempotent + fix C + fix E)
- §7.2 push → T16 (R2-then-D1; orphan blob acceptance is documented behavior — fix D)
- §7.3 pull → T17 (composite cursor — fix A)
- §7.4 lazy blob → T19 + T25 (caller wire-up)
- §7.5 selective sync → T21
- §7.6 backfill → T20
- §8 UI → T23 (panel) + T24 (Preferences with parallel ping — fix F)
- §10 errors → covered through SyncEngine error returns + SyncQueue backoff
- §11 tests → each module has unit / integration tests; T27 = real cloud round-trip
- §12 acceptance → unit + manual (T26) cover items 1, 2, 3, 5; items 4 (24h CPU) and 6 (backfill < 100ms UI) are manual measurements
- §13 deferred → device push, panel ⏳/⚠️ icons, "立刻同步"/"查看错误" buttons, modal onboarding

**Placeholder scan:**
- T16 `pushTomb` and `pushDevice` are stubs → `pushTomb` implemented in T21; `pushDevice` is permanently empty per Out of Scope
- No "TBD" / "implement later" in shipped code

**Type/signature consistency:**
- `enqueueClipPush(itemID:at:)`: T16 defines, T25 calls
- `pushOnce(now:)`: T16, T25
- `pullOnce(now:)`: T17, T25
- `enableSync(password:dataSource:state:keychain:account:)`: T18, T24
- `excludeItem(id:at:)`: T21, T25
- `excludeItemByHash(contentHash:at:)`: T25 references; impl provided in T25 step 1 note
- `fetchBlob(blobID:)`: T19, T25
- `backfill(now:)`: T20, T25
- `name(forContentHash:)` on CryptoBox: T3, T16, T19, T17

All consistent.

---

## Out of Scope (explicit) — for STATUS.md handoff

These items appear in the spec or were natural follow-ups but are **deliberately not implemented in this plan**. STATUS.md must surface them so the user knows what's stubbed vs shipped:

| Spec ref | Item | Why deferred | Workaround for v3 ship |
|---|---|---|---|
| §3.16 / §7.3 | Wake / hotkey-trigger immediate pull + 5s rate-limit | 30s tick is functional for daily use; immediate-pull is a latency win, not correctness | User waits ≤ 30s for cross-device updates |
| §6.4 / §7.x | Device push (`pushDevice` actor stub) + "已知设备" Preferences UI | Cosmetic / observability feature; DevicePayload + DeviceRow are defined and `upsertDevice` / `listDevices` exist on the protocol so v3.1 just wires push + UI | Sync still works; users can't see device list (use Console.app to identify) |
| §8.1 | "立刻同步" / "查看错误" / "清空云端" / "重置同步密码" buttons | Read-only diagnostics + dangerous ops; not load-bearing for daily sync | "立刻同步" → quit + relaunch app. "查看错误" → `sqlite3 ~/Library/Application Support/clip/history.sqlite 'SELECT * FROM sync_queue'`. "清空云端" → `wrangler d1 execute clip-sync --command 'DELETE FROM clips; DELETE FROM devices; DELETE FROM config'` + clear R2 bucket. "重置密码" → clear cloud + re-enable |
| §8.2 | Panel icons ⏳ / 📤 / ⚠️ (only ☁️ / 🚫 in T23) | UX polish; underlying state computed correctly, not surfaced visually | Add in a follow-up commit; trivial UI change |
| §8.4 | First-launch modal sheet ("first Mac vs join existing" branching with progress bar) | Bootstrap logic IS in T18; UI shows it as Preferences form rather than separate onboarding sheet | Functional via Preferences |
| §10.1 | R2/D1 401/403 special pause-and-notify | Generic backoff covers it (sync_queue.last_error captures the auth-error message) | Manual: rotate token in dashboard + paste new token in CloudSyncView |
| §10.2 | Password change flow (5-step blocking re-encrypt) | Heavy feature; reset-cloud-and-re-enable accomplishes the same with minor data loss | "Clear cloud + re-enable with new password" via dashboard |
| §10.4 | In-app quota-exceeded remediation flow | Spec says "user handles via dashboard" | Dashboard link in CloudSyncView status text (manual step) |
| §12 #4 / #6 | 24h CPU < 0.5% / Backfill 1000 < 100ms UI block | Manual measurements; no automated long-running benchmark in v3 | Activity Monitor + manual smoke during backfill |

For each item: the engine architecture is forward-compatible — a v3.1 plan can add tasks without touching the core push/pull/crypto/queue modules.

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-02-clip-cloud-sync.md`.**

For the autonomous-superpowers session: this plan will be executed via `superpowers:subagent-driven-development` (one fresh subagent per task with two-stage review).
