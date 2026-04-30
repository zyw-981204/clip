## 安装

下载下方 `Clip-<版本>.zip`，解压得到 `Clip.app`。

由于本 release 是 ad-hoc 签名（未购买 Apple Developer ID 也未公证），双击会被 Gatekeeper 拦下并提示"无法验证开发者"。先在终端解除 quarantine 再启动：

```bash
xattr -dr com.apple.quarantine /path/to/Clip.app
```

或者把 `Clip.app` 放到 `/Applications` 后：

```bash
xattr -dr com.apple.quarantine /Applications/Clip.app
open /Applications/Clip.app
```

## 首次配置

1. 启动后会弹引导窗，按引导去 `系统设置 → 隐私与安全 → 辅助功能` 勾上 **Clip**。**没授权选条目只会落到剪贴板，不会自动 ⌘V**。
2. 默认热键 `⌃⌥⌘V` 召出剪贴板面板；可在 `偏好设置 → 热键` 自定义。

## 已知限制

- ad-hoc 签名 → 每次升级到新版本，TCC 会丢失 Accessibility 授权，需重新勾选（cdhash 变化所致）。
- 未公证 → 必须按上面的 `xattr` 命令解除 quarantine，否则打不开。
