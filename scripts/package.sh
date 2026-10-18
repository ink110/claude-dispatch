#!/bin/bash
# 构建通用二进制并打成可分发的 zip，输出 SHA-256。
# 用法：./scripts/package.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"

"$ROOT/scripts/build.sh" "$VERSION"

DIST="$ROOT/dist"
mkdir -p "$DIST"
ZIP="$DIST/ClaudeDispatch-${VERSION}.zip"
rm -f "$ZIP" "$ZIP.sha256"

# --norsrc/--noextattr：不把本机扩展属性带进发布包。
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr \
  "$ROOT/build/ClaudeDispatch.app" "$ZIP"

echo
unzip -l "$ZIP"
echo
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
