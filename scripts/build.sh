#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ClaudePulse.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  "$ROOT"/Sources/*.swift \
  "$ROOT"/Sources/UI/*.swift \
  -o "$APP/Contents/MacOS/ClaudePulse" \
  -framework AppKit \
  -framework Network

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# 本地 ad-hoc 签名，减少 Gatekeeper / TCC 的干扰
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
