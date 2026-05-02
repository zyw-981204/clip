# clip — 云端剪贴板同步设计文档

**状态**：spec / pending review
**日期**：2026-05-02
**工作名**：cloud-sync（增量到 v3）
**前序文档**：`docs/superpowers/specs/2026-04-29-clip-design.md`

## 0. 与原 spec 的关系（必读）

原 spec §2.2 明确把 "iCloud / 跨机同步" 列为**永远不做**。本文档**推翻**这条决策。

**为什么改**：用户使用一段时间后明确提出"我想要剪贴板信息同步到云端，跨设备可用"。原 spec 当时的"永远不做"是对 v1 范围的克制，不是对功能本身的否定。本文档作为 v3 的设计延伸，原 spec 其余部分（数据模型 v1/v2、隐私过滤、面板交互、性能预算）继续有效，本文档**只**描述云同步增量。

**revision 记录**：原 spec line 31 `iCloud / 跨机同步（永远不做）` → 本 spec 取代。

### 0.1 关于实现拆分

本 spec 涵盖 KDF + crypto、S3 v4 签名、queue/backoff、lazy-blob fetch、Preferences 重设计、modal onboarding、migration v3、tombstone 语义、密码轮换、R2 集成测试、panel icon、新热键。reviewer 可能认为这跨越多个独立子系统、应该拆成 3-4 份 spec/plan。

**保持单 spec / 单 plan 的理由**：上述模块之间高度耦合——所有路径都共用 `CryptoBox`、`CloudSyncBackend`、`SyncEngine` 三个核心抽象，拆开后边界处反而要重复定义同样的契约（PayloadVersion、ETag 表示、错误类型）。**拆分应该发生在 plan 内的 task 划分**（pp 1: foundations / 2: backend / 3: engine / 4: UI），而不是 spec 维度。`superpowers:writing-plans` 流程天然把这种规模分解成 bite-sized tasks。

## 1. 概述

为 clip 增加**端到端加密**的跨 Mac 剪贴板历史同步。后端选 **Cloudflare R2**（S3 兼容对象存储），客户端用 ChaCha20-Poly1305 加密后再上传，云端永远拿不到明文。剪贴板条目是 immutable history events，用 content-addressed 命名 → 同条目跨设备天然去重，无合并冲突。

**典型用法**：用户在 Mac A 复制一段代码 → 几秒后在 Mac B 唤起面板 → 看到该条目 → Enter 粘贴。

## 2. 目标 / 非目标

### 2.1 目标

- 跨 2-3 台 Mac 同步剪贴板**全部历史**（文字 + 图片）
- **强制 E2E 加密**：用户设同步密码，云端只存密文；密码丢 = 数据不可恢复（明示）
- 图片 ≤ 2MB 上传；> 2MB 本地存但跳过云
- 启用时**全量 backfill** 一次本地既有数据
- **选择性同步**：每条可标记"不上云"，已上传的会发 tombstone 删除
- 把 capture 之外的 sync / crypto / storage 抽到 `Sources/Clip/Sync/` 单目录，**为后续 iOS 客户端复用准备**（不在本期交付 iOS app）
- 沿用现有 LSUIElement / .accessory 架构、SQLite + GRDB、Migrations 链，不重写既有模块

### 2.2 非目标 / 留给以后

- iOS / iPadOS 客户端 app（架构准备好，本期不交付）
- CloudKit / Backblaze / 自建 S3 等其它 backend（架构 pluggable，本期只实现 R2）
- 实时推送（无 APNS entitlement 跨 app；用 30s 轮询 + 唤醒/激活时 immediate pull）
- 选择性同步的 app-id 维度规则（先用每条手动；现有 Blacklist 已经在 capture 层挡）
- "仅 WiFi" / 流量控制 / 带宽限速
- 同步 Preferences / 黑名单 / 热键设置
- 多账号 / 多 cloud profile（每台 Mac 一份配置）
- 端到端**密码恢复**机制（KDF + Keychain，丢密码就是丢数据；UI 上做强提醒）
- 密码轮换的**在线 / 增量 / 后台优化**（v3.1 再做。v3 已含基础密码修改流程，但是阻塞式重传——见 §10.2）

## 3. 设计决策汇总

