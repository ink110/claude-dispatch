#!/bin/bash
# 构建通用二进制（Apple Silicon + Intel）的 ClaudeDispatch.app。
# 用法：./scripts/build.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ClaudeDispatch.app"
TMP="$ROOT/build/tmp"
VERSION="${1:-}"
SOURCES=("$ROOT"/Sources/*.swift "$ROOT"/Sources/UI/*.swift)

if [ -z "$VERSION" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
fi
if [ -z "$VERSION" ]; then
  echo "无法确定版本号。"
  exit 1
fi

rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

compile_arch() {
  local arch="$1"
  echo "Compiling ${arch}…"
  swiftc -O -swift-version 5 \
    -target "${arch}-apple-macos14.0" \
    "${SOURCES[@]}" \
    -o "$TMP/ClaudeDispatch-${arch}" \
    -framework AppKit \
    -framework Network
}

compile_arch arm64
compile_arch x86_64

lipo -create \
  "$TMP/ClaudeDispatch-arm64" \
  "$TMP/ClaudeDispatch-x86_64" \
  -output "$APP/Contents/MacOS/ClaudeDispatch"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# 本地 ad-hoc 签名，减少 Gatekeeper / TCC 的干扰。签名失败必须让构建失败。
codesign --force --deep --sign - "$APP"

rm -rf "$TMP"

echo "Built: $APP (version $VERSION)"
lipo -info "$APP/Contents/MacOS/ClaudeDispatch"
