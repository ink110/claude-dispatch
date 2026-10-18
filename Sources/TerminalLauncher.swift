import AppKit

/// 把任务送进终端：
/// - 点击任务卡片 → 在 Terminal 里执行 `claude attach <短 id>`，直接进入该任务；
/// - 如果 Terminal 里已经有 `claude agents` 窗口，就在同一个窗口新开一个标签页；
/// - 进入任务后，Claude Code 原生支持按 ← 回到 agents 列表。
enum TerminalLauncher {
    /// AppleScript 和 ps 都可能卡住（Terminal 无响应、等待自动化授权），
    /// 一律放到后台串行队列，避免主线程冻结导致面板点不动。
    private static let queue = DispatchQueue(label: "com.claudepulse.terminal", qos: .userInitiated)

    static func openTask(attachId: String?, name: String) {
        debugLog("openTask attachId=\(attachId ?? "nil") name=\(name)")
        guard let attachId, !attachId.isEmpty else {
            DispatchQueue.main.async { activateTerminal() }
            return
        }

        let safeId = attachId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeId.isEmpty else {
            DispatchQueue.main.async { activateTerminal() }
            return
        }

        queue.async {
            openInTerminal(command: "claude attach \(safeId)", title: name)
        }
    }

    private static func openInTerminal(command: String, title: String) {
        let commandLiteral = appleScriptLiteral(command)
        let titleLiteral = appleScriptLiteral(title)
        let agentsTTY = findAgentsTTY()

        let targetScript: String
        if let agentsTTY {
            targetScript = """
            set targetWindow to missing value
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(appleScriptLiteral(agentsTTY)) then
                        set targetWindow to w
                        exit repeat
                    end if
                end repeat
                if targetWindow is not missing value then exit repeat
            end repeat
            """
        } else {
            targetScript = "set targetWindow to missing value"
        }

        let script = """
        with timeout of 10 seconds
            tell application "Terminal"
                activate
                \(targetScript)
                if targetWindow is not missing value then
                    set index of targetWindow to 1
                    set newTab to do script \(commandLiteral) in targetWindow
                else
                    set newTab to do script \(commandLiteral)
                end if
                try
                    set custom title of newTab to \(titleLiteral)
                end try
            end tell
        end timeout
        """

        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            debugLog("terminal script error: \(errorInfo)")
        } else {
            debugLog("terminal script ok: \(String(describing: result))")
        }
    }

    private static func debugLog(_ message: String) {
        pulseLog("terminal: \(message)")
    }

    /// 找到正在运行 `claude agents` 的 tty，用于复用同一个 Terminal 窗口。
    private static func findAgentsTTY() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "tty=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: "claude agents") else { continue }
            let prefix = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tty = prefix.components(separatedBy: .whitespaces).first ?? ""
            if tty.hasPrefix("ttys") {
                return "/dev/" + tty
            }
        }
        return nil
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func activateTerminal() {
        let bundleIDs = [
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty"
        ]
        for id in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }
}
