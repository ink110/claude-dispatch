import AppKit

/// `claude agents --json --all` 的单条记录。字段和 agents 列表一致。
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
    case needsInput
    case stale
    case running
    case completed
    case idle

    var sortOrder: Int {
        switch self {
        case .needsInput: return 0
        case .stale: return 1
        case .running: return 2
        case .completed: return 3
        case .idle: return 4
        }
    }

    var label: String {
        switch self {
        case .needsInput: return "等你处理"
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
    let state: TaskState
    let startedAt: Date?
    let lastActivity: Date?
    let activityText: String?
    let pending: Bool
}

/// 轮询 `claude agents --json --all`，作为悬停列表的状态源。
/// 这样列表里的分组、状态、短 id 都和 `claude agents` 一致。
final class AgentListStore {
    private(set) var items: [AgentListItem] = []
    private var timer: Timer?
    private var running = false
    private var claudePath: String?
    var onChange: (() -> Void)?

    func start() {
        claudePath = Self.resolveClaudePath()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
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
                guard let items else { return }
                self.items = items
                self.onChange?()
            }
        }
    }

    private static func fetch(path: String) -> [AgentListItem]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["agents", "--json", "--all"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
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
            seen.insert(item.sessionId)
            let live = liveBySession[item.sessionId]
            let activity = store.activity(for: item.sessionId)
            let last = activity?.lastEventAt ?? live?.lastActivity ?? item.startedDate
            let pending = pendingIds.contains(item.sessionId)
            let stale = live.map { store.isStale($0) } ?? false
            // `--all` 会把已经退出的会话也列出来，它们的 state 可能停在 blocked。
            // 只有真正带 waitingFor、status=waiting 或有实时请求的才算「等你处理」。
            let waiting = pending || item.waitingFor != nil || item.status == "waiting"
            let dead = item.pid == nil && item.status == nil

            let state: TaskState
            if waiting {
                state = .needsInput
            } else if dead {
                state = .completed
            } else if stale {
                state = .stale
            } else if item.status == "busy" || live?.isBusy == true {
                state = .running
            } else if item.state == "done" {
                state = .completed
            } else if item.kind == "interactive" {
                state = .idle
            } else if item.status == "idle" {
                state = .completed
            } else {
                state = .idle
            }

            let activityText: String?
            switch state {
            case .needsInput:
                activityText = "等你处理"
            case .stale:
                activityText = "可能卡住"
            case .running:
                activityText = activity?.currentSummary ?? "正在运行"
            case .completed:
                activityText = "已完成"
            case .idle:
                activityText = activity?.lastEventSummary ?? "空闲"
            }

            tasks.append(TaskItem(
                sessionId: item.sessionId,
                attachId: item.id,
                name: item.displayName,
                cwd: item.cwd,
                isBackground: item.isBackground,
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
                state = .needsInput
            } else {
                state = .idle
            }

            tasks.append(TaskItem(
                sessionId: session.sessionId,
                attachId: session.jobId,
                name: session.displayName,
                cwd: session.cwd,
                isBackground: session.isBackground,
                state: state,
                startedAt: session.startedDate,
                lastActivity: activity?.lastEventAt ?? session.lastActivity,
                activityText: activity?.currentSummary ?? activity?.lastEventSummary,
                pending: pending
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
