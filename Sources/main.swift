import AppKit
import Foundation

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// CLI 模式：不启动 App，只做 hooks 安装/卸载（install.sh 调用，保证配置只有这一份实现）。
let flags = Set(CommandLine.arguments.dropFirst())

// 排障开关：`open -a ClaudePulse --args --debug` 也能打开日志。
if flags.contains("--debug") {
    setenv("CLAUDE_PULSE_DEBUG", "1", 1)
}

if flags.contains("--install-hooks") {
    if HookInstaller.install() {
        print("hooks 已写入（幂等，已自动备份）。")
        exit(0)
    } else {
        printErr("hooks 写入失败，请查看 ~/.claude/settings.json 是否可读写。")
        exit(1)
    }
}

if flags.contains("--uninstall-hooks") {
    if HookInstaller.uninstall() {
        print("hooks 已移除（已自动备份）。")
        exit(0)
    } else {
        printErr("hooks 移除失败。")
        exit(1)
    }
}

// 排障：以 App 自身身份验证「打开任务」链路（Terminal 自动化权限等）。
if let index = CommandLine.arguments.firstIndex(of: "--open-attach"),
   CommandLine.arguments.indices.contains(index + 1) {
    TerminalLauncher.openTask(attachId: CommandLine.arguments[index + 1], name: "Claude Pulse 测试")
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    exit(0)
}

// 排障：在真实 App 进程里触发一次「聚焦交互式会话」，验证自动化权限链路。
if let index = CommandLine.arguments.firstIndex(of: "--focus-pid"),
   CommandLine.arguments.indices.contains(index + 1) {
    setenv("CLAUDE_PULSE_FOCUS_PID", CommandLine.arguments[index + 1], 1)
}
if let index = CommandLine.arguments.firstIndex(of: "--focus-session"),
   CommandLine.arguments.indices.contains(index + 1) {
    setenv("CLAUDE_PULSE_FOCUS_SESSION", CommandLine.arguments[index + 1], 1)
}

if let index = CommandLine.arguments.firstIndex(of: "--open-session"),
   CommandLine.arguments.indices.contains(index + 1),
   let pid = Int32(CommandLine.arguments[index + 1]) {
    TerminalLauncher.openTask(
        attachId: nil,
        name: "Claude Pulse 测试",
        isBackground: false,
        pid: pid
    )
    RunLoop.main.run(until: Date().addingTimeInterval(20))
    exit(0)
}

// 排障：以 App 身份主动弹系统「控制终端」授权框，等待用户选择后退出。
if flags.contains("--request-automation") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let status = TerminalLauncher.requestAutomationPermission()
    print("automation-status=\(status)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
