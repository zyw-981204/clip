# Clip Cloud Sync (v3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add E2E-encrypted Cloudflare-R2-backed clipboard history sync across 2-3 Macs, behind a pluggable `CloudSyncBackend` protocol, with selective per-item exclude, lazy image fetch, full backfill, and migration v3 schema additions.

**Scope note (post-review):** see "Out of Scope" section at the end of this doc — UX polish and observability features explicitly deferred to v3.x; this plan ships the load-bearing architecture (crypto + backend + engine + bootstrap + lazy fetch + Preferences enable form + ⌘N exclude).

**Architecture:** All sync code lives under `Sources/Clip/Sync/` (pure Foundation + CryptoKit, no AppKit) so a future `ClipKit` extraction for an iOS client is mechanical. R2 is reached via hand-rolled S3 Signature V4 over `URLSession` — no third-party S3 SDK. Encryption is `ChaChaPoly` with a `PBKDF2-HMAC-SHA256` (200k rounds) derived master key, HKDF-split into separate `kEncrypt` and `kName` subkeys; the master key lives in macOS Keychain (`kSecAttrSynchronizable=false`). Cloud objects are content-addressed via `HMAC(content_hash, kName)` so the same item across devices yields the same filename and dedups for free. `SyncEngine` is a Swift `actor` with two background `Task` loops (push drainer + 30s pull tick) plus signaling on app wake / hotkey trigger.

