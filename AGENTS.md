# AGENTS.md — clip

macOS 菜单栏剪贴板历史面板。SwiftPM 单可执行 `Clip`，运行为 `LSUIElement` 菜单栏 accessory。

## 工具链与构建

- **必须有完整 Xcode**，不是只装 Command Line Tools。依赖 `KeyboardShortcuts` 的 `Recorder.swift` 末尾用了 `#Preview` 宏，CLT toolchain 没有 `PreviewsMacros` 插件，编译会直接挂。
  - 验证：`xcrun -f swift` 应返回 `/Applications/Xcode.app/Contents/Developer/...`，不是 `/Library/Developer/CommandLineTools/...`。
  - 如果只有 CLT：`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。
- macOS 13+，Swift 6.0，`@MainActor` / `Sendable` 检查严格。
- 三种构建场景：

  | 命令 | 用途 | 注意 |
  |---|---|---|
  | `swift run` | 开发热改 | 没 `Info.plist` → `LSUIElement` 不生效，会有 Dock 图标，菜单栏行为不完整 |
  | `./package-app.sh` | 出 `dist/Clip.app` | release build + 写 `Info.plist` + codesign |
  | `swift test` | 跑单测 | 即 `Tests/ClipTests/`，CI 也跑这条 |

- `package-app.sh` 默认用 `CODESIGN_IDENTITY="Clip Dev"` 自签名证书。如果 Keychain 里没有该证书，**构建会失败**，必须显式 ad-hoc：`CODESIGN_IDENTITY=- ./package-app.sh`。注释里有自签证书的创建步骤。

## 第一次跑起来

1. 装 Xcode，授权 license，切 toolchain（见上）。
2. `./package-app.sh` 出 `dist/Clip.app`。
3. `open dist/Clip.app`，第一启动会弹 onboarding，按引导去 `系统设置 → 隐私与安全 → 辅助功能` 勾上 Clip。**没授权时选条目只会落到剪贴板，不会自动 ⌘V。**
4. 默认热键 `⌃⌥⌘V` 召出面板。

## 不能动 / 慎动的东西

- `setActivationPolicy(.accessory)`（`ClipApp.swift`）：保证菜单栏行为；改成 `.regular` 会出 Dock 图标。
- `Settings { EmptyView() }` scene 是占位，**不要往里塞真内容**。accessory app 里 `showSettingsWindow:` 没人响应，Preferences 必须走 `AppDelegate.openPreferences()`（手动 `NSWindow + NSHostingController`）。同理 onboarding。
- `PasteInjector.postCommandV()` 必须发四个 CGEvent（Cmd↓ V↓ V↑ Cmd↑），**不能简化成两个带 `.maskCommand` 的 V 事件**。Ghostty / Electron / 任何查 `NSEvent.modifierFlags` 的 app 会把简化版当成裸 "v" 输入。
- 任何写回 `NSPasteboard` 的代码路径都要带上 `PrivacyFilter.internalUTI` 标记，否则 `PasteboardObserver` 会把刚粘贴的内容再次入库形成 echo。
- `PasteboardObserver` 标记 `@unchecked Sendable`：所有可变状态只在 `clip.pasteboard.observer` 串行队列上改，加新字段时维持这个不变量。
- `HistoryStore` 是 GRDB `DatabasePool`（WAL 模式），跨线程安全。新增写操作走 `pool.write { ... }`；读 `pool.read { ... }`。
- 图片用 `clip_blobs` 表按 SHA-256 去重；`items` 表的 `kind = 'image'` 行 `content = ""`，搜索 SQL 显式过滤 `kind = 'text'` 才不会被空串污染。

## 代码风格

- **UI 文案中文**（"打开剪贴板面板"、"暂停采集"、"全部 / 文字 / 图片"）。新加的菜单项 / 按钮 / Onboarding 文案保持中文。
- 注释主要英文，解释 *why* 而不是 *what*；现存注释里很多踩坑记录（`@MainActor` 隔离、TCC、四个 CGEvent、blob 去重等），改相关逻辑前先读。
- Swift 6 concurrency：闭包跨 actor 边界要么用 `@MainActor` 标注，要么把依赖捕获成本地 `Sendable` 服务后再传（参考 `AppDelegate.applicationDidFinishLaunching` 里 `blacklistService` 的捕获写法）。

## 测试

- `swift test` 覆盖：HistoryStore（dedup / prune / blob 引用）、PasteboardObserver（用 `FakePasteboardSource` 喂数据）、PrivacyFilter、Blacklist、Migrations、`LIKE` 转义、ClipItem 哈希/截断。
- `Panel` / `PreviewWindow` / `Onboarding` / 全局热键 / `PasteInjector` 没有自动化测试，UI 改动跟着 `docs/MANUAL_TEST.md` 走人工 checklist。

## 数据存储

- 路径：`~/Library/Application Support/clip/history.sqlite`（mode 0600，README 约定）。
- `HistoryStore.init` 启动时跑 `PRAGMA integrity_check`，不通过会把 DB 文件连同 `-wal` / `-shm` 一起改名 `*.corrupted-<ts>` 隔离，本次启动以空库继续。
- 开发期想清空：删 `history.sqlite` + 同目录的 `-wal`、`-shm` 三个文件。

## 签名与 TCC（Accessibility）

- TCC 按 cdhash 记忆 Accessibility 授权。
  - **Ad-hoc 签名**：每次 release rebuild cdhash 就变，授权丢失，要重新去系统设置勾。开发体验差，但能跑。
  - **稳定签名身份**（自签 `Clip Dev` 或正式 Developer ID）：TCC 按证书匹配，授权跨重编保留。
- 不要 `--no-verify` 或 `codesign --skip-validation` 类 workaround；root cause 是签名身份不稳。

## CI

`.github/workflows/test.yml`（push main / PR 触发，single job 串行 3 步）：

1. 打印 toolchain（debug 失败用）
2. `swift test --enable-code-coverage`
3. `swift build -c release --product Clip` —— **每次 push 都做一次 release 编译**，捕获只在 release 模式才暴露的优化 / 链接 / 可见性错误，不要等到手动 `package-app.sh` 才发现。

runner 锁 `macos-15`（自带 Xcode 16.x，含 Swift 6.0 + `PreviewsMacros` 插件），通过 `DEVELOPER_DIR` env 把 toolchain 指向完整 Xcode。**不要回退到 `swift-actions/setup-swift@v2`**——它只装 Swift toolchain，缺 `PreviewsMacros`，依赖里 `KeyboardShortcuts/Recorder.swift` 的 `#Preview` 宏会编译失败。本地用 CLT 跑同样会挂。

