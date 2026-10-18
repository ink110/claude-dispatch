# Claude Dispatch（任务调度台）

macOS 菜单栏 + 悬浮确认面板，用于观测多个 Claude Code CLI 会话，并在任务需要确认时主动提醒、直接在浮层里批复或补充信息。

公开版本：v1.1.0，MIT 许可证，仓库名 `claude-dispatch`；分发形态为通用二进制 `.app` + zip（ad-hoc 签名，不公证）。

## 核心约定

- 目标用户：同时跑多个 Claude Code 任务的单人用户，非程序员。
- 原生优先：Swift + AppKit，零第三方依赖，不引入 Electron / Python 运行时。
- 本地优先：只绑定 `127.0.0.1`，不联网、无遥测、不读取代码内容之外的隐私数据。
- 可逆：所有对 `~/.claude/settings.json` 的修改必须可一键卸载并自动备份。
- 失败回退：App 未启动、超时或返回非 2xx 时，Claude Code 必须回落到终端原生弹窗，绝不吞掉确认请求。
- 不做「静默批准」：任何自动放行都必须由用户在浮层上显式点击。
- **所有需要用户操作的提醒必须是中文人话**：说清楚「要做什么、有什么影响、你要决定什么」，按钮也是中文动作。原始命令/路径只放在「查看完整命令」里，默认不展示大段代码。
- 提醒必须显眼但不抢键盘焦点：常驻状态条 + 确认卡升级（脉冲、声音、抬到最前、移动到鼠标所在屏幕），不改变用户当前输入焦点。
- 点击任意任务卡片必须打开对应终端会话：后台任务用 `claude attach`，交互式会话激活 Terminal（有自动化权限时按 tty 精确选中标签页），已完成会话用 `claude --resume`。终端启动走 `.command` + Launch Services，不把 Automation 权限当必需依赖。

## 目录结构

```
claude-dispatch/
  CLAUDE.md              本文件
  README.md              用户说明（中文）
  README.en.md           用户说明（英文）
  LICENSE                MIT
  CHANGELOG.md           版本记录
  SECURITY.md            安全模型与漏洞报告方式
  Sources/               Swift 源码
    main.swift           进程入口
    AppDelegate.swift    生命周期、组装各模块
    Models.swift         数据模型与会话活动
    HookServer.swift     localhost HTTP hook 服务（决策 + 活动流 + GET /status）
    HookInstaller.swift  hooks 安装/卸载/健康检查（唯一实现）
    Humanizer.swift      工具调用 → 中文描述（摘要、影响、动作、风险）
    TaskStore.swift      `claude agents --json` 主数据源 + 注册表降级 + 最近完成
    SessionStore.swift   会话注册表轮询 + 活动流 + 最近完成列表
    TerminalLauncher.swift 任务卡片 → 终端：attach / 激活标签页 / resume
    DebugLog.swift       CLAUDE_DISPATCH_DEBUG 门控的调试日志
    RequestCenter.swift  请求队列、chips 切换、每请求超时/提醒、/status 快照
    UI/                  状态条、菜单栏、状态面板、确认浮层、首次启动引导
  Resources/
    Info.plist           App bundle 配置（LSUIElement，版本号唯一来源）
    AppIcon.icns         应用图标（由 scripts/make-icon.sh 生成）
  scripts/
    build.sh             编译 arm64 + x86_64 并组装 .app
    install.sh           编译 + 安装 App + 调 `ClaudeDispatch --install-hooks`
    uninstall.sh         调 `ClaudeDispatch --uninstall-hooks`，无 jq 依赖
    package.sh           构建 + `dist/ClaudeDispatch-<version>.zip` + SHA-256
    make-icon.sh         生成 AppIcon.icns
    test-humanizer.sh    Humanizer 纯函数测试（复合命令/进程/敏感路径）
    smoke.sh             curl + /status 冒烟测试（不合成鼠标点击）
    demo-request.sh      注入合成确认卡（长问题/长计划/多步权限）
  docs/                  README 截图（状态条各状态、状态面板、三类确认卡、首次引导）
  build/                 构建产物（不提交）
  dist/                  发布包（不提交）
```

## 数据来源

1. **状态主源**：`claude agents --json`（**不加 `--all`**）每 5 秒轮询。官方支持的外部读取接口，含 attach 短 id、kind、status/waitingFor、state。
2. **降级备胎**：`claude agents` 连续 2 次失败 → 改读 `~/.claude/sessions/<pid>.json` 注册表；状态条黄点提示「数据降级」。
3. **严格过滤**：`pid == nil && status == nil` 的僵尸记录直接隐藏。红色 `needsInput` 只来自 hook 队列里存活的请求；`waitingFor != nil` 但没有存活卡片的标为橙色 `waitingInput`，不计入「请求等你处理」。`status == "waiting"` 单独不算。
4. **最近完成**：内存保留 10 分钟，由 `SessionEnd` / `Notification: agent_completed` 驱动。`Stop` 只表示「一轮回复结束」，只更新活动、不弹提示。
5. **需要确认**：`PermissionRequest` hook（权限确认、计划批准）。
6. **需要回答**：`PreToolUse` matcher `AskUserQuestion`，返回 `updatedInput.answers`。
7. **在做什么**：`PreToolUse` / `PostToolUse` matcher `*`，URL 带 `mode=activity`；只记录活动，立即放行，不参与权限决策；注册表刷新 debounce 0.5s。
8. **失效检查**：App 启动时和每 5 分钟检查一次 `~/.claude/settings.json`；决策 hooks 缺失或 token 不一致 = 红「点击修复」，活动流缺失 = 黄点。
9. **排障**：`GET /status?token=…` 返回队列/活动请求/会话/健康快照（状态迁移时原子生成）。

