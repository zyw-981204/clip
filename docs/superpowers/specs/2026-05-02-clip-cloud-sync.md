# clip — 云端剪贴板同步设计文档 (v2 架构)

**状态**：spec / pending review (architecture pivot)
**日期**：2026-05-02 (v2 重写)
**工作名**：cloud-sync (Migration v3)
**前序文档**：
- 原 v1 spec (R2-only): `docs/superpowers/specs/2026-05-02-clip-cloud-sync.v1.md.bak`
- 原 MVP spec: `docs/superpowers/specs/2026-04-29-clip-design.md`

## 0. 修订记录

### 0.1 与 v1 的关系（必读）

v1 把整个云端建模为 **R2 对象存储**：每条剪贴板 = 一个 `items/<hmac>.bin` 加密对象，删除 = `tomb/<hmac>.bin`，设备 = `devices/<id>.bin`。pull 阶段用 `backend.list("items/")` 全量列出再增量 GET。

v1 在 plan-review 流程结束后，user 提出尖锐的反例：**每 30s 全量 list 整个桶是浪费**——idle 时也要传几十 KB metadata，实际"什么都没变"。

更深的问题：**对象存储被硬当成数据库用**。每加一个 mutable 字段（pin / exclude / display_name）都要绕：要么重写整条 hmac 文件（pin 改一次 = 整个 item 重 PUT），要么开新 prefix（manifests / devices）。没有一阶的 `WHERE updated_at > ?` 概念。

### 0.2 v2 架构

把云端拆成两层：

- **Cloudflare D1（SQLite at edge）** — 存"轻数据"：每条剪贴板的 metadata + 内容**密文**。提供 SQL `WHERE updated_at > ?` 增量 query，是 pull 的真源。
- **Cloudflare R2** — 只存"重数据"：图片 / 文件原字节的**密文**。R2 不再被 list / 不再承担"哪条存在"的语义，纯字节 key-value 仓库。

加密规格不变（ChaCha20-Poly1305 + PBKDF2 + HKDF + HMAC 命名），E2E 担保不变（云端任何一层都拿不到明文）。改的是**云端数据的组织**和**pull 算法**。

### 0.3 与原 MVP spec 的关系

原 MVP spec line 31 `iCloud / 跨机同步（永远不做）` 已被 v1 推翻；v2 继续保留同步功能。MVP spec 其余部分（数据模型 v1/v2、隐私过滤、面板交互、性能预算）继续有效，本文档只描述云同步增量到 v3。

## 1. 概述

为 clip 增加**端到端加密的跨 Mac 剪贴板历史同步**。后端用 **Cloudflare D1 + R2**，本地 SQLite 仍是首要源；同步引擎把本地变更串行化推到云端 D1（图片字节走 R2），并轮询 D1 的 `updated_at` 增量游标拉对端变更。剪贴板内容**永远以密文形式离开本机**——D1 的 `ciphertext` 列、R2 的 `blobs/<hmac>.bin` 对象都是 ChaCha20-Poly1305 sealed box，cloud-side 服务（Cloudflare 自己 / 任何拿到 token 的攻击者）只能看到 metadata 索引列（id / hmac / 时间戳），无法解出内容。

**典型用法**：用户在 Mac A 复制一段代码 → 几秒内在 Mac B 唤起面板看到该条目 → Enter 粘贴。

## 2. 目标 / 非目标

### 2.1 目标

- 跨 2-3 台 Mac 同步剪贴板**全部历史**（文字 + 图片）
- **强制 E2E 加密**：用户设同步密码，云端 D1 行的内容字段、R2 blob 都是密文；密码丢 = 数据不可恢复（明示）
- 图片 ≤ 2MB 上传；> 2MB 本地存但跳过云
- 启用同步时**全量 backfill** 一次本地既有数据
- **选择性同步**：每条可标记"不上云"，已上传的会更新成 `deleted=1`
- D1 schema 在首次启用同步时由客户端自动创建（idempotent CREATE TABLE IF NOT EXISTS）
- 把 capture 之外的 sync / crypto / storage 抽到 `Sources/Clip/Sync/` 单目录，**为后续 iOS 客户端复用准备**（不在本期交付 iOS app）
- 沿用现有 LSUIElement / .accessory 架构、SQLite + GRDB、Migrations 链

### 2.2 非目标 / 留给以后

- iOS / iPadOS 客户端 app（架构准备好，本期不交付）
- 自建 PostgreSQL / Supabase / 其它 DB backend（架构 pluggable，本期只实现 D1）
- 实时推送（无 APNS entitlement；用 30s 轮询 + 唤醒 / 激活时 immediate pull）
- 选择性同步的 app-id 维度规则（先用每条手动；现有 Blacklist 在 capture 层挡）
- "仅 WiFi" / 流量控制 / 带宽限速
- 同步 Preferences / 黑名单 / 热键设置
- 多 cloud profile（每台 Mac 一份配置）
- E2E **密码恢复** 机制
- 密码轮换的**在线 / 增量 / 后台优化**（v3 含基础阻塞式重传，§10.2）
- R2 blob 的 lifecycle GC（被 tombstone 的 row 对应的 blob 不会自动删，留 v3.1）

## 3. 设计决策汇总