| # | 决策点 | 选择 | 理由 |
|---|---|---|---|
| 1 | Backend | Cloudflare R2（S3 API） | 免费 10GB / 出口免费 / 跨平台 / 控制力强；vs iCloud Drive 同步延迟不可控、跨端体验差 |
| 2 | Backend 抽象 | `CloudSyncBackend` protocol，5 个方法（put/get/delete/list/headObject） | 不绑定 R2；以后加 CloudKit / Backblaze / 自建 = 写一个 adapter |
| 3 | 加密算法 | **ChaCha20-Poly1305**（Apple `CryptoKit.ChaChaPoly`，AEAD） | 原生、性能好、AEAD 一步完成 confidentiality + integrity；vs AES-GCM 在 iOS 老设备性能差 |
| 4 | 密钥派生 | **PBKDF2-HMAC-SHA256**, 200k rounds, 32B 输出（CommonCrypto `CCKeyDerivationPBKDF`） | 抗暴力够用；CryptoKit 没原生 PBKDF2，scrypt/argon2 需引第三方依赖 |
| 5 | 密钥分层 | 主密钥 → HKDF 派生 `kEncrypt`（加密）+ `kName`（HMAC 命名） | 单个泄漏不污染另一个用途；标准 NIST SP 800-108 模式 |
| 6 | 文件命名 | `HMAC-SHA256(content_hash, kName)` 取 hex → 文件名 | 云端看不到 content_hash 也看不到内容；同 hash 跨设备命名一致 → 天然去重 |
| 7 | 内容寻址 | 是 | 同一段文字在两台 Mac 复制 → 同 hmac → 第二台 PUT 覆盖第一台，幂等无冲突 |
| 8 | 冲突解决 | **R2 LastModified 比较**（不是 payload 内的 created_at）。同 hmac 多次 PUT，list 拿到的 LastModified 较新者 wins。pin/exclude 是少数 mutable 字段；payload 内 created_at 用作 tombstone vs item 的复活判定（见 §10.3） | 区分两种比较语义：跨设备并发改 pin → 服务端时间为准；删除复活 → payload 时间为准 |
| 9 | 图片存储 | 元数据 + 缩略图（≤ 5KB）随 item JSON 一起；原图单独 `blobs/<hmac>` 对象；backfill 与正常 push 共用串行 pushTask（不并行） | 拉取端按需下载原图，避免一同步就占满本地磁盘；串行 push 简化错误恢复 |
| 10 | 大图阈值 | > 2MB 不上云（本地仍存） | 平衡带宽和实用性；同步 panel 显示 "📤 跳过云"  |
| 11 | Tombstone | 删除 = 删 `items/<h>` + 写 `tomb/<h>`；本地 `tombstones` 表防"复活"。复活判定语义见 §10.3 | 单写 `items/` 删的方案在 list-page 边界会复活：A 删后 B 在 list `items/` 拿到陈旧页面（没看到删除），又把它当作"新增"重新 INSERT，所以必须有显式 tomb 标记 |
| 12 | Pin / Exclude | inline 在 item JSON 里；toggle 即重传同 key | 简单；pin 改一次约几百字节 PUT |
| 13 | Backfill | 启用时把所有 items + clip_blobs 推入 sync_queue | 用户期望"过去的也能同步" |
| 14 | 拉取频率 | 30s 轮询 + app launch / wake / hotkey 唤起时 immediate pull | 没 APNS，轮询是唯一选项；30s 在能感知和省电之间 |
| 15 | Device 标识 | 每台 Mac 启用同步时生成 UUID，存 `sync_state.device_id` | 用于 item 元数据里"来源设备"展示 + 调试 |
| 16 | 密码丢失 | 不可恢复，UI 强提示；提供 "reset cloud" 清空 R2 + 重设密码 | E2E 的本质代价；自动备份密码到云就破坏 E2E |
| 17 | 模块组织 | `Sources/Clip/Sync/` 子目录，纯 Swift Foundation，无 AppKit 依赖 | 为后续抽 `ClipKit` 共享 lib 给 iOS 用做准备；本期不实际拆 package |
| 18 | iOS 客户端 | 不交付 | 设计上预留；交付清单里只是"代码能搬"，UI / Pasteboard 适配是独立工程 |

## 4. 架构

### 4.1 模块分工

| 模块 | 职责 | 路径 |
|---|---|---|
| `CloudSyncBackend`（protocol） | 抽象的对象存储读写接口 | `Sources/Clip/Sync/CloudSyncBackend.swift` |
| `R2Backend` | S3 v4 签名 + URLSession 实现 backend | `Sources/Clip/Sync/R2Backend.swift` |
| `LocalDirBackend` | 写本地目录的 backend，单测和无网测试用 | `Sources/Clip/Sync/LocalDirBackend.swift` |
| `CryptoBox` | ChaCha20 seal/open + HMAC 命名 | `Sources/Clip/Sync/CryptoBox.swift` |
| `KeyDerivation` | PBKDF2 包装；从密码 + salt → 主密钥 | `Sources/Clip/Sync/KeyDerivation.swift` |
| `SyncEngine` | 拉取轮询 + 推送队列调度 + tombstone 处理 | `Sources/Clip/Sync/SyncEngine.swift` |
| `SyncQueue` | 持久化重试队列（DB 表），带 backoff | `Sources/Clip/Sync/SyncQueue.swift` |
| `SyncSchema` | 云对象 payload 结构 + Codable | `Sources/Clip/Sync/SyncSchema.swift` |
| `SyncSettings` | 启用状态、密码、桶配置；密码不落盘 | `Sources/Clip/Sync/SyncSettings.swift` |
| `KeychainStore` | 主密钥 / R2 token 落 Keychain | `Sources/Clip/Sync/KeychainStore.swift` |
| `CloudSyncView`（SwiftUI） | Preferences 新 tab "云同步" | `Sources/Clip/Preferences/CloudSyncView.swift` |
| `Migrations.v3` | DB 迁移加 sync 相关字段和表 | `Sources/Clip/Storage/Migrations.swift` |

