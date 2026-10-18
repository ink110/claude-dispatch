import Foundation

/// Claude Code 自己维护的会话注册表（~/.claude/sessions/<pid>.json）
struct SessionRecord: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let kind: String?
    let status: String?
    let name: String?
    let startedAt: Double?
    let updatedAt: Double?
    let entrypoint: String?
    let jobId: String?

    var isBackground: Bool { kind == "bg" || kind == "background" }
    var displayName: String {
        if let name, !name.isEmpty { return name }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? sessionId.prefix(8).description : last
    }
    var shortId: String { jobId ?? String(sessionId.prefix(8)) }
    var isBusy: Bool { status == "busy" }
    var isWaiting: Bool { status == "waiting" || status == "blocked" }
    var startedDate: Date? {
        guard let startedAt else { return nil }
        return Date(timeIntervalSince1970: startedAt / 1000)
    }
    var lastActivity: Date {
        if let updatedAt { return Date(timeIntervalSince1970: updatedAt / 1000) }
        return startedDate ?? .distantPast
    }
}

enum RequestKind: String {
    case permission
    case question
    case plan
}

struct QuestionOption {
    let label: String
    let detail: String
}

struct QuestionItem {
    let question: String
    let header: String
    let options: [QuestionOption]
    let multiSelect: Bool
}

/// 一次等待用户处理的请求（权限 / 提问 / 计划）
struct PendingRequest {
    let id: String
    let kind: RequestKind
    let sessionId: String
    let sessionName: String
    let cwd: String
    let toolName: String
    let detailText: String
    let questions: [QuestionItem]
    let hasSuggestions: Bool
    let receivedAt: Date
    let rawEvent: [String: Any]
    /// 回写 hook 结果：success=false 表示主动放弃，让 Claude Code 回落终端弹窗
    let respond: (_ body: [String: Any]?, _ success: Bool) -> Void

    var isBlocking: Bool { kind == .permission || kind == .question || kind == .plan }
}

struct AppConfig {
    static let port: UInt16 = 18765
    static let appName = "Claude Pulse"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let stateDir = home.appendingPathComponent(".claude-pulse")
    static let tokenFile = stateDir.appendingPathComponent("token")
    /// 浮层无人响应后回落到终端弹窗的时间，可用环境变量覆盖。
    static var fallbackTimeout: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["CLAUDE_PULSE_TIMEOUT"],
           let value = Double(raw), value > 0 {
            return value
        }
        return 600
    }
}