| # | 决策点 | 选择 | 理由 |
|---|---|---|---|
| 1 | 云端"哪条存在"的真源 | **Cloudflare D1**（SQLite at edge，REST API 访问） | 原生支持 `WHERE updated_at > ?` 增量游标；pull 在没变化时 0 流量；schema 演进直接 ALTER TABLE。**vs R2 全 list**：节流量 100×+ |
| 2 | 云端 blob 字节存放 | **Cloudflare R2** | 只为图片用；2MB 单对象远低于 R2 5GB PUT 上限；同账号同 token 即可；DB 行通过 `blob_key` 引用 |
| 3 | DB 客户端 | 直接调 D1 REST API（**不**部署 Workers 中间层） | 个人工具不值得部署 Workers；REST `POST /accounts/{id}/d1/database/{db}/query` + Bearer token 一句话；后续要中间层（速率限制 / IP allowlist）再加 |
| 4 | 后端抽象 | **`CloudSyncDataSource`** (D1) + **`CloudSyncBlobStore`** (R2) 两个独立 protocol | 干净分层：行操作 vs 对象操作；测试时各自 mock；以后 D1 换 Supabase / R2 换 S3 各自独立替换 |
| 5 | 加密算法 | **ChaCha20-Poly1305**（CryptoKit `ChaChaPoly`，AEAD） | 同 v1 |
| 6 | 密钥派生 | **PBKDF2-HMAC-SHA256**, 200k rounds, 32B 输出 (CommonCrypto) | 同 v1 |
| 7 | 密钥分层 | 主密钥 → HKDF 派生 `kEncrypt`（加密 row）+ `kName`（HMAC 命名 R2 blob + 跨设备 dedup hash） | 同 v1 |
| 8 | DB row id | **客户端生成 UUID**，主键 | D1 服务端不能依赖 autoincrement（多设备并发 INSERT 会碰撞）；UUIDv4 全球唯一 |
| 9 | 跨设备去重 | 每行带 `hmac` 列（`HMAC(content_hash, kName)`，明文），有索引；客户端 push 前查"本地或云 hmac 已存在?" | 不能用 D1 UNIQUE 约束（hmac 是密文派生的，但明文 hmac 暴露存在等价性这个轻量 metadata；接受这种泄漏，因为它不暴露内容） |
| 10 | 删除语义 | D1 行 `deleted=1` flag + `updated_at` bump（**软删除**）；本地 `tombstones` 表保留防 capture 时复活 | 软删除在 SQL 模型里更自然，pull 看到 deleted=1 就本地删；hard-delete 会让 cursor 错过 |
| 11 | 冲突解决 | LWW by D1 server-side **`updated_at`**（D1 在 UPDATE 时由我们主动写入 `unixepoch()`，类似 trigger） | 同 row 在 A / B 上 pin 不一致 → 后写者赢；payload `created_at` 不参与 LWW（只用于 tomb-vs-fresh-item 复活判定） |
| 12 | Pin / Exclude | 内嵌在 row 的密文 payload；toggle = D1 UPDATE；`updated_at` 自动 bump | DB 模型天然支持 partial update |
| 13 | 图片存储 | 元数据 + 缩略图（≤ 5KB，base64）随 row ciphertext；原图字节 = R2 单独对象，DB row 持 `blob_key`；拉取端 lazy fetch | 拉端默认不拉原图；点开预览/粘贴时按 `blob_key` 去 R2 GET + 解密 |
| 14 | 大图阈值 | > 2MB 不上传（本地仍存）；DB 行不写入；UI 显示 📤 | 同 v1 |
| 15 | Tombstone vs item 同 hash | tomb 时间 ≥ item.created_at → tomb wins（防止陈旧 INSERT 复活已删条目）；item 较新 → item wins（用户在 tomb 后又复制了相同内容） | 同 v1 §10.3 |
| 16 | 拉取频率 | 30s 轮询 + app launch / wake / hotkey 触发的 immediate pull（5s 内合并） | 同 v1，但每次 pull = 一条 SQL `SELECT WHERE updated_at > cursor LIMIT 100`，idle 时返回 0 行 |
| 17 | 设备 metadata | D1 单独 `devices` 表（每设备一行；UPDATE on launch / display_name 改） | DB 模型下 trivial |
| 18 | KDF 配置存放 | D1 `config` 表（明文 KV），首次启用时 INSERT salt + iters | 替代 v1 的 `config.json` R2 对象；同样 idempotent；任意设备首次启用都能拿到 |
| 19 | iOS 客户端 | 不交付，架构允许 | D1 REST API 任何 platform 都可调；R2 同；`ClipKit` extraction 跟 v1 计划一致 |
| 20 | 密码丢失 | 不可恢复，UI 强提示；提供"清空云端 + 重设"流程 | 同 v1 |

## 4. 架构

### 4.1 进程 + 模块分工

仍是单进程 LSUIElement，新增 **`SyncEngine` actor** 串行化所有云端动作。

```
AppDelegate
  ├─ HistoryStore (existing) ← onChange hook → engine.enqueuePush
  ├─ PasteboardObserver (existing)
  └─ SyncEngine (new actor)
        ├─ pushTask (Task): drain SyncQueue → D1Backend.upsertRow / R2BlobBackend.put
        └─ pullTask (Task): 30s timer → D1Backend.queryChangesSince(cursor) → upsert local + lazy blob refs
```