`HistoryStore` 现有 API 不破坏，加少量 hooks（`onInsert`、`onDelete`、`onPinToggle` 回调），由 `AppDelegate` 在初始化时把 `SyncEngine.enqueue*` 接进去。

### 4.2 进程模型

仍是单进程 LSUIElement，新增一个**串行 actor** `SyncEngine`：

```
AppDelegate
  ├─ HistoryStore (existing)
  ├─ PasteboardObserver (existing) → store.insert → store hook → engine.enqueuePush
  └─ SyncEngine (new actor)
        ├─ pushTask: 串行 drain SyncQueue → backend.put
        └─ pullTask: 30s timer → backend.list → 比对 cloud_index → backend.get → store.upsert
```

`SyncEngine` 是 Swift `actor`，所有可变状态串行化。后台用 `Task` 跑两条不阻塞主线程的循环。

## 5. 数据模型 — Migration v3

### 5.1 字段增量

```sql
-- items 加 4 列
ALTER TABLE items ADD COLUMN sync_excluded INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN cloud_synced_at INTEGER;          -- NULL = 未上传
ALTER TABLE items ADD COLUMN cloud_etag TEXT;                  -- last seen / set ETag
ALTER TABLE items ADD COLUMN device_id TEXT;                   -- 来源设备 UUID

-- clip_blobs 加 2 列
ALTER TABLE clip_blobs ADD COLUMN cloud_synced_at INTEGER;
ALTER TABLE clip_blobs ADD COLUMN cloud_etag TEXT;
```

### 5.2 新表

```sql
-- 云端 tombstones：被删除的条目，防 "pull 又把它捡回来"
CREATE TABLE tombstones (
  hmac            TEXT PRIMARY KEY,         -- HMAC 后的云端文件名
  content_hash    TEXT NOT NULL,            -- 本地用，确认对应哪条
  tombstoned_at   INTEGER NOT NULL,
  cloud_synced_at INTEGER,                  -- NULL = 本地 only；NN = 已上传 tomb/<h>
  cloud_etag      TEXT                      -- last seen ETag of tomb/<h>; 用于 pull 增量判定
);
CREATE INDEX idx_tombstones_synced ON tombstones(cloud_synced_at);

-- 推送队列：persistent retry buffer
CREATE TABLE sync_queue (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  op          TEXT NOT NULL,                -- 'put_item'|'put_blob'|'put_tomb'
  target_key  TEXT NOT NULL,                -- 见下方 target_key 编码约定
  attempts    INTEGER NOT NULL DEFAULT 0,
  next_try_at INTEGER NOT NULL,             -- unix秒；backoff 后下次最早执行时间
  last_error  TEXT,
  enqueued_at INTEGER NOT NULL
);
CREATE INDEX idx_sync_queue_next ON sync_queue(next_try_at);

-- 同步状态：device_id / 上次拉取时间 / KDF 参数等
CREATE TABLE sync_state (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- 已知 keys:
--   device_id           UUID
--   last_pull_at        unix 秒
--   last_pull_cursor    JSON: {"items/": "<token>"|null, "tomb/": ..., "devices/": ...}
--                       —— 每个 prefix 一个独立 cursor；新 prefix 默认 null（从头开始）
--   kdf_salt_b64        base64(salt) - 16 bytes
--   kdf_iters           integer (200000)
--   kdf_version         integer (1)
```

**`sync_queue.target_key` 编码约定**：

| op | target_key 内容 | 说明 |
|---|---|---|
| `put_item` | `items.id` 的十进制字符串 | pusher 取行 → seal → PUT `items/<hmac>.bin` |
| `put_blob` | `clip_blobs.id` 的十进制字符串 | pusher 取 blob → seal → PUT `blobs/<hmac>.bin`（hmac 由 blob.sha256 派生）|
| `put_tomb` | `tombstones.hmac` 直接（不查表）| pusher 直接 PUT `tomb/<hmac>.bin` |
| `put_device` | `device_id` UUID 字符串 | pusher seal `DevicePayload` PUT `devices/<device_id>.bin`（首启 + 改名时） |

**选择性同步取消推送的语义**（替代 §5.2 早期版本里"标记 skip"的设想）：toggle `sync_excluded = 1` 时，**直接 `DELETE FROM sync_queue WHERE op IN ('put_item','put_blob') AND target_key 对应到此 item`**。无需在 sync_queue 加 skip 列。pusher 永远只看到"该跑就跑"的行。

### 5.3 关键约定

