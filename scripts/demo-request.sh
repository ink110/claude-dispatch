#!/bin/bash
# 注入合成请求，验证确认卡的排版与滚动。不合成鼠标点击，只构造 hook 事件。
# 前置：Claude Dispatch 已在运行（open build/ClaudeDispatch.app）。
# 用法：
#   ./scripts/demo-request.sh                  # 20 个问题的超长提问卡
#   ./scripts/demo-request.sh --questions 40   # 自定义问题数量
#   ./scripts/demo-request.sh --plan           # 超长计划批准卡
#   ./scripts/demo-request.sh --permission     # 多步骤权限确认卡
#   ./scripts/demo-request.sh --permission --steps 5
set -euo pipefail

PORT="${CLAUDE_DISPATCH_PORT:-18765}"
TOKEN_FILE="$HOME/.claude-dispatch/token"
TOKEN="${CLAUDE_DISPATCH_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null || true)}"
BASE="http://127.0.0.1:${PORT}"

COUNT=20
STEPS=30
MODE=question
while [ "$#" -gt 0 ]; do
  case "$1" in
    --questions)
      COUNT="${2:-}"
      shift 2
      ;;
    --steps)
      STEPS="${2:-}"
      shift 2
      ;;
    --plan)
      MODE=plan
      shift
      ;;
    --permission)
      MODE=permission
      shift
      ;;
    *)
      echo "未知参数：$1"
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "缺少 jq，无法构造演示请求。"
  exit 1
fi
if [ -z "$TOKEN" ]; then
  echo "找不到 token：${TOKEN_FILE}（请先启动 Claude Dispatch）"
  exit 1
fi
if ! curl -s --max-time 3 "${BASE}/status?token=${TOKEN}" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "Claude Dispatch 没有响应 ${BASE}/status，请先启动 App。"
  exit 1
fi

case "$MODE" in
  question)
    payload=$(jq -n --argjson count "$COUNT" '{
      hook_event_name: "PreToolUse",
      session_id: "demo-long-question",
      cwd: "/tmp/claude-dispatch-demo",
      tool_name: "AskUserQuestion",
      tool_input: {
        questions: [range(0; $count) | {
          question: ("第 \(. + 1) 个问题：这是一个用来验证超长内容滚动的示例问题。请根据当前项目情况选择最合适的选项，或者直接在下方输入自己的回答。这里故意写得很长，用来模拟真实项目里 Claude 一次追问很多细节的情况。"),
          header: ("问题 \(. + 1)"),
          multiSelect: false,
          options: [
            {label: "选项 A：继续按当前方案推进", detail: "保留现有设计，不再改动"},
            {label: "选项 B：先补充信息再继续", detail: "需要更多上下文才能判断"},
            {label: "选项 C：暂停这个任务", detail: "稍后再回来处理"}
          ]
        }]
      }
    }')
    ;;
  plan)
    payload=$(jq -n '{
      hook_event_name: "PermissionRequest",
      session_id: "demo-long-plan",
      cwd: "/tmp/claude-dispatch-demo",
      tool_name: "ExitPlanMode",
      tool_input: {
        plan: ([range(0; 60) | "## 第 \(. + 1) 步\n\n这是用于验证长计划批准卡滚动效果的内容。每一步都会说明改动范围、风险和验证方式，确保底部「批准计划 / 要求修改」按钮始终固定可见。\n"] | join("\n"))
      },
      permission_suggestions: []
    }')
    ;;
  permission)
    command=$(printf 'echo "step %02d: a deliberately long command for the scrolling demo"\n' $(seq 1 "$STEPS") | paste -sd ';' -)
    payload=$(jq -n --arg command "$command" '{
      hook_event_name: "PermissionRequest",
      session_id: "demo-long-permission",
      cwd: "/tmp/claude-dispatch-demo",
      tool_name: "Bash",
      tool_input: {command: $command},
      permission_suggestions: [{"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "echo"}]}]
    }')
    ;;
esac

echo "已注入演示请求（${MODE}），连接保持中。"
echo "确认卡片出现后按 Ctrl-C 结束演示，请求会自动从队列移除。"

curl -sS --max-time 600 -X POST "${BASE}/hook?token=${TOKEN}" \
  -H 'content-type: application/json' \
  --data "$payload" >/dev/null &
CURL_PID=$!
trap 'kill "$CURL_PID" 2>/dev/null || true' EXIT
wait "$CURL_PID" 2>/dev/null || true