| 模块 | 职责 | 路径 |
|---|---|---|
| `CloudSyncDataSource`（protocol） | D1 行抽象：upsert / queryChanges / setDeleted | `Sources/Clip/Sync/CloudSyncDataSource.swift` |
| `D1Backend` | D1 REST API 实现 (Cloudflare API token) | `Sources/Clip/Sync/D1Backend.swift` |
| `LocalSqliteDataSource` | 内存 SQLite 模拟 D1，仅给单测用 | `Sources/Clip/Sync/LocalSqliteDataSource.swift` |
| `CloudSyncBlobStore`（protocol） | R2 blob 抽象：put / get | `Sources/Clip/Sync/CloudSyncBlobStore.swift` |
| `R2BlobBackend` | URLSession + S3v4 实现，**只 put/get/delete blobs/<key>**（不 list） | `Sources/Clip/Sync/R2BlobBackend.swift` |
| `LocalDirBlobStore` | 文件系统模拟 R2，单测用 | `Sources/Clip/Sync/LocalDirBlobStore.swift` |
| `S3SignerV4` | AWS Sig V4 签名实现 | `Sources/Clip/Sync/S3SignerV4.swift` |
| `CryptoBox` | ChaChaPoly seal/open + HMAC 命名 | `Sources/Clip/Sync/CryptoBox.swift` |
| `KeyDerivation` | PBKDF2 wrapper | `Sources/Clip/Sync/KeyDerivation.swift` |
| `KeychainStore` | 主密钥 / token 落 Keychain | `Sources/Clip/Sync/KeychainStore.swift` |
| `SyncEngine` | 推送 + 拉取协调 | `Sources/Clip/Sync/SyncEngine.swift` |
| `SyncQueue` | DB-backed retry buffer | `Sources/Clip/Sync/SyncQueue.swift` |
| `SyncSchema` | 行 ciphertext payload Codable + D1 schema 字符串 | `Sources/Clip/Sync/SyncSchema.swift` |
| `SyncSettings` | UserDefaults wrapper：endpoints / token IDs | `Sources/Clip/Sync/SyncSettings.swift` |
| `SyncStateStore` | 本地 sync_state 表 KV wrapper | `Sources/Clip/Sync/SyncStateStore.swift` |
| `CloudSyncView`（SwiftUI） | Preferences 新 tab "云同步" | `Sources/Clip/Preferences/CloudSyncView.swift` |
| `Migrations.v3` | 本地 schema 迁移 | `Sources/Clip/Storage/Migrations.swift` |

### 4.2 `CloudSyncDataSource` 协议契约

```swift
struct CloudRow: Sendable, Equatable {
    var id: String              // UUID, plaintext primary key
    var hmac: String            // HMAC(content_hash, kName), plaintext, indexed
    var ciphertext: Data        // ChaChaPoly sealed JSON of {content, metadata}
    var kind: String            // "text" | "image"
    var blobKey: String?        // R2 object key for image; nil for text
    var byteSize: Int           // plaintext size, plaintext for UI hint / debug
    var deviceID: String        // last writer
    var createdAt: Int64
    var updatedAt: Int64        // server-side bumped on UPDATE/INSERT
    var deleted: Bool
}

struct DeviceRow: Sendable, Equatable {
    var deviceID: String
    var ciphertext: Data        // sealed JSON of {display_name, model}
    var lastSeenAt: Int64
}

struct ConfigEntry: Sendable {
    var key: String
    var value: String
}

protocol CloudSyncDataSource: Sendable {
    /// Idempotent schema bootstrap (CREATE TABLE IF NOT EXISTS). Called once
    /// per cold start of an enabled SyncEngine.
    func ensureSchema() async throws

    // Clips
    func upsertClip(_ row: CloudRow) async throws -> Int64    // returns server updated_at
    func queryClipsChangedSince(cursor: Int64, limit: Int) async throws -> [CloudRow]
    func setClipDeleted(id: String, at: Int64) async throws -> Int64

    // Devices
    func upsertDevice(_ row: DeviceRow) async throws
    func listDevices() async throws -> [DeviceRow]

    // Config (KDF salt etc.)
    func getConfig(key: String) async throws -> String?
    func setConfig(key: String, value: String) async throws
}

protocol CloudSyncBlobStore: Sendable {
    func putBlob(key: String, body: Data) async throws
    func getBlob(key: String) async throws -> Data?    // nil = 404
    func deleteBlob(key: String) async throws           // idempotent
}
```

**没有 `list` / `head`**：DataSource 不需要枚举（query 是增量 cursor）；BlobStore 也不枚举（拉取由 row 的 `blob_key` 直接定位）。

### 4.3 D1 REST API 调用约定

D1 SQL 查询走 `POST https://api.cloudflare.com/client/v4/accounts/{account_id}/d1/database/{database_id}/query`，body 形如：

```json
{ "sql": "SELECT * FROM clips WHERE updated_at > ?1 ORDER BY updated_at LIMIT ?2",
  "params": [12345, 100] }
```

`Authorization: Bearer <api_token>`。Response：

```json
{ "result": [{
    "results": [{ "id": "...", "hmac": "...", "ciphertext": "<base64>",
                  "kind": "text", ... }],
    "success": true, "meta": { "duration": 0.5, "rows_read": 1, "rows_written": 0 }
}] }
```

`ciphertext` 是 BLOB → D1 REST 把它编码成 base64 字符串。客户端解码后再 ChaChaPoly.open。

D1 token 权限：**Account → D1 → Edit**（用同一个 R2 token 加这条权限即可，不需要新 token）。

### 4.4 R2 用法（只剩 blob）

R2 用法窄化到三个方法：`putBlob` / `getBlob` / `deleteBlob`，全部 `blobs/<hmac>.bin` 前缀。

- `<hmac>` = `HMAC(blob_sha256, kName)`，跨设备同图片一致
- BlobStore **不 list**，BlobStore **不存 metadata**
- 上传时不写 ETag 头（D1 row 是真源；R2 ETag 不参与判定）

