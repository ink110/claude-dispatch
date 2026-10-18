import AppKit
import ApplicationServices
import Darwin

/// 把任务送进终端：
/// - 后台任务：在 Terminal 新窗口执行 `claude attach <短 id>`，进入任务对话；
/// - 交互式会话：进程还活着时把 Terminal 切到前台，有自动化权限时精确选中对应标签页；
/// - 已结束的交互式会话：用 `claude --resume <完整 id>` 重新打开历史对话。
/// 生成 `.command` 文件交给 Launch Services 打开，不依赖 Apple Events 权限。
enum TerminalLauncher {
    private static let queue = DispatchQueue(label: "com.claudepulse.terminal", qos: .userInitiated)
    private static let permissionQueue = DispatchQueue(label: "com.claudepulse.terminal.permission")
    private static var permissionAsked = false

    static func openTask(
        attachId: String?,
        name: String,
        cwd: String = "",
        isBackground: Bool = true,
        pid: Int32? = nil,
        sessionId: String? = nil,
        resume: Bool = false
    ) {
        debugLog("openTask attachId=\(attachId ?? "nil") bg=\(isBackground) pid=\(pid.map(String.init) ?? "nil") resume=\(resume)")

        // 已结束的任务 attach 不到，改为恢复历史对话。
        if resume, let sessionId, !sessionId.isEmpty {
            queue.async {
                openCommand("claude --resume \(sessionId)", title: name, cwd: cwd)
            }
            return
        }

        if isBackground {
            guard let attachId, let safeId = sanitizedId(attachId) else {
                DispatchQueue.main.async { activateTerminal() }
                return
            }
            queue.async {
                openCommand("claude attach \(safeId)", title: name, cwd: cwd)
            }
            return
        }

        // 交互式会话：还活着就切回它所在的终端窗口。
        if let pid, processAlive(pid) {
            DispatchQueue.main.async { activateTerminal() }
            queue.async { focusTerminalTab(forPID: pid) }
            return
        }

        // 进程已经结束：恢复历史会话，仍停留在对应项目目录。
        if let sessionId, !sessionId.isEmpty {
            queue.async {
                openCommand("claude --resume \(sessionId)", title: name, cwd: cwd)
            }
            return
        }

        DispatchQueue.main.async { activateTerminal() }
    }

    // MARK: - 新终端窗口

    private static func openCommand(_ command: String, title: String, cwd: String) {
        let fm = FileManager.default
        let dir = AppConfig.stateDir.appendingPathComponent("launch", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            debugLog("terminal: create launch dir failed: \(error)")
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        pruneOldScripts(in: dir)

        let url = dir.appendingPathComponent("task-\(UUID().uuidString.prefix(8)).command")
        let safeTitle = title
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        var lines = ["#!/bin/zsh"]
        if !cwd.isEmpty {
            lines.append("cd \(shellQuote(cwd))")
        }
        lines.append("printf '\\033]0;%s\\007' \(shellQuote(safeTitle))")
        lines.append(command)
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            debugLog("terminal: write command failed: \(error)")
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            debugLog("terminal: Terminal.app not found")
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        debugLog("terminal: opening command \(url.lastPathComponent)")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration) { _, error in
            if let error {
                pulseLog("terminal: open command failed: \(error)")
            } else {
                pulseLog("terminal: command opened")
            }
        }
    }

    private static func pruneOldScripts(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files where file.pathExtension == "command" {
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - 交互式会话定位

    /// 只做权限已授予时的精确聚焦；未授权时静默跳过，避免弹窗卡住后台队列。
    private static func focusTerminalTab(forPID pid: Int32) {
        guard let tty = ttyForPID(pid) else {
            debugLog("terminal: no tty for pid \(pid)")
            return
        }

        let permission = automationPermission(ask: false)
        if permission == errAEEventWouldRequireUserConsent || permission == OSStatus(-1744) {
            // 第一次点击交互式任务时向系统申请「控制 Terminal」权限；
            // 放在独立队列里，用户不响应也不会挡住其他任务打开。
            if !permissionAsked {
                permissionAsked = true
                debugLog("terminal: requesting automation permission")
                permissionQueue.async {
                    let result = automationPermission(ask: true)
                    debugLog("terminal: automation permission result=\(result)")
                }
            }
            debugLog("terminal: permission pending, terminal activated only")
            return
        }
        guard permission == noErr else {
            debugLog("terminal: automation denied (\(permission)), terminal activated only")
            return
        }
        let ttyLiteral = appleScriptLiteral(tty)
        let script = """
        with timeout of 5 seconds
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(ttyLiteral) then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
        end timeout
        """
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            debugLog("terminal: focus tab error: \(errorInfo)")
        } else {
            debugLog("terminal: focused tty \(tty)")
        }
    }

    private static func ttyForPID(_ pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // 先读 pipe 再等退出，避免子进程输出填满缓冲区后互相等待。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else { return nil }
        return raw.hasPrefix("/dev/") ? raw : "/dev/" + raw
    }

    private static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private static func automationPermission(ask: Bool) -> OSStatus {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal").aeDesc else {
            return OSStatus(-1)
        }
        return AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, ask)
    }

    private static func sanitizedId(_ value: String) -> String? {
        let safe = value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return safe.isEmpty ? nil : safe
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func activateTerminal() {
        let bundleIDs = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
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

    private static func debugLog(_ message: String) {
        pulseLog("terminal: \(message)")
    }
}