- **去重**：同 `content_hash` → 同 `hmac`（因为 `kName` 跨设备一致）→ 同 R2 文件名。云端永远只有一份。
- **device_id**：随机生成的 UUID，存 `sync_state`，在 item JSON 里也带一份让 panel 能显示"来自 Mac B"。
- **kdf 参数**：写在 `sync_state` 里也写在云端 `config.json` 里，新设备先拉 config 才能正确派生密钥。

## 6. 加密 / 命名 详细规范

### 6.1 KDF

```
salt          := 16 random bytes (per cloud profile, 一次性生成)
master_key    := PBKDF2-HMAC-SHA256(password, salt, iters=200_000, dkLen=32)
k_encrypt     := HKDF-SHA256(master_key, info="clip.encrypt.v1", L=32)
k_name        := HKDF-SHA256(master_key, info="clip.name.v1",    L=32)
```

`master_key` 派生后存 macOS Keychain（`kSecClassGenericPassword`，service `com.zyw.clip.cloud-master-v1`，account = device_id）；密码本身从不落盘。

### 6.2 文件命名

```
hmac          := HMAC-SHA256(k_name, content_hash_utf8)
filename      := items/<hex(hmac)>.bin     // 或 blobs/ tomb/
```

### 6.3 加密 payload

```
nonce         := 12 random bytes
sealed        := ChaChaPoly.seal(plaintext, key=k_encrypt, nonce=nonce)
                  → ciphertext + 16-byte tag
on_disk       := nonce(12) || ciphertext || tag(16)
```

解密对称：分割 12 / N / 16 → `ChaChaPoly.open`。失败（密码错或被篡改）抛 `CryptoBox.Error.decryptionFailed`，**不删本地数据**，UI 提示"密码不对或对象损坏"。

### 6.4 云端对象布局

```
config.json                                    # 明文，只含 KDF 参数 (没敏感信息)
items/<hex(hmac)>.bin                          # 加密 ItemPayload
blobs/<hex(hmac_of_blob_sha)>.bin              # 加密 BlobPayload (only for image kind, ≤2MB)
tomb/<hex(hmac)>.bin                           # 加密 TombstonePayload
devices/<device_id>.bin                        # 加密 DevicePayload (首启 + display name 改时上传)
```

**`cloud_etag` 来源**：S3 PUT 响应的 `ETag` header（R2 实现：MD5-style hex string，带双引号的版本去引号即用）。`backend.put` 返回这个字符串；`SyncEngine` 把它写入 `items.cloud_etag` / `tombstones.cloud_etag`。pull 阶段 `backend.list` 返回的每个 object 也带 `etag` 字段，与本地存的对比即可判断是否 changed。

**ItemPayload (encrypted JSON)**:
```json
{
  "v": 1,
  "kind": "text" | "image",
  "content_hash": "<hex sha256>",
  "content": "...",                            // text 才有
  "mime_type": "image/png",                    // image 才有
  "blob_hmac": "<hex>",                        // image 才有，指向 blobs/ 对象
  "blob_size": 12345,                          // image 才有
  "thumb_b64": "<base64 PNG ≤5KB>",            // image 才有；optional，本地能渲染就嵌
  "byte_size": 0, "truncated": false,
  "source_bundle_id": "...", "source_app_name": "...",
  "created_at": 1735689600,
  "pinned": false,
  "device_id": "<UUID>"
}
```

**TombstonePayload (encrypted JSON)**:
```json
{ "v": 1, "content_hash": "<hex>", "tombstoned_at": 1735689600, "device_id": "<UUID>" }
```

**DevicePayload (encrypted JSON)** — 用于 §8.1 "已知设备" UI 汇总：
```json
{ "v": 1, "device_id": "<UUID>", "display_name": "Mac-Mini-7",
  "model": "Mac15,12", "first_seen_at": 1735689600, "last_seen_at": 1735776000 }
```
设备首启 + 用户改 display name + 每次 app 启动（更新 last_seen_at）时 PUT。CloudSyncView 的 "已知设备" 列表 = 把 `devices/` 全部 GET + 解密 + 按 last_seen_at DESC 排序。

`config.json` 不加密（无敏感数据），但 PUT 时附 metadata `x-amz-meta-version` 防 backend 误读：

```json
{ "v": 1, "kdf": "pbkdf2-hmac-sha256", "kdf_iters": 200000,
  "kdf_salt_b64": "<base64>", "format": "chacha20-poly1305-ietf-12-16" }
```

## 7. 数据流

### 7.1 启用同步（首次配置）

```
用户在 Preferences > 云同步 → 输入 R2 endpoint / access key / secret / bucket
  ↓ 验证：backend.list("config.json") + backend.headObject("config.json")
  ↓ 不存在  → 这是首台 Mac，进入 "新 cloud profile" 分支
            生成 16B salt + UUID device_id
            提示用户输密码 (≥12 字符) + 确认 + 警告 "丢密码 = 丢数据"
            派生 master_key → Keychain
            构造 config.json → backend.put
            写 sync_state (device_id / kdf_*)
            把所有现有 items + clip_blobs 入 sync_queue (backfill)
  ↓ 已存在 → 这是新设备加入
            backend.get("config.json") → 解析 KDF 参数
            提示用户输已有密码 + 派生 master_key
            尝试 backend.get(任意一个 items/ 的 key) + 解密 → 失败说密码错
            通过 → 写 sync_state，启动 pull 全量同步
```

