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
    /// Claude Code 后台守护进程预热的空会话池（`spare: true`）。
    /// 没有对话内容，attach 只会打开一个空白 agent 视图，不能当任务展示。
    let spare: Bool?

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

/// 每个会话最近的活动，用来回答「它现在到底在干嘛」。
struct SessionActivity {
    var currentTool: String?
    var currentSummary: String?
    var currentRaw: String?
    var lastEventAt: Date?
    var lastEventSummary: String?
    var needsAttention: Bool = false
    var attentionLabel: String?
}

/// 最近结束的会话：`claude agents` 不再列出，但用户仍需要看到「刚完成」。
struct CompletedSession {
    let sessionId: String
    let attachId: String?
    let name: String
    let cwd: String
    let isBackground: Bool
    let completedAt: Date
}

/// 确认卡头部的会话 chip：点击可在多个等待请求之间切换。
struct RequestChip {
    let id: String
    let label: String
    let kind: RequestKind
    let urgent: Bool
}

/// 一次等待用户处理的请求（权限 / 提问 / 计划）
struct PendingRequest {
    let id: String
    let kind: RequestKind
    let sessionId: String
    let sessionName: String
    let cwd: String
    let toolName: String
    /// 给用户看的中文描述，不直接展示原始代码。
    let human: HumanDescription
    /// 原始内容，只在用户主动点「查看技术细节」时展示。
    let detailText: String
    let questions: [QuestionItem]
    let hasSuggestions: Bool
    let receivedAt: Date
    let rawEvent: [String: Any]
    /// 后台会话没有可回落的终端窗口，超时策略和按钮文案都不同。
    let isBackground: Bool
    let attachId: String?
    /// 回写 hook 结果：success=false 表示主动放弃，让 Claude Code 回落终端弹窗
    let respond: (_ body: [String: Any]?, _ success: Bool) -> Void

    var isBlocking: Bool { kind == .permission || kind == .question || kind == .plan }
}

struct AppConfig {
    static let port: UInt16 = 18765
    static let appName = "Claude Dispatch"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let stateDir = home.appendingPathComponent(".claude-dispatch")
    static let tokenFile = stateDir.appendingPathComponent("token")
    static let settingsFile = home.appendingPathComponent(".claude/settings.json")
    /// 浮层无人响应后回落到终端弹窗的时间，可用环境变量覆盖。
    static var fallbackTimeout: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["CLAUDE_DISPATCH_TIMEOUT"],
           let value = Double(raw), value > 0 {
            return value
        }
        return 600
    }
}