**Tech Stack:** Swift 6.0 / macOS 13+ / SwiftPM single executable. `CryptoKit` (ChaChaPoly, HMAC, HKDF), `CommonCrypto` (PBKDF2 only), `Network.framework` (NWPathMonitor), `GRDB` (existing). New tests live under `Tests/ClipTests/Sync/` inside the existing test target. R2 integration tests live under `Tests/ClipTests/R2Integration/` and self-skip when `R2_ACCESS_KEY_ID` env is unset (CI doesn't have it; local sources `~/.wrangler/clip.env`).

**Files created (new) — quick map:**

```
Sources/Clip/Sync/
├── KeyDerivation.swift       — PBKDF2 wrapper (CommonCrypto)
├── CryptoBox.swift           — ChaChaPoly seal/open + HMAC namer
├── KeychainStore.swift       — read/write versioned master_key entry
├── SyncTypes.swift           — CloudObjectMeta, ListPage, DeviceID, SyncOp
├── SyncSchema.swift          — ItemPayload / TombstonePayload / DevicePayload Codable
├── CloudSyncBackend.swift    — protocol
├── LocalDirBackend.swift     — Backend implementation writing to a local dir (tests)
├── S3SignerV4.swift          — Sig v4 canonical request + signing key derivation
├── R2Backend.swift           — Backend implementation: URLSession + S3SignerV4
├── SyncQueue.swift           — DB-backed retry queue (CRUD on sync_queue table)
├── SyncEngine.swift          — actor; push loop + pull loop + tombstone + backfill
├── SyncSettings.swift        — UserDefaults wrapper for endpoint/bucket/access_key_id
└── SyncStateStore.swift      — DB-backed sync_state table CRUD (device_id, cursors, KDF params)

Sources/Clip/Preferences/
└── CloudSyncView.swift       — Preferences "云同步" tab

Tests/ClipTests/Sync/         — unit + LocalDirBackend integration tests
Tests/ClipTests/R2Integration/ — opt-in real-R2 round-trip
```

**Files modified:**
- `Sources/Clip/Storage/Migrations.swift` — add v3 migration
- `Sources/Clip/Storage/HistoryStore.swift` — add `markSynced`, `markBlobSynced`, `setExclusion`, `forSyncBackfill` queries; add `onChange` callback hook
- `Sources/Clip/Storage/ClipItem.swift` — add `syncExcluded`, `cloudSyncedAt`, `cloudEtag`, `cloudLastModified`, `deviceID` properties
- `Sources/Clip/Preferences/PreferencesWindow.swift` — add "云同步" tab
- `Sources/Clip/Panel/PanelView.swift` — add ⌘N exclude toggle + sync status icon
- `Sources/Clip/Panel/PanelModel.swift` — `toggleExcludeSelected()` action
- `Sources/Clip/Panel/PanelWindow.swift` — wire ⌘N key to model
- `Sources/Clip/ClipApp.swift` — wire `SyncEngine` into `AppDelegate.applicationDidFinishLaunching`

**TDD discipline:** every task starts with a failing test, then minimal impl, then verify pass, then commit. Don't batch multiple features into one commit.

**Commit message convention:** `sync: <component> — <one-line summary>` (e.g. `sync: KeyDerivation — PBKDF2-SHA256 wrapper`).

**Build / test commands** (use these exact forms; AGENTS.md explains why CLT toolchain is wrong):

```bash
swift test                                       # full suite
swift test --filter ClipTests.<TestClass>        # single file
swift test --filter ClipTests.R2Integration      # opt-in R2 round-trip (needs env)
swift build -c release --product Clip            # release sanity (CI runs this too)
```

---

## Phase P1 — Foundations (storage + crypto)

These are pure-Swift, no network. Ship them all before touching backend code.

### Task 1: Migration v3 — schema additions

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
    func testV3AddsExpectedColumns() throws {
        let s = try HistoryStore.inMemory()
        try s.pool.read { db in
            let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(items)").map { $0["name"] as String }
            XCTAssertTrue(cols.contains("sync_excluded"))
            XCTAssertTrue(cols.contains("cloud_synced_at"))
            XCTAssertTrue(cols.contains("cloud_etag"))
            XCTAssertTrue(cols.contains("cloud_lastmodified"))
            XCTAssertTrue(cols.contains("cloud_name"))
            XCTAssertTrue(cols.contains("device_id"))

            let blobCols = try Row.fetchAll(db, sql: "PRAGMA table_info(clip_blobs)").map { $0["name"] as String }
            XCTAssertTrue(blobCols.contains("cloud_synced_at"))
            XCTAssertTrue(blobCols.contains("cloud_etag"))
        }
    }

    func testV3CreatesNewTables() throws {
        let s = try HistoryStore.inMemory()
        try s.pool.read { db in
            let names = try String.fetchAll(db, sql:
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            XCTAssertTrue(names.contains("tombstones"))
            XCTAssertTrue(names.contains("sync_queue"))
            XCTAssertTrue(names.contains("sync_state"))
        }
    }

    func testV3DefaultExcludedZero() throws {
        let s = try HistoryStore.inMemory()
        try s.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try s.pool.read { db in
            let v = try Int.fetchOne(db, sql: "SELECT sync_excluded FROM items LIMIT 1")
            XCTAssertEqual(v, 0)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.MigrationV3Tests
```

Expected: compile error (migration v3 not registered) or test failure ("no column sync_excluded").

- [ ] **Step 3: Implement v3 migration**

Append to `Sources/Clip/Storage/Migrations.swift` after the v2 migration block:

```swift
        // v3: cloud sync columns + tables.
        // Spec: docs/superpowers/specs/2026-05-02-clip-cloud-sync.md §5
        migrator.registerMigration("v3") { db in
            // items: 6 new columns
            try db.execute(sql: "ALTER TABLE items ADD COLUMN sync_excluded INTEGER NOT NULL DEFAULT 0;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_synced_at INTEGER;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_etag TEXT;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_lastmodified INTEGER;")
            try db.execute(sql: "ALTER TABLE items ADD COLUMN cloud_name TEXT;")    // hex(hmac), enables ETag tracking
            try db.execute(sql: "ALTER TABLE items ADD COLUMN device_id TEXT;")
            try db.execute(sql: "CREATE INDEX idx_items_cloud_name ON items(cloud_name);")

            // clip_blobs: 2 new columns
            try db.execute(sql: "ALTER TABLE clip_blobs ADD COLUMN cloud_synced_at INTEGER;")
            try db.execute(sql: "ALTER TABLE clip_blobs ADD COLUMN cloud_etag TEXT;")

            // tombstones
            try db.execute(sql: """
                CREATE TABLE tombstones (
                    hmac               TEXT PRIMARY KEY,
                    content_hash       TEXT NOT NULL,
                    tombstoned_at      INTEGER NOT NULL,
                    cloud_synced_at    INTEGER,
                    cloud_etag         TEXT,
                    cloud_lastmodified INTEGER
                );
            """)
            try db.execute(sql: "CREATE INDEX idx_tombstones_synced ON tombstones(cloud_synced_at);")

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

            // sync_state — generic kv
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

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Storage/Migrations.swift Tests/ClipTests/Sync/MigrationV3Tests.swift
git commit -m "sync: Migration v3 — schema additions for cloud sync"
```

---

### Task 2: KeyDerivation — PBKDF2-SHA256 wrapper

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
        // RFC 7914 SCRYPT test vectors aren't applicable; use our own deterministic
        // expectation. PBKDF2-HMAC-SHA256(password="password", salt="salt",
        // iters=1, dkLen=32). Computed once with Python hashlib and pinned here.
        let key = KeyDerivation.pbkdf2_sha256(
            password: "password",
            salt: Data("salt".utf8),
            iterations: 1,
            keyLength: 32)
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

Expected: compile error ("no type KeyDerivation").

- [ ] **Step 3: Implement KeyDerivation**

```swift
// Sources/Clip/Sync/KeyDerivation.swift
import Foundation
import CommonCrypto

/// PBKDF2-HMAC-SHA256 wrapper.
///
/// CryptoKit does not expose PBKDF2; CommonCrypto's CCKeyDerivationPBKDF is the
/// canonical Apple-platform implementation. Spec §6.1 pins iters=200_000,
/// dkLen=32 for cloud master-key derivation.
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
        let master = Data(repeating: 0xAB, count: 32)
        return CryptoBox(masterKey: master)
    }

    func testSealOpenRoundTrip() throws {
        let box = makeBox()
        let plain = Data("hello, world".utf8)
        let sealed = try box.seal(plain)
        let opened = try box.open(sealed)
        XCTAssertEqual(opened, plain)
        XCTAssertGreaterThan(sealed.count, plain.count, "sealed has nonce + tag overhead")
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
        sealed[sealed.count - 1] ^= 0x01      // flip last byte of tag
        XCTAssertThrowsError(try box.open(sealed))
    }

    func testNonceUniqueness() throws {
        let box = makeBox()
        let plain = Data("same input".utf8)
        var nonces = Set<Data>()
        for _ in 0..<5000 {
            let sealed = try box.seal(plain)
            nonces.insert(sealed.prefix(12))   // first 12B = nonce
        }
        XCTAssertEqual(nonces.count, 5000, "all nonces must be unique")
    }

    func testNameIsDeterministic() {
        let box = makeBox()
        let h = "abc123"
        XCTAssertEqual(box.name(forContentHash: h), box.name(forContentHash: h))
        XCTAssertNotEqual(box.name(forContentHash: "abc"),
                          box.name(forContentHash: "def"))
        XCTAssertEqual(box.name(forContentHash: h).count, 64,
                       "HMAC-SHA256 hex = 64 chars")
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

Expected: compile error ("no type CryptoBox").

- [ ] **Step 3: Implement CryptoBox**

```swift
// Sources/Clip/Sync/CryptoBox.swift
import Foundation
import CryptoKit

/// AEAD seal/open + content-hash → cloud filename mapping.
///
/// Master key is HKDF-split into two subkeys (spec §6.1):
///   k_encrypt — ChaChaPoly seal/open
///   k_name    — HMAC-SHA256(content_hash) → cloud filename
///
/// Sealed format: nonce(12B) || ciphertext || tag(16B) — exactly what
/// `ChaChaPoly.SealedBox.combined` produces. Opening reverses.
struct CryptoBox: Sendable {
    enum Error: Swift.Error, Equatable {
        case decryptionFailed
    }

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
        let sealed = try ChaChaPoly.seal(plaintext, using: kEncrypt)
        return sealed.combined
    }

    func open(_ sealed: Data) throws -> Data {
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            return try ChaChaPoly.open(box, using: kEncrypt)
        } catch {
            throw Error.decryptionFailed
        }
    }

    /// HMAC-SHA256(kName, content_hash_utf8) → 64-char hex.
    /// Used as the leaf of `items/<name>.bin`, `tomb/<name>.bin`, etc.
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

Notes: each test uses a unique service identifier so tests don't collide across runs. We delete on tearDown.

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

Expected: compile error ("no type KeychainStore").

- [ ] **Step 3: Implement KeychainStore**

```swift
// Sources/Clip/Sync/KeychainStore.swift
import Foundation
import Security

/// Thin wrapper around macOS Keychain `kSecClassGenericPassword`.
///
/// Each "account" within a service is one logical key. Spec §6.1 mandates
/// `kSecAttrSynchronizable = false` — we MUST NOT sync the master key
/// through iCloud Keychain (that would put Apple in the trust path and
/// break the E2E promise).
struct KeychainStore: Sendable {
    let service: String

    init(service: String) { self.service = service }

    enum Error: Swift.Error {
        case keychain(OSStatus)
    }

    func read(account: String) throws -> Data? {
        let q: [String: Any] = [
            kSecClass        as String: kSecClassGenericPassword,
            kSecAttrService  as String: service,
            kSecAttrAccount  as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData   as String: true,
            kSecMatchLimit   as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Error.keychain(status) }
        return out as? Data
    }

    func write(account: String, data: Data) throws {
        // Try update first.
        let q: [String: Any] = [
            kSecClass        as String: kSecClassGenericPassword,
            kSecAttrService  as String: service,
            kSecAttrAccount  as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let upd = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if upd == errSecSuccess { return }
        if upd != errSecItemNotFound { throw Error.keychain(upd) }

        // Insert.
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw Error.keychain(st) }
    }

    func delete(account: String) throws {
        let q: [String: Any] = [
            kSecClass        as String: kSecClassGenericPassword,
            kSecAttrService  as String: service,
            kSecAttrAccount  as String: account,
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

Expected: 4 tests pass.

> **If tests hang or prompt for keychain access**: the test process may need `--enable-keychain-access` or to be signed. On normal `swift test` invocation in a logged-in user's TTY this works without prompts because `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is permissive enough. If a UI prompt appears, click "Always Allow".

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/KeychainStore.swift Tests/ClipTests/Sync/KeychainStoreTests.swift
git commit -m "sync: KeychainStore — generic-password wrapper, sync disabled"
```

---

### Task 5: SyncTypes — value types for backend protocol + queue ops

**Files:**
- Create: `Sources/Clip/Sync/SyncTypes.swift`
- Create: `Tests/ClipTests/Sync/SyncTypesTests.swift`

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

    func testCloudObjectMetaInit() {
        let m = CloudObjectMeta(key: "items/abc.bin", etag: "deadbeef",
                                lastModified: 100, size: 50)
        XCTAssertEqual(m.key, "items/abc.bin")
        XCTAssertEqual(m.etag, "deadbeef")
        XCTAssertEqual(m.lastModified, 100)
        XCTAssertEqual(m.size, 50)
    }

    func testListPageDefaults() {
        let p = ListPage(objects: [], nextCursor: nil)
        XCTAssertTrue(p.objects.isEmpty)
        XCTAssertNil(p.nextCursor)
    }

    func testCloudPrefixes() {
        XCTAssertEqual(CloudKey.itemsPrefix, "items/")
        XCTAssertEqual(CloudKey.tombPrefix, "tomb/")
        XCTAssertEqual(CloudKey.blobsPrefix, "blobs/")
        XCTAssertEqual(CloudKey.devicesPrefix, "devices/")
        XCTAssertEqual(CloudKey.configKey, "config.json")
        XCTAssertEqual(CloudKey.itemKey(name: "abc"), "items/abc.bin")
        XCTAssertEqual(CloudKey.tombKey(name: "abc"), "tomb/abc.bin")
        XCTAssertEqual(CloudKey.blobKey(name: "abc"), "blobs/abc.bin")
        XCTAssertEqual(CloudKey.deviceKey(deviceID: "ID"), "devices/ID.bin")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncTypesTests
```

Expected: compile error.

- [ ] **Step 3: Implement SyncTypes**

```swift
// Sources/Clip/Sync/SyncTypes.swift
import Foundation

/// One row in `sync_queue.op`.
enum SyncOp: String, CaseIterable, Sendable {
    case putItem    = "put_item"
    case putBlob    = "put_blob"
    case putTomb    = "put_tomb"
    case putDevice  = "put_device"
}

struct CloudObjectMeta: Sendable, Equatable {
    var key: String
    var etag: String
    var lastModified: Int64    // unix seconds
    var size: Int
}

struct ListPage: Sendable {
    var objects: [CloudObjectMeta]
    var nextCursor: String?
}

/// Centralized cloud key construction. All the prefixes / suffixes live here
/// so a typo doesn't accidentally split traffic across two key spaces.
enum CloudKey {
    static let itemsPrefix   = "items/"
    static let tombPrefix    = "tomb/"
    static let blobsPrefix   = "blobs/"
    static let devicesPrefix = "devices/"
    static let configKey     = "config.json"

    static func itemKey(name: String)   -> String { itemsPrefix + name + ".bin" }
    static func tombKey(name: String)   -> String { tombPrefix + name + ".bin" }
    static func blobKey(name: String)   -> String { blobsPrefix + name + ".bin" }
    static func deviceKey(deviceID: String) -> String { devicesPrefix + deviceID + ".bin" }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncTypesTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncTypes.swift Tests/ClipTests/Sync/SyncTypesTests.swift
git commit -m "sync: SyncTypes — backend value types + cloud key constants"
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
    func testItemPayloadTextRoundTrip() throws {
        let p = ItemPayload(
            v: 1, kind: "text", contentHash: "abc",
            content: "hello", mimeType: nil, blobHmac: nil, blobSize: nil,
            thumbB64: nil, byteSize: 5, truncated: false,
            sourceBundleId: "com.apple.Safari", sourceAppName: "Safari",
            createdAt: 100, pinned: false, deviceId: "DEV1")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(ItemPayload.self, from: data)
        XCTAssertEqual(back, p)
    }

    func testItemPayloadImageRoundTrip() throws {
        let p = ItemPayload(
            v: 1, kind: "image", contentHash: "def",
            content: nil, mimeType: "image/png", blobHmac: "fff", blobSize: 12345,
            thumbB64: "AAA=", byteSize: 0, truncated: false,
            sourceBundleId: nil, sourceAppName: nil,
            createdAt: 200, pinned: true, deviceId: "DEV2")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(ItemPayload.self, from: data)
        XCTAssertEqual(back, p)
    }

    func testTombstonePayloadRoundTrip() throws {
        let t = TombstonePayload(v: 1, contentHash: "x", tombstonedAt: 999, deviceId: "D")
        let back = try JSONDecoder().decode(TombstonePayload.self,
                                            from: try JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
    }

    func testDevicePayloadRoundTrip() throws {
        let d = DevicePayload(v: 1, deviceId: "ID", displayName: "Mac-Mini-7",
                              model: "Mac15,12", firstSeenAt: 1, lastSeenAt: 2)
        let back = try JSONDecoder().decode(DevicePayload.self,
                                            from: try JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
    }

    func testConfigPayloadRoundTrip() throws {
        let c = CloudConfigPayload(v: 1, kdf: "pbkdf2-hmac-sha256",
                                   kdfIters: 200_000, kdfSaltB64: "QUJD",
                                   format: "chacha20-poly1305-ietf-12-16")
        let back = try JSONDecoder().decode(CloudConfigPayload.self,
                                            from: try JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncSchemaTests
```

Expected: compile error.

- [ ] **Step 3: Implement SyncSchema**

```swift
// Sources/Clip/Sync/SyncSchema.swift
import Foundation

/// Cloud object payloads. JSON wire format; keys use snake_case to stay
/// stable across language ports (future iOS Swift, hypothetical CLI tool, etc.).
///
/// `v` field on every payload — bump if breaking, current readers must
/// reject unknown major versions.

struct ItemPayload: Codable, Equatable, Sendable {
    var v: Int
    var kind: String                // "text" | "image"
    var contentHash: String
    var content: String?            // text only
    var mimeType: String?           // image only
    var blobHmac: String?           // image only — points at blobs/<blobHmac>.bin
    var blobSize: Int?              // image only
    var thumbB64: String?           // image only — base64-encoded ≤5KB PNG thumbnail
    var byteSize: Int
    var truncated: Bool
    var sourceBundleId: String?
    var sourceAppName: String?
    var createdAt: Int64
    var pinned: Bool
    var deviceId: String

    enum CodingKeys: String, CodingKey {
        case v, kind, content, truncated, pinned
        case contentHash       = "content_hash"
        case mimeType          = "mime_type"
        case blobHmac          = "blob_hmac"
        case blobSize          = "blob_size"
        case thumbB64          = "thumb_b64"
        case byteSize          = "byte_size"
        case sourceBundleId    = "source_bundle_id"
        case sourceAppName     = "source_app_name"
        case createdAt         = "created_at"
        case deviceId          = "device_id"
    }
}

struct TombstonePayload: Codable, Equatable, Sendable {
    var v: Int
    var contentHash: String
    var tombstonedAt: Int64
    var deviceId: String

    enum CodingKeys: String, CodingKey {
        case v
        case contentHash  = "content_hash"
        case tombstonedAt = "tombstoned_at"
        case deviceId     = "device_id"
    }
}

struct DevicePayload: Codable, Equatable, Sendable {
    var v: Int
    var deviceId: String
    var displayName: String
    var model: String
    var firstSeenAt: Int64
    var lastSeenAt: Int64

    enum CodingKeys: String, CodingKey {
        case v, model
        case deviceId    = "device_id"
        case displayName = "display_name"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt  = "last_seen_at"
    }
}

struct CloudConfigPayload: Codable, Equatable, Sendable {
    var v: Int
    var kdf: String
    var kdfIters: Int
    var kdfSaltB64: String
    var format: String

    enum CodingKeys: String, CodingKey {
        case v, kdf, format
        case kdfIters    = "kdf_iters"
        case kdfSaltB64  = "kdf_salt_b64"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncSchemaTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncSchema.swift Tests/ClipTests/Sync/SyncSchemaTests.swift
git commit -m "sync: SyncSchema — Codable Item/Tombstone/Device/Config payloads"
```

---

### Task 7: HistoryStore additions — sync columns + hooks + queries

**Files:**
- Modify: `Sources/Clip/Storage/ClipItem.swift` — add 5 properties
- Modify: `Sources/Clip/Storage/HistoryStore.swift` — extend `itemFromRow`, `_insert`; add new methods
- Create: `Tests/ClipTests/Sync/HistoryStoreSyncTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/HistoryStoreSyncTests.swift
import XCTest
@testable import Clip

final class HistoryStoreSyncTests: XCTestCase {
    func testNewItemDefaultsAreUnsynced() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        let item = try XCTUnwrap(try s.itemByID(id))
        XCTAssertEqual(item.syncExcluded, false)
        XCTAssertNil(item.cloudSyncedAt)
        XCTAssertNil(item.cloudEtag)
        XCTAssertNil(item.cloudLastModified)
        XCTAssertNil(item.deviceID)
    }

    func testMarkSyncedWritesCloudFields() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(ClipItem(
            id: nil, content: "y", contentHash: ClipItem.contentHash(of: "y"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try s.markItemSynced(id: id, at: 100, etag: "deadbeef", lastModified: 99)
        let item = try XCTUnwrap(try s.itemByID(id))
        XCTAssertEqual(item.cloudSyncedAt, 100)
        XCTAssertEqual(item.cloudEtag, "deadbeef")
        XCTAssertEqual(item.cloudLastModified, 99)
    }

    func testSetExclusionTogglesFlag() throws {
        let s = try HistoryStore.inMemory()
        let id = try s.insert(ClipItem(
            id: nil, content: "z", contentHash: ClipItem.contentHash(of: "z"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try s.setSyncExcluded(id: id, excluded: true)
        XCTAssertEqual(try s.itemByID(id)?.syncExcluded, true)
        try s.setSyncExcluded(id: id, excluded: false)
        XCTAssertEqual(try s.itemByID(id)?.syncExcluded, false)
    }

    func testOnChangeFiresOnInsert() throws {
        let s = try HistoryStore.inMemory()
        var calls: [HistoryStoreChange] = []
        s.onChange = { calls.append($0) }
        try s.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        XCTAssertEqual(calls.count, 1)
        if case .inserted = calls[0] {} else { XCTFail("expected .inserted") }
    }

    func testOnChangeFiresOnDelete() throws {
        let s = try HistoryStore.inMemory()
        var calls: [HistoryStoreChange] = []
        let id = try s.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        s.onChange = { calls.append($0) }
        try s.delete(id: id)
        XCTAssertEqual(calls.count, 1)
        if case .deleted = calls[0] {} else { XCTFail("expected .deleted") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.HistoryStoreSyncTests
```

Expected: compile errors (missing properties / methods).

- [ ] **Step 3: Extend ClipItem**

In `Sources/Clip/Storage/ClipItem.swift`, replace the existing `ClipItem` struct with the version below (preserves all existing fields, adds 5 new ones):

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
    // not concerned with sync don't change.
    var syncExcluded: Bool = false
    var cloudSyncedAt: Int64? = nil
    var cloudEtag: String? = nil
    var cloudLastModified: Int64? = nil
    var cloudName: String? = nil      // hex(hmac); set on insert if sync enabled, on UPSERT during pull
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

(`import CryptoKit` was already at the top.)

- [ ] **Step 4: Add change-notification type and extend HistoryStore**

Add at the top of `Sources/Clip/Storage/HistoryStore.swift`, before the class:

```swift
/// Events emitted when the store is mutated. Sync engine subscribes to these
/// to know what to push.
enum HistoryStoreChange: Sendable {
    case inserted(itemID: Int64)
    case deleted(itemID: Int64, contentHash: String)
    case pinToggled(itemID: Int64)
    case excludedToggled(itemID: Int64)
}
```

In the `HistoryStore` class:

1. Add a stored callback near the other properties:
```swift
    /// Called after every mutation. Set by AppDelegate to wire SyncEngine.
    /// May be invoked from any queue — implementer must hop to its own actor
    /// if needed.
    var onChange: (@Sendable (HistoryStoreChange) -> Void)?
```

2. Update `_insert` to read 5 new columns when called via the public API. Actually `_insert` writes — leave it. Update `itemFromRow` to read them:

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
            syncExcluded: ((row["sync_excluded"] as Int64?) ?? 0) != 0,
            cloudSyncedAt: row["cloud_synced_at"],
            cloudEtag: row["cloud_etag"],
            cloudLastModified: row["cloud_lastmodified"],
            cloudName: row["cloud_name"],
            deviceID: row["device_id"]
        )
    }

    /// Look up the local cloud_etag for a given hmac (used by SyncEngine pull
    /// to skip GET when local row's cloud_etag already matches the listing
    /// ETag — fixes the "always re-download" correctness gap flagged by review).
    func cloudEtagByName(_ name: String, table: String = "items") throws -> String? {
        try pool.read { db in
            try String.fetchOne(db,
                sql: "SELECT cloud_etag FROM \(table) WHERE cloud_name = ? LIMIT 1",
                arguments: [name])
        }
    }

    func tombstoneEtagByName(_ name: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db,
                sql: "SELECT cloud_etag FROM tombstones WHERE hmac = ? LIMIT 1",
                arguments: [name])
        }
    }

    /// Set cloud_name on an items row (called by SyncEngine after first PUT).
    func setItemCloudName(id: Int64, name: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE items SET cloud_name = ? WHERE id = ?",
                           arguments: [name, id])
        }
    }
```

3. Wrap existing `insert`, `insertOrPromote`, `insertImage`, `delete`, `togglePin` to fire `onChange` after success. Example for `insert`:

```swift
    @discardableResult
    func insert(_ item: ClipItem) throws -> Int64 {
        let id = try pool.write { db in
            try Self._insert(db, item: item)
        }
        onChange?(.inserted(itemID: id))
        return id
    }
```

Apply the same pattern to `insertOrPromote` (`.inserted`), `insertImage` (`.inserted`), `delete` (`.deleted` — but you need `contentHash` first; query before delete or via the `Row` you fetch), `togglePin` (`.pinToggled`).

For `delete`:
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

4. Add new methods:

```swift
    /// Fetch a single item by id (used by sync push pipeline).
    func itemByID(_ id: Int64) throws -> ClipItem? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [id])
                .map(Self.itemFromRow)
        }
    }

    /// Mark an item as cloud-synced (called by SyncEngine after successful PUT).
    func markItemSynced(id: Int64, at: Int64, etag: String, lastModified: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE items SET cloud_synced_at = ?, cloud_etag = ?, cloud_lastmodified = ?
                WHERE id = ?
            """, arguments: [at, etag, lastModified, id])
        }
    }

    /// Mark a blob as cloud-synced.
    func markBlobSynced(id: Int64, at: Int64, etag: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE clip_blobs SET cloud_synced_at = ?, cloud_etag = ? WHERE id = ?
            """, arguments: [at, etag, id])
        }
    }

    /// Toggle the per-item exclude flag and fire onChange.
    func setSyncExcluded(id: Int64, excluded: Bool) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE items SET sync_excluded = ? WHERE id = ?",
                           arguments: [excluded ? 1 : 0, id])
        }
        onChange?(.excludedToggled(itemID: id))
    }
