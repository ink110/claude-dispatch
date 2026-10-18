import AppKit

/// `claude agents --json` 的单条记录。字段和 agents 列表一致。
struct AgentListItem: Decodable {
    let pid: Int?
    let id: String?
    let sessionId: String
    let cwd: String
    let kind: String
    let startedAt: Double?
    let name: String?
    let status: String?
    let state: String?
    /// 仅在真正等待用户时非空，例如 "permission prompt"、"input needed"。
    let waitingFor: String?

    var isBackground: Bool { kind == "background" }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? String(sessionId.prefix(8)) : last
    }

    var startedDate: Date? {
        guard let startedAt else { return nil }
        return Date(timeIntervalSince1970: startedAt / 1000)
    }
}

/// 和 agents 列表对齐的四种主状态，外加「可能卡住」的警告态。
enum TaskState {
    /// 有真实的 hook 请求在浮层里等你操作。
    case needsInput
    /// 终端自己在等输入，但 App 没有可展示的卡片（例如 hook 已断开）。
    case waitingInput
    case stale
    case running
    case completed
    case idle

    var sortOrder: Int {
        switch self {
        case .needsInput: return 0
        case .waitingInput: return 1
        case .stale: return 2
        case .running: return 3
        case .completed: return 4
        case .idle: return 5
        }
    }

    var label: String {
        switch self {
        case .needsInput: return "等你处理"
        case .waitingInput: return "等待输入"
        case .stale: return "可能卡住"
        case .running: return "运行中"
        case .completed: return "已完成"
        case .idle: return "空闲"
        }
    }
}

struct TaskItem {
    let sessionId: String
    let attachId: String?
    let name: String
    let cwd: String
    let isBackground: Bool
    /// 交互式会话靠 pid 找到它所在的终端窗口；后台任务用 attachId。
    let pid: Int32?
    let state: TaskState
    let startedAt: Date?
    let lastActivity: Date?
    let activityText: String?
    let pending: Bool
}

/// 轮询 `claude agents --json`，作为悬停列表的主数据源。
/// 连续两次失败后清空列表并标记降级，由 TaskBuilder 回落到会话注册表。
final class TaskStore {
    private(set) var items: [AgentListItem] = []
    /// `claude agents` 连续失败、当前依赖注册表兜底时为 true。
    private(set) var isDegraded = false
    private var consecutiveFailures = 0
    private var timer: Timer?
    private var running = false
    private var claudePath: String?
    var onChange: (() -> Void)?

    func start() {
        claudePath = Self.resolveClaudePath()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !running, let claudePath else { return }
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let items = Self.fetch(path: claudePath)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                guard let items else {
                    self.consecutiveFailures += 1
                    // 一次瞬时失败很常见，连续两次才降级，避免列表闪空。
                    if self.consecutiveFailures >= 2 {
                        self.isDegraded = true
                        self.items = []
                        self.onChange?()
                    }
                    return
                }
                self.consecutiveFailures = 0
                self.isDegraded = false
                self.items = items
                self.onChange?()
            }
        }
    }

    private static func fetch(path: String) -> [AgentListItem]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["agents", "--json"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return try JSONDecoder().decode([AgentListItem].self, from: data)
        } catch {
            return nil
        }
    }

    private static func resolveClaudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.local/bin/claude",
            "/usr/bin/claude"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

/// 把 agents 列表、本地会话注册表和活动流合并成悬停列表要显示的任务。
enum TaskBuilder {
    /// 后台会话生成标题前，注册表里放的是首条 prompt，过长就不适合当卡片标题。
    private static func displayName(_ raw: String, cwd: String, sessionId: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name.count <= 24 && !name.contains("\n") {
            return name
        }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty
            ? String(sessionId.prefix(8))
            : "\(folder) · \(String(sessionId.prefix(4)))"
    }

