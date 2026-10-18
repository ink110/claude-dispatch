#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DEST="$HOME/Applications/ClaudePulse.app"

# 1. 构建
"$ROOT/scripts/build.sh"

# 2. 安装 App（放到 ~/Applications，不需要管理员权限）
mkdir -p "$HOME/Applications"
pkill -f "ClaudePulse.app/Contents/MacOS/ClaudePulse" 2>/dev/null || true
sleep 0.5
rm -rf "$APP_DEST"
cp -R "$ROOT/build/ClaudePulse.app" "$APP_DEST"

# 3. 安装 hooks（唯一实现：ClaudePulse --install-hooks，自动备份并轮转）
"$APP_DEST/Contents/MacOS/ClaudePulse" --install-hooks

# 5. 启动
open "$APP_DEST"
echo "Claude Pulse 已启动。菜单栏会出现脉搏图标。"
echo "卸载：$ROOT/scripts/uninstall.sh"
