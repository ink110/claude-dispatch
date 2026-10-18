# Claude Pulse（任务脉搏）

macOS 菜单栏小工具：同时盯住多个 Claude Code 会话，在任务需要你确认时主动弹出浮层，直接批复或补充信息，不用切回终端。

不依赖 Claude 账号，用 DeepSeek 等第三方 provider 同样可用；纯本地运行，不联网、无遥测。

## 它解决什么

你同时跑多个 Claude Code 任务时，常见三个问题：

1. 某个任务卡在权限确认，你却没看见，时间白等。
2. Claude 反问你一个问题，你要重新找到那个终端窗口。
3. 想知道「现在到底有几个任务在跑、哪个在等我」。

Claude Pulse 对应给出：

- **常驻脉搏条**：右上角一条常驻提示，显示「几个任务运行中 / 几个请求等你处理 / 谁可能卡住」。可拖动，所有 Space 和全屏应用上都可见。
- **状态面板**：悬停或点击脉搏条展开，按「需要你处理 / 运行中 / 空闲」分组列出所有会话，含项目路径、已运行时长、最近活动、当前在做什么。
- **确认浮层**：权限请求、Claude 提问、计划批准三类场景，直接在弹出的卡片上处理。默认只显示中文描述和你要做的动作，原始命令收在「查看完整命令」里。
- **提醒升级**：确认卡 15 秒未处理会脉冲并再响一次；45 秒会抬到最前，并移动到鼠标所在屏幕；之后最多再提醒 3 次。不会抢键盘焦点。
- **完成提示**：任务结束时右上角出现轻提示，不打断你。
- **失效修复**：cc-switch 重写 settings 导致 hooks 丢失时，脉搏条会显示「点击修复」，点一下即可恢复。

## 安装

```bash
cd ~/Desktop/claude-pulse
./scripts/install.sh
```

脚本会：

1. 编译 App 并装到 `~/Applications/ClaudePulse.app`
2. 调用 `ClaudePulse --install-hooks`：生成随机 token（`~/.claude-pulse/token`，权限 600）、备份 `~/.claude/settings.json`、幂等写入 hooks
3. 启动 App；首次从 `~/Applications` 启动会默认开启「登录时启动」

要求：macOS 14+、Xcode Command Line Tools（`swiftc`）。不需要 Homebrew 或 jq。

## 使用

- **脉搏条**：常驻右上角，橙点 = 有任务在跑，红点 = 有请求等你，黄字 = 可能卡住。悬停展开会话列表；拖动可换位置，位置会记住。
- **权限确认**：默认只显示中文摘要、影响说明和你要做的动作，例如「删除文件和目录『build/tmp』」「需要你决定：允许这次操作，还是拒绝？」。想核对原文时点「查看完整命令」。
- **Claude 提问**：中文说明 + 问题本身；单选 / 多选直接点，也可以自己输入答案；支持一次多个问题。
- **计划批准**：中文说明 + 计划正文；可以「批准计划」，或填写修改意见后「要求修改」。
- **提醒升级**：确认卡不会自动消失。15 秒脉冲 + 再响一次；45 秒抬到最前并移动到鼠标所在屏幕；之后最多再提醒 3 次。全程不抢键盘焦点。
- **转回终端**：不想在浮层处理时，点右上角「转回终端」或按 Esc，确认会回到终端原生弹窗。
- **打开任务**：点任意任务卡片都会打开对应终端。后台任务在 Terminal 新窗口执行 `claude attach <id>`；交互式会话把 Terminal 切到前台（授予自动化权限后会精确选中对应标签页）；已结束的任务用 `claude --resume` 恢复历史对话。
- **等待输入**：终端自己在等输入、但 App 没有卡片可展示时（例如 hook 连接已断开），任务显示橙色「等待输入」，不计入红色「请求等你处理」；点卡片可直接进入该会话。
- **可能卡住**：会话处于运行中、但 5 分钟没有任何工具活动时，会标成「可能卡住」，只提示，不自动干预。

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
  ├─ claude agents --json  ──每 5 秒──> 脉搏条 / 状态面板（主数据源）
  │    └─ 连续失败 → 降级读 ~/.claude/sessions/<pid>.json（脉搏条黄点）
  └─ hooks ──HTTP POST──> 127.0.0.1:18765 ──> 浮层 ──> 返回 allow / deny / 答案
       └─ PreToolUse / PostToolUse（mode=activity）──> 活动流（当前工具、命令摘要、最近活动）
