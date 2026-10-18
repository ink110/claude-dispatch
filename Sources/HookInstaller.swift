import Foundation

/// 检查 Claude Code 的 hooks 是否还在。cc-switch 切换 provider 时可能重写 settings.json。
enum HookHealth {
    static func isHealthy() -> Bool {
        guard
            let data = try? Data(contentsOf: AppConfig.settingsFile),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return false }

        for event in ["PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Notification"] {
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            let hasOurHook = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { handler in
                    (handler["url"] as? String)?.contains("127.0.0.1:18765") == true
                }
            }
            if !hasOurHook { return false }
        }

        guard let preToolGroups = hooks["PreToolUse"] as? [[String: Any]] else { return false }
        let matchers = preToolGroups.compactMap { $0["matcher"] as? String }
        return matchers.contains("AskUserQuestion")
            && matchers.contains("ExitPlanMode")
            && matchers.contains("*")
    }
}

/// 在 App 内直接修复 hooks，不依赖 install.sh，也不需要用户开终端。
enum HookInstaller {
    static func repair() -> Bool {
        let fileManager = FileManager.default
        guard
            let token = try? String(contentsOf: AppConfig.tokenFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else { return false }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: AppConfig.settingsFile),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        // 先备份，保证可逆。
        if fileManager.fileExists(atPath: AppConfig.settingsFile.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backup = AppConfig.settingsFile
                .deletingLastPathComponent()
                .appendingPathComponent("settings.json.bak-claude-pulse-\(formatter.string(from: Date()))")
            try? fileManager.copyItem(at: AppConfig.settingsFile, to: backup)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let baseURL = "http://127.0.0.1:18765/hook?token=\(token)"
        let activityURL = baseURL + "&mode=activity"

        for event in ["PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Notification", "SessionStart", "SessionEnd"] {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            hooks[event] = groups.filter { group in
                !(group["hooks"] as? [[String: Any]] ?? []).contains { handler in
                    (handler["url"] as? String)?.contains("127.0.0.1:18765") == true
                }
            }
        }

        func add(_ event: String, matcher: String?, timeout: Int, url: String) {
            let handler: [String: Any] = ["type": "http", "url": url, "timeout": timeout]
            var group: [String: Any] = ["hooks": [handler]]
            if let matcher { group["matcher"] = matcher }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(group)
            hooks[event] = groups
        }

        // 会阻塞等待你操作的请求。
        add("PermissionRequest", matcher: nil, timeout: 3600, url: baseURL)
        add("PreToolUse", matcher: "AskUserQuestion", timeout: 3600, url: baseURL)
        add("PreToolUse", matcher: "ExitPlanMode", timeout: 3600, url: baseURL)

        // 只记录「在干嘛」，不参与决策，立即放行。
        add("PreToolUse", matcher: "*", timeout: 2, url: activityURL)
        add("PostToolUse", matcher: "*", timeout: 2, url: activityURL)

        // 完成/等待/会话生命周期。
        add("Stop", matcher: nil, timeout: 10, url: baseURL)
        add("Notification", matcher: "idle_prompt|agent_needs_input", timeout: 10, url: baseURL)
        add("SessionStart", matcher: nil, timeout: 5, url: baseURL)
        add("SessionEnd", matcher: nil, timeout: 5, url: baseURL)

        root["hooks"] = hooks

        guard
            JSONSerialization.isValidJSONObject(root),
            let output = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
        else { return false }

        do {
            try fileManager.createDirectory(
                at: AppConfig.settingsFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try output.write(to: AppConfig.settingsFile, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
