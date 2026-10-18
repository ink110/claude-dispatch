# Claude Dispatch

[English](README.en.md) · 中文

macOS 菜单栏上的 Claude Code 任务调度台：同时盯住多个会话，在任务需要你确认时主动提醒，并让你直接在浮层里批复，不用切回终端。

纯本地运行，不联网、无遥测；不依赖 Claude 账号，用 DeepSeek 等第三方 provider 同样可用。

![权限确认卡](docs/request-card.png)

## 解决什么问题

同时跑多个 Claude Code 任务时，最常见的三个坑：

1. 某个任务卡在权限确认，你没看见，时间白等。
2. Claude 反问你一个问题，你要重新找到那个终端窗口。
3. 想知道「现在到底有几个任务在跑、哪个在等我」。

Claude Dispatch 的做法：

- **常驻状态条**：右上角显示「几个任务运行中 / 几个请求等你处理」。可拖动，所有 Space 和全屏应用上都可见。
- **状态面板**：悬停或点击状态条展开，按「需要你处理 / 运行中 / 空闲」分组列出所有会话，含项目路径、运行时长、最近活动。
- **确认浮层**：权限请求、Claude 提问、计划批准三类场景直接处理。默认只显示中文描述和你要做的动作，原始命令收在「查看完整命令」里。
- **长内容可滚动**：问题很多、命令很长时，卡片自动限制高度，正文滚动，提交/允许按钮始终固定在底部。
- **提醒升级**：15 秒未处理会脉冲并再响一次；45 秒抬到最前，并移动到鼠标所在屏幕。不抢键盘焦点。
- **点卡片回终端**：后台任务用 `claude attach`，交互式会话精确切到对应标签页，已结束的会话用 `claude --resume` 恢复。
- **失效修复**：cc-switch 重写 settings 导致 hooks 丢失时，状态条显示「点击修复」，点一下即可恢复。

![常驻状态条](docs/status-bar.png)

## 系统要求

