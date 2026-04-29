# clip

A macOS menu-bar clipboard history panel. Background-running, global-hotkey-driven, substring search, pinning, marker-based privacy filtering, 500-item / 30-day retention.

## Build & run

```
swift run            # dev run
./package-app.sh     # produce dist/Clip.app
```

## Default hotkey

`⌃⌥⌘V` — configurable in Preferences > Hotkey.

## Permissions

Requires macOS Accessibility permission to synthesize ⌘V into the focused app.

See `docs/superpowers/specs/2026-04-29-clip-design.md` for the full spec.