    static func tasks(
        agentItems: [AgentListItem],
        store: SessionStore,
        pendingIds: Set<String>
    ) -> [TaskItem] {
        var liveBySession: [String: SessionRecord] = [:]
        for session in store.sessions {
            liveBySession[session.sessionId] = session
        }
        var tasks: [TaskItem] = []
        var seen = Set<String>()

        for item in agentItems {
            // supervisor 已停掉进程的僵尸记录：既没有 pid 也没有 status，直接隐藏。
            guard !(item.pid == nil && item.status == nil) else { continue }
            seen.insert(item.sessionId)
            let live = liveBySession[item.sessionId]
            let activity = store.activity(for: item.sessionId)
            let last = activity?.lastEventAt ?? live?.lastActivity ?? item.startedDate
            let pending = pendingIds.contains(item.sessionId)
            let stale = live.map { store.isStale($0) } ?? false
            // 只有真正带 waitingFor 或有实时请求的才算「等你处理」；
            // status == "waiting" 单独出现不足以证明在等用户，避免误报。
            let waiting = pending || item.waitingFor != nil

            let state: TaskState
            if waiting {
                state = pending ? .needsInput : .waitingInput
            } else if stale {
                state = .stale
            } else if item.status == "busy" || live?.isBusy == true {
                state = .running
            } else if item.state == "done" || item.state == "failed" {
                state = .completed
            } else {
                state = .idle
            }

            let activityText: String?
            switch state {
            case .needsInput:
                activityText = "等你处理"
            case .waitingInput:
                activityText = "在终端等待输入 · 点击打开"
            case .stale:
                activityText = "可能卡住"
            case .running:
                activityText = activity?.currentSummary ?? "正在运行"
            case .completed:
                activityText = item.state == "failed" ? "执行失败" : "已完成"
            case .idle:
                activityText = activity?.lastEventSummary ?? "空闲"
            }

            tasks.append(TaskItem(
                sessionId: item.sessionId,
                attachId: item.id,
                name: displayName(item.displayName, cwd: item.cwd, sessionId: item.sessionId),
                cwd: item.cwd,
                isBackground: item.isBackground,
                pid: item.pid.map(Int32.init),
                state: state,
                startedAt: item.startedDate,
                lastActivity: last,
                activityText: activityText,
                pending: pending
            ))
        }

        // agents 列表刚刷新、注册表还没跟上时，把本地实时会话补进来。
        for session in store.sessions where !seen.contains(session.sessionId) {
            let activity = store.activity(for: session.sessionId)
            let pending = pendingIds.contains(session.sessionId)
            let stale = store.isStale(session)
            let state: TaskState
            if pending {
                state = .needsInput
            } else if stale {
                state = .stale
            } else if session.isBusy {
                state = .running
            } else if session.isWaiting {
                state = .waitingInput
            } else {
                state = .idle
            }

            tasks.append(TaskItem(
                sessionId: session.sessionId,
                attachId: session.jobId,
                name: displayName(session.displayName, cwd: session.cwd, sessionId: session.sessionId),
                cwd: session.cwd,
                isBackground: session.isBackground,
                pid: session.pid,
                state: state,
                startedAt: session.startedDate,
                lastActivity: activity?.lastEventAt ?? session.lastActivity,
                activityText: state == .waitingInput
                    ? "在终端等待输入 · 点击打开"
                    : (activity?.currentSummary ?? activity?.lastEventSummary),
                pending: pending
            ))
        }

        // 任务结束后会从 `claude agents` 列表消失；用内存里的完成列表保留 10 分钟。
        for done in store.recentlyCompleted where !seen.contains(done.sessionId) {
            seen.insert(done.sessionId)
            tasks.append(TaskItem(
                sessionId: done.sessionId,
                attachId: done.attachId,
                name: displayName(done.name, cwd: done.cwd, sessionId: done.sessionId),
                cwd: done.cwd,
                isBackground: done.isBackground,
                pid: nil,
                state: .completed,
                startedAt: nil,
                lastActivity: done.completedAt,
                activityText: "已完成",
                pending: false
            ))
        }

        return tasks.sorted { lhs, rhs in
            if lhs.state.sortOrder != rhs.state.sortOrder {
                return lhs.state.sortOrder < rhs.state.sortOrder
            }
            return (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
        }
    }
}