### 7.2 推送（本地→云）

```
事件触发: store.insert → onInsert hook → engine.enqueuePush(.putItem(item.id))
         store.delete → onDelete hook → engine.enqueueTombstone(content_hash)
         store.togglePin → onPin → engine.enqueuePush(.putItem(id))  // 重传 metadata
         配置选择性排除 → engine.enqueueTombstone + 标记 sync_excluded=1
  ↓
SyncQueue.append(op, target, next_try_at = now)
  ↓
pushTask 循环 (Task in actor):
  loop {
    await engine.maybePump()  // 取 next_try_at <= now 的最早一条
    if none → await Task.sleep until next or wakeup signal
    item = next
    do {
      payload = build(item)            // SyncSchema serialize
      sealed = cryptoBox.seal(payload)
      etag = await backend.put(key, sealed, contentType: "application/octet-stream")
      store.markSynced(item.id, at: now, etag: etag)
      delete from sync_queue where id = item.id
    } catch {
      attempts += 1
      next_try_at = now + min(900, 2^attempts)   // 指数 backoff，封顶 15 分钟
      last_error = describe(error)
      update sync_queue
      // attempts > 10 → log + 不再自动重试，等手动"重试"按钮
    }
  }
```

### 7.3 拉取（云→本地）

**触发**：30s 定时器；app launch；NSWorkspace.didWake；hotkey 唤起 panel。后三种触发会被 **rate-limited**：同 prefix 在 5s 内的多次唤起合并为一次 pull（避免 panel 反复弹出导致 burst）。

**没有独立 cloud_index 表**：每个 object 类型已有"本地映像 + cloud_etag" 的列：
- `items/<h>` ↔ `items.content_hash` 行的 `cloud_etag`
- `tomb/<h>` ↔ `tombstones.hmac` 行的 `cloud_etag`
- `devices/<id>` ↔ in-memory cache（不持久化，每次启动重 GET）

```
触发后 pullTask:
  cursors = JSON.parse(sync_state.last_pull_cursor) ?? {}
  for prefix in ["tomb/", "items/", "devices/"]:    # tomb 先于 items 防复活
    cursor = cursors[prefix]
    while True:
      page = await backend.list(prefix, after: cursor)
      for object in page.objects:
        local_etag = lookupLocalEtag(prefix, object.key)
        if local_etag == object.etag: continue           # 已知不变
        sealed = await backend.get(object.key)
        plain  = cryptoBox.open(sealed)
        switch prefix:
          case "items/":   handleItemPayload(decode(plain), etag: object.etag)
          case "tomb/":    handleTombstone(decode(plain), etag: object.etag)
          case "devices/": cacheDevice(decode(plain))
      if !page.hasMore: break
      cursor = page.nextCursor
    cursors[prefix] = cursor
  sync_state.last_pull_at = now
  sync_state.last_pull_cursor = JSON.stringify(cursors)
```

`handleItemPayload(payload, etag)`：
- 查 `tombstones` 表，hmac 命中且 `tombstoned_at >= payload.created_at` → **skip**（等号情况：tomb wins，与 §10.3 一致；保护"删后又出现陈旧复活"场景）
- 查本地 `items` 表 by `content_hash`：
  - 命中：UPDATE 可变字段 `pinned`, `device_id`, `cloud_etag = etag`（payload 内的 created_at 不动；本机 created_at 是本地真值）
  - 未命中：INSERT，cloud_etag = etag。image kind 时 `clip_blobs` 插占位行（bytes NULL，blob_hmac/byte_size 来自 payload），thumbnail 落 ThumbnailCache
- 解密失败：log warning + 跳过；不删本地

`handleTombstone(payload, etag)`：
- UPSERT into `tombstones` (hmac, content_hash, tombstoned_at, cloud_etag = etag, cloud_synced_at = now)
- `DELETE FROM items WHERE content_hash = payload.content_hash AND created_at <= payload.tombstoned_at`（== 时也删；tomb wins）
- `DELETE FROM clip_blobs WHERE id NOT IN (SELECT blob_id FROM items WHERE blob_id IS NOT NULL)` 的常规清理在 prune 路径里走，不在这里同步做

### 7.4 Lazy blob fetch（图片按需下载）

```
PreviewWindow 或 PasteInjector.pasteImage 调 store.blob(id) → bytes
  ↓
HistoryStore.blob(id):
  row = SELECT bytes, blob_hmac, cloud_etag FROM clip_blobs WHERE id = ?
  if row.bytes IS NOT NULL: return row.bytes
  if row.blob_hmac IS NULL: return nil   // 真没有
  // 远端拉
  sealed = await syncEngine.fetchBlob(blob_hmac)
  bytes  = cryptoBox.open(sealed)
  store.fillBlob(id, bytes: bytes)
  return bytes
```