`R2BlobBackend` 复用 `S3SignerV4`（v1 写好的同一份代码），但 backend 类只用其中 PUT/GET/DELETE 三个方法（不需要 list / XML 解析）。

## 5. 数据模型

### 5.1 本地 SQLite — Migration v3

```sql
-- items: 加 6 列
ALTER TABLE items ADD COLUMN cloud_id TEXT;                        -- D1 row UUID; NULL = 未同步
ALTER TABLE items ADD COLUMN cloud_updated_at INTEGER;             -- D1 server-side updated_at; LWW + skip 用
ALTER TABLE items ADD COLUMN cloud_synced_at INTEGER;              -- 本机最近一次成功同步该行的时间
ALTER TABLE items ADD COLUMN cloud_blob_key TEXT;                  -- R2 object key (image kind only)
ALTER TABLE items ADD COLUMN sync_excluded INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN device_id TEXT;                       -- 最近写者 device UUID

CREATE UNIQUE INDEX idx_items_cloud_id ON items(cloud_id) WHERE cloud_id IS NOT NULL;

-- 本地 tombstones：防止 capture 把已删除条目重新入库 + 重新推送
CREATE TABLE tombstones (
  content_hash       TEXT PRIMARY KEY,
  cloud_id           TEXT NOT NULL,
  tombstoned_at      INTEGER NOT NULL,
  cloud_updated_at   INTEGER NOT NULL
);

-- sync_queue: 本地 retry 缓冲
CREATE TABLE sync_queue (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  op          TEXT NOT NULL,                  -- 'put_clip' | 'put_blob' | 'put_tomb' | 'put_device'
  target_key  TEXT NOT NULL,                  -- items.id / clip_blobs.id / tombstones.content_hash / device_id
  attempts    INTEGER NOT NULL DEFAULT 0,
  next_try_at INTEGER NOT NULL,
  last_error  TEXT,
  enqueued_at INTEGER NOT NULL
);
CREATE INDEX idx_sync_queue_next ON sync_queue(next_try_at);

-- sync_state: KV
CREATE TABLE sync_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- known keys:
--   device_id              UUID
--   cloud_pull_cursor      最大已见 D1 updated_at (unix sec)
--   cloud_pull_device_cursor 同上 for devices 表
--   kdf_salt_b64           base64(salt) - 16 bytes
--   kdf_iters              integer (200000)
--   kdf_version            integer (1)
```

clip_blobs 不需要新列（lazy 标记复用现有 sha256 列的 `lazy:` 前缀约定，同 v1）。

**与 v1 的 schema 差异**：v1 的 `cloud_etag` / `cloud_lastmodified` / `cloud_name` 全部移除，由 `cloud_id` + `cloud_updated_at` 替代（DB 模型不需要 ETag）。

### 5.2 云端 D1 — schema (clip_v3 db)

```sql
CREATE TABLE IF NOT EXISTS clips (
  id           TEXT PRIMARY KEY,           -- UUID v4，客户端生成
  hmac         TEXT NOT NULL,              -- HMAC(content_hash, kName), 用于跨设备 dedup 查询
  ciphertext   BLOB NOT NULL,              -- ChaChaPoly sealed JSON (RowPayload)
  kind         TEXT NOT NULL,              -- 'text' | 'image'
  blob_key     TEXT,                       -- 'blobs/<hmac>.bin' or NULL
  byte_size    INTEGER NOT NULL,           -- plaintext content size (UI hint)
  device_id    TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL,           -- 必须 monotonic; pull cursor
  deleted      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_clips_updated_at ON clips(updated_at);
CREATE INDEX IF NOT EXISTS idx_clips_hmac ON clips(hmac);

CREATE TABLE IF NOT EXISTS devices (
  device_id     TEXT PRIMARY KEY,
  ciphertext    BLOB NOT NULL,             -- sealed JSON {display_name, model, first_seen_at}
  last_seen_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_devices_last_seen ON devices(last_seen_at);

CREATE TABLE IF NOT EXISTS config (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

`ensureSchema()` 在 SyncEngine 每次启动时跑一遍。`CREATE TABLE IF NOT EXISTS` 是幂等的；旧 D1 数据库不会被破坏。

### 5.3 RowPayload (D1 ciphertext 解密后)

```json
{
  "v": 1,
  "content": "...",                        // text 才有；image 为空
  "thumb_b64": "<base64 PNG ≤5KB>",        // image 才有 (optional)
  "mime_type": "image/png",                // image 才有
  "blob_size": 12345,                      // image 才有；R2 blob 字节数
  "truncated": false,
  "source_bundle_id": "com.apple.Safari",
  "source_app_name": "Safari",
  "pinned": false,
  "content_hash": "<hex sha256>"           // 重复明文 hmac 的源；解密后用于本地 dedup
}
```

### 5.4 DevicePayload (devices.ciphertext 解密后)

```json
{ "v": 1, "display_name": "Mac-Mini-7", "model": "Mac15,12", "first_seen_at": 1735000000 }
```

## 6. 加密 / 命名规范

加密层与 v1 完全一致；**变化点只是"加密的范围"**：v1 加密一个完整 item（含所有字段），v2 加密一个**RowPayload**（不含主键 / hmac / 时间戳等需要服务端索引的字段）。

### 6.1 KDF（同 v1）

```
salt        := 16 random bytes (per cloud profile)
master_key  := PBKDF2-HMAC-SHA256(password, salt, iters=200_000, dkLen=32)
k_encrypt   := HKDF-SHA256(master_key, info="clip.encrypt.v1", L=32)
k_name      := HKDF-SHA256(master_key, info="clip.name.v1",    L=32)
```

`master_key` 派生后存 macOS Keychain (`kSecAttrSynchronizable=false`)，密码不落盘。

### 6.2 行级加密（v2 新）

```
plaintext      := JSON.encode(RowPayload)
sealed         := ChaChaPoly.seal(plaintext, key=k_encrypt)
                  → nonce(12) || ciphertext || tag(16)
