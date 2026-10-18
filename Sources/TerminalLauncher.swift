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
    private static let stateLock = NSLock()
    private static var automationAllowed = false

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
            queue.async {
                focusTerminalTab(forPID: pid, sessionId: sessionId, name: name, cwd: cwd)
            }
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

    /// 直接执行 AppleScript 精确聚焦对应标签页。
    /// 不用 AEDeterminePermissionToAutomateTarget 预检：首次授权或待授权时它会无限阻塞。
    /// 已授权时立即生效；未授权时由系统弹授权框或返回错误，且全程在后台队列，不卡 UI。
    private static func focusTerminalTab(
        forPID pid: Int32,
        sessionId: String?,
        name: String,
        cwd: String
    ) {
        debugLog("terminal: focusing pid \(pid)")
        guard let tty = ttyForPID(pid) else {
            debugLog("terminal: no tty for pid \(pid)")
            return
        }
        debugLog("terminal: tty for pid \(pid) = \(tty)")
        permissionQueue.async {
            let found = focusTab(tty: tty)
            guard !found else { return }

            // 会话跑在 Terminal 之外（如远程 tmux）：无法选中标签页，
            // 改为新开终端恢复该会话，保证点卡片仍能进入对应对话。
            guard let sessionId, !sessionId.isEmpty else { return }
            debugLog("terminal: no tab for tty \(tty), resuming session")
            openCommand("claude --resume \(sessionId)", title: name, cwd: cwd)
        }
    }

    private static func focusTab(tty: String) -> Bool {
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
                            return "found"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
        end timeout
        """
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            debugLog("terminal: focus tab error: \(errorInfo)")
            return false
        }
        let found = result?.stringValue == "found"
        debugLog(found ? "terminal: focused tty \(tty)" : "terminal: no tab for tty \(tty)")
        return found
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

    /// 主动触发系统「控制终端」授权弹窗（排障/首次授权用）。
    @discardableResult
    static func requestAutomationPermission() -> OSStatus {
        // 真实 Apple Event 最容易触发系统授权框；preflight API 在部分系统版本上不弹窗。
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Terminal\" to get name"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        debugLog("terminal: automation probe exit=\(process.terminationStatus)")

        var status = automationPermission(ask: false)
        debugLog("terminal: automation status after probe=\(status)")
        if status != noErr {
            status = automationPermission(ask: true)
            debugLog("terminal: automation request status=\(status)")
        }
        if status == noErr {
            setAutomationAllowed(true)
        }
        return status
    }

    private static func isAutomationAllowed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return automationAllowed
    }

    private static func setAutomationAllowed(_ value: Bool) {
        stateLock.lock()
        automationAllowed = value
        stateLock.unlock()
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
