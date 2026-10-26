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
        debugLog("openTask name=\(name) attachId=\(attachId ?? "nil") bg=\(isBackground) pid=\(pid.map(String.init) ?? "nil") resume=\(resume)")

        // 已结束的任务 attach 不到，改为恢复历史对话。
        if resume, let sessionId, !sessionId.isEmpty {
            let marker = "resume-\(sanitizedId(sessionId) ?? "session")"
            queue.async {
                openOrFocus(
                    command: "claude --resume \(sessionId)",
                    claudeArgs: ["--resume", sessionId],
                    title: name,
                    cwd: cwd,
                    marker: marker,
                    name: name
                )
            }
            return
        }

        if isBackground {
            guard let attachId, let safeId = sanitizedId(attachId) else {
                DispatchQueue.main.async { activateTerminal() }
                return
            }
            let marker = "attach-\(safeId)"
            queue.async {
                openOrFocus(
                    command: "claude attach \(safeId)",
                    claudeArgs: ["attach", safeId],
                    title: name,
                    cwd: cwd,
                    marker: marker,
                    name: name
                )
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
            let marker = "resume-\(sanitizedId(sessionId) ?? "session")"
            queue.async {
                openOrFocus(
                    command: "claude --resume \(sessionId)",
                    claudeArgs: ["--resume", sessionId],
                    title: name,
                    cwd: cwd,
                    marker: marker,
                    name: name
                )
            }
            return
        }

        DispatchQueue.main.async { activateTerminal() }
    }

    // MARK: - 新终端窗口

    /// 统一入口：先找已存在的窗口；没有再看是否刚为同一任务开过窗口，都没有才新建。
    /// 必须在 `queue` 上调用（与 `claimOpening` 一起保证串行）。
    private static func openOrFocus(
        command: String,
        claudeArgs: [String],
        title: String,
        cwd: String,
        marker: String,
        name: String
    ) {
        if focusExistingWindow(claudeArgs: claudeArgs, marker: marker, reviveCommand: command, name: name) { return }
        guard claimOpening(marker) else {
            // 连点同一个任务：第一个窗口正在启动，第二个点击只把终端带到前台。
            debugLog("skip duplicate open for \(marker)")
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        openCommand(command, title: title, cwd: cwd, marker: marker)
    }

    /// 最近为某个任务开过窗口的时间。启动脚本的进程要几百毫秒后才出现，
    /// 只靠进程扫描挡不住「第一次窗口还没起来、第二次点击已经进来」。
    private static var openingMarkers: [String: Date] = [:]

    private static func claimOpening(_ marker: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = Date()
        openingMarkers = openingMarkers.filter { now.timeIntervalSince($0.value) < 60 }
        if let last = openingMarkers[marker], now.timeIntervalSince(last) < 8 {
            return false
        }
        openingMarkers[marker] = now
        return true
    }

    /// 窗口最终没开起来时释放占位，用户可以立刻重试。
    private static func releaseOpening(_ marker: String) {
        stateLock.lock()
        openingMarkers[marker] = nil
        stateLock.unlock()
    }

    /// `marker` 会写进脚本文件名（`task-<marker>-<uuid>.command`），
    /// 用来在 claude 子进程的 argv 变化后仍能认出这个窗口（见 `launchScript`）。
    private static func openCommand(_ command: String, title: String, cwd: String, marker: String) {
        let fm = FileManager.default
        let dir = AppConfig.stateDir.appendingPathComponent("launch", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            debugLog("create launch dir failed: \(error)")
            releaseOpening(marker)
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        pruneOldScripts(in: dir)

        let safeMarker = sanitizedId(marker) ?? "task"
        let url = dir.appendingPathComponent("task-\(safeMarker)-\(UUID().uuidString.prefix(8)).command")
        let safeTitle = title
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        var lines = ["#!/bin/zsh"]
        if !cwd.isEmpty {
            lines.append("cd \(shellQuote(cwd))")
        }
        lines.append("printf '\\033]0;%s\\007' \(shellQuote(safeTitle))")
        lines.append(command)
        // 命令结束后留一个交互 shell：窗口和它对应的启动脚本会一直留在进程表里。
        // 否则 attach 一旦退出（用户 detach、会话结束），脚本进程消失、窗口还在，
        // 下次点击同一任务时进程表里找不到它，只能再开一个重复窗口。
        lines.append("zsh -i")
        do {
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            debugLog("write command failed: \(error)")
            releaseOpening(marker)
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            debugLog("Terminal.app not found")
            releaseOpening(marker)
            DispatchQueue.main.async { activateTerminal() }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        debugLog("opening command \(url.lastPathComponent)")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration) { _, error in
            if let error {
                releaseOpening(marker)
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
            let marker = "resume-\(sanitizedId(sessionId) ?? "session")"
            debugLog("no tab for tty \(tty), resuming session")
            queue.async {
                openOrFocus(
                    command: "claude --resume \(sessionId)",
                    claudeArgs: ["--resume", sessionId],
                    title: name,
                    cwd: cwd,
                    marker: marker,
                    name: name
                )
            }
        }
    }

    /// 用独立 `osascript` 子进程执行 AppleScript 并等待结果，不用进程内 NSAppleScript：
    /// 后者在后台线程发送 Apple Event 会一直阻塞（实测 >15s 不返回），把整个队列卡死。
    /// 子进程可以按超时强杀，未授权或终端无响应时最多等 4 秒。
    private static func runAppleScript(_ script: String, description: String) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else {
            debugLog("\(description): osascript failed to launch")
            return (-1, "")
        }
        if finished.wait(timeout: .now() + 4) == .timedOut {
            process.terminate()
            debugLog("\(description): timed out")
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }

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
        let (status, output) = runAppleScript(script, description: "focus tab")
        guard status == 0 else {
            debugLog("focus tab: osascript exit=\(status) for tty \(tty)")
            return .failed
        }
        if output == "found" {
            debugLog("focused tty \(tty)")
            return .focused
        }
        debugLog("no tab for tty \(tty)")
        return .notFound
    }

    private enum HuskResult {
        /// 标签页存在且没有任何进程在跑：就是这个任务的空壳窗口。
        case husk
        /// 标签页里还有程序在跑，说明 tty 已被别的窗口复用。
        case busy
        case notFound
        case failed
    }

    /// 按 tty 检查 Terminal 里是否还有一个「空壳」标签页（命令已退出、窗口还在）。
    /// Terminal 的 `busy` 对交互 shell 也是 true，只有完全没有进程时才是 false，
    /// 正好可以区分「我们的空壳窗口」和「tty 被别的新窗口复用」。
    private static func huskTab(tty: String) -> HuskResult {
        let ttyLiteral = appleScriptLiteral(tty)
        let script = """
        with timeout of 3 seconds
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(ttyLiteral) then
                            set selected tab of w to t
                            set index of w to 1
                            if busy of t then
                                return "busy"
                            end if
                            activate
                            return "husk"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
        end timeout
        """
        let (status, output) = runAppleScript(script, description: "husk tab")
        guard status == 0 else { return .failed }
        switch output {
        case "husk": return .husk
        case "busy": return .busy
        case "missing": return .notFound
        default: return .failed
        }
    }

    private enum ReviveResult {
        /// 聚焦成功，并在同页重新拉起了对话。
        case revived
        case notFound
        case failed
    }

    /// 窗口还在但对话已退出（启动脚本末尾的 linger shell 保证了窗口可找）：
    /// 聚焦该标签页，直接在同页执行 `claude attach/resume`，把对话拉回到原窗口，
    /// 而不是新开一个。调用前必须确认该 tty 上只剩 shell（见 `scriptIdle`）。
    private static func reviveTab(tty: String, command: String) -> ReviveResult {
        let ttyLiteral = appleScriptLiteral(tty)
        let commandLiteral = appleScriptLiteral(command)
        let script = """
        with timeout of 3 seconds
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(ttyLiteral) then
                            set selected tab of w to t
                            set index of w to 1
                            do script \(commandLiteral) in t
                            return "revived"
                        end if
                    end repeat
                end repeat
            end tell
            return "missing"
        end timeout
        """
        let (status, output) = runAppleScript(script, description: "revive tab")
        guard status == 0 else { return .failed }
        switch output {
        case "revived":
            debugLog("revived tty \(tty) with `\(command)`")
            return .revived
        case "missing":
            debugLog("no tab for tty \(tty) during revive")
            return .notFound
        default:
            return .failed
        }
    }

    // MARK: - 已有任务窗口

    /// 在正在运行的进程里找到这个任务已经打开的终端窗口，直接把对应 Terminal
    /// 标签页切到前台；如果窗口里对话已经退出（只剩 linger shell），在同一个窗口
    /// 里重新执行 attach/resume 把对话拉回来。找不到返回 false，由调用方新开窗口。
    /// 找到了但选不中标签页（未授权自动化、终端正忙）时只把终端激活到前台，
    /// 不再开第二个同样的窗口——重复窗口比手动找标签页更让人困惑。
    private static func focusExistingWindow(
        claudeArgs: [String],
        marker: String,
        reviveCommand: String,
        name: String
    ) -> Bool {
        let existing = findExistingWindow(claudeArgs: claudeArgs, marker: marker)
        if let tty = existing.live {
            debugLog("existing window for \(claudeArgs.joined(separator: " ")) at \(tty)")
            recordWindow(marker: marker, tty: tty)
            return focusOrActivate(tty: tty)
        }
        if let tty = existing.script {
            recordWindow(marker: marker, tty: tty)
            if existing.scriptIdle {
                debugLog("idle window for \(marker) at \(tty), reviving")
                return reviveOrActivate(tty: tty, command: reviveCommand)
            }
            // 窗口里正跑着别的界面（如 agent 视图）：只聚焦，不往终端里注入命令。
            debugLog("busy window for \(marker) at \(tty), focusing only")
            return focusOrActivate(tty: tty)
        }

        // 进程表里已经没有这个任务的窗口了。旧版本创建的窗口没有 linger shell，
        // 对话退出后进程消失、窗口还在；靠登记过的 tty 把它找回来，绝不新开。
        if let entry = registeredEntry(marker: marker) {
            if entry.manual {
                // 手动打开的窗口（用户在终端里跑 `claude agents` 选的会话）：
                // 里面会一直有程序在跑，tty 是否仍属于这个任务要靠标签页标题确认。
                switch verifyManualTab(tty: entry.tty, name: name) {
                case .match:
                    debugLog("focused registered window for \(marker) at \(entry.tty)")
                    return focusOrActivate(tty: entry.tty)
                case .mismatch, .notFound:
                    // 标题变了（改名）或窗口关了：作废登记，落到下面的标题扫描再找一遍。
                    forgetWindow(marker: marker)
                case .failed:
                    DispatchQueue.main.async { activateTerminal() }
                    requestAutomationConsentOnce()
                    return true
                }
            } else {
                switch huskTab(tty: entry.tty) {
                case .husk:
                    debugLog("focused registered window for \(marker) at \(entry.tty)")
                    recordWindow(marker: marker, tty: entry.tty)
                    return true
                case .busy:
                    // tty 已被别的窗口复用（里面有程序在跑），不能再认。
                    forgetWindow(marker: marker)
                case .notFound:
                    forgetWindow(marker: marker)
                case .failed:
                    DispatchQueue.main.async { activateTerminal() }
                    requestAutomationConsentOnce()
                    return true
                }
            }
        }

        // 兜底：窗口是用户手动在终端里跑 `claude agents` 打开的——进程表里
        // 既没有 attach 子进程、也没有启动脚本，但 Terminal 标签页标题会跟随
        // 会话名（如「◑ 插件迭代2.0」）。按标题认窗，只聚焦，绝不往里注入命令。
        if let tty = tabTitledLike(name) {
            debugLog("existing window for \(marker) by tab title at \(tty)")
            recordWindow(marker: marker, tty: tty, manual: true)
            return focusOrActivate(tty: tty)
        }
        return false
    }

    // MARK: - 窗口登记（兼容没有 linger shell 的旧窗口）

    /// 任务标记 → 窗口 tty 的持久登记。新版本生成的窗口有 linger shell，
    /// 靠进程表就能找到；旧版本窗口在对话退出后只剩一个空壳，只能按 tty 找。
    /// `manual` 标记的是「用户手动在终端里打开的窗口」：里面始终有程序在跑，
    /// 校验时看标签页标题而不是进程是否为空（见 `verifyManualTab`）。
    private static var registry: [String: [String: Any]] = [:]
    private static var registryLoaded = false
    private static var registryURL: URL {
        AppConfig.stateDir.appendingPathComponent("windows.json")
    }

    private static func loadRegistryIfNeeded() {
        guard !registryLoaded else { return }
        registryLoaded = true
        guard
            let data = try? Data(contentsOf: registryURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        registry = object.filter { ($0.value["at"] as? Double ?? 0) >= cutoff }
    }

    private static func recordWindow(marker: String, tty: String, manual: Bool = false) {
        stateLock.lock()
        loadRegistryIfNeeded()
        registry[marker] = ["tty": tty, "at": Date().timeIntervalSince1970, "manual": manual]
        persistRegistry()
        stateLock.unlock()
    }

    private static func registeredEntry(marker: String) -> (tty: String, manual: Bool)? {
        stateLock.lock()
        loadRegistryIfNeeded()
        defer { stateLock.unlock() }
        guard let entry = registry[marker], let tty = entry["tty"] as? String else { return nil }
        return (tty, entry["manual"] as? Bool ?? false)
    }

    private static func forgetWindow(marker: String) {
        stateLock.lock()
        loadRegistryIfNeeded()
        registry[marker] = nil
        persistRegistry()
        stateLock.unlock()
    }

    /// 调用方需持有 `stateLock`。
    private static func persistRegistry() {
        guard let data = try? JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys]) else {
            return
        }
        try? FileManager.default.createDirectory(at: AppConfig.stateDir, withIntermediateDirectories: true)
        try? data.write(to: registryURL, options: .atomic)
    }

    // MARK: - 手动打开的窗口（按标签页标题认领）

    private enum ManualTabResult {
        /// 标签页还在，标题仍然对得上这个任务。
        case match
        /// 标签页在，但标题已经是别的会话（改名了）或为空。
        case mismatch
        case notFound
        case failed
    }

    /// 校验登记过的手动窗口是否仍属于这个任务。这类窗口里始终有程序在跑
    /// （`claude agents` 浏览器），不能用「有没有进程」判断，只能看标题：
    /// Claude Code 会把终端标题设成「状态符 + 会话名」，并随改名更新。
    private static func verifyManualTab(tty: String, name: String) -> ManualTabResult {
        let script = """
        with timeout of 3 seconds
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is \(appleScriptLiteral(tty)) then
                            set tabTitle to ""
                            try
                                set tabTitle to custom title of t
                            end try
                            return tabTitle
                        end if
                    end repeat
                end repeat
            end tell
            return "__cd_missing__"
        end timeout
        """
        let (status, output) = runAppleScript(script, description: "verify manual tab")
        guard status == 0 else { return .failed }
        if output == "__cd_missing__" { return .notFound }
        return tabTitle(output, matches: name) ? .match : .mismatch
    }

    /// 扫描所有 Terminal 标签页，找出标题与任务名一致的那个窗口的 tty。
    /// 找不到返回 nil。一次 AppleScript 调用取回全部「tty + 标题」，在 Swift 侧比较。
    /// 注意：分隔符不能用 `tab` 常量——在 Terminal 的 tell 块里它会被解析成
    /// Terminal 的 tab 类，拼进字符串变成字面量 "tab"（实测）。
    private static func tabTitledLike(_ name: String) -> String? {
        let script = """
        set sep to ASCII character 9
        with timeout of 3 seconds
            tell application "Terminal"
                set out to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set tabTitle to ""
                        try
                            set tabTitle to custom title of t
                        end try
                        set out to out & (tty of t) & sep & tabTitle & linefeed
                    end repeat
                end repeat
                return out
            end tell
        end timeout
        """
        let (status, output) = runAppleScript(script, description: "scan tab titles")
        guard status == 0 else {
            debugLog("scan tab titles failed: exit=\(status) output=\(output)")
            return nil
        }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, tabTitle(String(parts[1]), matches: name) else { continue }
            return String(parts[0])
        }
        return nil
    }

    /// 标签页标题与任务名的匹配。标题形如「◑ 插件迭代2.0」——状态旋转符 +
    /// 空格 + 会话名；剥掉符号前缀后按全等比较，并容忍一端是另一端的截断
    /// （数据源的名字可能带「…」，至少 4 个字符才允许前缀匹配）。
    private static func tabTitle(_ title: String, matches name: String) -> Bool {
        var trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstSpace = trimmed.firstIndex(of: " ") {
            let prefix = trimmed[trimmed.startIndex..<firstSpace]
            if !prefix.isEmpty, prefix.rangeOfCharacter(from: CharacterSet.alphanumerics) == nil {
                trimmed = String(trimmed[trimmed.index(after: firstSpace)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !target.isEmpty else { return false }
        if trimmed.caseInsensitiveCompare(target) == .orderedSame { return true }
        for pair in [(trimmed, target), (target, trimmed)] where pair.1.hasSuffix("…") {
            let stem = String(pair.1.dropLast())
            if stem.count >= 4, pair.0.hasPrefix(stem) { return true }
        }
        return false
    }

    /// 聚焦成功返回 true；标签页不在 Terminal 或聚焦失败时也返回 true
    /// （只激活终端/请求授权），让调用方不再开重复窗口。
    private static func focusOrActivate(tty: String) -> Bool {
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

    /// 窗口还在但对话已退出：聚焦并在同一标签页重新拉起对话。
    private static func reviveOrActivate(tty: String, command: String) -> Bool {
        switch reviveTab(tty: tty, command: command) {
        case .revived:
            return true
        case .notFound:
            // 进程表里有脚本、Terminal 里却没有标签页（极端不一致）：按没找到处理。
            return false
        case .failed:
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

    /// 扫描进程表，分别找「活着的对话」和「窗口还在但对话已退出」两种已有窗口。
    /// `scriptIdle` 表示该窗口的 tty 上只剩 shell（说明对话已退出、终端停在提示符），
    /// 这时可以安全地在原窗口重新拉起对话；如果还跑着 agent 视图或其他程序则不行。
    private static func findExistingWindow(
        claudeArgs: [String],
        marker: String
    ) -> (live: String?, script: String?, scriptIdle: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,tty=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (nil, nil, false) }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return (nil, nil, false) }

        var live: String?
        var script: String?
        var processesByTTY: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let pid = Int32(parts[0]) ?? 0
            let tty = String(parts[1])
            guard pid > 0, pid != getpid(), tty != "??", tty != "-" else { continue }
            let command = String(parts[2])
            let normalized = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
            processesByTTY[normalized, default: []].append(command)
            if live == nil, commandLine(command, matches: claudeArgs) {
                live = normalized
            }
            if script == nil, launchScript(command, matches: marker) {
                script = normalized
            }
        }

        var scriptIdle = false
        if let script {
            let shellNames: Set<String> = ["zsh", "bash", "fish", "sh", "login"]
            let commands = processesByTTY[script] ?? []
            // ps 里的首个 token 是 shell（/bin/zsh、zsh -i、login、-zsh）才算空闲；
            // 出现 claude、python 等任何其他程序都不能注入命令。
            scriptIdle = !commands.isEmpty && commands.allSatisfy { command in
                let executable = command.split(separator: " ").first.map(String.init) ?? ""
                let name = (executable as NSString).lastPathComponent
                // 登录 shell 在 ps 里显示为 "-zsh"。
                return shellNames.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
            }
        }
        return (live, script, scriptIdle)
    }

    /// 认出发起窗口的那个 `.command` 脚本（名字里带任务标记）。
    /// `claude attach <id>` 被用户按 ← 退回 agent 视图、或 attach 提前退出后，
    /// claude 子进程的 argv 不再含任务 id，但保留着的父 shell 仍然在跑这个脚本。
    private static func launchScript(_ command: String, matches marker: String) -> Bool {
        command.contains("task-\(marker)-") && command.contains(".command")
    }

    private static func commandLine(_ command: String, matches claudeArgs: [String]) -> Bool {
        let tokens = command.split(separator: " ").map(String.init)
        guard tokens.count > claudeArgs.count else { return false }
        let executableNames = ["claude", "claude.exe"]
        for index in 0..<(tokens.count - claudeArgs.count) {
            guard executableNames.contains((tokens[index] as NSString).lastPathComponent) else { continue }
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
