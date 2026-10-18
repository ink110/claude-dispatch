#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="$HOME/.claude-pulse"
TOKEN_FILE="$STATE_DIR/token"
APP_DEST="$HOME/Applications/ClaudePulse.app"
PORT="18765"

if ! command -v jq >/dev/null 2>&1; then
  echo "缺少 jq，无法安全合并 settings.json。"
  exit 1
fi

# 1. 构建
"$ROOT/scripts/build.sh"

# 2. 安装 App（放到 ~/Applications，不需要管理员权限）
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$ROOT/build/ClaudePulse.app" "$APP_DEST"

# 3. token
mkdir -p "$STATE_DIR"
if [ ! -s "$TOKEN_FILE" ]; then
  (uuidgen; uuidgen) | tr -d '\n-' | tr '[:upper:]' '[:lower:]' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
TOKEN="$(cat "$TOKEN_FILE")"

# 4. 备份并合并 hooks（幂等）
mkdir -p "$HOME/.claude"
if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.bak-claude-pulse-$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$BACKUP"
  echo "已备份原配置：$BACKUP"
else
  echo '{}' > "$SETTINGS"
fi

URL="http://127.0.0.1:${PORT}/hook?token=${TOKEN}"

jq --arg url "$URL" '
  def strip_cp:
    map(select(([.hooks[]?.url?] | any(. != null and (contains("127.0.0.1:18765")))) | not));

  .hooks = (.hooks // {}) |
  .hooks.PermissionRequest = (((.hooks.PermissionRequest // []) | strip_cp)
    + [{hooks: [{type: "http", url: $url, timeout: 3600}]}]) |
  .hooks.PreToolUse = (((.hooks.PreToolUse // []) | strip_cp)
    + [{matcher: "AskUserQuestion", hooks: [{type: "http", url: $url, timeout: 3600}]}]) |
  .hooks.Stop = (((.hooks.Stop // []) | strip_cp)
    + [{hooks: [{type: "http", url: $url, timeout: 10}]}]) |
  .hooks.Notification = (((.hooks.Notification // []) | strip_cp)
    + [{matcher: "idle_prompt|agent_needs_input", hooks: [{type: "http", url: $url, timeout: 10}]}]) |
  .hooks.SessionStart = (((.hooks.SessionStart // []) | strip_cp)
    + [{hooks: [{type: "http", url: $url, timeout: 5}]}]) |
  .hooks.SessionEnd = (((.hooks.SessionEnd // []) | strip_cp)
    + [{hooks: [{type: "http", url: $url, timeout: 5}]}])
' "$SETTINGS" > "$SETTINGS.claude-pulse.tmp"

jq empty "$SETTINGS.claude-pulse.tmp"
mv "$SETTINGS.claude-pulse.tmp" "$SETTINGS"

echo "已写入 hooks（只监听 127.0.0.1:${PORT}）。"

# 5. 启动
open "$APP_DEST"
echo "Claude Pulse 已启动。菜单栏会出现脉搏图标。"
echo "卸载：$ROOT/scripts/uninstall.sh"
