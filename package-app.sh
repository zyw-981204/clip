#!/bin/bash

set -euo pipefail

SOURCE_PATH="${BASH_SOURCE[0]}"
while [ -L "$SOURCE_PATH" ]; do
    SOURCE_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
    SOURCE_PATH="$(readlink "$SOURCE_PATH")"
    [[ "$SOURCE_PATH" != /* ]] && SOURCE_PATH="$SOURCE_DIR/$SOURCE_PATH"
done

SCRIPT_DIR="$(cd "$(dirname "$SOURCE_PATH")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
APP_NAME="Clip"
APP_DIR="$PROJECT_ROOT/dist/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VERSION="${VERSION:-0.1.0}"

swift build --package-path "$PROJECT_ROOT" -c release --product Clip >/dev/null

BUILD_BIN_DIR="$(swift build --package-path "$PROJECT_ROOT" -c release --show-bin-path)"
APP_BIN="$BUILD_BIN_DIR/Clip"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$APP_BIN" "$MACOS_DIR/Clip"
chmod +x "$MACOS_DIR/Clip"

cat >"$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Clip</string>
  <key>CFBundleIdentifier</key>
  <string>com.zyw.clip</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF


# Code signing.
#
# Stable signing matters for macOS TCC (Privacy & Security): without a stable
# signing identity, every rebuild changes the binary's cdhash, which makes
# TCC drop the previous Accessibility grant — you'd have to re-authorize on
# every rebuild.
#
# Options:
#   - Default: ad-hoc sign (--sign -) with explicit identifier. Better than
#     unsigned (TCC at least sees a stable bundle id), but cdhash still
#     changes per rebuild → re-authorize each time.
#   - Set CODESIGN_IDENTITY="Clip Dev" (a self-signed code-signing cert in
#     your login keychain) → TCC matches by certificate identity, so
#     authorization persists across rebuilds.
#
# To create a self-signed cert once:
#   open -a "Keychain Access" → Certificate Assistant → Create a Certificate
#   Name: "Clip Dev"; Identity Type: Self Signed Root; Type: Code Signing
#   Then `security find-identity -v -p codesigning` should list it.

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Clip Dev}"
codesign --force --deep --sign "$CODESIGN_IDENTITY" \
    --identifier com.zyw.clip \
    --options runtime \
    "$APP_DIR" 2>&1 | sed 's/^/codesign: /'

printf '%s\n' "Packaged app: $APP_DIR"
printf 'Signed with identity: %s\n' "$CODESIGN_IDENTITY"
