# Clip — Manual Smoke Test Checklist

Run through every item before tagging a release. Each checkbox represents a real interaction; do not check anything you have not personally observed.

- [ ] 全新安装 → 首启引导 → Accessibility 授权回流
- [ ] 撤销 Accessibility → 红点 → 修复路径
- [ ] 热键打开面板 < 100ms
- [ ] 在 Safari 复制 → 面板出现该条目
- [ ] 1Password 复制密码 → 面板**不**出现
- [ ] 加 1Password 到黑名单 → 旧条仍在但新复制不入库
- [ ] ↑↓ + Enter 粘贴到 Safari 地址栏成功
- [ ] ⌘1–9 直接粘贴
- [ ] ⌘P 切换 pin
- [ ] ⌘D 删 pinned 弹二次确认
- [ ] 面板期间切 app → 自动关闭
- [ ] 系统睡眠 5 分钟 → 唤醒 polling 恢复
- [ ] 锁屏 → 解锁 → polling 恢复
- [ ] 双击 .app → 二实例不启动
- [ ] 复制 5MB 文本 → 不卡 UI；面板加 "(截断)"
- [ ] 1 小时 idle → Activity Monitor 该进程 < 0.5% CPU

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
- [ ] A 复制一张 3MB 图 → A 行尾**无图标** (v3 ☁️/🚫 only;  spec §8.2 的 📤 标志在 v3.x 才加)；不上传，B 永远看不到这条
- [ ] A 在面板按 ⌘N 标记不同步一条已有 → B 上消失（行尾 🚫 在 A 出现）
- [ ] 重启两台 Mac → 历史保留 + 后续复制仍同步
- [ ] 输错密码 → 不删本地数据；statusMessage 显示密码错

**边角**
- [ ] A 排除一条 → B 删 → A 重新复制相同文字 → push 命中现有 cloud_id → D1 行 deleted 翻 0（fix B）
- [ ] 网络断开 → 复制内容入 sync_queue → 网络恢复后自动 drain
- [ ] 把同步密码改错重启 app → SyncEngine.start 期间所有 GET 都解密失败 → 本地数据无损（无静默删除）
