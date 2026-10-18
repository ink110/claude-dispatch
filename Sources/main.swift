import AppKit
import Foundation

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// CLI 模式：不启动 App，只做 hooks 安装/卸载（install.sh 调用，保证配置只有这一份实现）。
let flags = Set(CommandLine.arguments.dropFirst())

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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