UI 在 lazy fetch 期间显示 spinner（PreviewWindow）或灰显 + tooltip（panel 行）。

### 7.5 选择性同步

UI 在 panel 行有快捷键 `⌘N` toggle "不上云"（确认 ⌘N 在现有 panel 键映射中未被占用：现有 ⌘P/⌘D/⌘F/⌘1-9/⌘,/Esc/⌘B/⌘E 都不冲突）：
- 已 synced 的项 → INSERT tombstone + enqueue tomb push + UPDATE items SET sync_excluded = 1 + **DELETE FROM sync_queue WHERE op IN ('put_item','put_blob') AND target_key 对应到本 item**
- 未 synced 的项 → UPDATE sync_excluded = 1 + DELETE 相同 sync_queue 行（无 tomb 必要，反正未上传过）

再次 `⌘N` 取消排除：UPDATE sync_excluded = 0 + 重新 enqueue put_item（如果 cloud_synced_at 仍然 NULL）。已上传过的 tomb 不会自动收回——重新出现的 hash 走正常 INSERT，云端会有一份新的 items/<h>，但旧 tomb 文件还在直到 lifecycle 清理。这是已知行为，不在 v3 自动 GC tomb。

Panel 行尾若 `sync_excluded = 1` 显示 🚫；否则若 `cloud_synced_at IS NULL AND sync queue has it` 显示 ⏳；否则若 `cloud_synced_at NOT NULL` 显示 ☁️；否则不显示。

### 7.6 Backfill

启用时事务里：
```sql
INSERT INTO sync_queue (op, target_key, next_try_at, enqueued_at)
SELECT 'put_item', CAST(id AS TEXT), strftime('%s','now'), strftime('%s','now')
FROM items WHERE sync_excluded = 0;

INSERT INTO sync_queue (op, target_key, next_try_at, enqueued_at)
SELECT 'put_blob', CAST(id AS TEXT), strftime('%s','now'), strftime('%s','now')
FROM clip_blobs
WHERE id IN (SELECT blob_id FROM items WHERE sync_excluded = 0 AND blob_id IS NOT NULL)
  AND byte_size <= 2*1024*1024;
```

UI 显示 "Backfill: M / N" 进度条，由 sync_queue 长度差驱动。

## 8. UI / UX

### 8.1 Preferences 新 tab "云同步"

```
[ ] 启用云同步                          (开关；off 时下面灰显)

R2 endpoint:    https://<account>.r2.cloudflarestorage.com
                  (验证：必须 https://; host 须以 .r2.cloudflarestorage.com 结尾或为
                   用户自定义 endpoint; account ID 32 hex chars)
Bucket name:    clip-sync           (验证：DNS-safe，3-63 chars，[a-z0-9-])
Access Key ID:  <…>                    (focus 时显示完整，blur 时遮蔽)
Secret:         ●●●●●●●●               (写入触发；存 Keychain，读不出)
                [测试连接]              (动作：HEAD config.json 期望 200 或 404；
                                        其它 HTTP 状态展示 `测试失败: <code> <body截断>`)

同步密码:        ●●●●●●●●●●●●          (≥12 chars)
                [设置 / 修改]
                ⚠️ 密码丢失 = 云端数据全部不可恢复。请使用密码管理器保存。

设备:
  • 本机: Mac-Mini-7 (device_id 前 8 位)
  • 已知: Mac-Studio-A, Mac-Air-B    (从云端 device 元数据汇总)

状态:
  云端: 1284 条 / 392 MB
  本地未同步: 3 条 (重试中)         [立刻同步] [查看错误]
  上次拉取: 12 秒前 (自动 30 秒)
  Backfill: 1284 / 1284 (完成)

危险区:
  [清空云端数据 + 撤销同步...]      (二次确认 + 输入 device 名匹配)
  [重置同步密码...]                (会上传所有对象的重加密版本，慢)
```

### 8.2 Panel 行尾同步状态指示

每行最右加 12pt 宽的小图标：

| 图标 | 含义 |
|---|---|
| ☁️ | 已同步到云 |
| ⏳ | 队列里等待推送 |
| 🚫 | 用户标记不同步（sync_excluded=1） |
| 📤 | 跳过（> 2MB image 等技术原因，不是用户意志） |
| ⚠️ | 推送失败 attempts > 3 |
| (无) | 本地 only / 未启用同步 |

### 8.3 快捷键

新增：
| 按键 | 动作 |
|---|---|
| ⌘N（panel 内）| toggle 选中行 sync_excluded |

### 8.4 首次启用引导

启用同步开关 → 弹一个 modal sheet：

1. 选 "首台 Mac (新建云端 profile)" 或 "已有云端，加入新设备"
2. 配 R2 凭据 → 测试连接
3. 设 / 输密码（首台带强度提示 + 不可恢复警告）
4. 首台显示 "正在 backfill 1284 条…" 进度条；非首台显示 "正在拉取 1284 条…" 进度条
5. 完成 → 关 sheet，回 Preferences tab 显示状态

