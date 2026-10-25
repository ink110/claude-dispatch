import AppKit
import ApplicationServices
import Darwin

/// 把任务送进终端：
/// - 后台任务：已经 attach 过的，直接定位到那个 Terminal 标签页；没有才新开窗口执行 `claude attach <短 id>`；
/// - 交互式会话：进程还活着时把 Terminal 切到前台，有自动化权限时精确选中对应标签页；
/// - 已结束的交互式会话：已经 resume 过的直接定位，否则用 `claude --resume <完整 id>` 打开历史对话。
/// 新开窗口走 `.command` 文件交给 Launch Services，不依赖 Apple Events 权限；
/// 只有「精确定位标签页」需要一次性的「控制 Terminal」授权。
enum TerminalLauncher {
    private static let queue = DispatchQueue(label: "com.ink.claudedispatch.terminal", qos: .userInitiated)
    private static let permissionQueue = DispatchQueue(label: "com.ink.claudedispatch.terminal.permission")
    private static let stateLock = NSLock()
    private static var automationAllowed = false
    private static var automationConsentRequested = false

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
                // 之前已经恢复过的窗口先定位过去，不重复开新窗口。
                if focusExistingWindow(claudeArgs: ["--resume", sessionId]) { return }
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
                // 这个任务已经 attach 在某个终端窗口里时，直接切过去。
                if focusExistingWindow(claudeArgs: ["attach", safeId]) { return }
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
                if focusExistingWindow(claudeArgs: ["--resume", sessionId]) { return }
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
            debugLog("create launch dir failed: \(error)")
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
            debugLog("write command failed: \(error)")
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            debugLog("Terminal.app not found")
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        debugLog("opening command \(url.lastPathComponent)")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration) { _, error in
            if let error {
                dispatchLog("terminal: open command failed: \(error)")
            } else {
                dispatchLog("terminal: command opened")
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

    private enum FocusResult {
        case focused
        case notFound
        case failed
    }

    /// 直接执行 AppleScript 精确聚焦对应标签页。
    /// 全程在后台队列，不卡 UI；子进程有硬超时，终端无响应也不会拖住后续点击。
    private static func focusTerminalTab(
        forPID pid: Int32,
        sessionId: String?,
        name: String,
        cwd: String
    ) {
        debugLog("focusing pid \(pid)")
        guard let tty = ttyForPID(pid) else {
            debugLog("no tty for pid \(pid)")
            return
        }
        debugLog("tty for pid \(pid) = \(tty)")
        permissionQueue.async {
            switch focusTab(tty: tty) {
            case .focused:
                return
            case .failed:
                // 多半是还没给「控制 Terminal」权限：先把终端带到前台，并只弹一次授权框。
                DispatchQueue.main.async { activateTerminal() }
                requestAutomationConsentOnce()
                return
            case .notFound:
                break
            }

            // 会话跑在 Terminal 之外（如远程 tmux）：无法选中标签页，
            // 改为恢复该会话；如果之前已经恢复过，先定位到那个窗口。
            guard let sessionId, !sessionId.isEmpty else { return }
            debugLog("no tab for tty \(tty), resuming session")
            if focusExistingWindow(claudeArgs: ["--resume", sessionId]) { return }
            openCommand("claude --resume \(sessionId)", title: name, cwd: cwd)
        }
    }

    /// 用独立 `osascript` 子进程执行聚焦，不用进程内 NSAppleScript：
    /// 后者在后台线程发送 Apple Event 会一直阻塞（实测 >15s 不返回），把整个队列卡死。
    /// 子进程可以按超时强杀，未授权或终端无响应时最多等 4 秒。
    private static func focusTab(tty: String) -> FocusResult {
        let ttyLiteral = appleScriptLiteral(tty)
        let script = """
        with timeout of 3 seconds
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else {
            debugLog("focus tab: osascript failed to launch")
            return .failed
        }
        if finished.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            debugLog("focus tab: timed out for tty \(tty)")
            return .failed
        }
        guard process.terminationStatus == 0 else {
            debugLog("focus tab: osascript exit=\(process.terminationStatus) for tty \(tty)")
            return .failed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if output == "found" {
            debugLog("focused tty \(tty)")
            return .focused
        }
        debugLog("no tab for tty \(tty)")
        return .notFound
    }

    // MARK: - 已有任务窗口

    /// 在正在运行的进程里找到这个任务已经打开的终端会话（`attach` / `--resume`），
    /// 直接把对应 Terminal 标签页切到前台。找不到返回 false，由调用方新开窗口。
    /// 找到了但选不中标签页（未授权自动化、终端正忙）时只把终端激活到前台，
    /// 不再开第二个同样的窗口——重复窗口比手动找标签页更让人困惑。
    private static func focusExistingWindow(claudeArgs: [String]) -> Bool {
        guard let tty = existingTTY(claudeArgs: claudeArgs) else { return false }
        debugLog("existing window for \(claudeArgs.joined(separator: " ")) at \(tty)")
        switch focusTab(tty: tty) {
        case .focused:
            return true
        case .notFound:
            // 标签页不在 Terminal（可能在 iTerm2 等）：激活对应终端，不再开重复窗口。
            DispatchQueue.main.async { activateTerminal() }
            return true
        case .failed:
            // 多半是没给「控制 Terminal」权限：激活终端，并只弹一次授权框。
            DispatchQueue.main.async { activateTerminal() }
            requestAutomationConsentOnce()
            return true
        }
    }

    /// 首次聚焦失败时主动弹一次系统授权框。用户允许后，后续点击就能精确选中标签页。
    private static func requestAutomationConsentOnce() {
        stateLock.lock()
        let shouldRequest = !automationConsentRequested
        automationConsentRequested = true
        stateLock.unlock()
        guard shouldRequest else { return }
        debugLog("requesting automation consent")
        permissionQueue.async { _ = requestAutomationPermission() }
    }

    /// 扫描进程表，返回第一条匹配命令的 tty。
    /// 只认真正的 `claude` 进程，避免把脚本路径或参数里的同样字符串误判成任务窗口。
    private static func existingTTY(claudeArgs: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,tty=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let pid = Int32(parts[0]) ?? 0
            let tty = String(parts[1])
            guard pid > 0, pid != getpid(), tty != "??", tty != "-" else { continue }
            guard commandLine(String(parts[2]), matches: claudeArgs) else { continue }
            return tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        }
        return nil
    }

    private static func commandLine(_ command: String, matches claudeArgs: [String]) -> Bool {
        let tokens = command.split(separator: " ").map(String.init)
        guard tokens.count > claudeArgs.count else { return false }
        for index in 0..<(tokens.count - claudeArgs.count) {
            guard (tokens[index] as NSString).lastPathComponent == "claude" else { continue }
            let arguments = Array(tokens[(index + 1)...(index + claudeArgs.count)])
            if arguments == claudeArgs { return true }
        }
        return false
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
        debugLog("automation probe exit=\(process.terminationStatus)")

        var status = automationPermission(ask: false)
        debugLog("automation status after probe=\(status)")
        if status != noErr {
            status = automationPermission(ask: true)
            debugLog("automation request status=\(status)")
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
        dispatchLog("terminal: \(message)")
    }
}