## 发版

`.github/workflows/release.yml`（**只在 push `v*` tag 时触发**——push 代码到分支不会发版）：

1. 派生版本号：`v0.1.0` → CFBundleShortVersionString `0.1.0`
2. `swift test`（保险，红了就不发）
3. `./package-app.sh`，环境里塞 `CODESIGN_IDENTITY=-` 走 ad-hoc
4. `ditto -c -k --keepParent Clip.app Clip-v0.1.0.zip`（**不要用 plain `zip`**，会损坏 .app bundle 的 resource fork / xattrs / symlinks）
5. `gh release create` 上传 zip，notes = `.github/RELEASE_NOTES_PREFIX.md`（含 `xattr -dr com.apple.quarantine` 安装说明）+ commits-since-last-tag 自动 changelog

发版操作：
```bash
git tag v0.1.0
git push origin v0.1.0
```

升级签名为 Developer ID 时，把 `CODESIGN_IDENTITY: '-'` 改成证书 CN，cert + key 走 GitHub Secrets + 临时 keychain；同时可在 zip 步骤后追加 `xcrun notarytool submit --wait` + `xcrun stapler staple` 完成公证，那之后用户就不用 `xattr` 了。

**不要每 push 出 release**：macOS runner 比 Linux 贵 10×，且 release 应该是版本事件。

## 文档定位

- **设计 spec**：`docs/superpowers/specs/2026-04-29-clip-design.md`（中文，目标 / 非目标 / 数据模型 / 隐私策略全在这里，改动方向之前先 align）。
- **实施计划**：`docs/superpowers/plans/2026-04-29-clip-mvp.md`。
- **手测 checklist**：`docs/MANUAL_TEST.md`。

## 依赖

- `groue/GRDB.swift` 7.x — SQLite ORM，WAL。
- `sindresorhus/KeyboardShortcuts` 2.x — 全局热键 + Preferences 录制器。**升级前先检查 Recorder.swift 是否仍含 `#Preview`，CLT 用户会因此编不过**。