- macOS 14 Sonoma 或更高
- Apple Silicon 或 Intel（通用二进制）
- 已安装并可使用 [Claude Code](https://claude.com/claude-code)

> v1.0.0 的应用界面为中文。

## 安装

### 下载安装（推荐）

1. 到 [Releases](https://github.com/ink110/claude-dispatch/releases/latest) 下载 `ClaudeDispatch-1.0.0.zip`。
2. 解压，把 `ClaudeDispatch.app` 拖进「应用程序」。
3. **首次打开必须右键 →「打开」**。应用没有 Apple 开发者签名，双击会被 Gatekeeper 拦下。

   如果仍然提示无法打开，到「系统设置 → 隐私与安全性」点「仍要打开」；或在终端执行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/ClaudeDispatch.app
   ```

4. 首次启动会出现引导窗口，点「启用提醒」。正在运行的 Claude Code 会话需要重启后才会加载新 hooks。

也可以校验下载包的 SHA-256（Release 页面会同时提供 `.sha256`）：

```bash
shasum -a 256 -c ClaudeDispatch-1.0.0.zip.sha256
```

### 从源码构建

要求 Xcode Command Line Tools（`swiftc`），不需要 Homebrew、jq 或第三方依赖。

```bash
git clone https://github.com/ink110/claude-dispatch.git
cd claude-dispatch
./scripts/install.sh
```

`install.sh` 会编译通用二进制、安装到 `~/Applications/ClaudeDispatch.app`、写入 hooks（自动备份 `~/.claude/settings.json`）并启动应用。

## 使用

- **状态条**：橙点 = 有任务在跑，红点 = 有请求等你，黄字 = 可能卡住。悬停展开列表；拖动可换位置，位置会记住。
- **权限确认**：显示中文摘要、影响说明和动作按钮；想核对原文时点「查看技术细节」。
- **Claude 提问**：单选 / 多选直接点，也可以自己输入；支持一次多个问题，内容过长时滚动查看。
- **计划批准**：可「批准计划」，或填写修改意见后「要求修改」。
- **转回终端**：点右上角「转回终端」或按 Esc，确认会回到 Claude Code 的原生弹窗。
- **打开任务**：点击任意任务卡片进入对应终端会话。
- **登录时启动**：首次从安装目录启动会默认开启；之后可在状态面板底部关闭。

### 控制「终端」的自动化权限（可选）

点击交互式任务卡片时，精确选中对应的 Terminal 标签页需要「控制终端」权限。未授权时只会把 Terminal 切到前台，`claude attach` 不受影响。

如果授权弹窗没有出现，可主动调出：

```bash
open -n /Applications/ClaudeDispatch.app --args --request-automation
```

## 隐私与安全

- hook 服务只绑定 `127.0.0.1:18765`，所有请求都校验本机随机 token（`~/.claude-dispatch/token`，权限 600）。
- 不联网、无遥测、不上传代码或对话内容。
- 只修改 Claude Code 的 `~/.claude/settings.json` 中的 hooks 字段，每次修改前自动备份（保留最近 5 份）。
- 不会静默批准任何操作；「以后都允许同类操作」也必须由你点击。
- App 未运行、超时或返回错误时，Claude Code 自动回落到终端原生确认，不会把任务卡死。

## 工作原理

```
Claude Code 会话
  ├─ claude agents --json ──每 5 秒──> 状态条 / 状态面板（主数据源）
  │    └─ 连续失败 → 降级读 ~/.claude/sessions/<pid>.json
  └─ hooks ──HTTP POST──> 127.0.0.1:18765 ──> 浮层 ──> 返回 allow / deny / 答案
```

| Hook 事件 | 作用 |
|---|---|
| `PermissionRequest` | 权限确认、计划批准；浮层阻塞等待选择 |
| `PreToolUse`（`AskUserQuestion`） | 回答问题，返回 `updatedInput.answers` |
| `PreToolUse` / `PostToolUse`（`*`，`mode=activity`） | 记录「正在做什么」，只记录、不决策 |
| `Stop` | 一轮回复结束，只更新活动 |
| `Notification` | 等待输入、后台任务完成提醒 |
| `SessionStart` / `SessionEnd` | 刷新状态与「最近完成」列表 |

## 限制

- 只处理需要你决策的环节：权限、提问、计划批准。想让 Claude 凭空开始一个新任务，请回终端。
- 同一时间显示一张确认卡，多个请求排队；卡片顶部 chips 可切换，切换不丢已填内容。
- 「计划批准」是尽力而为：部分 Claude Code 版本/模式下 `ExitPlanMode` 由终端 TUI 自己处理，此时仍回落到终端。
- 应用未公证，首次打开需要右键或手动放行。
- 数据源优先使用官方 `claude agents --json`；Claude Code 大版本升级后接口若有变化，状态条可能显示数据降级。

## 卸载

```bash
# 按实际安装位置调整（下载安装通常在 /Applications，源码安装脚本装在 ~/Applications）
/Applications/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch --uninstall-hooks
```

这会移除全部 Claude Dispatch hooks 并备份 settings。然后把 `ClaudeDispatch.app` 移到废纸篓，并在「系统设置 → 通用 → 登录项」中移除 Claude Dispatch。

## 开发

```bash
./scripts/build.sh          # 编译 arm64 + x86_64 通用二进制
./scripts/test-humanizer.sh # Humanizer 纯函数测试
./scripts/smoke.sh          # curl + /status 冒烟测试（App 需运行）
./scripts/demo-request.sh   # 注入合成的长提问卡，验证滚动与固定按钮
./scripts/package.sh        # 生成 dist/ClaudeDispatch-<version>.zip + SHA-256
```

Swift + AppKit，零第三方依赖。源码结构与设计约定见 [CLAUDE.md](CLAUDE.md)。

## 许可证

[MIT](LICENSE) © 2026 ink

Claude 是 Anthropic 的商标。本项目是独立的社区工具，与 Anthropic 没有隶属或背书关系。
