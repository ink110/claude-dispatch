#!/bin/bash
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "缺少 jq。"
  exit 1
fi

if [ ! -f "$SETTINGS" ]; then
  echo "没有找到 $SETTINGS"
  exit 0
fi

BACKUP="$SETTINGS.bak-claude-pulse-uninstall-$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

jq '
  def strip_cp:
    map(select(([.hooks[]?.url?] | any(. != null and (contains("127.0.0.1:18765")))) | not));
  if .hooks then
    .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) | strip_cp) |
    .hooks.PreToolUse = ((.hooks.PreToolUse // []) | strip_cp) |
    .hooks.Stop = ((.hooks.Stop // []) | strip_cp) |
    .hooks.Notification = ((.hooks.Notification // []) | strip_cp) |
    .hooks.SessionStart = ((.hooks.SessionStart // []) | strip_cp) |
    .hooks.SessionEnd = ((.hooks.SessionEnd // []) | strip_cp) |
    .hooks |= with_entries(select(.value | length > 0))
  else . end
' "$SETTINGS" > "$SETTINGS.claude-pulse.tmp"

jq empty "$SETTINGS.claude-pulse.tmp"
mv "$SETTINGS.claude-pulse.tmp" "$SETTINGS"

# 退出正在运行的 App
pkill -f "ClaudePulse.app/Contents/MacOS/ClaudePulse" 2>/dev/null || true

echo "已移除 Claude Pulse 的 hooks（备份：$BACKUP）。"
echo "App 仍保留在 ~/Applications/ClaudePulse.app；如需删除请手动移入废纸篓。"
