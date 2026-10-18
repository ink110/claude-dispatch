# Claude Pulse（任务脉搏）

macOS 菜单栏小工具：同时盯住多个 Claude Code 会话，在任务需要你确认时主动弹出浮层，直接批复或补充信息，不用切回终端。

不依赖 Claude 账号，用 DeepSeek 等第三方 provider 同样可用；纯本地运行，不联网、无遥测。

## 它解决什么

你同时跑多个 Claude Code 任务时，常见三个问题：

1. 某个任务卡在权限确认，你却没看见，时间白等。
2. Claude 反问你一个问题，你要重新找到那个终端窗口。
3. 想知道「现在到底有几个任务在跑、哪个在等我」。

Claude Pulse 对应给出：

- **菜单栏**：橙色数字 = 运行中的任务数；红色铃铛 + 数字 = 有请求等你处理。
- **状态面板**：点菜单栏图标，按「需要你处理 / 运行中 / 空闲」分组列出所有会话，含项目路径、会话类型、状态。
- **确认浮层**：权限请求、Claude 提问、计划批准三类场景，直接在弹出的卡片上处理。
- **完成提示**：任务结束时右上角出现轻提示，不打断你。

## 安装

```bash
cd ~/Desktop/claude-pulse
./scripts/install.sh
```

脚本会：

1. 编译 App 并装到 `~/Applications/ClaudePulse.app`
2. 生成随机 token（`~/.claude-pulse/token`，权限 600）
3. 备份 `~/.claude/settings.json`，再幂等写入 hooks
4. 启动 App

要求：macOS 14+、Xcode Command Line Tools（`swiftc`）。不需要 Homebrew。

## 使用

- **权限确认**：浮层显示工具名和完整命令。可选「拒绝」「允许」，以及「以后都允许同类操作」（会把 Claude Code 建议的权限规则写进设置）。
- **Claude 提问**：单选 / 多选问题直接点选，也可以自己输入答案；支持一次多个问题。
- **计划批准**：显示计划正文；可以「批准」，或填写修改意见后「要求修改」。
- **转回终端**：不想在浮层处理时，点右上角「转回终端」或按 Esc，确认会回到终端原生弹窗。
- **跳到会话**：状态面板里点某一行，后台任务会在 Terminal 里执行 `claude attach <id>`；交互式会话会尝试激活终端窗口。

### 为什么有些命令不弹确认

Claude Code 当前的默认权限模式是 `auto`（分类器自动批准），加上你的 `permissions.allow` 里有 `Bash(*)`，大部分命令不会进入确认流程。

- 想让写操作都经过你：在 Claude Code 里用 `Shift+Tab` 切到 **Manual**。
- 想只拦高风险命令：在 `~/.claude/settings.json` 的 `permissions.ask` 里加规则，例如：

```json
{
  "permissions": {
    "ask": [
      "Bash(rm *)",
      "Bash(git push *)",
      "Bash(git reset --hard *)"
    ]
  }
}
```

规则语法是 `Bash(命令前缀 *)`，`*` 匹配任意后续内容。ask 规则优先于 allow。

## 卸载

```bash
cd ~/Desktop/claude-pulse
./scripts/uninstall.sh
```

只移除 Claude Pulse 写入的 hooks，并备份当前设置。App 仍在 `~/Applications/ClaudePulse.app`，手动移到废纸篓即可。

## 工作原理

```
Claude Code 会话
  ├─ ~/.claude/sessions/<pid>.json  ──轮询──> 状态面板（会话、状态、cwd、名称）
  └─ hooks ──HTTP POST──> 127.0.0.1:18765 ──> 浮层 ──> 返回 allow / deny / 答案
```

使用的 hook 事件：

| 事件 | 作用 |
|---|---|
| `PermissionRequest` | 权限确认、计划批准；浮层阻塞等待你的选择 |
| `PreToolUse`（`AskUserQuestion`） | 回答问题，返回 `updatedInput.answers` |
| `Stop` | 任务完成轻提示 |
| `Notification`（`idle_prompt` / `agent_needs_input`） | 等你输入时提示 |
| `SessionStart` / `SessionEnd` | 触发状态刷新 |

设计约束：

- 服务只绑定 `127.0.0.1`，每个请求校验 token。
- App 未启动、超时（默认 600 秒）或返回非 2xx 时，Claude Code 自动回落到终端原生确认，不会吞掉请求。
- 不会静默批准任何操作；「以后都允许」也必须由你点击。
- 不读取对话内容；状态来自 Claude Code 自己维护的会话注册表。

## 常见问题

**改完 cc-switch 的 provider 后不弹了？**
cc-switch 可能重写 `~/.claude/settings.json`，把 hooks 清掉。重新执行 `./scripts/install.sh` 即可（幂等）。

**端口被占用？**
默认端口 18765。关闭另一个 Claude Pulse 实例后再启动。

**浮层一直没出现，但终端在等？**
确认 App 正在运行：菜单栏应有脉搏图标。如果 App 没运行，hook 连接失败会自动回落到终端，不会卡住任务。

**想调整无人响应后的回退时间？**
从终端启动 App 时设置环境变量，例如：

```bash
CLAUDE_PULSE_TIMEOUT=120 ~/Applications/ClaudePulse.app/Contents/MacOS/ClaudePulse
```

## 开发

```bash
./scripts/build.sh     # 编译并组装 build/ClaudePulse.app
```

源码结构见 `CLAUDE.md`。Swift + AppKit，零第三方依赖。

## 边界

- 只覆盖「工具调用需要的信息」：权限、Claude 的提问、计划批准。任务空闲时想凭空给 Claude 发一条消息，不在本工具范围内。
- 同一时间只显示一张确认卡片，多个请求按到达顺序排队，避免多窗口干扰。
- `AskUserQuestion` 的回答格式是官方 hook 协议；DeepSeek 模型是否调用这个工具取决于它自己的行为。
- **计划批准是尽力而为**：当前 Claude Code 版本里，`ExitPlanMode` 的确认有时由终端 TUI 自己处理（「Ready to code?」），不经过 hook；这种情况下仍回落到终端，浮层不会出现。权限确认和提问不受影响。本工具已经注册了官方的 `PreToolUse → ExitPlanMode` 钩子，在会走 hook 的版本/模式里可直接在浮层批准。