```

使用的 hook 事件：

| 事件 | 作用 |
|---|---|
| `PermissionRequest` | 权限确认、计划批准；浮层阻塞等待你的选择 |
| `PreToolUse`（`AskUserQuestion`） | 回答问题，返回 `updatedInput.answers` |
| `PreToolUse` / `PostToolUse`（`*`，`mode=activity`） | 记录「正在做什么」，只记录、不决策，2 秒超时 |
| `Stop` | 一轮回复结束；只更新活动，不弹提示 |
| `Notification`（`idle_prompt` / `agent_needs_input`） | 等你输入时提示 |
| `Notification`（`agent_completed`） | 后台任务真正完成时弹轻提示 |
| `SessionStart` / `SessionEnd` | 刷新状态；SessionEnd 进入「最近完成」列表（保留 10 分钟） |

活动流与决策使用不同的 URL（`mode=activity`），避免同一个事件被处理两次。

设计约束：

- 服务只绑定 `127.0.0.1`，每个请求校验 token。
- 不会静默批准任何操作；「以后都允许」也必须由你点击。
- 不读取对话内容；状态优先来自官方 `claude agents --json`，注册表只做降级。
- **交互式会话**：App 未启动、超时（默认 600 秒）或返回非 2xx 时，Claude Code 自动回落到终端原生确认。
- **后台会话**：没有可回落的终端，卡片永不自动超时；显示「在终端打开」，点击后先释放 hook 再 `claude attach`，不会把任务静默拒绝。
- 多个请求同时到达时只显示一张卡，头部 chips 可切换；每个请求保留自己的已填内容。

## 常见问题

**为什么新功能对正在跑的会话不生效？**
Claude Code 在会话启动时读取 hooks。安装或修复后，新启动的会话会使用新的活动流和提醒；已经在跑的会话需要重启（或在下次启动时）才会生效。

**改完 cc-switch 的 provider 后不弹了？**
cc-switch 可能重写 `~/.claude/settings.json`，把 hooks 清掉。脉搏条会显示「点击修复」，点一下即可；也可以重新执行 `./scripts/install.sh`（幂等）。

**点了交互式任务只切到 Terminal，没选中对应标签页？**
精确选中标签页需要「控制终端」的自动化权限：系统设置 → 隐私与安全性 → 自动化 → 允许 Claude Pulse 控制「终端」。未授权时只会把终端切到前台；后台任务的 `claude attach` 不受影响。

**端口被占用？**
默认端口 18765。关闭另一个 Claude Pulse 实例后再启动。

**浮层一直没出现，但终端在等？**
确认 App 正在运行：菜单栏应有脉搏图标。如果 App 没运行，hook 连接失败会自动回落到终端，不会卡住任务。

**想调整无人响应后的回退时间？**
从终端启动 App 时设置环境变量，例如：

```bash
CLAUDE_PULSE_TIMEOUT=120 ~/Applications/ClaudePulse.app/Contents/MacOS/ClaudePulse
```

## 登录自启与调试

- **登录时启动**：首次从 `~/Applications` 启动会默认注册；之后可在状态面板底部用「登录时启动」开关控制。
- **调试日志**：默认关闭。需要排障时用 `CLAUDE_PULSE_DEBUG=1` 启动 App，或 `open -a ClaudePulse --args --debug`；日志写入 `~/.claude-pulse/debug.log`，超过 1MB 自动清空。

## 开发

```bash
./scripts/build.sh          # 编译并组装 build/ClaudePulse.app
./scripts/test-humanizer.sh # Humanizer 纯函数测试
./scripts/smoke.sh          # curl + /status 冒烟测试（App 需在运行）
```

源码结构见 `CLAUDE.md`。Swift + AppKit，零第三方依赖。

## 边界

- 只覆盖「工具调用需要的信息」：权限、Claude 的提问、计划批准。任务空闲时想凭空给 Claude 发一条消息，不在本工具范围内。
- 同一时间只显示一张确认卡片，多个请求按到达顺序排队；卡片头部 chips 可切换，切换不丢已填内容。
- `AskUserQuestion` 的回答格式是官方 hook 协议；DeepSeek 模型是否调用这个工具取决于它自己的行为。
- **计划批准是尽力而为**：当前 Claude Code 版本里，`ExitPlanMode` 的确认有时由终端 TUI 自己处理（「Ready to code?」），不经过 hook；这种情况下仍回落到终端，浮层不会出现。权限确认和提问不受影响。本工具已经注册了官方的 `PreToolUse → ExitPlanMode` 钩子，在会走 hook 的版本/模式里可直接在浮层批准。
