#!/bin/bash
# 移除 Claude Dispatch 写入 ~/.claude/settings.json 的全部 hooks，并退出 App。
# hook 的安装/卸载只有一份实现：ClaudeDispatch --uninstall-hooks。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CANDIDATES=(
  "$HOME/Applications/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch"
  "/Applications/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch"
  "$ROOT/build/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch"
)

APP_BIN=""
for candidate in "${CANDIDATES[@]}"; do
  if [ -x "$candidate" ]; then
    APP_BIN="$candidate"
    break
  fi
done

if [ -z "$APP_BIN" ]; then
  echo "找不到 Claude Dispatch.app。"
  echo "请先把 App 放回 ~/Applications 或 /Applications，再运行本脚本；"
  echo "也可以直接运行：ClaudeDispatch --uninstall-hooks"
  exit 1
fi

"$APP_BIN" --uninstall-hooks

pkill -f "ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch" 2>/dev/null || true

echo
echo "已移除 Claude Dispatch 的 hooks（settings.json 已自动备份）。"
echo "App 仍在原位置；如需彻底删除，请把 ClaudeDispatch.app 移到废纸篓，"
echo "并在「系统设置 → 通用 → 登录项」中移除 Claude Dispatch。"