clips.ciphertext := sealed
```

D1 BLOB 列接受任意字节；REST API 在请求 / 响应 JSON 里 base64 encode 这个 BLOB。

### 6.3 跨设备命名 / 去重

```
content_hash  := SHA256(text trim) 或 SHA256(image bytes)（沿用 ClipItem.contentHash）
hmac          := HMAC-SHA256(k_name, content_hash) → 64 hex chars
clips.hmac    := hmac                  // 明文，indexed
blob_key      := "blobs/" + hmac + ".bin"
```

push 前 SyncEngine 查 D1 `SELECT id FROM clips WHERE hmac = ?`；命中 → 改成 UPDATE 而非 INSERT（避免重复 row）。**这是去重的唯一关口**。

### 6.4 图片 blob

R2 对象 = 同样的 sealed box (nonce || ciphertext || tag)。`getBlob(key)` 回来的 bytes 直接 `ChaChaPoly.open(...)`。

### 6.5 安全 / 威胁模型

| 攻击者 | 能看到 | 不能看到 |
|---|---|---|
| Cloudflare 自己 / 拿到 D1 token 的人 | id (UUID), hmac (HMAC，不可反向到原文), kind, blob_key, byte_size, device_id, created_at, updated_at, deleted | 内容、缩略图、source app、pinned 状态 |
| 拿到 R2 token 的人 | 哪些 hmac 有 blob、blob 字节数 | blob 解密后的图片 |
| 同时拿到 D1 + R2 token | 两表合起来 | 同上，仍无法解密 |
| 拿到本机 master_key（攻破 Keychain）| 一切 | — |

`hmac` 列的暴露含义：攻击者能看出"两条 row 内容是否相同"（同 hmac 等价于同 content_hash）。这是接受的轻量泄漏，换来跨设备 dedup。如果不能接受，需要在 v3.1 把 hmac 列也改成 per-row 随机 nonce + 客户端 dedup（牺牲服务端去重查询效率）。

## 7. 数据流

### 7.1 启用同步（首次配置）

```
用户在 Preferences > 云同步 → 输入 R2 endpoint / bucket / access key / secret +
                              D1 account ID / database ID / API token
  ↓ 按 "测试连接"
  ↓ ensureSchema() 在 D1 上跑（CREATE TABLE IF NOT EXISTS …）
  ↓ getConfig("kdf_salt_b64") + getConfig("kdf_iters")
     ├─ 缺  → 新 cloud profile：生成 16B salt + setConfig + 提示输密码 + 派生 master_key
     └─ 有  → 加入现有 profile：拉 KDF 参数 + 提示输密码 + 派生
  ↓ master_key → Keychain
  ↓ 是 firstDevice → backfill 本地全部 items 入 sync_queue
  ↓ 启动 pushTask + pullTask
```

### 7.2 推送（本地→云）

```
触发：HistoryStore.onChange (.inserted / .deleted / .pinToggled)
  ↓ engine.enqueueClipPush(itemID, at: now)
  ↓ SyncQueue.append(op='put_clip', target_key=itemID)
  ↓
pushTask 循环（actor 内串行）:
  loop {
    row = queue.dequeueDueAt(now)
    if none → sleep until next_try_at OR wakeup
    item = store.itemByID(row.target_key)

    // 1. 查 D1 有没有同 hmac 的现有 row（去重）
    hmac = crypto.name(forContentHash: item.contentHash)
    existing = await dataSource.queryClipByHmac(hmac)

    // 2. 准备 ciphertext + 决定 cloud_id
    rowPayload = build(item)
    sealed = crypto.seal(JSON.encode(rowPayload))
    cloudID = item.cloudID ?? existing?.id ?? UUID()

    // 3. (image 才走) 先上 blob
    if item.kind == .image && item.cloudBlobKey == nil:
      blobBytes = store.blob(id: item.blobID!)
      sealedBlob = crypto.seal(blobBytes)
      blobKey = "blobs/" + crypto.name(forContentHash: blobInfo.sha) + ".bin"
      try await blobStore.putBlob(key: blobKey, body: sealedBlob)
      store.markBlobSynced(id: blobID, at: now)
      item.cloudBlobKey = blobKey

    // 4. UPSERT row
    serverUpdatedAt = try await dataSource.upsertClip(CloudRow(
        id: cloudID, hmac: hmac, ciphertext: sealed,
        kind: item.kind.rawValue, blobKey: item.cloudBlobKey,
        byteSize: item.byteSize, deviceID: deviceID,
        createdAt: item.createdAt, updatedAt: 0,    // server overrides
        deleted: false))
    store.markClipSynced(id: item.id, cloudID: cloudID,
                         updatedAt: serverUpdatedAt, at: now)
    queue.delete(id: row.id)
  } catch {
    queue.recordFailure(id: row.id, attempts: row.attempts+1, at: now)
  }
```

D1 INSERT/UPDATE SQL 模板（`upsertClip` 实现细节）：

```sql
INSERT INTO clips (id, hmac, ciphertext, kind, blob_key, byte_size,
                   device_id, created_at, updated_at, deleted)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, unixepoch(), 0)
