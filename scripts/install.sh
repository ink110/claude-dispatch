#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DEST="$HOME/Applications/ClaudeDispatch.app"

# 1. 构建
"$ROOT/scripts/build.sh"

# 2. 安装 App（放到 ~/Applications，不需要管理员权限）
mkdir -p "$HOME/Applications"
pkill -f "ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch" 2>/dev/null || true
sleep 0.5
rm -rf "$APP_DEST"
cp -R "$ROOT/build/ClaudeDispatch.app" "$APP_DEST"

# 3. 安装 hooks（唯一实现：ClaudeDispatch --install-hooks，自动备份并轮转）
"$APP_DEST/Contents/MacOS/ClaudeDispatch" --install-hooks

# 5. 启动
open "$APP_DEST"
echo "Claude Dispatch 已启动。菜单栏会出现状态图标。"
echo "卸载：$ROOT/scripts/uninstall.sh"