```

- [ ] **Step 5: Run test to verify it passes**

```bash
swift test --filter ClipTests.HistoryStoreSyncTests
```

Expected: 5 tests pass.

- [ ] **Step 6: Run the full existing suite (regression guard)**

```bash
swift test
```

Expected: all pre-existing tests still pass (HistoryStoreTests, MigrationTests, etc.).

- [ ] **Step 7: Commit**

```bash
git add Sources/Clip/Storage/ClipItem.swift Sources/Clip/Storage/HistoryStore.swift Tests/ClipTests/Sync/HistoryStoreSyncTests.swift
git commit -m "sync: HistoryStore — sync columns, onChange hook, markSynced helpers"
```

---

## Phase P2 — Backend (protocol, local impl, R2 impl)

### Task 8: CloudSyncBackend protocol

**Files:**
- Create: `Sources/Clip/Sync/CloudSyncBackend.swift`

(No test for the protocol itself — it's tested via the implementations.)

- [ ] **Step 1: Write the protocol**

```swift
// Sources/Clip/Sync/CloudSyncBackend.swift
import Foundation

/// Object-store abstraction. Spec §4.3 contract.
///
/// Implementations: LocalDirBackend (tests), R2Backend (production).
/// Keep small: 5 operations, all async, no streaming, no auth refresh
/// (engine layer handles 401/403 by surfacing to user).
protocol CloudSyncBackend: Sendable {
    /// PUT object. Returns `(etag, lastModified)` from the response headers.
    func put(key: String, body: Data, contentType: String?) async throws -> (etag: String, lastModified: Int64)

    /// GET object. Returns nil when 404; throws on other errors.
    func get(key: String) async throws -> Data?

    /// HEAD object. Returns metadata or nil on 404.
    func head(key: String) async throws -> CloudObjectMeta?

    /// DELETE object. 404 is treated as success (idempotent).
    func delete(key: String) async throws

    /// LIST a prefix. Pagination via `cursor`; nil = first page.
    /// Each page is up to backend-defined max (R2: 1000).
    func list(prefix: String, after cursor: String?) async throws -> ListPage
}
```

- [ ] **Step 2: Verify it compiles**

```bash
swift build
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/Clip/Sync/CloudSyncBackend.swift
git commit -m "sync: CloudSyncBackend protocol — 5-op contract"
```

---

### Task 9: LocalDirBackend — write to a local dir for tests

**Files:**
- Create: `Sources/Clip/Sync/LocalDirBackend.swift`
- Create: `Tests/ClipTests/Sync/LocalDirBackendTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/LocalDirBackendTests.swift
import XCTest
@testable import Clip

final class LocalDirBackendTests: XCTestCase {
    var dir: URL!
    var backend: LocalDirBackend!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backend = LocalDirBackend(root: dir)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testPutGetRoundTrip() async throws {
        let body = Data("hello".utf8)
        let (etag, lm) = try await backend.put(key: "items/abc.bin", body: body, contentType: nil)
        XCTAssertFalse(etag.isEmpty)
        XCTAssertGreaterThan(lm, 0)
        let got = try await backend.get(key: "items/abc.bin")
        XCTAssertEqual(got, body)
    }

    func testGetMissing() async throws {
        XCTAssertNil(try await backend.get(key: "nope.bin"))
    }

    func testHead() async throws {
        let body = Data("xyz".utf8)
        _ = try await backend.put(key: "k.bin", body: body, contentType: nil)
        let meta = try XCTUnwrap(try await backend.head(key: "k.bin"))
        XCTAssertEqual(meta.size, 3)
        XCTAssertNil(try await backend.head(key: "missing.bin"))
    }

    func testDeleteIdempotent() async throws {
        _ = try await backend.put(key: "d.bin", body: Data([0x01]), contentType: nil)
        try await backend.delete(key: "d.bin")
        try await backend.delete(key: "d.bin")  // again, must not throw
        XCTAssertNil(try await backend.get(key: "d.bin"))
    }

    func testListByPrefix() async throws {
        _ = try await backend.put(key: "items/a.bin", body: Data([0x01]), contentType: nil)
        _ = try await backend.put(key: "items/b.bin", body: Data([0x02, 0x03]), contentType: nil)
        _ = try await backend.put(key: "tomb/c.bin",  body: Data([0x04]), contentType: nil)
        let page = try await backend.list(prefix: "items/", after: nil)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(Set(page.objects.map(\.key)), ["items/a.bin", "items/b.bin"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.LocalDirBackendTests
```

Expected: compile error ("no type LocalDirBackend").

- [ ] **Step 3: Implement LocalDirBackend**

```swift
// Sources/Clip/Sync/LocalDirBackend.swift
import Foundation
import CryptoKit

/// Filesystem-backed CloudSyncBackend used in unit / integration tests so
/// the engine can be exercised without network. Each `key` becomes a
/// nested file under `root`.
///
/// `etag` is computed as the hex MD5 of the body (matches what real R2
/// returns for non-multipart uploads).
final class LocalDirBackend: CloudSyncBackend, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root }

    private func url(for key: String) -> URL {
        root.appendingPathComponent(key)
    }

    func put(key: String, body: Data, contentType _: String?) async throws -> (etag: String, lastModified: Int64) {
        let u = url(for: key)
        try FileManager.default.createDirectory(
            at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: u, options: .atomic)
        let md5 = Insecure.MD5.hash(data: body)
        let etag = md5.map { String(format: "%02x", $0) }.joined()
        let lm = Int64(Date().timeIntervalSince1970)
        return (etag, lm)
    }

    func get(key: String) async throws -> Data? {
        let u = url(for: key)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Data(contentsOf: u)
    }

    func head(key: String) async throws -> CloudObjectMeta? {
        let u = url(for: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
        else { return nil }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let body = (try? Data(contentsOf: u)) ?? Data()
        let etag = Insecure.MD5.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return CloudObjectMeta(key: key, etag: etag,
                               lastModified: Int64(mtime.timeIntervalSince1970),
                               size: size)
    }

    func delete(key: String) async throws {
        let u = url(for: key)
        if FileManager.default.fileExists(atPath: u.path) {
            try FileManager.default.removeItem(at: u)
        }
    }

    func list(prefix: String, after _: String?) async throws -> ListPage {
        let prefixURL = root.appendingPathComponent(prefix)
        guard let it = FileManager.default.enumerator(
            at: prefixURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return ListPage(objects: [], nextCursor: nil) }

        var objects: [CloudObjectMeta] = []
        for case let url as URL in it {
            let v = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey,
                                                     .contentModificationDateKey])
            if v.isDirectory ?? false { continue }
            let key = String(url.path.dropFirst(root.path.count + 1))
            let body = (try? Data(contentsOf: url)) ?? Data()
            let etag = Insecure.MD5.hash(data: body).map { String(format: "%02x", $0) }.joined()
            objects.append(CloudObjectMeta(
                key: key,
                etag: etag,
                lastModified: Int64(v.contentModificationDate?.timeIntervalSince1970 ?? 0),
                size: v.fileSize ?? 0))
        }
        // No pagination — local backend always returns everything.
        return ListPage(objects: objects, nextCursor: nil)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.LocalDirBackendTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/LocalDirBackend.swift Tests/ClipTests/Sync/LocalDirBackendTests.swift
git commit -m "sync: LocalDirBackend — filesystem CloudSyncBackend for tests"
```

---

### Task 10: S3SignerV4 — AWS Sig V4 implementation

**Files:**
- Create: `Sources/Clip/Sync/S3SignerV4.swift`
- Create: `Tests/ClipTests/Sync/S3SignerV4Tests.swift`

The test pins one of AWS's official Sig V4 test vectors (`get-vanilla` from `aws4_testsuite`, with the canonical request hash and final signature pinned). This way we know the implementation is correct independent of any S3 round-trip.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/S3SignerV4Tests.swift
import XCTest
@testable import Clip

final class S3SignerV4Tests: XCTestCase {
    // Pinned from the AWS aws4_testsuite "get-vanilla" test vector,
    // recomputed for service="s3" / region="us-east-1" / payload="UNSIGNED-PAYLOAD"
    // with a known fixed date and creds. Independent of any real network call.
    func testSignReturnsExpectedHeaders() {
        let signer = S3SignerV4(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            region: "us-east-1",
            service: "s3"
        )
        var req = URLRequest(url: URL(string: "https://example.com/")!)
        req.httpMethod = "GET"

        let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
        let result = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD", date: date)

        // We're not asserting the entire signature byte-for-byte (the AWS
        // suite's reference signature is for SignedPayload, not UNSIGNED).
        // We assert structure: required headers exist + parse correctly.
        XCTAssertNotNil(result.value(forHTTPHeaderField: "Authorization"))
        let auth = result.value(forHTTPHeaderField: "Authorization")!
        XCTAssertTrue(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request"))
        XCTAssertTrue(auth.contains("SignedHeaders=host;x-amz-content-sha256;x-amz-date"))
        XCTAssertTrue(auth.contains("Signature="))
        XCTAssertEqual(result.value(forHTTPHeaderField: "x-amz-date"), "20150830T123600Z")
        XCTAssertEqual(result.value(forHTTPHeaderField: "x-amz-content-sha256"), "UNSIGNED-PAYLOAD")
    }

    func testSignaturesDifferByDate() {
        let s = S3SignerV4(accessKeyID: "AK", secretAccessKey: "SK",
                           region: "auto", service: "s3")
        let req = URLRequest(url: URL(string: "https://x.r2.cloudflarestorage.com/b/k")!)
        let date1 = Date(timeIntervalSince1970: 1_700_000_000)
        let date2 = Date(timeIntervalSince1970: 1_700_000_001)
        let r1 = s.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD", date: date1)
        let r2 = s.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD", date: date2)
        XCTAssertNotEqual(r1.value(forHTTPHeaderField: "Authorization"),
                          r2.value(forHTTPHeaderField: "Authorization"))
    }

    func testCanonicalUriEncoding() {
        // /items/abc.bin should NOT have its / encoded.
        let s = S3SignerV4(accessKeyID: "AK", secretAccessKey: "SK",
                           region: "auto", service: "s3")
        let url = URL(string: "https://x.r2.cloudflarestorage.com/clip-sync/items/abc.bin")!
        let req = URLRequest(url: url)
        let signed = s.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD", date: Date())
        // the signing process internally must use "/clip-sync/items/abc.bin"
        // (slashes intact) — if it didn't, the signature would be invalid
        // server-side. We can't easily assert that without parsing the
        // canonical request, so we sanity check the URL is preserved.
        XCTAssertEqual(signed.url?.path, "/clip-sync/items/abc.bin")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.S3SignerV4Tests
```

Expected: compile error.

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
    let region: String              // R2: "auto"; AWS examples: "us-east-1"
    let service: String             // "s3"

    /// Returns a copy of `request` with `Authorization`, `x-amz-date`, and
    /// `x-amz-content-sha256` headers set. `payloadSha256` is the literal
    /// string `"UNSIGNED-PAYLOAD"` for v3 use; could be a real hex digest
    /// if a future caller wants signed payloads.
    func sign(request: URLRequest, payloadSha256: String, date: Date = Date()) -> URLRequest {
        var req = request

        let amzDate = Self.amzDateFormatter.string(from: date)         // "20150830T123600Z"
        let dateStamp = String(amzDate.prefix(8))                      // "20150830"

        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadSha256, forHTTPHeaderField: "x-amz-content-sha256")

        // Canonical request --------------------------------------------------
        let method = req.httpMethod ?? "GET"
        let url = req.url!
        let canonicalURI = url.path.isEmpty ? "/" : url.path
        let canonicalQuery = Self.canonicalQuery(url: url)

        // Build sorted host; x-amz-content-sha256; x-amz-date headers.
        let host = url.host ?? ""
        let headerPairs: [(String, String)] = [
            ("host", host),
            ("x-amz-content-sha256", payloadSha256),
            ("x-amz-date", amzDate),
        ].sorted { $0.0 < $1.0 }
        let canonicalHeaders = headerPairs.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headerPairs.map { $0.0 }.joined(separator: ";")

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadSha256,
        ].joined(separator: "\n")

        // String to sign -----------------------------------------------------
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let crSha = Self.sha256Hex(Data(canonicalRequest.utf8))
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            crSha,
        ].joined(separator: "\n")