ON CONFLICT(id) DO UPDATE SET
  hmac = excluded.hmac, ciphertext = excluded.ciphertext,
  kind = excluded.kind, blob_key = excluded.blob_key,
  byte_size = excluded.byte_size, device_id = excluded.device_id,
  updated_at = unixepoch(), deleted = 0
RETURNING updated_at;
```

`unixepoch()` 是 SQLite 内置函数，由 D1 服务端在执行时求值——这是 LWW 单调时钟的源。

### 7.3 拉取（云→本地）

```
触发：30s 定时器；app launch；NSWorkspace.didWake；hotkey 唤起 panel
       后三种合并到 5s 内不重复触发

pullTask:
  cursor = sync_state.get("cloud_pull_cursor") ?? 0
  loop {
    rows = try await dataSource.queryClipsChangedSince(cursor: cursor, limit: 100)
    if rows.isEmpty: break
    for row in rows:
      // 0. ETag-equivalent skip
      if local = store.itemByCloudID(row.id), local.cloudUpdatedAt >= row.updatedAt:
        continue

      // 1. 解密
      plain = try crypto.open(row.ciphertext)
      payload = try JSON.decode(RowPayload, plain)

      // 2. 处理 deleted
      if row.deleted:
        store.upsertTombstone(contentHash: payload.contentHash, cloudID: row.id,
                              tombstonedAt: row.updatedAt, cloudUpdatedAt: row.updatedAt)
        store.deleteItemsByContentHashOlderThan(payload.contentHash, row.updatedAt)
        continue

      // 3. 资源化复活判定 (v1 §10.3 同)
      if tomb = store.tombstoneAt(contentHash: payload.contentHash),
         tomb >= row.createdAt:
        continue   // tomb 较新；丢弃这条

      // 4. UPSERT 本地
      store.upsertFromCloud(row, payload)
        // image kind: 本地 clip_blobs 插占位行 (lazy)，bytes=NULL
        //             items.cloud_blob_key = row.blob_key
    cursor = max(rows.map { $0.updatedAt })
  }
  sync_state.set("cloud_pull_cursor", String(cursor))

  // devices 同样模式（独立 cursor）
  deviceCursor = sync_state.get("cloud_pull_device_cursor") ?? 0
  devices = try await dataSource.listDevices()
    .filter { $0.lastSeenAt > deviceCursor }
  for d in devices: cacheDevice(decrypt(d.ciphertext))
  sync_state.set("cloud_pull_device_cursor", String(devices.map { $0.lastSeenAt }.max() ?? deviceCursor))
```

**带宽**：idle (无变化) → 单次 pull = 一次 SQL roundtrip + JSON `{"results":[]}`，几百字节。500 条历史 / 30s tick / 全 idle ≈ 60KB/小时。**vs v1 的 ~9MB/小时（150× 节流）**。

### 7.4 Lazy blob fetch

同 v1：本地 `clip_blobs` 行 sha256 = `lazy:<hmac>` + bytes empty。`HistoryStore.blob(id)` 仍是 sync 接口；调用者（PreviewWindow / PasteInjector）的 async 上下文里，发现 bytes 空时 await `engine.fetchBlob(blobID)`：

```swift
func fetchBlob(blobID: Int64) async throws -> Data {
  guard let info = try store.lazyBlobHmac(id: blobID) else { ... }
  let key = "blobs/" + info.hmac + ".bin"
  guard let sealed = try await blobStore.getBlob(key: key) else { ... }
  let bytes = try crypto.open(sealed)
  try store.fillBlob(id: blobID, bytes: bytes, sha256: ClipItem.contentHash(of: bytes), at: now)
  return bytes
}
```

### 7.5 选择性同步

UI 在 panel 行 `⌘N` toggle "不上云"：
- 已 synced → store.setSyncExcluded(true) + dataSource.setClipDeleted(cloud_id) + queue.deleteAllForItem
- 未 synced → store.setSyncExcluded(true) + queue.deleteAllForItem（无云端动作）

再次 `⌘N` 取消：UPDATE sync_excluded=0 + 重新 enqueue put_clip。云端走正常 INSERT 路径，会 `ON CONFLICT(id) DO UPDATE`：但因为 cloud_id 已存在且 deleted=1 → UPDATE 把它复活（`deleted = 0`）。**这是设计意图**：选择性同步是可逆的。

### 7.6 Backfill

```sql
-- 启用同步独立事务，新设备首次 enable 时跑：
INSERT INTO sync_queue (op, target_key, attempts, next_try_at, enqueued_at)
SELECT 'put_clip', CAST(items.id AS TEXT), 0, strftime('%s','now'), strftime('%s','now')
FROM items
LEFT JOIN clip_blobs ON items.blob_id = clip_blobs.id
WHERE items.sync_excluded = 0
  AND items.cloud_id IS NULL                    -- 没同步过的
  AND (items.kind = 'text' OR clip_blobs.byte_size <= 2097152)
ORDER BY items.created_at DESC;
```

新加入设备 (joinedExisting) 不需要 backfill **本地**——它的本地是空的，pull 会把 D1 全部数据拉下来。

### 7.7 大图（> 2MB）

A 端 enqueue 时检查 `blob_size > 2MB` → 不入 queue（既不 put_clip 也不 put_blob）→ row 在 D1 永远不存在 → B 端永远看不到这条。同 v1。

## 8. UI / UX

### 8.1 Preferences "云同步" tab

```
[ ] 启用云同步                                    (开关)

