import Foundation
import Darwin

/// 轮询 Claude Code 的会话注册表，得到所有存活会话的实时状态。
/// 注册表由 Claude Code 自己维护，比解析 transcript 更准也更便宜。
final class SessionStore {
    private(set) var sessions: [SessionRecord] = []
    /// 最近 10 分钟结束的会话，`claude agents` 列表不再包含它们。
    private(set) var recentlyCompleted: [CompletedSession] = []
    private var activities: [String: SessionActivity] = [:]
    private var timer: Timer?
    private var pendingRefresh: DispatchWorkItem?
    private var lastSignature = ""
    private static let completedRetention: TimeInterval = 600
    var onChange: (() -> Void)?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 活动流

    func activity(for sessionId: String) -> SessionActivity? {
        activities[sessionId]
    }

    func lastActivity(for session: SessionRecord) -> Date {
        activities[session.sessionId]?.lastEventAt ?? session.lastActivity
    }

    /// busy 但 5 分钟没有任何活动，只提示「可能卡住」，不自动干预。
    /// 没有活动数据的旧会话不判定，避免把「模型思考中」误报成卡住。
    func isStale(_ session: SessionRecord, now: Date = Date()) -> Bool {
        guard session.isBusy, !session.isWaiting else { return false }
        guard let activity = activities[session.sessionId], let last = activity.lastEventAt else { return false }
        if activity.needsAttention { return false }
        return now.timeIntervalSince(last) > 300
    }

    func recordPreTool(sessionId: String, toolName: String, input: [String: Any]) {
        guard !sessionId.isEmpty else { return }
        var activity = activities[sessionId] ?? SessionActivity()
        let summary = Humanizer.describeActivity(toolName: toolName, input: input)
        activity.currentTool = toolName
        activity.currentSummary = summary
        activity.currentRaw = Humanizer.rawDetail(toolName: toolName, input: input)
        activity.lastEventAt = Date()
        activity.lastEventSummary = summary
        activities[sessionId] = activity
    }

    func recordPostTool(sessionId: String, toolName: String, input: [String: Any]) {
        guard !sessionId.isEmpty else { return }
        var activity = activities[sessionId] ?? SessionActivity()
        let verb = Humanizer.activityVerb(toolName: toolName, input: input)
        activity.currentTool = nil
        activity.currentSummary = nil
        activity.currentRaw = nil
        activity.lastEventAt = Date()
        activity.lastEventSummary = "刚完成：\(verb)"
        activities[sessionId] = activity
    }

    func markAttention(sessionId: String, label: String) {
        guard !sessionId.isEmpty else { return }
        var activity = activities[sessionId] ?? SessionActivity()
        activity.needsAttention = true
        activity.attentionLabel = label
        activity.lastEventAt = Date()
        activity.lastEventSummary = label
        activities[sessionId] = activity
    }

    func clearAttention(sessionId: String) {
        guard var activity = activities[sessionId] else { return }
        activity.needsAttention = false
        activity.attentionLabel = nil
        activities[sessionId] = activity
    }

    /// Stop hook：一轮回复结束，会话还在。只更新活动，不打扰、不弹提示。
    func recordTurnEnd(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        var activity = activities[sessionId] ?? SessionActivity()
        activity.currentTool = nil
        activity.currentSummary = nil
        activity.currentRaw = nil
        activity.lastEventAt = Date()
        activity.lastEventSummary = activity.lastEventSummary == "任务完成" ? "任务完成" : "刚完成一轮"
        activities[sessionId] = activity
    }

    /// 会话真正结束（SessionEnd / agent_completed）：清等待标记，标记完成。
    func recordSessionEnd(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        var activity = activities[sessionId] ?? SessionActivity()
        activity.currentTool = nil
        activity.currentSummary = nil
        activity.currentRaw = nil
        activity.needsAttention = false
        activity.attentionLabel = nil
        activity.lastEventAt = Date()
        activity.lastEventSummary = "任务完成"
        activities[sessionId] = activity
        recordCompleted(sessionId: sessionId)
    }

    private func recordCompleted(sessionId: String) {
        let live = sessions.first { $0.sessionId == sessionId }
        let entry = CompletedSession(
            sessionId: sessionId,
            attachId: live?.jobId,
            name: live?.displayName ?? String(sessionId.prefix(8)),
            cwd: live?.cwd ?? "",
            isBackground: live?.isBackground ?? true,
            completedAt: Date()
        )
        recentlyCompleted.removeAll { $0.sessionId == sessionId }
        recentlyCompleted.insert(entry, at: 0)
        pruneCompleted()
    }

    @discardableResult
    private func pruneCompleted(now: Date = Date()) -> Bool {
        let before = recentlyCompleted.count
        recentlyCompleted.removeAll { now.timeIntervalSince($0.completedAt) > Self.completedRetention }
        return recentlyCompleted.count != before
    }

    /// 活动流高频触发时合并刷新，避免每次都扫目录拖慢 hook 响应。
    func refreshDebounced() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func refresh() {
        if pruneCompleted() { onChange?() }
        // 截图/演示用：只展示演示数据，不混入本机真实会话。
        if ProcessInfo.processInfo.environment["CLAUDE_DISPATCH_DEMO_AGENTS"] != nil {
            update([])
            return
        }
        let dir = AppConfig.home.appendingPathComponent(".claude/sessions")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            update([])
            return
        }

        var loaded: [SessionRecord] = []
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let record = try? JSONDecoder().decode(SessionRecord.self, from: data)
            else { continue }
            guard isAlive(pid: record.pid) else { continue }
            loaded.append(record)
        }

        loaded.sort { lhs, rhs in
            if lhs.isWaiting != rhs.isWaiting { return lhs.isWaiting }
            if lhs.isBusy != rhs.isBusy { return lhs.isBusy }
            return lhs.lastActivity > rhs.lastActivity
        }
        update(loaded)
    }

    private func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func update(_ newSessions: [SessionRecord]) {
        let signature = newSessions
            .map { "\($0.sessionId)|\($0.status ?? "")|\($0.name ?? "")|\($0.updatedAt ?? 0)" }
            .joined(separator: ",")
        guard signature != lastSignature else { return }
        lastSignature = signature
        sessions = newSessions
        onChange?()
    }
}