## 9. 性能预算

| 维度 | 预算 |
|---|---|
| 推送 idle CPU | < 0.05%（队列空时 sleep） |
| 拉取 idle CPU | < 0.1%（30s tick + 增量 list；wake/hotkey 触发的 immediate pull 走 5s 合并 token bucket，长期均摊不超过 ~6 pulls/min） |
| 推送一条 text item | < 200ms 总（encrypt 1ms + put 50-150ms） |
| 推送一条 2MB image | < 1.5s 总（encrypt 30ms + put ~1s） |
| 拉取一条 text item | < 150ms（list 摊销 + get + decrypt + insert） |
| Backfill 1000 条 text + 100 张图 | < 3 min（受限于 R2 PUT 串行 / 总 ~200MB） |
| panel 显示 lazy 图片 | 命中本地：原 < 50ms；远端 lazy：< 1.5s + spinner |
| 多余磁盘占用 | 同步未下载的 image 行只占 SQLite 中元数据（每条 ~500B） |
| 错误后重试 | 指数 backoff，10 次后停（约 17 分钟） |

R2 一次 PUT/GET 假定 50-200ms（中国大陆 → APAC 区）。

## 10. 错误处理 & 边界 case

### 10.1 网络

| 场景 | 处理 |
|---|---|
| 完全离线 | enqueue 不阻塞；status bar 显示 "离线"；联网后 SyncEngine 收到 `Reachability` 通知 wakeup |
| R2 5xx | backoff 重试 |
| R2 429 throttle | backoff 重试，next_try_at 加随机 jitter |
| R2 401/403 | token 失效；通知用户去 Preferences 重新粘贴；推送循环暂停直到用户操作 |
| GET 404 | 该对象在我们 list 后被删；当作 tombstone 走（如果没有 tomb 文件，记 warning） |

### 10.2 加密 / 密码

| 场景 | 处理 |
|---|---|
| 解密失败 | `CryptoBox.Error.decryptionFailed`；UI 提示"密码错或对象损坏"；**不删本地** |
| 用户改密码 | v3 实现：阻塞式重传所有对象。流程：① 用旧密码派生 old_master 解密；② 用新密码 + 旧 salt 派生 new_master；③ 把新 master 写入 Keychain 的**新** service identifier（`com.zyw.clip.cloud-master-v2-<ts>`）；④ 串行下载所有 items/blobs/tomb 对象 → 用 old key 解 → 用 new key 重新 seal → PUT 覆盖；⑤ 全部成功后从 Keychain **删除** old service identifier，更新 sync_state.kdf_version；任何中途失败 → 保留两个 master key，可手动重启继续 |
| 密码丢失 | 不可恢复。引导用户用 "清空云端 + 重设" 流程；本地数据无损 |
| 密码不够强（< 12 字符） | 输入框拒绝 |

### 10.3 数据一致性

| 场景 | 处理 |
|---|---|
| 同条目两台同时 PUT | 同 hmac 文件名，S3 LWW；payload 无 mutable 区别（content immutable）→ 无影响 |
| pin 状态两台冲突 | LWW by **R2 LastModified**（list 返回的 server-side mtime），不是 payload 内字段；用户感知到的是"最近一台 pin/unpin 的状态" |
| tombstone vs 新 item 同 hash | 比较 `tombstones.tombstoned_at` 和 `payload.created_at`：**tomb 时间 ≥ item 时间 → tomb wins**（视为已删，丢弃新 item）；item 时间 > tomb 时间 → item wins（DELETE FROM tombstones + INSERT 该 item，对应"用户在 tomb 后又复制了相同内容"） |
| 设备时钟漂移 | created_at 用本地时钟；接受 ±60s 漂移；不做 NTP 校正。漂移 > 60s 的极端情况：可能导致 LWW 判错（例如 device A 时钟超前 5 分钟，A 发的 tomb 会战胜 B 5 分钟内才发的同 hash item）；这是已知限制，依赖系统层 NTP；UI 不弹窗 |
| Migration 失败 | 沿用现有：弹窗 "备份并重置 / 退出"，绝不静默丢数据 |
| Migration v3 内 backfill INSERT 爆量 | 不在 migrator block 里 backfill；migrator 只 ALTER + CREATE。backfill 是**启用同步动作**的一部分（不是迁移的一部分），写在 SyncEngine.enableSync() 里，独立事务，失败不影响 schema |

### 10.4 大对象 / 配额

| 场景 | 处理 |
|---|---|
| 单 image > 2MB | A 端：检查 byte_size > 2MB → 不入 sync_queue（既不 put_item 也不 put_blob）→ 行尾显示 📤；item 在云上完全不存在，因此 B 端**永远看不到这条**（无对象可 list / get）。这是设计取舍：避免大图同步；用户感知到"大图只在本地"。`sync_excluded` 不设（区分用户意志 vs 技术限制） |
| R2 配额超 | put 失败；状态显示"配额超限"；用户处理（升级 plan / 删旧条目） |