— R2（图片字节）—
R2 endpoint:    https://<account>.r2.cloudflarestorage.com
Bucket:         clip-sync
Access Key ID:  <…>
Secret:         ●●●●●●●●

— D1（条目元数据）—
Account ID:     <已从 endpoint 解析；只读>
Database ID:    <UUID>                            (也可点 [查询] 自动列出可用 DB)
API Token:      ●●●●●●●●                          (Account → D1:Edit + R2:Edit)
                [测试连接]                        (动作: D1.queryConfig + R2.head)

— 同步密码 —
●●●●●●●●●●●●                                       (≥12 chars)
[初始化 / 加入云端]                                ⚠️ 密码丢失 = 数据丢失

— 状态 —
云端: 1284 条 / 392 MB
本地未同步: 3 条 (重试中)                          [立刻同步] [查看错误]
上次拉取: 12 秒前
Backfill: 1284 / 1284 (完成)

— 设备 —
本机:   Mac-Mini-7 (devID 前 8: a1b2c3d4)
已知:   Mac-Studio-A (12 小时前)、Mac-Air-B (3 天前)

— 危险区 —
[清空云端数据 + 撤销同步...]
[重置同步密码...]
```

简化版本（v3 实际交付）：先做配置 + 测试连接 + 密码 + 状态 + 错误显示；devices 列表 / 危险区按钮文字明示 "v3.1"。

### 8.2 Panel 行尾同步状态指示

| 图标 | 含义 |
|---|---|
| ☁️ | 已同步 |
| ⏳ | 队列里等待 |
| 🚫 | sync_excluded=1 |
| 📤 | > 2MB 图片，技术原因不传 |
| ⚠️ | attempts > 3 |

v3 必须 ☁️ + 🚫；其它图标可后置（同 v1 的妥协）。

### 8.3 快捷键

`⌘N` 同 v1：toggle 选中行 sync_excluded。

## 9. 性能预算

| 维度 | 预算 |
|---|---|
| Pull idle CPU | < 0.05%（30s tick + 单条 SQL；返回 0 行成本极低） |
| Pull idle 带宽 | < 1 KB/tick (`{"results":[]}`)；600 KB/小时 |
| Push 一条 text | < 250ms (encrypt 1ms + D1 UPSERT 100-200ms RTT) |
| Push 一条 2MB image | < 1.5s (R2 PUT ~1s + D1 UPSERT) |
| Pull 100 条 text 一页 | < 600ms (queryChangesSince + 100 × decrypt) |
| Backfill 1000 条 text | < 4 min (串行 D1 UPSERT，每个 200ms RTT) |
| 多余磁盘占用（拉端 lazy 图） | < 1KB / 条 |
| 错误退避封顶 | 15 分钟 |

D1 query latency 对中国大陆用户预估 100-300ms RTT (CF Anycast)。

## 10. 错误处理 & 边界

### 10.1 网络

| 场景 | 处理 |
|---|---|
| 离线 | enqueue 不阻塞；status bar "离线"；联网后 NWPathMonitor 唤醒 |
| D1 5xx | backoff 重试 |
| D1 401/403 | token 失效；UI 提示去 Preferences；push 暂停直到用户操作（v3.1 实现，v3 走 generic backoff，sync_queue.last_error 可见）|
| D1 429 throttle | backoff + 随机 jitter |
| D1 schema drift（未来加列） | upsertClip 用显式列名，不依赖 SELECT *；新列默认 NULL；旧客户端忽略 |
| R2 5xx / 401 | 同 D1 |
| GET 404 (blob 缺失) | log warning + 给用户一个"图片已删除"占位 |

### 10.2 加密

| 场景 | 处理 |
|---|---|
| 解密失败 | log + 跳过；不删本地；UI 提示密码错（首次 pull 失败时全弹） |
| 用户改密码 | v3 阻塞式：拉所有 D1 row → 旧 key 解 → 新 key seal → upsertClip 全部覆盖；R2 blob 同样按需 redown + reup；进度条；中途失败保留两个 master_key 可手动重启 |
| 密码丢失 | 引导"清空 D1 表 + 清空 R2 桶 + 重设" |
| 密码强度 | 输入框拒绝 < 12 字符 |

### 10.3 数据一致性

| 场景 | 处理 |
|---|---|
| 同 hash 两台并发 push | 第一台 INSERT 成功；第二台 push 前 hmac 查询命中第一台的 cloud_id → 改成 UPDATE，覆盖一次（payload 几乎一样） |
| pin 状态两台冲突 | LWW by D1 server-side updated_at；后写者赢 |
| 同 hash 删了又 capture | 本地 tombstones 防止 capture 立刻入库；用户必须显式 `⌘N` 取消 exclude 或手动从 history 里复活（v3 实现 §7.5 路径）|
| 设备时钟漂移 | 服务端 unixepoch() 是 LWW 真源；本地时钟仅用于 capture 排序 |
| Migration v3 失败 | 沿用现有：弹窗 "备份并重置 / 退出" |
| D1 schema 损坏 / 表丢失 | ensureSchema CREATE IF NOT EXISTS 自愈；row 数据丢失则等同新 cloud profile，要求用户重新初始化 |

### 10.4 配额 / 大对象

| 场景 | 处理 |
|---|---|
| > 2MB image | A 端不入队 → row 不存在；B 永远看不到；A UI 行尾 📤 |
| D1 写次数到上限（5M/day 免费） | push 失败 → backoff；状态文字"D1 配额超限" + 链接 dashboard |
| R2 流量 / ops 异常 | 同上 |

## 11. 测试

### 11.1 单元（pure，无网）

| 文件 | 关键 case |
|---|---|
| KeyDerivationTests | (同 v1) |
| CryptoBoxTests | (同 v1) |
| KeychainStoreTests | (同 v1) |
| SyncSchemaTests | RowPayload / DevicePayload Codable round-trip; v1 解码 |
| SyncQueueTests | enqueue/dequeue/backoff/deleteAllForItem (同 v1) |
| MigrationV3Tests | 6 列 + tombstones + sync_queue + sync_state 创建 |

### 11.2 集成（用 LocalSqliteDataSource + LocalDirBlobStore，无网）

| 文件 | 关键 case |
|---|---|
| SyncEnginePushTests | text upsert → DataSource 收到 ciphertext 行；image 走 BlobStore + DataSource |
| SyncEnginePullTests | 两个 store 共享一个 DataSource：A push → B pull → 同 content_hash 出现 |
| SyncEngineTombstoneTests | A 删 → A push tomb (deleted=1) → B pull → B 本地删 + tombstones 表写入 |
| SyncEnginePinTests | A pin → B pull → B local pinned=1; B unpin → A pull → A pinned=0 (LWW) |
| SyncEngineImageTests | A push image → BlobStore 有 sealed bytes + DataSource 行；B pull 只插 lazy blob ref；fetchBlob 触发 GET + 解密 + 填本地 |
| SyncEngineExcludeTests | exclude synced item → setClipDeleted + queue 清；exclude unsynced → 仅 queue 清 |
| SyncEngineEnableBootstrapTests | 第一台：salt 写 D1 config + master_key 入 Keychain; 第二台：从 D1 读 salt + 派生同 master_key |

### 11.3 真 D1 + 真 R2 集成（opt-in，不进 CI）

`Tests/ClipTests/CloudIntegration/`，require `~/.wrangler/clip.env` 加载（包含 R2 + D1 凭据）：

- 整个 push → pull → tomb → fetchBlob 路径打真 D1 + 真 R2
- 跑完清空 D1 表（DELETE FROM clips; DELETE FROM devices）+ R2 桶

### 11.4 手动 smoke

加到 `docs/MANUAL_TEST.md`（取代 v1 的 checklist）：

- A B 两台 Mac 装最新 build；A 配 R2 + D1 + 输密码 → "已初始化新云端"；B 配相同 + 同密码 → "已加入" + 拉数据
- 复制 → 60s 内 B 看到（行尾 ☁️）
- 删 → B 上消失
- pin → B pin
- 1MB image → B 看到行 → 点开预览 spinner → 解密渲染
- 3MB image → A 行尾 📤；B 看不到
- ⌘N 标记不同步已有 → B 上消失
- 重启两台 → 历史保留 + 同步继续

## 12. 验收标准

1. ClipSyncTests 单元 + 集成测试全过
2. 真 R2 + 真 D1 双机 smoke：A 复制 → B 看到 ≤ 60s；A 删 → B 删；A pin → B pin
3. 重启两台 Mac 后状态保留
4. Activity Monitor 实测启用同步 24h idle CPU < 0.5%（手动观察）
5. 输错密码不删本地
6. backfill 1000 条不卡 UI > 100ms（手动观察）

## 13. 留待后续 / 已知风险

- iOS 客户端
- 自建 backend (Postgres / Supabase) 替换 D1 = 实现新 `CloudSyncDataSource` adapter
- D1 401/403 special pause-and-notify
- 密码轮换在线增量
- R2 blob lifecycle GC for deleted rows
- "已知设备"完整 UI（v3 列文字即可，删 / 重命名 / 远程登出留 v3.1）
- 面板图标 ⏳ / 📤 / ⚠️
- 首次启用 modal sheet（v3 用 Preferences form 替代）
- Backend abuse mitigation: D1 token 泄漏 → 攻击者只能写垃圾 / 删数据，不能解密；v3.1 加 row 数量上限触发 + ratelimit warning
- `clip_blobs` 孤儿清理沿用原 prune 路径（lazy NULL-bytes 占位行不会被清，因为 items.blob_id 仍指向）

---

**v2 与 v1 的核心实现差异（给 plan-rewrite 的索引）**：

| v1 模块 | v2 状态 |
|---|---|
| `CloudSyncBackend` (5 ops, 含 list/head) | 拆成 `CloudSyncDataSource` + `CloudSyncBlobStore` |
| `R2Backend` (含 list + ListV2 XML 解析) | 简化为 `R2BlobBackend` (只 put/get/delete blobs/) |
| `LocalDirBackend` | 拆成 `LocalSqliteDataSource` + `LocalDirBlobStore` |
| `cloud_name` 列 (v1 加的 hmac → 文件名映射) | **去掉**；v2 用 `cloud_id` UUID + D1 UPSERT 语义；hmac 在 D1 行里直接是列 |
| `tomb/<hmac>.bin` 单独对象 | **去掉**；改 D1 `deleted=1` flag |
| `devices/<id>.bin` 单独对象 | **去掉**；改 D1 `devices` 表 |
| `config.json` R2 对象 | **去掉**；改 D1 `config` 表 |
| `last_pull_cursor` JSON map per prefix | 简化为单标量 `cloud_pull_cursor` (max updated_at) |
| Pull 算法：list + GET | SQL `SELECT WHERE updated_at > ? LIMIT 100` |

新增模块：`D1Backend`（HTTPS REST 客户端）、`LocalSqliteDataSource`（in-memory SQLite 模拟，单测用）。
