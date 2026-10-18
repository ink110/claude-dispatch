import Foundation

/// 本地 token 的读取与创建（App 启动与 --install-hooks 共用一份实现）。
enum TokenStore {
    static func loadOrCreate() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: AppConfig.stateDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: AppConfig.tokenFile),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }

        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        try token.write(to: AppConfig.tokenFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppConfig.tokenFile.path)
        return token
    }
}

/// hooks 健康分级。
/// - broken：决策 hooks（权限/提问/计划）缺失或 token 不匹配 → 浮层收不到确认请求，必须修复。
/// - degraded：活动流/通知 hooks 缺失 → 还能确认，但「在干嘛」和完成提醒不完整。
enum HookHealthLevel {
    case ok
    case degraded
    case broken
}

/// 检查 Claude Code 的 hooks 是否还在、token 是否还有效。
/// cc-switch 切换 provider 时可能重写 settings.json，把 hooks 清掉或换了 token。
enum HookHealth {
    static func check() -> HookHealthLevel {
        guard
            let data = try? Data(contentsOf: AppConfig.settingsFile),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return .broken }

        let token = (try? String(contentsOf: AppConfig.tokenFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let preToolGroups = groups(hooks, "PreToolUse")

        let decisionOK =
            hasOurHook(groups(hooks, "PermissionRequest"), token: token)
            && hasOurHook(preToolGroups, matcher: "AskUserQuestion", token: token)
            && hasOurHook(preToolGroups, matcher: "ExitPlanMode", token: token)

        guard decisionOK else { return .broken }

        let notificationMatchers = matcherNames(groups(hooks, "Notification"))
        let notificationOK = notificationMatchers.contains { matcher in
            matcher.contains("idle_prompt") || matcher.contains("agent_needs_input") || matcher.contains("agent_completed")
        }

        let activityOK =
            hasOurHook(preToolGroups, matcher: "*", token: token, mode: "activity")
            && hasOurHook(groups(hooks, "PostToolUse"), matcher: "*", token: token, mode: "activity")
            && hasOurHook(groups(hooks, "Stop"), token: token)
            && hasOurHook(groups(hooks, "SessionStart"), token: token)
            && hasOurHook(groups(hooks, "SessionEnd"), token: token)
            && notificationOK

        return activityOK ? .ok : .degraded
    }

    private static func groups(_ hooks: [String: Any], _ event: String) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    private static func matcherNames(_ groups: [[String: Any]]) -> [String] {
        groups.compactMap { $0["matcher"] as? String }
    }

    /// 找到本工具写入的 hook：URL 指向 127.0.0.1:18765，且（若传入 token）query 里的 token 一致。
    private static func hasOurHook(
        _ groups: [[String: Any]],
        matcher: String? = nil,
        token: String?,
        mode: String? = nil
    ) -> Bool {
        for group in groups {
            if let matcher, group["matcher"] as? String != matcher { continue }
            for handler in group["hooks"] as? [[String: Any]] ?? [] {
                guard let url = handler["url"] as? String,
                      url.contains("127.0.0.1:18765") else { continue }
                if let mode, url.contains("mode=activity") != (mode == "activity") { continue }
                if let token, !token.isEmpty {
                    guard let queryToken = Self.queryValue(url: url, name: "token"),
                          queryToken == token else { continue }
                }
                return true
            }
        }
        return false
    }

    private static func queryValue(url: String, name: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }
}

/// hooks 安装/卸载的唯一实现。install.sh 通过 `ClaudePulse --install-hooks` 调用，
/// App 内「点击修复」也走这里；不再维护第二份 jq 版本。
enum HookInstaller {
    /// 幂等安装：先剥离本工具旧 hooks，再写入完整配置。备份自动轮转（保留最近 5 份）。
    static func install() -> Bool {
        let token: String
        do {
            token = try TokenStore.loadOrCreate()
        } catch {
            return false
        }

        guard var settings = readSettings() else { return false }

        guard backupSettings() else { return false }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in Self.allEvents {
            hooks[event] = stripped(groups: groups(hooks, event))
        }

        let baseURL = "http://127.0.0.1:18765/hook?token=\(token)"
        let activityURL = baseURL + "&mode=activity"

        func add(_ event: String, matcher: String?, timeout: Int, url: String) {
            let handler: [String: Any] = ["type": "http", "url": url, "timeout": timeout]
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher { group["matcher"] = matcher }
            var all = groups(hooks, event)
            all.append(group)
            hooks[event] = all
        }

        // 会阻塞等待用户操作的决策 hooks。
        add("PermissionRequest", matcher: nil, timeout: 3600, url: baseURL)
        add("PreToolUse", matcher: "AskUserQuestion", timeout: 3600, url: baseURL)
        add("PreToolUse", matcher: "ExitPlanMode", timeout: 3600, url: baseURL)

        // 只记录「在干嘛」的活动流，不参与决策。
        add("PreToolUse", matcher: "*", timeout: 2, url: activityURL)
        add("PostToolUse", matcher: "*", timeout: 2, url: activityURL)

        // 生命周期与通知（agent_completed 用于「任务完成」提示）。
        add("Stop", matcher: nil, timeout: 10, url: baseURL)
        add("Notification", matcher: "idle_prompt|agent_needs_input|agent_completed", timeout: 10, url: baseURL)
        add("SessionStart", matcher: nil, timeout: 5, url: baseURL)
        add("SessionEnd", matcher: nil, timeout: 5, url: baseURL)

        settings["hooks"] = hooks
        return writeSettings(settings)
    }

