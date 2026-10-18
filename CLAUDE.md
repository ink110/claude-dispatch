# Claude Pulse（任务脉搏）

macOS 菜单栏 + 悬浮确认面板，用于观测多个 Claude Code CLI 会话，并在任务需要确认时主动提醒、直接在浮层里批复或补充信息。

## 核心约定

- 目标用户：同时跑多个 Claude Code 任务的单人用户，非程序员。
- 原生优先：Swift + AppKit，零第三方依赖，不引入 Electron / Python 运行时。
- 本地优先：只绑定 `127.0.0.1`，不联网、无遥测、不读取代码内容之外的隐私数据。
- 可逆：所有对 `~/.claude/settings.json` 的修改必须可一键卸载并自动备份。
- 失败回退：App 未启动、超时或返回非 2xx 时，Claude Code 必须回落到终端原生弹窗，绝不吞掉确认请求。
- 不做「静默批准」：任何自动放行都必须由用户在浮层上显式点击。

## 目录结构

```
claude-pulse/
  CLAUDE.md              本文件
  README.md              给用户的使用说明（中文）
  Sources/               Swift 源码
    main.swift           进程入口
    AppDelegate.swift    生命周期、组装各模块
    Models.swift         数据模型
    HookServer.swift     localhost HTTP hook 服务
    SessionStore.swift   会话注册表轮询
    RequestCenter.swift  待确认请求队列与超时
    UI/                  菜单栏、状态面板、确认浮层
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
4. **完成/空闲**：`Stop`、`Notification` hook。

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
- 冒烟：用 `curl` 向 `/hook` 发构造事件，确认浮层出现并能回写 JSON。
- 真实验证：在临时项目里配置 hook，跑 `claude -p` 触发 `PermissionRequest`。