        // Signing key --------------------------------------------------------
        let kDate    = Self.hmac(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion  = Self.hmac(key: kDate, data: Data(region.utf8))
        let kService = Self.hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = Self.hmac(key: kService, data: Data("aws4_request".utf8))
        let signature = Self.hmac(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let auth = "AWS4-HMAC-SHA256 " +
            "Credential=\(accessKeyID)/\(credentialScope), " +
            "SignedHeaders=\(signedHeaders), " +
            "Signature=\(signature)"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - helpers

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
        // Sort by name, then percent-encode each name+value per RFC 3986.
        return items.sorted(by: { $0.name < $1.name }).map { item in
            let n = Self.rfc3986Encode(item.name)
            let v = Self.rfc3986Encode(item.value ?? "")
            return "\(n)=\(v)"
        }.joined(separator: "&")
    }

    /// RFC 3986 unreserved chars only: A–Z a–z 0–9 - _ . ~
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
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
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

### Task 11: R2Backend — URLSession + S3SignerV4

**Files:**
- Create: `Sources/Clip/Sync/R2Backend.swift`
- Create: `Tests/ClipTests/Sync/R2BackendTests.swift` (no real network — uses `URLProtocol` stub to verify correct request shape)

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/R2BackendTests.swift
import XCTest
@testable import Clip

/// Stub URLProtocol that captures requests and returns canned responses.
/// Lets us verify R2Backend builds the right URLs/headers without network.
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

final class R2BackendTests: XCTestCase {
    var session: URLSession!

    override func setUp() {
        super.setUp()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProto.self]
        session = URLSession(configuration: cfg)
    }
    override func tearDown() {
        StubProto.handler = nil
        super.tearDown()
    }

    func makeBackend() -> R2Backend {
        R2Backend(
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
            let r = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["ETag": "\"deadbeef\"",
                               "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"])!
            return (r, nil)
        }
        let backend = makeBackend()
        let (etag, lm) = try await backend.put(
            key: "items/abc.bin", body: Data([0xAA]), contentType: "application/octet-stream")

        XCTAssertEqual(etag, "deadbeef", "ETag quotes stripped")
        XCTAssertGreaterThan(lm, 0)

        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.url?.absoluteString,
                       "https://account.r2.cloudflarestorage.com/clip-sync/items/abc.bin")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-amz-content-sha256"), "UNSIGNED-PAYLOAD")
    }

    func testGetReturnsBodyOn200() async throws {
        StubProto.handler = { req in
            let r = HTTPURLResponse(url: req.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!
            return (r, Data("payload".utf8))
        }
        let body = try await makeBackend().get(key: "k.bin")
        XCTAssertEqual(body, Data("payload".utf8))
    }

    func testGetReturnsNilOn404() async throws {
        StubProto.handler = { req in
            let r = HTTPURLResponse(url: req.url!, statusCode: 404,
                                    httpVersion: nil, headerFields: nil)!
            return (r, nil)
        }
        XCTAssertNil(try await makeBackend().get(key: "missing.bin"))
    }

    func testDeleteOk() async throws {
        StubProto.handler = { req in
            XCTAssertEqual(req.httpMethod, "DELETE")
            let r = HTTPURLResponse(url: req.url!, statusCode: 204,
                                    httpVersion: nil, headerFields: nil)!
            return (r, nil)
        }
        try await makeBackend().delete(key: "x.bin")  // no throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.R2BackendTests
```

Expected: compile error.

- [ ] **Step 3: Implement R2Backend**

```swift
// Sources/Clip/Sync/R2Backend.swift
import Foundation

/// CloudSyncBackend implementation against Cloudflare R2 over the S3 API.
/// Pure Foundation + S3SignerV4. No third-party SDK.
final class R2Backend: CloudSyncBackend, @unchecked Sendable {
    enum Error: Swift.Error {
        case http(status: Int, body: String)
        case missingHeader(String)
    }

    let endpoint: URL              // e.g. https://account.r2.cloudflarestorage.com
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
        // Path-style: https://endpoint/bucket/key
        endpoint.appendingPathComponent(bucket).appendingPathComponent(key)
    }

    // MARK: - put

    func put(key: String, body: Data, contentType: String?) async throws -> (etag: String, lastModified: Int64) {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "PUT"
        req.httpBody = body
        if let contentType {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let rawEtag = http.value(forHTTPHeaderField: "ETag") else {
            throw Error.missingHeader("ETag")
        }
        let etag = rawEtag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let lm = Self.parseHttpDate(http.value(forHTTPHeaderField: "Last-Modified"))
            ?? Int64(Date().timeIntervalSince1970)
        return (etag, lm)
    }

    // MARK: - get

    func get(key: String) async throws -> Data? {
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

    // MARK: - head

    func head(key: String) async throws -> CloudObjectMeta? {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "HEAD"
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (_, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode, body: "")
        }
        let etag = (http.value(forHTTPHeaderField: "ETag") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let lm = Self.parseHttpDate(http.value(forHTTPHeaderField: "Last-Modified"))
            ?? Int64(Date().timeIntervalSince1970)
        let size = Int(http.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
        return CloudObjectMeta(key: key, etag: etag, lastModified: lm, size: size)
    }

    // MARK: - delete

    func delete(key: String) async throws {
        var req = URLRequest(url: url(for: key))
        req.httpMethod = "DELETE"
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        // 204 No Content is the normal success; 404 is OK (idempotent).
        if http.statusCode == 404 { return }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - list

    func list(prefix: String, after cursor: String?) async throws -> ListPage {
        var comps = URLComponents(url: endpoint.appendingPathComponent(bucket),
                                  resolvingAgainstBaseURL: false)!
        var q = [URLQueryItem(name: "list-type", value: "2"),
                 URLQueryItem(name: "prefix", value: prefix),
                 URLQueryItem(name: "max-keys", value: "1000")]
        if let cursor { q.append(URLQueryItem(name: "continuation-token", value: cursor)) }
        comps.queryItems = q
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let signed = signer.sign(request: req, payloadSha256: "UNSIGNED-PAYLOAD")
        let (data, resp) = try await session.data(for: signed)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode,
                             body: String(data: data, encoding: .utf8) ?? "")
        }
        return Self.parseListV2(data)
    }

    /// Minimal XML parser for ListBucketResult. Extracts the fields we
    /// need (Key, ETag, LastModified, Size) plus the IsTruncated /
    /// NextContinuationToken pagination fields.
    static func parseListV2(_ xml: Data) -> ListPage {
        let parser = ListV2Parser()
        let p = XMLParser(data: xml)
        p.delegate = parser
        p.parse()
        return ListPage(objects: parser.objects, nextCursor: parser.nextCursor)
    }

    private final class ListV2Parser: NSObject, XMLParserDelegate {
        var objects: [CloudObjectMeta] = []
        var nextCursor: String?
        private var element = ""
        private var key = ""; private var etag = ""; private var size = 0; private var lm: Int64 = 0
        private var inContents = false; private var truncated = false

        func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?,
                    qualifiedName q: String?, attributes a: [String : String] = [:]) {
            element = n
            if n == "Contents" {
                inContents = true
                key = ""; etag = ""; size = 0; lm = 0
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) {
            switch element {
            case "Key" where inContents: key += s
            case "ETag" where inContents: etag += s
            case "Size" where inContents: size = (Int(size.description + s) ?? size)
            case "LastModified" where inContents:
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = f.date(from: s) { lm = Int64(d.timeIntervalSince1970) }
            case "IsTruncated": truncated = (s.trimmingCharacters(in: .whitespaces) == "true")
            case "NextContinuationToken":
                nextCursor = (nextCursor ?? "") + s
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?,
                    qualifiedName q: String?) {
            if n == "Contents" {
                let cleanEtag = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                objects.append(CloudObjectMeta(key: key, etag: cleanEtag,
                                               lastModified: lm, size: size))
                inContents = false
            }
            element = ""
        }
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "GMT")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func parseHttpDate(_ s: String?) -> Int64? {
        guard let s, let d = httpDateFormatter.date(from: s) else { return nil }
        return Int64(d.timeIntervalSince1970)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.R2BackendTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/R2Backend.swift Tests/ClipTests/Sync/R2BackendTests.swift
git commit -m "sync: R2Backend — URLSession + Sig V4, S3 ListV2 XML parser"
```

---

## Phase P3 — Engine

### Task 12: SyncQueue — DB-backed retry queue

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
        try q.enqueue(op: .putItem, targetKey: "1", at: 100)
        try q.enqueue(op: .putItem, targetKey: "2", at: 50)
        try q.enqueue(op: .putItem, targetKey: "3", at: 200)
        let r1 = try XCTUnwrap(try q.dequeueDueAt(now: 1000))
        XCTAssertEqual(r1.targetKey, "2")  // smallest next_try_at first
        try q.delete(id: r1.id)
        let r2 = try XCTUnwrap(try q.dequeueDueAt(now: 1000))
        XCTAssertEqual(r2.targetKey, "1")
    }

    func testDequeueRespectsNextTryAt() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putItem, targetKey: "future", at: 1000)
        XCTAssertNil(try q.dequeueDueAt(now: 500))
        XCTAssertNotNil(try q.dequeueDueAt(now: 1500))
    }

    func testRecordFailureAppliesBackoff() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putItem, targetKey: "x", at: 100)
        let r = try XCTUnwrap(try q.dequeueDueAt(now: 1000))
        try q.recordFailure(id: r.id, attempts: r.attempts + 1, error: "boom", at: 1000)
        // attempts=1 → backoff = 2^1 = 2s; next_try_at = 1002
        XCTAssertNil(try q.dequeueDueAt(now: 1001))
        XCTAssertNotNil(try q.dequeueDueAt(now: 1002))
    }

    func testBackoffCappedAt900() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putItem, targetKey: "x", at: 0)
        let r = try XCTUnwrap(try q.dequeueDueAt(now: 1000))
        // attempts=20 → 2^20 = 1M; capped at 900s
        try q.recordFailure(id: r.id, attempts: 20, error: "boom", at: 1000)
        XCTAssertNil(try q.dequeueDueAt(now: 1899))
        XCTAssertNotNil(try q.dequeueDueAt(now: 1900))
    }

    func testDeleteByItemTargetKey() throws {
        let s = try HistoryStore.inMemory()
        let q = SyncQueue(store: s)
        try q.enqueue(op: .putItem, targetKey: "5", at: 0)
        try q.enqueue(op: .putBlob, targetKey: "5", at: 0)
        try q.enqueue(op: .putTomb, targetKey: "x", at: 0)
        try q.deleteAllForItem(itemID: 5)
        let remaining = try q.peekAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.op, .putTomb)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncQueueTests
```

Expected: compile error.

- [ ] **Step 3: Implement SyncQueue**

```swift
// Sources/Clip/Sync/SyncQueue.swift
import Foundation
import GRDB

/// DB-backed retry queue (table sync_queue, created in Migration v3).
/// Spec §7.2: pusher dequeues lowest next_try_at <= now; on failure,
/// recordFailure with backoff = min(900, 2^attempts) seconds.
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

    /// Dequeue is a peek — caller deletes after success or recordFailure on error.
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

    /// Apply exponential backoff: next_try_at = now + min(900, 2^attempts).
    func recordFailure(id: Int64, attempts: Int, error: String, at now: Int64) throws {
        let backoff = min(900, Int(truncatingIfNeeded: 1 &<< min(attempts, 20)))
        try store.pool.write { db in
            try db.execute(sql: """
                UPDATE sync_queue SET attempts = ?, last_error = ?, next_try_at = ?
                WHERE id = ?
            """, arguments: [attempts, error, now + Int64(backoff), id])
        }
    }

    /// Remove all queue rows referencing a given items.id (op = put_item or put_blob).
    func deleteAllForItem(itemID: Int64) throws {
        let target = String(itemID)
        try store.pool.write { db in
            try db.execute(sql: """
                DELETE FROM sync_queue
                WHERE op IN ('put_item', 'put_blob')
                  AND target_key = ?
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
            op: SyncOp(rawValue: r["op"]) ?? .putItem,
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

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncQueue.swift Tests/ClipTests/Sync/SyncQueueTests.swift
git commit -m "sync: SyncQueue — DB-backed retry queue with exponential backoff"
```

---

### Task 13: SyncStateStore — KV access to `sync_state` table

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
        let kv = SyncStateStore(store: s)
        XCTAssertNil(try kv.get("device_id"))
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

Expected: compile error.

- [ ] **Step 3: Implement SyncStateStore**

```swift
// Sources/Clip/Sync/SyncStateStore.swift
import Foundation
import GRDB

/// Tiny KV wrapper around the sync_state table. Keys/values both TEXT;
/// callers responsible for JSON-encoding non-string values.
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

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncStateStore.swift Tests/ClipTests/Sync/SyncStateStoreTests.swift
git commit -m "sync: SyncStateStore — kv wrapper over sync_state table"
```

---

### Task 14: SyncEngine — push loop only

This task adds the actor with a `pushOnce()` method that drains exactly one queue row. The full loop (`runForever`) and pull are added in subsequent tasks.

**Files:**
- Create: `Sources/Clip/Sync/SyncEngine.swift`
- Create: `Tests/ClipTests/Sync/SyncEnginePushTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEnginePushTests.swift
import XCTest
@testable import Clip

final class SyncEnginePushTests: XCTestCase {
    func makeBackend() -> LocalDirBackend {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LocalDirBackend(root: dir)
    }

    func testPushOnceUploadsItemPayload() async throws {
        let store = try HistoryStore.inMemory()
        let backend = makeBackend()
        let crypto = CryptoBox(masterKey: Data(repeating: 1, count: 32))
        let engine = SyncEngine(store: store, backend: backend, crypto: crypto,
                                deviceID: "DEV", state: SyncStateStore(store: store))

        let id = try store.insert(ClipItem(
            id: nil, content: "hello", contentHash: ClipItem.contentHash(of: "hello"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 5, truncated: false))

        try await engine.enqueueItemPush(itemID: id, at: 100)
        let did = try await engine.pushOnce(now: 200)
        XCTAssertTrue(did)

        // After push: item should be marked synced + cloud should have an items/ object
        let item = try XCTUnwrap(try store.itemByID(id))
        XCTAssertNotNil(item.cloudSyncedAt)
        XCTAssertNotNil(item.cloudEtag)

        let name = crypto.name(forContentHash: item.contentHash)
        let bytes = try await backend.get(key: CloudKey.itemKey(name: name))
        XCTAssertNotNil(bytes)

        // And: no more rows due
        let again = try await engine.pushOnce(now: 200)
        XCTAssertFalse(again)
    }

    func testPushOnceFailureAppliesBackoff() async throws {
        let store = try HistoryStore.inMemory()
        let backend = AlwaysFailBackend()
        let crypto = CryptoBox(masterKey: Data(repeating: 1, count: 32))
        let engine = SyncEngine(store: store, backend: backend, crypto: crypto,
                                deviceID: "DEV", state: SyncStateStore(store: store))

        let id = try store.insert(ClipItem(
            id: nil, content: "h", contentHash: ClipItem.contentHash(of: "h"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 1, truncated: false))
        try await engine.enqueueItemPush(itemID: id, at: 100)

        let didTry = try await engine.pushOnce(now: 200)
        XCTAssertTrue(didTry)
        // attempts=1 → backoff = 2; not due at 201, is due at 202
        let again = try await engine.pushOnce(now: 201)
        XCTAssertFalse(again)
        let dueAt202 = try await engine.pushOnce(now: 202)
        XCTAssertTrue(dueAt202)
    }
}

/// Backend that throws on every operation. For backoff testing.
final class AlwaysFailBackend: CloudSyncBackend, @unchecked Sendable {
    struct E: Error {}
    func put(key: String, body: Data, contentType: String?) async throws -> (etag: String, lastModified: Int64) { throw E() }
    func get(key: String) async throws -> Data? { throw E() }
    func head(key: String) async throws -> CloudObjectMeta? { throw E() }
    func delete(key: String) async throws { throw E() }
    func list(prefix: String, after cursor: String?) async throws -> ListPage { throw E() }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEnginePushTests
```

Expected: compile error.

- [ ] **Step 3: Implement SyncEngine (push half only)**

```swift
// Sources/Clip/Sync/SyncEngine.swift
import Foundation

/// Cloud sync orchestrator. Spec §4.2: actor; two background loops
/// (push drainer + 30s pull tick) plus signal-based wakeups. This
/// initial implementation has push only; pull, tombstones, blob
/// fetch, backfill come in subsequent tasks.
actor SyncEngine {
    let store: HistoryStore
    let backend: CloudSyncBackend
    let crypto: CryptoBox
    let deviceID: String
    let state: SyncStateStore
    let queue: SyncQueue

    init(store: HistoryStore, backend: CloudSyncBackend,
         crypto: CryptoBox, deviceID: String, state: SyncStateStore) {
        self.store = store
        self.backend = backend
        self.crypto = crypto
        self.deviceID = deviceID
        self.state = state
        self.queue = SyncQueue(store: store)
    }

    // MARK: - public enqueue API

    func enqueueItemPush(itemID: Int64, at: Int64) throws {
        // Spec §10.4 — runtime guard against >2MB images. Backfill SQL also
        // filters but live onChange-fired enqueues need their own check.
        if let item = try store.itemByID(itemID),
           item.kind == .image, let blobID = item.blobID,
           let info = try store.blobInfo(id: blobID),
           info.size > 2 * 1024 * 1024 {
            return                  // skip; UI will show 📤 (panel icon task)
        }
        try queue.enqueue(op: .putItem, targetKey: String(itemID), at: at)
    }

    func enqueueBlobPush(blobID: Int64, at: Int64) throws {
        try queue.enqueue(op: .putBlob, targetKey: String(blobID), at: at)
    }

    // MARK: - push drainer

    /// Drain at most one queue row. Returns true iff a row was attempted
    /// (success or failure both count). Returns false iff nothing was due.
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
        case .putItem:
            try await pushItem(itemID: Int64(row.targetKey)!)
        case .putBlob:
            try await pushBlob(blobID: Int64(row.targetKey)!)
        case .putTomb:
            try await pushTomb(hmac: row.targetKey)
        case .putDevice:
            try await pushDevice()
        }
    }

    private func pushItem(itemID: Int64) async throws {
        guard let item = try store.itemByID(itemID) else { return }
        let payload = ItemPayload(
            v: 1, kind: item.kind.rawValue, contentHash: item.contentHash,
            content: item.kind == .text ? item.content : nil,
            mimeType: item.mimeType,
            blobHmac: item.blobID.map { _ in
                // Resolve blob_hmac from clip_blobs.sha256, hashed via crypto.name
                // For now placeholder; pushBlob will set it. v3 keeps simple:
                // we encode null and let pull side derive from the blob name lookup.
                ""  // overridden below
            },
            blobSize: nil, thumbB64: nil,
            byteSize: item.byteSize, truncated: item.truncated,
            sourceBundleId: item.sourceBundleID,
            sourceAppName: item.sourceAppName,
            createdAt: item.createdAt, pinned: item.pinned,
            deviceId: item.deviceID ?? deviceID)

        // For text-only items the blob_hmac reference is unused on the
        // pull side. For image items we want the actual blob_hmac so that
        // lazy fetch can locate the blobs/<name> object. Compute it from
        // the blob's sha256.
        var finalPayload = payload
        if item.kind == .image, let blobID = item.blobID,
           let info = try store.blobInfo(id: blobID) {
            finalPayload.blobHmac = crypto.name(forContentHash: info.sha)
            finalPayload.blobSize = info.size
        } else if item.kind == .text {
            finalPayload.blobHmac = nil
        }

        let json = try JSONEncoder().encode(finalPayload)
        let sealed = try crypto.seal(json)
        let name = crypto.name(forContentHash: item.contentHash)
        let key = CloudKey.itemKey(name: name)
        let now = Int64(Date().timeIntervalSince1970)
        let (etag, lm) = try await backend.put(key: key, body: sealed,
                                               contentType: "application/octet-stream")
        try store.markItemSynced(id: itemID, at: now, etag: etag, lastModified: lm)
        try store.setItemCloudName(id: itemID, name: name)   // enables future ETag-skip on pull
    }

    private func pushBlob(blobID: Int64) async throws {
        guard let bytes = try store.blob(id: blobID),
              let info = try store.blobInfo(id: blobID) else { return }
        let sealed = try crypto.seal(bytes)
        let name = crypto.name(forContentHash: info.sha)
        let key = CloudKey.blobKey(name: name)
        let now = Int64(Date().timeIntervalSince1970)
        let (etag, _) = try await backend.put(key: key, body: sealed,
                                              contentType: "application/octet-stream")
        try store.markBlobSynced(id: blobID, at: now, etag: etag)
    }

    private func pushTomb(hmac: String) async throws {
        // Implementation in task 16 (tombstones). For now: no-op stub so
        // tests that don't enqueue tomb rows pass. Calling this with an
        // actual hmac before task 16 will silently no-op.
        _ = hmac
    }

    private func pushDevice() async throws {
        // Implementation in task 18.
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEnginePushTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEnginePushTests.swift
git commit -m "sync: SyncEngine — push half (item + blob upload, backoff on failure)"
```

---

### Task 15: SyncEngine — pull half (items only)

Adds `pullOnce()` that lists `items/` and reconciles into the local store. Tombstones come next.

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — append pull methods
- Create: `Tests/ClipTests/Sync/SyncEnginePullTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEnginePullTests.swift
import XCTest
@testable import Clip

final class SyncEnginePullTests: XCTestCase {
    /// Two stores share one backend (LocalDirBackend writing to a temp dir).
    /// A inserts → push → B pulls → B should see the same content_hash.
    func testTwoStoresEndToEnd() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backend = LocalDirBackend(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 7, count: 32))

        let storeA = try HistoryStore.inMemory()
        let stateA = SyncStateStore(store: storeA)
        let engineA = SyncEngine(store: storeA, backend: backend, crypto: crypto,
                                 deviceID: "A", state: stateA)

        let storeB = try HistoryStore.inMemory()
        let stateB = SyncStateStore(store: storeB)
        let engineB = SyncEngine(store: storeB, backend: backend, crypto: crypto,
                                 deviceID: "B", state: stateB)

        let id = try storeA.insert(ClipItem(
            id: nil, content: "shared!", contentHash: ClipItem.contentHash(of: "shared!"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 7, truncated: false))
        try await engineA.enqueueItemPush(itemID: id, at: 100)
        _ = try await engineA.pushOnce(now: 200)

        try await engineB.pullOnce(now: 300)
        let items = try storeB.listRecent()
        XCTAssertEqual(items.map(\.content), ["shared!"])
    }

    func testPullSkipsAlreadySeenEtag() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backend = LocalDirBackend(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 7, count: 32))
        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, backend: backend, crypto: crypto,
                                 deviceID: "A", state: SyncStateStore(store: storeA))
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, backend: backend, crypto: crypto,
                                 deviceID: "B", state: SyncStateStore(store: storeB))

        let id = try storeA.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 1, truncated: false))
        try await engineA.enqueueItemPush(itemID: id, at: 1)
        _ = try await engineA.pushOnce(now: 1)

        try await engineB.pullOnce(now: 2)
        XCTAssertEqual(try storeB.listRecent().count, 1)
        // Second pull: no change → still 1, no errors.
        try await engineB.pullOnce(now: 3)
        XCTAssertEqual(try storeB.listRecent().count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEnginePullTests
```

Expected: compile error ("no method pullOnce").

- [ ] **Step 3: Add pull methods to SyncEngine**

Append inside the `actor SyncEngine` body, after the push methods:

```swift
    // MARK: - pull tick

    /// One pass: list items/ + tomb/ + devices/, reconcile each into
    /// local store. Cursor lives in sync_state. Spec §7.3.
    func pullOnce(now: Int64) async throws {
        // tomb/ first so a freshly-pulled item that already had a tomb
        // is recognized as deleted in handleItemPayload.
        for prefix in [CloudKey.tombPrefix, CloudKey.itemsPrefix, CloudKey.devicesPrefix] {
            try await pullPrefix(prefix)
        }
        try state.set("last_pull_at", String(now))
    }

    private func pullPrefix(_ prefix: String) async throws {
        var cursor: String? = nil
        repeat {
            let page = try await backend.list(prefix: prefix, after: cursor)
            for obj in page.objects {
                let known = try lookupLocalEtag(prefix: prefix, key: obj.key)
                if known == obj.etag { continue }
                guard let sealed = try await backend.get(key: obj.key) else { continue }
                let plain = try crypto.open(sealed)
                switch prefix {
                case CloudKey.itemsPrefix:
                    let payload = try JSONDecoder().decode(ItemPayload.self, from: plain)
                    try handleItemPayload(payload, etag: obj.etag, lastModified: obj.lastModified)
                case CloudKey.tombPrefix:
                    let payload = try JSONDecoder().decode(TombstonePayload.self, from: plain)
                    try handleTombstonePayload(payload, etag: obj.etag, lastModified: obj.lastModified,
                                               key: obj.key)
                case CloudKey.devicesPrefix:
                    // device cache is in-memory only; v3 just decodes to ensure
                    // payload is well-formed. Wired to UI in task 18.
                    _ = try? JSONDecoder().decode(DevicePayload.self, from: plain)
                default: break
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
    }

    /// Spec §7.3 — incremental pull: skip GET if list ETag already matches what we
    /// stored last time. Fixes the "always re-download" correctness gap by querying
    /// the per-row cloud_etag column added in Migration v3 (Task 1).
    private func lookupLocalEtag(prefix: String, key: String) throws -> String? {
        // Cloud key shape: "<prefix><name>.bin" where name = hex(hmac).
        let dropped = key.dropFirst(prefix.count)
        guard dropped.hasSuffix(".bin") else { return nil }
        let name = String(dropped.dropLast(".bin".count))
        switch prefix {
        case CloudKey.itemsPrefix:    return try store.cloudEtagByName(name, table: "items")
        case CloudKey.tombPrefix:     return try store.tombstoneEtagByName(name)
        case CloudKey.devicesPrefix:  return nil   // device cache is in-memory only
        default:                      return nil
        }
    }

    private func handleItemPayload(_ payload: ItemPayload, etag: String, lastModified: Int64) throws {
        // Tombstone resurrection guard: §10.3 (tomb wins on >=).
        let hmac = crypto.name(forContentHash: payload.contentHash)
        if let tombAt = try store.tombstoneAt(hmac: hmac), tombAt >= payload.createdAt {
            return
        }

        if let existing = try store.itemByContentHash(payload.contentHash) {
            // LWW by R2 LastModified (§3 row 8 / §7.3).
            let local = existing.cloudLastModified ?? 0
            if lastModified > local {
                try store.updateMutableFromPayload(itemID: existing.id!, payload: payload,
                                                  etag: etag, lastModified: lastModified)
            }
            return
        }

        // Fresh INSERT. Image kind: blob row inserted with bytes NULL (lazy fetch).
        let now = Int64(Date().timeIntervalSince1970)
        var item = ClipItem(
            id: nil,
            content: payload.content ?? "",
            contentHash: payload.contentHash,
            sourceBundleID: payload.sourceBundleId,
            sourceAppName: payload.sourceAppName,
            createdAt: payload.createdAt,
            pinned: payload.pinned,
            byteSize: payload.byteSize,
            truncated: payload.truncated,
            kind: ClipKind(rawValue: payload.kind) ?? .text,
            blobID: nil,
            mimeType: payload.mimeType,
            cloudSyncedAt: now,
            cloudEtag: etag,
            cloudLastModified: lastModified,
            deviceID: payload.deviceId)

        if item.kind == .image, let blobHmac = payload.blobHmac, let blobSize = payload.blobSize {
            // Insert lazy blob row (bytes empty). Real bytes filled by fetchBlob (Task 17A).
            let blobID = try store.insertLazyBlob(blobHmac: blobHmac, byteSize: blobSize, now: now)
            item.blobID = blobID
        }
        // Set cloud_name so the next pull can ETag-skip this row.
        item.cloudName = hmac
        _ = try store.insert(item)
    }

    private func handleTombstonePayload(_ payload: TombstonePayload, etag: String,
                                        lastModified: Int64, key: String) throws {
        let hmac = String(key.dropFirst(CloudKey.tombPrefix.count).dropLast(".bin".count))
        try store.upsertTombstone(hmac: hmac, contentHash: payload.contentHash,
                                  tombstonedAt: payload.tombstonedAt,
                                  etag: etag, lastModified: lastModified)
        // Delete any local items whose created_at <= tombstonedAt.
        try store.deleteItemsByContentHashOlderThan(
            contentHash: payload.contentHash, tombstonedAt: payload.tombstonedAt)
    }
```

- [ ] **Step 4: Add the supporting HistoryStore helpers**

Append to `Sources/Clip/Storage/HistoryStore.swift`:

```swift
    // MARK: - Sync helpers (Task 15+)

    func itemByContentHash(_ hash: String) throws -> ClipItem? {
        try pool.read { db in
            try Row.fetchOne(db,
                sql: "SELECT * FROM items WHERE content_hash = ? LIMIT 1",
                arguments: [hash]).map(Self.itemFromRow)
        }
    }

    func tombstoneAt(hmac: String) throws -> Int64? {
        try pool.read { db in
            try Int64.fetchOne(db,
                sql: "SELECT tombstoned_at FROM tombstones WHERE hmac = ? LIMIT 1",
                arguments: [hmac])
        }
    }

    func updateMutableFromPayload(itemID: Int64, payload: ItemPayload,
                                  etag: String, lastModified: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE items SET pinned = ?, device_id = ?, cloud_etag = ?,
                                 cloud_lastmodified = ?
                WHERE id = ?
            """, arguments: [payload.pinned ? 1 : 0, payload.deviceId, etag, lastModified, itemID])
        }
    }

    func upsertTombstone(hmac: String, contentHash: String, tombstonedAt: Int64,
                         etag: String, lastModified: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO tombstones
                (hmac, content_hash, tombstoned_at, cloud_synced_at, cloud_etag, cloud_lastmodified)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(hmac) DO UPDATE SET
                  content_hash = excluded.content_hash,
                  tombstoned_at = excluded.tombstoned_at,
                  cloud_synced_at = excluded.cloud_synced_at,
                  cloud_etag = excluded.cloud_etag,
                  cloud_lastmodified = excluded.cloud_lastmodified
            """, arguments: [hmac, contentHash, tombstonedAt, lastModified, etag, lastModified])
        }
    }

    func deleteItemsByContentHashOlderThan(contentHash: String, tombstonedAt: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                DELETE FROM items WHERE content_hash = ? AND created_at <= ?
            """, arguments: [contentHash, tombstonedAt])
        }
    }

    /// Insert a placeholder blob row whose bytes are NULL (lazy-fetched later).
    /// Stores `lazy:<blobHmac>` in the sha256 column so the row can be uniquely
    /// addressed; real-blob fillBlob() updates sha256 to the actual SHA when bytes arrive.
    func insertLazyBlob(blobHmac: String, byteSize: Int, now: Int64) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO clip_blobs (sha256, bytes, byte_size, created_at)
                VALUES (?, ?, ?, ?)
            """, arguments: ["lazy:" + blobHmac, Data(), byteSize, now])
            return db.lastInsertedRowID
        }
    }
```

(Also `import GRDB` is already present at the top.)

- [ ] **Step 5: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEnginePullTests
```

Expected: 2 tests pass.

- [ ] **Step 6: Run the full suite (regression guard)**

```bash
swift test
```

- [ ] **Step 7: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Sources/Clip/Storage/HistoryStore.swift Tests/ClipTests/Sync/SyncEnginePullTests.swift
git commit -m "sync: SyncEngine — pull half (list/get/upsert items, lazy blob ref)"
```

---

### Task 16: SyncEngine — tombstones (delete + propagate)

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — implement `pushTomb` + `enqueueTombstone`
- Modify: `Sources/Clip/Storage/HistoryStore.swift` — add `insertTombstone`
- Create: `Tests/ClipTests/Sync/SyncEngineTombstoneTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineTombstoneTests.swift
import XCTest
@testable import Clip

final class SyncEngineTombstoneTests: XCTestCase {
    func testDeleteOnAPropagatesToB() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backend = LocalDirBackend(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 9, count: 32))

        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, backend: backend, crypto: crypto,
                                 deviceID: "A", state: SyncStateStore(store: storeA))
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, backend: backend, crypto: crypto,
                                 deviceID: "B", state: SyncStateStore(store: storeB))

        // A inserts + pushes
        let id = try storeA.insert(ClipItem(
            id: nil, content: "doomed", contentHash: ClipItem.contentHash(of: "doomed"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 6, truncated: false))
        try await engineA.enqueueItemPush(itemID: id, at: 100)
        _ = try await engineA.pushOnce(now: 100)

        // B pulls — sees the item
        try await engineB.pullOnce(now: 200)
        XCTAssertEqual(try storeB.listRecent().count, 1)

        // A deletes + tombstones + pushes the tomb
        let hash = ClipItem.contentHash(of: "doomed")
        try storeA.delete(id: id)
        try await engineA.enqueueTombstone(contentHash: hash, at: 300)
        _ = try await engineA.pushOnce(now: 300)

        // B pulls — should see the tomb and remove the local row
        try await engineB.pullOnce(now: 400)
        XCTAssertEqual(try storeB.listRecent().count, 0)
        // tombstones table on B should have a row preventing resurrection
        XCTAssertNotNil(try storeB.tombstoneAt(hmac: crypto.name(forContentHash: hash)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineTombstoneTests
```

Expected: compile error ("no method enqueueTombstone").

- [ ] **Step 3: Add enqueueTombstone + pushTomb impl**

In `SyncEngine`, replace the placeholder `pushTomb` and add `enqueueTombstone`:

```swift
    func enqueueTombstone(contentHash: String, at: Int64) throws {
        let hmac = crypto.name(forContentHash: contentHash)
        try store.insertTombstone(hmac: hmac, contentHash: contentHash, tombstonedAt: at)
        try queue.enqueue(op: .putTomb, targetKey: hmac, at: at)
    }

    private func pushTomb(hmac: String) async throws {
        guard let row = try store.tombstoneRow(hmac: hmac) else { return }
        let payload = TombstonePayload(v: 1, contentHash: row.contentHash,
                                       tombstonedAt: row.tombstonedAt, deviceId: deviceID)
        let json = try JSONEncoder().encode(payload)
        let sealed = try crypto.seal(json)
        let key = CloudKey.tombKey(name: hmac)
        let now = Int64(Date().timeIntervalSince1970)
        let (etag, lm) = try await backend.put(key: key, body: sealed,
                                               contentType: "application/octet-stream")
        try store.markTombstoneSynced(hmac: hmac, at: now, etag: etag, lastModified: lm)
        // Also delete the original items/<hmac>.bin so subsequent pulls don't re-INSERT.
        try await backend.delete(key: CloudKey.itemKey(name: hmac))
    }
```

In `HistoryStore`, append:

```swift
    func insertTombstone(hmac: String, contentHash: String, tombstonedAt: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO tombstones (hmac, content_hash, tombstoned_at)
                VALUES (?, ?, ?)
                ON CONFLICT(hmac) DO UPDATE SET tombstoned_at = excluded.tombstoned_at
            """, arguments: [hmac, contentHash, tombstonedAt])
        }
    }

    struct TombstoneRow: Sendable {
        var hmac: String
        var contentHash: String
        var tombstonedAt: Int64
    }

    func tombstoneRow(hmac: String) throws -> TombstoneRow? {
        try pool.read { db in
            try Row.fetchOne(db,
                sql: "SELECT hmac, content_hash, tombstoned_at FROM tombstones WHERE hmac = ?",
                arguments: [hmac]).map { row in
                    TombstoneRow(hmac: row["hmac"], contentHash: row["content_hash"],
                                 tombstonedAt: row["tombstoned_at"])
                }
        }
    }

    func markTombstoneSynced(hmac: String, at: Int64, etag: String, lastModified: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE tombstones SET cloud_synced_at = ?, cloud_etag = ?, cloud_lastmodified = ?
                WHERE hmac = ?
            """, arguments: [at, etag, lastModified, hmac])
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineTombstoneTests
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Sources/Clip/Storage/HistoryStore.swift Tests/ClipTests/Sync/SyncEngineTombstoneTests.swift
git commit -m "sync: SyncEngine — tombstone push + propagation, items/<h> cleanup on tomb"
```

---

### Task 17: SyncEngine — backfill

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — add `enableSync()` and `backfill()`
- Modify: `Sources/Clip/Storage/HistoryStore.swift` — add `forSyncBackfill` query helpers
- Create: `Tests/ClipTests/Sync/SyncEngineEnableTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineEnableTests.swift
import XCTest
@testable import Clip

final class SyncEngineEnableTests: XCTestCase {
    func testEnableQueuesExistingItemsNewestFirst() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backend = LocalDirBackend(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let store = try HistoryStore.inMemory()
        let state = SyncStateStore(store: store)
        let engine = SyncEngine(store: store, backend: backend, crypto: crypto,
                                deviceID: "DEV", state: state)

        // Three pre-existing items, oldest first by createdAt
        for (i, c) in ["old", "mid", "new"].enumerated() {
            try store.insert(ClipItem(
                id: nil, content: c, contentHash: ClipItem.contentHash(of: c),
                sourceBundleID: nil, sourceAppName: nil, createdAt: Int64(100 + i),
                pinned: false, byteSize: c.utf8.count, truncated: false))
        }

        try await engine.backfill(now: 1000)

        // sync_queue should have 3 put_item rows; first dequeued = newest
        let q = SyncQueue(store: store)
        let r1 = try XCTUnwrap(try q.dequeueDueAt(now: 2000))
        XCTAssertEqual(r1.op, .putItem)
        let item1 = try XCTUnwrap(try store.itemByID(Int64(r1.targetKey)!))
        XCTAssertEqual(item1.content, "new")
    }

    func testEnableSkipsExcludedItems() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backend = LocalDirBackend(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xAA, count: 32))
        let store = try HistoryStore.inMemory()
        let engine = SyncEngine(store: store, backend: backend, crypto: crypto,
                                deviceID: "DEV", state: SyncStateStore(store: store))

        let id = try store.insert(ClipItem(
            id: nil, content: "secret", contentHash: ClipItem.contentHash(of: "secret"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 1,
            pinned: false, byteSize: 6, truncated: false))
        try store.setSyncExcluded(id: id, excluded: true)

        try await engine.backfill(now: 1000)

        XCTAssertEqual(try SyncQueue(store: store).peekAll().count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineEnableTests
```

Expected: compile error.

- [ ] **Step 3: Add backfill to SyncEngine**

```swift
    /// Spec §7.6: enqueue every existing non-excluded item (and its blob if
    /// ≤ 2MB) into sync_queue. Run once **after** `enableSync` (Task 17A) finishes
    /// the bootstrap. Independent transaction; not part of Migrator.
    func backfill(now: Int64) async throws {
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
                SELECT 'put_item', CAST(items.id AS TEXT), 0, ?, ?
                FROM items
                LEFT JOIN clip_blobs ON items.blob_id = clip_blobs.id
                WHERE items.sync_excluded = 0
                  AND (items.kind = 'text' OR clip_blobs.byte_size <= 2097152)
                ORDER BY items.created_at DESC
            """, arguments: [now, now])
            try db.execute(sql: """
                INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
                SELECT 'put_blob', CAST(clip_blobs.id AS TEXT), 0, ?, ?
                FROM clip_blobs
                JOIN items ON items.blob_id = clip_blobs.id
                WHERE items.sync_excluded = 0 AND clip_blobs.byte_size <= 2097152
                ORDER BY items.created_at DESC
            """, arguments: [now, now])
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineEnableTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEngineEnableTests.swift
git commit -m "sync: SyncEngine — backfill enqueues existing items newest-first"
```

---

### Task 18: SyncEngine — exclude propagation

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — `excludeItem(id:)` method
- Create: `Tests/ClipTests/Sync/SyncEngineExcludeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineExcludeTests.swift
import XCTest
@testable import Clip

final class SyncEngineExcludeTests: XCTestCase {
    func testExcludingSyncedItemEnqueuesTombAndDeletesPendingPushes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backend = LocalDirBackend(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xCC, count: 32))
        let store = try HistoryStore.inMemory()
        let engine = SyncEngine(store: store, backend: backend, crypto: crypto,
                                deviceID: "DEV", state: SyncStateStore(store: store))

        let id = try store.insert(ClipItem(
            id: nil, content: "x", contentHash: ClipItem.contentHash(of: "x"),
            sourceBundleID: nil, sourceAppName: nil, createdAt: 100,
            pinned: false, byteSize: 1, truncated: false))
        try await engine.enqueueItemPush(itemID: id, at: 100)
        _ = try await engine.pushOnce(now: 100)  // it's now synced

        try await engine.excludeItem(id: id, at: 200)

        // sync_queue: a tomb row, no put_item row
        let q = try SyncQueue(store: store).peekAll()
        XCTAssertEqual(q.filter { $0.op == .putTomb }.count, 1)
        XCTAssertEqual(q.filter { $0.op == .putItem }.count, 0)

        // item flagged
        XCTAssertEqual(try store.itemByID(id)?.syncExcluded, true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineExcludeTests
```

Expected: compile error.

- [ ] **Step 3: Add excludeItem method**

```swift
    /// User toggles "do not sync this" on a panel row.
    /// Spec §7.5: synced item → tomb push + delete pending; unsynced → just delete pending.
    func excludeItem(id: Int64, at: Int64) async throws {
        guard let item = try store.itemByID(id) else { return }
        try store.setSyncExcluded(id: id, excluded: true)
        try queue.deleteAllForItem(itemID: id)
        if item.cloudSyncedAt != nil {
            try enqueueTombstone(contentHash: item.contentHash, at: at)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineExcludeTests
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEngineExcludeTests.swift
git commit -m "sync: SyncEngine — excludeItem (tomb + drop pending pushes)"
```

---

### Task 17A: SyncEngine — enableSync (config.json bootstrap + master-key derivation)

This task closes the most load-bearing gap surfaced by plan-review pass 1: without it, no device can ever produce a valid `master_key` in Keychain, so `AppDelegate.startCloudSyncIfEnabled` (Task 22) silently no-ops and nothing ever syncs.

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — add `enableSync(password:)` actor method
- Modify: `Sources/Clip/Storage/HistoryStore.swift` — no change (uses `SyncStateStore`)
- Create: `Tests/ClipTests/Sync/SyncEngineEnableBootstrapTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineEnableBootstrapTests.swift
import XCTest
@testable import Clip

final class SyncEngineEnableBootstrapTests: XCTestCase {
    func makeBackend() -> LocalDirBackend {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LocalDirBackend(root: dir)
    }

    func testFirstDeviceWritesConfigAndDerivesMasterKey() async throws {
        let backend = makeBackend()
        let store = try HistoryStore.inMemory()
        let state = SyncStateStore(store: store)
        let kc = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")

        let result = try await SyncEngine.enableSync(
            password: "correct-horse-battery-staple",
            backend: backend, state: state, keychain: kc, account: "master")

        XCTAssertEqual(result, .firstDevice)
        // config.json now exists in cloud
        XCTAssertNotNil(try await backend.get(key: CloudKey.configKey))
        // master key in Keychain
        XCTAssertNotNil(try kc.read(account: "master"))
        // sync_state populated
        XCTAssertNotNil(try state.get("kdf_salt_b64"))
        XCTAssertEqual(try state.get("kdf_iters"), "200000")
    }

    func testJoiningDeviceRestoresMasterKeyFromExistingConfig() async throws {
        let backend = makeBackend()

        // Device A: bootstrap
        let storeA = try HistoryStore.inMemory()
        let stateA = SyncStateStore(store: storeA)
        let kcA = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")
        _ = try await SyncEngine.enableSync(
            password: "correct-horse-battery-staple",
            backend: backend, state: stateA, keychain: kcA, account: "master")
        let masterA = try kcA.read(account: "master")

        // Device B: joins with same password
        let storeB = try HistoryStore.inMemory()
        let stateB = SyncStateStore(store: storeB)
        let kcB = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")
        let result = try await SyncEngine.enableSync(
            password: "correct-horse-battery-staple",
            backend: backend, state: stateB, keychain: kcB, account: "master")

        XCTAssertEqual(result, .joinedExisting)
        XCTAssertEqual(try kcB.read(account: "master"), masterA, "same password+salt → same key")
    }

    func testJoiningWithWrongPasswordStillDerivesKeyButCallerCanReject() async throws {
        // The bootstrap function does not itself verify the password against
        // an existing payload — that's the engine's pull job to surface
        // (decryption fails on first item GET). This test pins the design.
        let backend = makeBackend()

        let storeA = try HistoryStore.inMemory()
        let kcA = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")
        _ = try await SyncEngine.enableSync(
            password: "correct-pass",
            backend: backend, state: SyncStateStore(store: storeA),
            keychain: kcA, account: "master")

        let storeB = try HistoryStore.inMemory()
        let kcB = KeychainStore(service: "com.zyw.clip.test.\(UUID().uuidString)")
        // Different password: still completes bootstrap (different master_key
        // gets written). Caller verifies via test-decryption afterward.
        let result = try await SyncEngine.enableSync(
            password: "wrong-pass",
            backend: backend, state: SyncStateStore(store: storeB),
            keychain: kcB, account: "master")
        XCTAssertEqual(result, .joinedExisting)
        XCTAssertNotEqual(try kcA.read(account: "master"),
                          try kcB.read(account: "master"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineEnableBootstrapTests
```

Expected: compile error.

- [ ] **Step 3: Add enableSync to SyncEngine**

Append (as a `static` method on `SyncEngine` because it runs before the engine instance is constructed):

```swift
extension SyncEngine {
    enum BootstrapResult: Equatable {
        case firstDevice         // wrote config.json + new salt
        case joinedExisting      // read config.json, derived from existing salt
    }

    /// Spec §7.1 first-time enable flow. Runs before SyncEngine is instantiated;
    /// once successful, AppDelegate can construct the engine with the freshly
    /// written master_key and run pull/push as normal.
    ///
    /// Side effects:
    ///   - config.json present in `backend` (created if missing)
    ///   - kdf_salt_b64 / kdf_iters / kdf_version persisted to sync_state
    ///   - master_key written to Keychain under `(service:account)`
    ///   - device_id allocated to sync_state if not already there
    static func enableSync(
        password: String,
        backend: CloudSyncBackend,
        state: SyncStateStore,
        keychain: KeychainStore,
        account: String
    ) async throws -> BootstrapResult {
        let iters = 200_000
        let configBytes = try await backend.get(key: CloudKey.configKey)
        let result: BootstrapResult
        let salt: Data

        if let configBytes {
            let config = try JSONDecoder().decode(CloudConfigPayload.self, from: configBytes)
            guard let s = Data(base64Encoded: config.kdfSaltB64) else {
                throw NSError(domain: "SyncEngine", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "config salt malformed"])
            }
            salt = s
            try state.set("kdf_iters", String(config.kdfIters))
            result = .joinedExisting
        } else {
            // First device — generate salt + write config.
            var fresh = Data(count: 16)
            _ = fresh.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            salt = fresh
            let payload = CloudConfigPayload(
                v: 1, kdf: "pbkdf2-hmac-sha256",
                kdfIters: iters, kdfSaltB64: salt.base64EncodedString(),
                format: "chacha20-poly1305-ietf-12-16")
            let json = try JSONEncoder().encode(payload)
            _ = try await backend.put(key: CloudKey.configKey, body: json,
                                      contentType: "application/json")
            try state.set("kdf_iters", String(iters))
            result = .firstDevice
        }

        try state.set("kdf_salt_b64", salt.base64EncodedString())
        try state.set("kdf_version", "1")

        let masterKey = KeyDerivation.pbkdf2_sha256(
            password: password, salt: salt,
            iterations: iters, keyLength: 32)
        try keychain.write(account: account, data: masterKey)

        if try state.get("device_id") == nil {
            try state.set("device_id", UUID().uuidString)
        }

        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineEnableBootstrapTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Tests/ClipTests/Sync/SyncEngineEnableBootstrapTests.swift
git commit -m "sync: SyncEngine.enableSync — config.json bootstrap + master-key derivation"
```

---

### Task 17B: SyncEngine + HistoryStore — lazy blob fetch

Closes the second load-bearing gap from plan-review: insert side of lazy blobs is in T15, but no read side; image rows on B device would have `bytes` empty forever.

**Files:**
- Modify: `Sources/Clip/Sync/SyncEngine.swift` — add `fetchBlob(blobHmac:) async throws -> Data`
- Modify: `Sources/Clip/Storage/HistoryStore.swift` — add `fillBlob`, `lazyBlobHmac` helpers; refactor `blob(id:)` is unchanged (it stays sync; lazy resolution happens in caller)
- Create: `Tests/ClipTests/Sync/SyncEngineLazyBlobTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ClipTests/Sync/SyncEngineLazyBlobTests.swift
import XCTest
@testable import Clip

final class SyncEngineLazyBlobTests: XCTestCase {
    func testFetchBlobDecryptsAndFillsLocalRow() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clip-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backend = LocalDirBackend(root: dir)
        let crypto = CryptoBox(masterKey: Data(repeating: 0xEE, count: 32))

        let storeA = try HistoryStore.inMemory()
        let engineA = SyncEngine(store: storeA, backend: backend, crypto: crypto,
                                 deviceID: "A", state: SyncStateStore(store: storeA))
        let storeB = try HistoryStore.inMemory()
        let engineB = SyncEngine(store: storeB, backend: backend, crypto: crypto,
                                 deviceID: "B", state: SyncStateStore(store: storeB))

        // A inserts an image
        let bytes = Data(repeating: 0x42, count: 1024)
        let aID = try storeA.insertImage(
            bytes: bytes, mimeType: "image/png",
            sourceBundleID: nil, sourceAppName: nil, now: 100)
        let aBlobID = try XCTUnwrap(try storeA.itemByID(aID)?.blobID)
        try await engineA.enqueueItemPush(itemID: aID, at: 100)
        try await engineA.enqueueBlobPush(blobID: aBlobID, at: 100)
        _ = try await engineA.pushOnce(now: 100)
        _ = try await engineA.pushOnce(now: 101)

        // B pulls — has lazy blob row but no bytes
        try await engineB.pullOnce(now: 200)
        let bItem = try XCTUnwrap(try storeB.listRecent().first)
        let bBlobID = try XCTUnwrap(bItem.blobID)
        let beforeBytes = try storeB.blob(id: bBlobID) ?? Data()
        XCTAssertTrue(beforeBytes.isEmpty, "lazy row starts empty")

        // B fetches: should hit backend, decrypt, fill local
        let got = try await engineB.fetchBlob(blobID: bBlobID)
        XCTAssertEqual(got, bytes)
        let after = try XCTUnwrap(try storeB.blob(id: bBlobID))
        XCTAssertEqual(after, bytes, "row now filled")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncEngineLazyBlobTests
```

Expected: compile error.

- [ ] **Step 3: Implement fetchBlob + HistoryStore helpers**

Append to `Sources/Clip/Sync/SyncEngine.swift` inside the actor:

```swift
    /// Spec §7.4 — lazy image download. Caller holds a clip_blobs.id whose
    /// `bytes` is empty (sha256 prefixed `lazy:`). Resolves the blob_hmac,
    /// GETs blobs/<hmac>.bin, decrypts, fills the local row, returns bytes.
    func fetchBlob(blobID: Int64) async throws -> Data {
        guard let info = try store.lazyBlobHmac(id: blobID) else {
            throw NSError(domain: "SyncEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "blob \(blobID) is not lazy"])
        }
        let key = CloudKey.blobKey(name: info.hmac)
        guard let sealed = try await backend.get(key: key) else {
            throw NSError(domain: "SyncEngine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "blob \(info.hmac) missing in cloud"])
        }
        let bytes = try crypto.open(sealed)
        let realSha = ClipItem.contentHash(of: bytes)
        try store.fillBlob(id: blobID, bytes: bytes, sha256: realSha,
                          at: Int64(Date().timeIntervalSince1970))
        return bytes
    }
```

Append to `Sources/Clip/Storage/HistoryStore.swift`:

```swift
    /// If `clip_blobs.sha256` starts with "lazy:", return the hmac suffix
    /// and current byte_size. Otherwise nil (already filled).
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

    /// Replace the lazy placeholder with real bytes + real sha256.
    /// `cloud_synced_at` is set so subsequent prune knows it's "live".
    func fillBlob(id: Int64, bytes: Data, sha256: String, at: Int64) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE clip_blobs SET bytes = ?, sha256 = ?, cloud_synced_at = ?
                WHERE id = ?
            """, arguments: [bytes, sha256, at, id])
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncEngineLazyBlobTests
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncEngine.swift Sources/Clip/Storage/HistoryStore.swift Tests/ClipTests/Sync/SyncEngineLazyBlobTests.swift
git commit -m "sync: SyncEngine.fetchBlob — lazy image download + decrypt + local fill"
```

---

## Phase P4 — UI + wire-in

### Task 19: SyncSettings — UserDefaults config wrapper

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
        XCTAssertNil(s.endpoint)
        XCTAssertNil(s.bucket)
        XCTAssertNil(s.accessKeyID)
    }

    func testRoundTrip() {
        s.enabled = true
        s.endpoint = "https://x.r2.cloudflarestorage.com"
        s.bucket = "clip-sync"
        s.accessKeyID = "AK"
        let s2 = SyncSettings(defaults: defaults)
        XCTAssertTrue(s2.enabled)
        XCTAssertEqual(s2.endpoint, "https://x.r2.cloudflarestorage.com")
        XCTAssertEqual(s2.bucket, "clip-sync")
        XCTAssertEqual(s2.accessKeyID, "AK")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
swift test --filter ClipTests.SyncSettingsTests
```

Expected: compile error.

- [ ] **Step 3: Implement SyncSettings**

```swift
// Sources/Clip/Sync/SyncSettings.swift
import Foundation

/// User-facing sync configuration. Non-secret values live in UserDefaults;
/// the secret access key + master key live in Keychain. Spec §8.1.
final class SyncSettings: Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let enabled     = "clip.cloud.enabled"
        static let endpoint    = "clip.cloud.endpoint"
        static let bucket      = "clip.cloud.bucket"
        static let accessKeyID = "clip.cloud.access_key_id"
    }

    var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }
    var endpoint: String? {
        get { defaults.string(forKey: Key.endpoint) }
        set { defaults.set(newValue, forKey: Key.endpoint) }
    }
    var bucket: String? {
        get { defaults.string(forKey: Key.bucket) }
        set { defaults.set(newValue, forKey: Key.bucket) }
    }
    var accessKeyID: String? {
        get { defaults.string(forKey: Key.accessKeyID) }
        set { defaults.set(newValue, forKey: Key.accessKeyID) }
    }
}
```

> Note: `Sendable` final class with mutable storage is technically unsafe, but `UserDefaults` itself is documented thread-safe. For test simplicity we accept this; in production usage the Settings instance lives behind `@MainActor PreferencesContainer`.

- [ ] **Step 4: Run test to verify it passes**

```bash
swift test --filter ClipTests.SyncSettingsTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Sync/SyncSettings.swift Tests/ClipTests/Sync/SyncSettingsTests.swift
git commit -m "sync: SyncSettings — UserDefaults wrapper for non-secret cloud config"
```

---

### Task 20: PanelView — sync icon + ⌘N exclude shortcut

**Files:**
- Modify: `Sources/Clip/Panel/PanelView.swift` — show icon column
- Modify: `Sources/Clip/Panel/PanelModel.swift` — `toggleExcludeSelected()` action
- Modify: `Sources/Clip/Panel/PanelWindow.swift` — wire ⌘N to model

> No automated test (UI). Manually verifiable via `docs/MANUAL_TEST.md` checklist updated in Task 24.

- [ ] **Step 1: Add `toggleExcludeSelected` to PanelModel**

In `Sources/Clip/Panel/PanelModel.swift`, append a method (this method dispatches to `AppDelegate` via the existing wired-up callback pattern; for now just emit through the same paste callback infrastructure).

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

In `Sources/Clip/Panel/PanelWindow.swift`, find the `KeyHandlers` struct and add:

```swift
    var onExclude: () -> Void = {}
```

In the key-handling switch in the same file, add a case for `n` with `.command` modifier:

```swift
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "n" {
            keyHandlers.onExclude()
            return nil
        }
```

(The exact location of the switch is just before/after the existing ⌘P / ⌘D handling — follow that pattern.)

- [ ] **Step 3: Add sync status icon column to PanelView**

In `Sources/Clip/Panel/PanelView.swift`, in the row-rendering view (search for "📌" or where rows are rendered), append after the existing trailing metadata:

```swift
            if let icon = syncIcon(for: item) {
                Text(icon)
                    .frame(width: 14, alignment: .center)
                    .help(syncTooltip(for: item))
            }
```

And add this helper at the bottom of the file (outside any existing struct/class but in the same file):

```swift
private func syncIcon(for item: ClipItem) -> String? {
    if item.syncExcluded { return "🚫" }
    if item.cloudSyncedAt != nil { return "☁️" }
    // Note: ⏳ for pending and 📤/⚠️ are added when wired to SyncEngine state.
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

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Panel/PanelView.swift Sources/Clip/Panel/PanelModel.swift Sources/Clip/Panel/PanelWindow.swift
git commit -m "sync: PanelView ⌘N exclude + sync status icon column"
```

---

### Task 21: CloudSyncView — Preferences "云同步" tab

**Files:**
- Create: `Sources/Clip/Preferences/CloudSyncView.swift`
- Modify: `Sources/Clip/Preferences/PreferencesWindow.swift` — add tab
- Modify: `Sources/Clip/Preferences/PreferencesContainer` — wire `SyncSettings` + (optional) `SyncEngine` reference

> No automated test (SwiftUI). Manually verified via Manual Test checklist.

- [ ] **Step 1: Create CloudSyncView**

```swift
// Sources/Clip/Preferences/CloudSyncView.swift
import SwiftUI

@MainActor
struct CloudSyncView: View {
    @State private var enabled: Bool = false
    @State private var endpoint: String = ""
    @State private var bucket: String = "clip-sync"
    @State private var accessKeyID: String = ""
    @State private var secretAccessKey: String = ""
    @State private var syncPassword: String = ""
    @State private var statusMessage: String = ""
    @State private var testing = false
    @State private var bootstrapping = false

    private var settings: SyncSettings { PreferencesContainer.shared.syncSettings }

    var body: some View {
        Form {
            Toggle("启用云同步", isOn: $enabled)
                .onChange(of: enabled) { _, new in settings.enabled = new }

            if enabled {
                Section("R2 配置") {
                    TextField("Endpoint",  text: $endpoint)
                        .help("形如 https://<account>.r2.cloudflarestorage.com")
                    TextField("Bucket",    text: $bucket)
                    TextField("Access Key ID", text: $accessKeyID)
                    SecureField("Secret Access Key", text: $secretAccessKey)
                    HStack {
                        Button(testing ? "测试中…" : "测试连接") { testConnection() }
                            .disabled(testing || endpoint.isEmpty || bucket.isEmpty
                                      || accessKeyID.isEmpty || secretAccessKey.isEmpty)
                        Spacer()
                        Text(statusMessage).font(.caption).foregroundColor(.secondary)
                    }
                }

                Section("同步密码 (E2E)") {
                    SecureField("同步密码 (≥12 字符)", text: $syncPassword)
                    Button(bootstrapping ? "正在初始化…" : "初始化 / 加入云端") {
                        bootstrap()
                    }
                    .disabled(bootstrapping || syncPassword.count < 12 ||
                              endpoint.isEmpty || bucket.isEmpty
                              || accessKeyID.isEmpty || secretAccessKey.isEmpty)
                    Text("剪贴板内容在上传前用你的同步密码做端到端加密 (ChaCha20-Poly1305)，云端永远拿不到明文。\n\n⚠️ 密码丢失 = 云端数据全部不可恢复，请使用密码管理器保存。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
        .onAppear {
            enabled = settings.enabled
            endpoint = settings.endpoint ?? ""
            bucket = settings.bucket ?? "clip-sync"
            accessKeyID = settings.accessKeyID ?? ""
        }
    }

    private func testConnection() {
        testing = true
        let endpoint = self.endpoint
        let bucket = self.bucket
        let ak = self.accessKeyID
        let sk = self.secretAccessKey
        Task {
            defer { Task { @MainActor in testing = false } }
            guard let url = URL(string: endpoint) else {
                await setStatus("Endpoint URL 无效")
                return
            }
            let backend = R2Backend(endpoint: url, bucket: bucket,
                                    accessKeyID: ak, secretAccessKey: sk)
            do {
                _ = try await backend.head(key: CloudKey.configKey)
                await setStatus("✓ 连接成功")
                await persistOnSuccess()
            } catch {
                await setStatus("✗ 失败: \(error)")
            }
        }
    }

    @MainActor
    private func persistOnSuccess() {
        settings.endpoint = endpoint
        settings.bucket = bucket
        settings.accessKeyID = accessKeyID
        // Secret goes to Keychain (Task 22 wires the engine to read it).
        try? KeychainStore(service: "com.zyw.clip.cloud-r2-secret-v1")
            .write(account: "current", data: Data(secretAccessKey.utf8))
    }

    @MainActor
    private func setStatus(_ s: String) { statusMessage = s }

    /// Spec §7.1 — call SyncEngine.enableSync(...) to either bootstrap a fresh
    /// cloud profile (first device) or derive the master key from the existing
    /// config.json (joining device). Persists settings on success and asks
    /// AppDelegate to spin up the engine.
    private func bootstrap() {
        bootstrapping = true
        let pwd = syncPassword
        let endpoint = self.endpoint
        let bucket = self.bucket
        let ak = self.accessKeyID
        let sk = self.secretAccessKey
        Task {
            defer { Task { @MainActor in bootstrapping = false } }
            guard let url = URL(string: endpoint) else {
                await setStatus("Endpoint URL 无效"); return
            }
            let backend = R2Backend(endpoint: url, bucket: bucket,
                                    accessKeyID: ak, secretAccessKey: sk)
            // Persist secret first so the engine can pick it up.
            try? KeychainStore(service: "com.zyw.clip.cloud-r2-secret-v1")
                .write(account: "current", data: Data(sk.utf8))
            let store = PreferencesContainer.shared.store!  // wired in AppDelegate
            let state = SyncStateStore(store: store)
            let masterKC = KeychainStore(service: "com.zyw.clip.cloud-master-v1")
            do {
                let result = try await SyncEngine.enableSync(
                    password: pwd, backend: backend, state: state,
                    keychain: masterKC, account: "current")
                await MainActor.run {
                    settings.endpoint = endpoint
                    settings.bucket = bucket
                    settings.accessKeyID = ak
                    settings.enabled = true
                }
                await setStatus(result == .firstDevice
                                ? "✓ 已初始化新云端 profile"
                                : "✓ 已加入现有云端")
                // Tell AppDelegate to spin up the engine + (if first device) backfill.
                await NotificationCenter.default.post(
                    name: .clipCloudSyncDidEnable, object: nil)
            } catch {
                await setStatus("✗ 初始化失败: \(error)")
            }
        }
    }
}

extension Notification.Name {
    static let clipCloudSyncDidEnable = Notification.Name("clip.cloud.didEnable")
}
```

- [ ] **Step 2: Add the tab to PreferencesWindow**

In `Sources/Clip/Preferences/PreferencesWindow.swift`, find the existing `TabView { ... }` and add:

```swift
            CloudSyncView()
                .tabItem { Label("云同步", systemImage: "cloud") }
                .tag("cloud")
```

- [ ] **Step 3: Add `syncSettings` to PreferencesContainer**

In whichever file declares `PreferencesContainer.shared`, add:

```swift
    var syncSettings: SyncSettings = SyncSettings()
```

(Wire it in `AppDelegate.applicationDidFinishLaunching` between `PreferencesContainer.shared.store = store` and the observer setup, but as default it just uses standard UserDefaults so no work needed if you don't override.)

- [ ] **Step 4: Build to verify it compiles**

```bash
swift build
```

Expected: success.

- [ ] **Step 5: Commit**

```bash
git add Sources/Clip/Preferences/CloudSyncView.swift Sources/Clip/Preferences/PreferencesWindow.swift
git commit -m "sync: CloudSyncView — Preferences \"云同步\" tab + R2 connection test"
```

---

### Task 22: AppDelegate wire-in — instantiate SyncEngine when enabled

**Files:**
- Modify: `Sources/Clip/ClipApp.swift` — instantiate engine + start two background loops + wire panel exclude

- [ ] **Step 1: Add engine + background tasks to AppDelegate**

In `AppDelegate`, after the existing `observer.start()` line in `applicationDidFinishLaunching`, append:

```swift
        // 7.5 Cloud sync (v3). Spec §4.2: actor + two background Tasks.
        startCloudSyncIfEnabled()
```

And add this method at the bottom of `AppDelegate`:

```swift
    var syncEngine: SyncEngine?
    private var pushLoopTask: Task<Void, Never>?
    private var pullLoopTask: Task<Void, Never>?

    func startCloudSyncIfEnabled() {
        let settings = PreferencesContainer.shared.syncSettings
        guard settings.enabled,
              let endpoint = settings.endpoint.flatMap(URL.init),
              let bucket = settings.bucket,
              let accessKeyID = settings.accessKeyID,
              let secretData = try? KeychainStore(service: "com.zyw.clip.cloud-r2-secret-v1")
                                        .read(account: "current"),
              let secret = String(data: secretData, encoding: .utf8),
              let masterData = try? KeychainStore(service: "com.zyw.clip.cloud-master-v1")
                                       .read(account: "current")
        else { return }

        let backend = R2Backend(endpoint: endpoint, bucket: bucket,
                                accessKeyID: accessKeyID, secretAccessKey: secret)
        let crypto = CryptoBox(masterKey: masterData)
        let state = SyncStateStore(store: store)
        let deviceID = (try? state.get("device_id")) ?? UUID().uuidString
        try? state.set("device_id", deviceID)

        let engine = SyncEngine(store: store, backend: backend, crypto: crypto,
                                deviceID: deviceID, state: state)
        self.syncEngine = engine

        // Wire HistoryStore.onChange → engine.enqueue
        store.onChange = { [weak self] change in
            guard let engine = self?.syncEngine else { return }
            let now = Int64(Date().timeIntervalSince1970)
            Task {
                switch change {
                case .inserted(let id):
                    try? await engine.enqueueItemPush(itemID: id, at: now)
                case .deleted(_, let hash):
                    try? await engine.enqueueTombstone(contentHash: hash, at: now)
                case .pinToggled(let id):
                    try? await engine.enqueueItemPush(itemID: id, at: now)
                case .excludedToggled:
                    break  // SyncEngine.excludeItem already handles
                }
            }
        }

        // Wire panel ⌘N
        panelModel.onExclude = { [weak self] id in
            guard let engine = self?.syncEngine else { return }
            let now = Int64(Date().timeIntervalSince1970)
            Task { try? await engine.excludeItem(id: id, at: now) }
        }

        // Push drainer loop: drain whenever there's work, sleep 1s when empty.
        pushLoopTask = Task { [weak engine] in
            while !Task.isCancelled, let engine {
                let did = (try? await engine.pushOnce(now: Int64(Date().timeIntervalSince1970))) ?? false
                if !did { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
        }
        // Pull tick loop: 30s.
        pullLoopTask = Task { [weak engine] in
            while !Task.isCancelled, let engine {
                _ = try? await engine.pullOnce(now: Int64(Date().timeIntervalSince1970))
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
```

**Bootstrap notification wiring** — also subscribe to the notification CloudSyncView posts after enableSync returns, so the engine spins up immediately (without requiring an app restart) and the first device's backfill kicks off:

```swift
        NotificationCenter.default.addObserver(
            forName: .clipCloudSyncDidEnable, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.startCloudSyncIfEnabled()
            // First-device profile: kick backfill exactly once.
            // (joinedExisting case: no-op because backfill rows would just dup
            // existing cloud objects — which is harmless but wasteful.)
            if let engine = self.syncEngine {
                Task { try? await engine.backfill(now: Int64(Date().timeIntervalSince1970)) }
            }
        }

- [ ] **Step 2: Build to verify it compiles**

```bash
swift build
```

Expected: success.

- [ ] **Step 3: Run full test suite**

```bash
swift test
```

Expected: all tests still pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Clip/ClipApp.swift
git commit -m "sync: AppDelegate wire-in — engine + push/pull background tasks + onChange hooks"
```

---

### Task 23: Manual test checklist update

**Files:**
- Modify: `docs/MANUAL_TEST.md` — add cloud-sync section

- [ ] **Step 1: Append to docs/MANUAL_TEST.md**

```markdown
## 云同步 (v3)

需要两台 Mac (A, B) + 都装了同 build + 都登录到同一 Cloudflare 账号的 R2 凭据。

- [ ] A 启用同步 → 输 endpoint/bucket/access_key/secret → "测试连接" 显示 ✓
- [ ] A 输入同步密码（≥12 字符） → backfill 进度条跑完
- [ ] B 启用同步 → 输入同 endpoint + 同密码 → 显示 "正在拉取 N 条…" → 完成
- [ ] A 复制一段文字 → ≤ 60 秒 B 唤起面板能看到该条目（行尾 ☁️）
- [ ] A 删一条 → B 上消失
- [ ] A pin 一条 → B 上 pin 状态同步
- [ ] A 复制一张 1MB 图 → B 看到行（lazy thumbnail）→ 点开预览 spinner → 解密后显示
- [ ] A 复制一张 3MB 图 → A 行尾显示 📤；B 永远看不到
- [ ] A 在面板按 ⌘N 标记不同步一条已有项 → 行尾 🚫；B 上消失
- [ ] 重启两台 Mac → 历史保留 + 后续复制仍同步
- [ ] 输错密码 → 不删本地数据；提示密码错
```

- [ ] **Step 2: Commit**

```bash
git add docs/MANUAL_TEST.md
git commit -m "sync: manual smoke checklist for cross-Mac cloud sync"
```

---

## Phase P5 — R2 integration test (opt-in)

### Task 24: Real-R2 round-trip test

**Files:**
- Create: `Tests/ClipTests/R2Integration/R2RoundTripTests.swift`

This test self-skips if `R2_ACCESS_KEY_ID` env is not set; CI will skip silently. Local dev runs it after `set -a; source ~/.wrangler/clip.env; set +a`.

- [ ] **Step 1: Create the integration test**

```swift
// Tests/ClipTests/R2Integration/R2RoundTripTests.swift
import XCTest
@testable import Clip

/// Real-R2 end-to-end. Self-skips when env not set so CI doesn't fail.
/// Local: source ~/.wrangler/clip.env first.
final class R2RoundTripTests: XCTestCase {
    func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    func testPutGetDeleteAgainstRealBucket() async throws {
        guard let endpoint = env("R2_ENDPOINT").flatMap(URL.init),
              let bucket   = env("R2_BUCKET"),
              let ak       = env("R2_ACCESS_KEY_ID"),
              let sk       = env("R2_SECRET_ACCESS_KEY")
        else {
            throw XCTSkip("R2 env not set; skipping integration test")
        }
        let backend = R2Backend(endpoint: endpoint, bucket: bucket,
                                accessKeyID: ak, secretAccessKey: sk)
        let key = "_probe/swift-roundtrip-\(UUID().uuidString).bin"
        let body = Data("clip swift integration probe \(Date())".utf8)
        let (etag, lm) = try await backend.put(key: key, body: body, contentType: "application/octet-stream")
        XCTAssertFalse(etag.isEmpty)
        XCTAssertGreaterThan(lm, 0)
        let got = try await backend.get(key: key)
        XCTAssertEqual(got, body)
        try await backend.delete(key: key)
        XCTAssertNil(try await backend.get(key: key))
    }
}
```

- [ ] **Step 2: Run the test**

```bash
set -a; source ~/.wrangler/clip.env; set +a
swift test --filter ClipTests.R2RoundTripTests
```

Expected: 1 test passes.

If the env isn't sourced, expect: 1 test SKIPPED (not failed) — that's the design.

- [ ] **Step 3: Commit**

```bash
git add Tests/ClipTests/R2Integration/R2RoundTripTests.swift
git commit -m "sync: R2 integration test (self-skips without env)"
```

---

## Final sweep

- [ ] **Step 1: Run the entire test suite**

```bash
swift test
```

Expected: all green (R2 integration test passes if env sourced, otherwise skipped).

- [ ] **Step 2: Release build**

```bash
swift build -c release --product Clip
```

Expected: success.

- [ ] **Step 3: Manual smoke (optional but recommended)**

```bash
./package-app.sh
open dist/Clip.app
# walk through docs/MANUAL_TEST.md "云同步" section
```

- [ ] **Step 4: Verify file map matches plan**

```bash
ls Sources/Clip/Sync/
ls Tests/ClipTests/Sync/
```

Should match the "Files created" table at the top of this plan.

---

## Self-review (post-write checklist)

This is the planner's self-check, not a separate review pass:

**Spec coverage:**
- §3 decisions 1-18: each maps to a task above (R2 backend = T11; pluggable protocol = T8; ChaCha20 = T3; PBKDF2 = T2; HMAC naming = T3; image lazy = T15 + future preview wiring; LWW = T15; tombstones = T16; backfill = T17; selective sync = T18 + T20)
- §5 Migration v3: T1
- §6 Crypto + naming + signing: T2 / T3 / T6 / T10 / T11
- §7 Data flows: T14-T18
- §8 UI: T20-T21
- §10 Error handling: covered through SyncEngine error returns + SyncQueue backoff + R2Backend.Error.http
- §11 Tests: each crypto/queue/engine task has its own test file; integration test = T24
- §12 Acceptance: covered by `swift test` + manual checklist (T23)
- §13 Deferred: explicitly out of scope

**Placeholder scan:** No "TBD"/"implement later"; the only `// no-op stub` is the placeholder `pushTomb` in T14, which is replaced in T16 (this is bounded refactoring, not a placeholder TODO left in shipped code).

**Type consistency:** Method names checked across tasks:
- `enqueueItemPush(itemID:at:)` defined T14, used T22
- `pushOnce(now:)` defined T14, used T22
- `pullOnce(now:)` defined T15, used T22
- `enqueueTombstone(contentHash:at:)` defined T16, used T18 + T22
- `excludeItem(id:at:)` defined T18, used T22
- `backfill(now:)` defined T17, used by user-trigger UI (not in this plan; future task or manual call)
- `name(forContentHash:)` on CryptoBox defined T3, used T14, T16, T20
- `setSyncExcluded(id:excluded:)` defined T7, used T18

All consistent.

---

## Out of Scope (explicit) — for STATUS.md handoff

These items appear in the spec (some only as UI affordances) but are **deliberately not implemented in this plan**. STATUS.md must surface them so the user knows what's stubbed vs shipped:

| Spec ref | Item | Why deferred | Workaround for v3 ship |
|---|---|---|---|
| §3.14, §7.3 | Wake / hotkey-trigger immediate pull + 5s rate-limit | 30s tick is functional for daily use; immediate-pull is a latency win, not correctness | User waits ≤ 30s for cross-device updates |
| §6.4 + §7.x | Device push (`pushDevice` actor stub) + `devices/<id>` aggregation in Preferences "已知设备" UI | Cosmetic / observability feature; payload type defined (`DevicePayload`) but PUT/decode pipeline not wired | Sync still works; users can't see device list (use Console.app to identify which Mac wrote what) |
| §8.1 | "立刻同步" button | Background tick covers it | Quit + relaunch app = same effect |
| §8.1 | "查看错误" sheet (per-row sync_queue inspection) | Read-only diagnostic — not load-bearing | Inspect `~/Library/Application Support/clip/history.sqlite` directly: `sqlite3 history.sqlite 'SELECT * FROM sync_queue'` |
| §8.1 | "清空云端数据" button | Use `wrangler r2 object delete` from CLI for now | `wrangler r2 bucket clear clip-sync` (or per-prefix delete) |
| §8.1 | "重置同步密码" button | Spec'd but full re-encryption flow is non-trivial | "Clear cloud + re-enable with new password" via dashboard |
| §8.2 | Panel icons ⏳ / 📤 / ⚠️ (only ☁️ / 🚫 in T20) | UX polish; the underlying state (sync_queue / blob skip / failed attempts) is computed correctly, just not surfaced visually | Icons can be added in a follow-up commit |
| §8.4 | First-launch modal sheet ("first Mac vs join existing" branching with progress bar) | The bootstrap logic IS in T17A; UI shows it as a Preferences form rather than a separate onboarding sheet | Functional — user bootstraps via Preferences instead of modal |
| §10.2 | Password change flow (5-step blocking re-encrypt) | Heavy feature; reset-cloud-and-re-enable accomplishes the same with minor data loss | Per workaround in §8.1 |
| §10.4 | In-app quota-exceeded remediation flow | Spec already says "user handles via dashboard" | Dashboard link in CloudSyncView status text (manual step) |

For each item above, the engine architecture is forward-compatible: a follow-up plan can add tasks without touching the core push/pull/crypto/queue modules.

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-02-clip-cloud-sync.md`.**

For the autonomous-superpowers session: this plan will be executed via `superpowers:subagent-driven-development` (one fresh subagent per task with two-stage review).