    /// 移除本工具写入的全部 hooks（同样先备份）。
    static func uninstall() -> Bool {
        guard var settings = readSettings() else { return false }
        guard backupSettings() else { return false }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in Self.allEvents {
            let stripped = stripped(groups: groups(hooks, event))
            if stripped.isEmpty {
                hooks[event] = nil
            } else {
                hooks[event] = stripped
            }
        }
        if hooks.isEmpty {
            settings["hooks"] = nil
        } else {
            settings["hooks"] = hooks
        }
        return writeSettings(settings)
    }

    private static let allEvents = [
        "PermissionRequest", "PreToolUse", "PostToolUse",
        "Stop", "Notification", "SessionStart", "SessionEnd"
    ]

    private static func groups(_ hooks: [String: Any], _ event: String) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    /// 去掉 URL 指向本工具端口的 hook 组。
    private static func stripped(groups: [[String: Any]]) -> [[String: Any]] {
        groups.filter { group in
            !(group["hooks"] as? [[String: Any]] ?? []).contains { handler in
                (handler["url"] as? String)?.contains("127.0.0.1:18765") == true
            }
        }
    }

    private static func readSettings() -> [String: Any]? {
        // 文件不存在 → 全新安装；文件损坏 → 返回 nil 不动它（宁可不装也不覆盖）。
        guard let data = try? Data(contentsOf: AppConfig.settingsFile) else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }

    private static func writeSettings(_ settings: [String: Any]) -> Bool {
        guard
            JSONSerialization.isValidJSONObject(settings),
            let output = try? JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return false }

        do {
            try FileManager.default.createDirectory(
                at: AppConfig.settingsFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try output.write(to: AppConfig.settingsFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 备份 settings.json，并把历史备份裁到最近 `keeping` 份，防止无限增长。
    private static func backupSettings(keeping: Int = 5) -> Bool {
        let fm = FileManager.default
        let dir = AppConfig.settingsFile.deletingLastPathComponent()

        if fm.fileExists(atPath: AppConfig.settingsFile.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backup = dir.appendingPathComponent(
                "settings.json.bak-claude-pulse-\(formatter.string(from: Date()))"
            )
            do {
                try fm.copyItem(at: AppConfig.settingsFile, to: backup)
            } catch {
                return false
            }
        }

        let prefix = "settings.json.bak-claude-pulse"
        let backups = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .sorted()
        guard backups.count > keeping else { return true }
        for name in backups.dropLast(keeping) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        return true
    }
}
