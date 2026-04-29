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
