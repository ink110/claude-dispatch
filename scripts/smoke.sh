#!/bin/bash
# 冒烟测试：不合成鼠标点击，用 curl 构造 hook 事件 + GET /status 断言状态机。
# 前置：Claude Dispatch 已在运行（./scripts/install.sh 或 open build/ClaudeDispatch.app）。
# 用法：./scripts/smoke.sh [--install-hooks]
set -uo pipefail

PORT="${CLAUDE_DISPATCH_PORT:-18765}"
TOKEN_FILE="$HOME/.claude-dispatch/token"
TOKEN="${CLAUDE_DISPATCH_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"
BASE="http://127.0.0.1:${PORT}"
AUTH="?token=${TOKEN}"

failures=0
pass() { echo "PASS  $1"; }
fail_test() { echo "FAIL  $1  ${2:-}"; failures=$((failures + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "缺少 jq，无法解析 /status。"
  exit 1
fi
if [ -z "$TOKEN" ]; then
  echo "找不到 token：$TOKEN_FILE"
  exit 1
fi

snapshot() { curl -s --max-time 3 "${BASE}/status${AUTH}"; }

permission_event() {
  local session="$1"
  printf '{"hook_event_name":"PermissionRequest","session_id":"%s","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo smoke"},"permission_suggestions":[]}' "$session"
}

cleanup_children() {
  [ -n "${C1:-}" ] && kill "$C1" 2>/dev/null
  [ -n "${C2:-}" ] && kill "$C2" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup_children EXIT

if ! snapshot | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "Claude Dispatch 没有响应 ${BASE}/status，请先启动 App。"
  exit 1
fi

# 1. 鉴权
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${BASE}/status")
[ "$code" = "401" ] && pass "无 token 访问 /status 返回 401" || fail_test "无 token 应返回 401" "got $code"

# 2. 活动流：2xx 空 body，不产生待处理请求
body=$(curl -s --max-time 3 -X POST "${BASE}/hook${AUTH}&mode=activity" \
  -H 'content-type: application/json' \
  --data '{"hook_event_name":"PreToolUse","session_id":"smoke-activity","cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"echo smoke"}}')
[ -z "$body" ] && pass "活动流返回空 body" || fail_test "活动流应返回空 body" "$body"

# 3. 第一个确认请求：入队并成为当前卡
curl -s --max-time 15 -X POST "${BASE}/hook${AUTH}" -H 'content-type: application/json' \
  --data "$(permission_event smoke-1)" >/dev/null 2>&1 &
C1=$!
sleep 0.8
status=$(snapshot)
echo "$status" | jq -e '.pending_count == 1 and .active.kind == "permission" and .active.session_id == "smoke-1"' >/dev/null \
  && pass "确认请求入队并成为当前卡" \
  || fail_test "确认请求未正确入队" "$status"

# 4. 第二个请求：仍然只有一张卡，但队列里有两个会话（chips=2）
curl -s --max-time 15 -X POST "${BASE}/hook${AUTH}" -H 'content-type: application/json' \
  --data "$(permission_event smoke-2)" >/dev/null 2>&1 &
C2=$!
sleep 0.8
status=$(snapshot)
echo "$status" | jq -e '.pending_count == 2 and (.queue | length == 2)' >/dev/null \
  && pass "两个请求同时排队（chips=2）" \
  || fail_test "第二个请求排队失败" "$status"
echo "$status" | jq -e '[.queue[].session_id] | sort == ["smoke-1", "smoke-2"]' >/dev/null \
  && pass "队列包含两个会话" \
  || fail_test "队列会话不正确" "$status"

# 5. 断连清理：第一个请求的连接断开后自动移除，第二个顶上
kill "$C1" 2>/dev/null
wait "$C1" 2>/dev/null
sleep 1
status=$(snapshot)
echo "$status" | jq -e '.pending_count == 1 and .active.session_id == "smoke-2"' >/dev/null \
  && pass "断连请求自动清理，下一个顶上" \
  || fail_test "断连清理失败" "$status"

kill "$C2" 2>/dev/null
wait "$C2" 2>/dev/null
sleep 1
status=$(snapshot)
echo "$status" | jq -e '.pending_count == 0' >/dev/null \
  && pass "全部断开后队列清空" \
  || fail_test "队列未清空" "$status"

# 6. 可选：--install-hooks 幂等（会重写一次 settings.json，自动备份）
if [ "${1:-}" = "--install-hooks" ]; then
  APP="$HOME/Applications/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch"
  SETTINGS="$HOME/.claude/settings.json"
  if [ -x "$APP" ]; then
    before=$(jq '[.. | objects | select(.url? and ((.url | tostring) | contains("127.0.0.1:18765")))] | length' "$SETTINGS")
    "$APP" --install-hooks >/dev/null
    after=$(jq '[.. | objects | select(.url? and ((.url | tostring) | contains("127.0.0.1:18765")))] | length' "$SETTINGS")
    [ "$before" = "$after" ] \
      && pass "--install-hooks 幂等（hook 数量不变：${after}）" \
      || fail_test "--install-hooks 不幂等" "before=$before after=$after"
  else
    fail_test "--install-hooks 检查" "找不到 $APP"
  fi
fi

if [ "$failures" -gt 0 ]; then
  echo
  echo "$failures 个失败"
  exit 1
fi
echo
echo "全部通过"