### 10.5 启动 / 多实例

沿用原 spec 的 single-instance 守卫；SyncEngine 的 actor 模式天然防多线程并发同 op。多 Mac 间无强制锁——LWW + content-addressed 已经处理。

## 11. 测试策略

### 11.1 单元（pure logic, 无网络）

| 文件 | 关键 case |
|---|---|
| `KeyDerivationTests` | 同 password+salt 跨平台/跨调用结果一致；不同 password 派生不同；iters / dkLen 边界 |
| `CryptoBoxTests` | seal → open round-trip；open 错 key 失败；open 篡改 ciphertext 失败；nonce 唯一性（10000 次无重复） |
| `SyncSchemaTests` | ItemPayload / TombstonePayload Codable round-trip；version v1 解码；缺字段容错 |
| `SyncQueueTests` | enqueue / dequeue 顺序；backoff 计算；attempts 上限；持久化跨重启 |

### 11.2 集成（用 `LocalDirBackend`，无云）

| 文件 | 关键 case |
|---|---|
| `SyncEngineTests` | 推送一条 text → backend 收到加密对象；拉取后另一个 store 解密插入相同 content_hash |
| `SyncEngineTombstoneTests` | A 端删条目 → tomb/ 出现 → B 端 pull 后本地行删除 + tombstones 表有记录；B 之后即使 items/ 复活也不再 INSERT |
| `SyncEnginePinTests` | A pin → B pull 后本地 pinned=1；B unpin → A pull 后 pinned=0（LWW） |
| `SyncEngineImageTests` | A 推 < 2MB image → blobs/ + items/ 都出现；B pull 只插 ref，bytes NULL；store.blob(id) 触发 fetchBlob 解密填充 |
| `SyncEngineExcludeTests` | 标 sync_excluded → 已 synced 发 tomb；未 synced 不发 |
| `SyncEngineBackfillTests` | 启用时把全部既有 items 入队；drain 顺序 |

### 11.3 真 R2 集成（不进 CI；本地 opt-in）

`Tests/ClipR2IntegrationTests/`，require `~/.wrangler/clip.env` 加载：

- 用本机 token 跑 SyncEngine 的 push + pull 一遍真 R2，最后清空桶
- 这个 target 默认 disabled，CI 不跑（CI 没 secrets）；本机用 `swift test --filter R2Integration` 显式跑

### 11.4 手动 smoke

加到 `docs/MANUAL_TEST.md`：

- 两台 Mac 装最新 build；A 配新 cloud profile；B 用同密码加入；几秒后 A 复制的 text 出现在 B
- B 删除一条 → A 上消失
- A pin → B 上 pin 状态同步
- A 复制一张 1MB 图 → B panel 显示 spinner → 几秒后图片可预览/粘贴
- A 复制一张 3MB 图 → 行尾显示 "📤 跳过云"，B 看不到该条
- A `⌘N` 标记不同步一条已有 → B 上消失
- 改密码 → 提示进度 → 完成；旧密码确认无法解密
- "清空云端数据" → 确认对话框 → 桶清空，本地保留

### 11.5 CI

新加测试 target `ClipSyncTests`（pure + integration with LocalDirBackend），`swift test` 一并跑。R2 integration target 不进 CI。

## 12. 验收标准

1. 全部 `ClipSyncTests` 单元 + 集成测试通过
2. 真 R2 双机 smoke：A 复制 → B 看到（≤ 60 秒）；A 删除 → B 删除；A pin → B pin
3. 重启两台 Mac 后状态保留
4. Activity Monitor 实测启用同步 24 小时 idle，CPU < 0.5%
5. 输错密码不删本地数据
6. backfill 1000 条不卡 UI > 100ms

## 13. 留待后续 / 已知风险

- **iOS 客户端**：架构已抽到 Sync/ 子目录，无 AppKit 依赖；后续做 iOS app 时把这些文件移到独立 SPM target `ClipKit` 给两个 platform 共享
- **CloudKit / 自建 backend**：实现新的 `CloudSyncBackend` adapter 即可
- **密码轮换在线优化**：v3 是阻塞重传；v3.1 做后台 chunked 重加密
- **带宽 / 配额限制**：v3.x 加 "仅 WiFi" 开关 + 配额监控
- **同步 Preferences 本身**：v4
- **冲突 UI**：当前 LWW 静默处理；如果用户报"我的 pin 状态怎么没了"，再加冲突日志
- **R2 token 撤销 / 轮换**：需要用户手动在 dashboard 撤销 + 在 Preferences 重新粘贴；UI 给链接
- **Backend abuse**：如果用户的 token 泄漏，攻击者只能往桶里写垃圾或删除（不能解密）；v3.1 加 R2 lifecycle 自动删除 N 天前对象作为兜底