不要依赖 `~/.claude/jobs/` 和 daemon socket，官方明确不是稳定接口。

## 兼容性

`onFailure: "block"` 需要 Claude Code ≥ 2.1.295；当前本机版本按「hook 失败 = 非阻塞回落」设计：交互式会话回终端原生提示，`-p` 任务视为拒绝，agent view 后台任务进入 blocked 等待。不要假设 App 挂掉时 hook 会 block。

## 命名与代码风格

- 文件名、类型名、变量名用英文；UI 文案用中文；代码注释可中文。
- Swift 5 语言模式编译（`-swift-version 5`），避免严格并发检查干扰 AppKit。
- 每个文件职责单一，UI 与传输/状态逻辑分离。
- 不为了跑通而注释报错；先找根因。

## UI 规范（对齐 Apple HIG）

- 所有颜色、圆角、字号、分割线从 `Sources/UI/Theme.swift` 取，不在各视图里散落硬编码。
- 面板使用标准材质（`NSVisualEffectView` + `.popover`）。**不要在材质上叠白底卡片**：列表行默认透明，悬停/选中才用 `Theme.fill` / `Theme.hoverFill`。
- **不要画黑色描边**：面板无边框；分割线统一用 `Theme.hairline`（`labelColor` 9%），不再用 `separatorColor` 直接画线。唯一的边框是红色升级提醒，且只短暂出现。
- 透明无边框窗口一律 `hasShadow = false`：系统窗口阴影会沿矩形窗口边缘画出一圈深色线，看起来就是黑色描边。
- 软阴影统一由 `WindowShadow` 的独立透明窗口承载（圆角 `shadowPath`，随主面板移动/缩放）。不要重新打开 `NSWindow.hasShadow`。
- 材质圆角必须用 `RoundedEffectView` 的 `maskImage` 裁切；只设 `layer.cornerRadius` 会留下方形材质，形成「尖角上叠圆角」。
- 图标统一用 SF Symbols（Apple 官方图标库），菜单栏用模板图标；状态图标 16–18pt、中等字重（展开面板 18pt）。
- macOS 正文字号 13pt，辅助 11–12pt，最小 10pt；不再出现 9.5pt 以下文字。
- 动效必须克制并尊重「减弱动态效果」：面板出现 0.16s 淡入，状态图标切换 0.15s 淡入淡出；旋转/脉冲在开启减弱动态时停用。
- 状态语义不能只靠颜色：选项行同时用圆形指示器的形状和颜色表达选中态。

## 验证

- 构建：`./scripts/build.sh`（应输出 `Architectures: x86_64 arm64`）
- 单元测试：`./scripts/test-humanizer.sh`
- 安装：`./scripts/install.sh`（App + hooks 一次装好，自动备份 settings.json）
- 冒烟：`./scripts/smoke.sh`（需要 App 已启动；用 `/status` 断言入队、双请求、断连清理）
- 长内容：`./scripts/demo-request.sh --questions 20`，截图确认正文滚动、底部按钮固定；`--permission --steps 5` 验证多行 footer。
- 首次启动：`open -n build/ClaudeDispatch.app --args --show-onboarding`，截图确认引导窗口与 hook 状态。
- 悬浮状态面板：`CLAUDE_DISPATCH_SHOW_FLOATING_STATUS=1 build/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch`，截图确认真圆角、无描边、状态图标 18pt。
- 截图/文档数据：`CLAUDE_DISPATCH_DEMO_AGENTS=<agents.json> CLAUDE_DISPATCH_SHOW_FLOATING_STATUS=1 build/ClaudeDispatch.app/Contents/MacOS/ClaudeDispatch`，用固定演示会话展示各状态，不读取本机真实会话。锁屏时 `screencapture -l <windowid> -o` 仍可截取单个窗口。
- 打包：`./scripts/package.sh`，检查 zip 只含 `.app`、无备份/token，并记录 SHA-256。
- 卸载：`./scripts/uninstall.sh`（无 jq 依赖，走 `--uninstall-hooks`）
- 提醒内容验收：权限卡默认不出现大段代码；中文摘要、影响说明、动作按钮齐全；「查看完整命令」能展开且不误触允许。
- UI 验收只看截图（`screencapture`），**不合成鼠标点击**；快捷键必须点击卡片后才生效。
- 发布前扫描：`git grep -nE 'sk-[A-Za-z0-9]{10,}|@inkdeMac'` 应无结果；`git grep -n '/Users/' -- ':!CLAUDE.md'` 只应命中测试里的 `/Users/example`。
- 真实验证：在临时项目里配置 hook，跑交互式 `claude` 触发 `PermissionRequest`；新启动的会话才会加载新 hooks。
- 自动化权限：`open -n ~/Applications/ClaudeDispatch.app --args --request-automation` 主动调出「控制终端」授权框（首次授权或排障用）。
- 终端聚焦：`open ~/Applications/ClaudeDispatch.app --args --focus-pid <pid>` 在真实 App 进程里触发一次标签页聚焦，配合 `~/.claude-dispatch/debug.log` 断言 `focused tty`。
- 调试日志默认关闭；`CLAUDE_DISPATCH_DEBUG=1` 开启，写入 `~/.claude-dispatch/debug.log`，超过 1MB 自动清空。
