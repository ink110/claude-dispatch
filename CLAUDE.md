# Claude Pulse（任务脉搏）

macOS 菜单栏 + 悬浮确认面板，用于观测多个 Claude Code CLI 会话，并在任务需要确认时主动提醒、直接在浮层里批复或补充信息。

## 核心约定

- 目标用户：同时跑多个 Claude Code 任务的单人用户，非程序员。
- 原生优先：Swift + AppKit，零第三方依赖，不引入 Electron / Python 运行时。
- 本地优先：只绑定 `127.0.0.1`，不联网、无遥测、不读取代码内容之外的隐私数据。
- 可逆：所有对 `~/.claude/settings.json` 的修改必须可一键卸载并自动备份。
- 失败回退：App 未启动、超时或返回非 2xx 时，Claude Code 必须回落到终端原生弹窗，绝不吞掉确认请求。
- 不做「静默批准」：任何自动放行都必须由用户在浮层上显式点击。
- **所有需要用户操作的提醒必须是中文人话**：说清楚「要做什么、有什么影响、你要决定什么」，按钮也是中文动作。原始命令/路径只放在「查看完整命令」里，默认不展示大段代码。
- 提醒必须显眼但不抢键盘焦点：常驻脉搏条 + 确认卡升级（脉冲、声音、抬到最前、移动到鼠标所在屏幕），不改变用户当前输入焦点。

## 目录结构

```
claude-pulse/
  CLAUDE.md              本文件
  README.md              给用户的使用说明（中文）
  Sources/               Swift 源码
    main.swift           进程入口
    AppDelegate.swift    生命周期、组装各模块
    Models.swift         数据模型与会话活动
    HookServer.swift     localhost HTTP hook 服务（决策 + 活动流）
    HookInstaller.swift  hooks 健康检查与 App 内修复
    Humanizer.swift      工具调用 → 中文描述（摘要、影响、动作、风险）
    SessionStore.swift   会话注册表轮询 + 活动流
    RequestCenter.swift  待确认请求队列、提醒升级、超时
    UI/                  脉搏条、菜单栏、状态面板、确认浮层
  Resources/Info.plist   App bundle 配置（LSUIElement）
  scripts/
    build.sh             编译并组装 .app
    install.sh           安装 hooks（幂等、带备份）
    uninstall.sh         移除 hooks
  build/                 构建产物（不提交）
```

## 数据来源

1. **状态**：`~/.claude/sessions/<pid>.json`（Claude Code 自己维护的会话注册表，主来源）。
2. **需要确认**：`PermissionRequest` hook（权限确认、计划批准）。
3. **需要回答**：`PreToolUse` matcher `AskUserQuestion`，返回 `updatedInput.answers`。
4. **在做什么**：`PreToolUse` / `PostToolUse` matcher `*`，URL 带 `mode=activity`；只记录活动，立即放行，不参与权限决策。
5. **完成/空闲**：`Stop`、`Notification` hook。
6. **失效检查**：App 启动时和每 5 分钟检查一次 `~/.claude/settings.json` 是否仍有本项目 hooks；丢失时脉搏条显示「点击修复」。

不要依赖 `~/.claude/jobs/` 和 daemon socket，官方明确不是稳定接口。

## 命名与代码风格

- 文件名、类型名、变量名用英文；UI 文案用中文；代码注释可中文。
- Swift 5 语言模式编译（`-swift-version 5`），避免严格并发检查干扰 AppKit。
- 每个文件职责单一，UI 与传输/状态逻辑分离。
- 不为了跑通而注释报错；先找根因。

## 验证

- 构建：`./scripts/build.sh`
- 安装：`./scripts/install.sh`（会备份 `~/.claude/settings.json`）
- 卸载：`./scripts/uninstall.sh`
- 冒烟：用 `curl` 向 `/hook` 发构造事件，确认浮层出现并能回写 JSON；活动事件用 `?mode=activity`。
- 提醒内容验收：权限卡默认不出现大段代码；中文摘要、影响说明、动作按钮齐全；「查看完整命令」能展开且不误触允许。
- 真实验证：在临时项目里配置 hook，跑交互式 `claude` 触发 `PermissionRequest`；新启动的会话才会加载新 hooks。
