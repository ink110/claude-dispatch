import AppKit

enum UserAction {
    case allow(always: Bool)
    case deny(message: String?)
    case answer([String: String])
    /// 交互式会话：回落到终端原生提示。
    case fallback
    /// 后台会话：先释放 hook，再 `claude attach` 进入任务。
    case attach
}

/// 处理所有等待用户的请求：同一时间只显示一张卡，
/// 卡片头部用 chips 在多个等待会话之间切换，每个请求保留自己的面板与已填内容。
final class RequestCenter {
    private(set) var queue: [PendingRequest] = []
    private(set) var active: PendingRequest?
    /// 每个请求一个面板实例，切换时只显示/隐藏，不销毁，避免丢掉已填内容。
    private var panels: [String: RequestPanelController] = [:]
    private var timeoutTimers: [String: Timer] = [:]
    private var escalationWork: [String: [DispatchWorkItem]] = [:]
    private var urgentIds = Set<String>()
    /// 五个出口（允许/拒绝/回答/断连/超时）都走这里做幂等，保证每个请求只结算一次。
    private var settledIds = Set<String>()

    // /status 快照：主线程写，HTTP 队列读，靠锁保证跨线程安全。
    private let snapshotLock = NSLock()
    private var cachedSnapshot = Data("{}".utf8)

    var store: SessionStore?
    var onChange: (() -> Void)?
    /// 由悬浮条提供，让确认卡出现在脉搏条下方，而不是永远固定在屏幕右上角。
    var anchorProvider: (() -> NSRect?)?
    /// 数据源降级状态（`claude agents` 连续失败），用于 /status 和脉搏条。
    var dataDegradedProvider: (() -> Bool)?
    var healthProvider: (() -> HookHealthLevel)?
    /// 由 App 层合并注册表与 agents 列表，判断会话是不是后台任务。
    var backgroundProvider: ((String) -> Bool)?

    init() {
        rebuildSnapshot()
    }

    var pendingCount: Int { queue.count + (active == nil ? 0 : 1) }
    var activeRequest: PendingRequest? { active }
    var queuedRequests: [PendingRequest] { queue }

    /// 卡片显示顺序：当前卡在前，其余按等待顺序。
    private var allPending: [PendingRequest] {
        var all: [PendingRequest] = []
        if let active { all.append(active) }
        all.append(contentsOf: queue)
        return all
    }

    private var chips: [RequestChip] {
        allPending.map { request in
            RequestChip(
                id: request.id,
                label: request.sessionName,
                kind: request.kind,
                urgent: urgentIds.contains(request.id)
            )
        }
    }

    func focusActive() {
        active.flatMap { panels[$0.id] }?.raiseToFront()
    }

    /// 从展开面板召回某个会话的确认卡：若在队列里，先切过去再置顶。
    /// 返回 false 表示没有存活的 hook 请求（例如后台会话已被 block），调用方应改为 attach。
    @discardableResult
    func focus(sessionId: String) -> Bool {
        if let active, active.sessionId == sessionId {
            focusActive()
            return true
        }
        guard let request = queue.first(where: { $0.sessionId == sessionId }) else { return false }
        switchTo(id: request.id)
        focusActive()
        return true
    }

    var pendingSessionIds: Set<String> {
        var ids = Set(queue.map(\.sessionId))
        if let active { ids.insert(active.sessionId) }
        return ids
    }

    /// GET /status 的只读快照。可能在 HTTP 队列调用，不能在主线程外碰 AppKit 状态。
    func snapshotData() -> Data? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return cachedSnapshot
    }

    /// HookServer 的所有事件入口。阻塞型事件会留在队列里等用户操作。
    func handle(
        event: [String: Any],
        respond: @escaping (HookHTTPResult) -> Void,
        registerCancel: @escaping (@escaping () -> Void) -> Void
    ) {
        let hookName = event["hook_event_name"] as? String ?? ""
        let toolName = event["tool_name"] as? String ?? ""
        let mode = event["_claude_pulse_mode"] as? String
        let sessionId = event["session_id"] as? String ?? ""
        let input = event["tool_input"] as? [String: Any] ?? [:]

        // 活动流 hook：只记录「在干嘛」，不参与决策，立即放行（空 body = 无决策）。
        if mode == "activity" {
            if hookName == "PreToolUse" {
                store?.recordPreTool(sessionId: sessionId, toolName: toolName, input: input)
            } else if hookName == "PostToolUse" {
                store?.recordPostTool(sessionId: sessionId, toolName: toolName, input: input)
            }
            store?.refresh()
            onChange?()
            respond(.empty)
            return
        }

        if hookName == "PermissionRequest" {
            let kind: RequestKind = toolName == "ExitPlanMode" ? .plan : .permission
            enqueue(event: event, kind: kind, toolName: toolName, respond: respond, registerCancel: registerCancel)
            return
        }

        if hookName == "PreToolUse" && toolName == "AskUserQuestion" {
            enqueue(event: event, kind: .question, toolName: toolName, respond: respond, registerCancel: registerCancel)
            return
        }

        // ExitPlanMode 的终端确认不经过 PermissionRequest，必须用 PreToolUse 接管。
        if hookName == "PreToolUse" && toolName == "ExitPlanMode" {
            enqueue(event: event, kind: .plan, toolName: toolName, respond: respond, registerCancel: registerCancel)
            return
        }

        // 兼容旧版安装：没有 mode 的 PreToolUse 也只记录活动。
        if hookName == "PreToolUse" {
            store?.recordPreTool(sessionId: sessionId, toolName: toolName, input: input)
            store?.refreshDebounced()
            onChange?()
            respond(.empty)
            return
        }

        if hookName == "PostToolUse" {
            store?.recordPostTool(sessionId: sessionId, toolName: toolName, input: input)
            store?.refreshDebounced()
            onChange?()
            respond(.empty)
            return
        }

        // 非阻塞事件：只更新状态，空 body 放行。
        // Stop 是「一轮回复结束」，不是任务完成——每个回合弹提示只会变成噪音。
        var refreshImmediately = false
        if hookName == "Stop" {
            store?.recordTurnEnd(sessionId: sessionId)
        } else if hookName == "SessionStart" {
            store?.clearAttention(sessionId: sessionId)
        } else if hookName == "SessionEnd" {
            store?.recordSessionEnd(sessionId: sessionId)
            refreshImmediately = true
        } else if hookName == "Notification" {
            let type = event["notification_type"] as? String ?? ""
            switch type {
            case "idle_prompt", "agent_needs_input":
                store?.markAttention(sessionId: sessionId, label: "等你输入")
                notifyWaiting(event)
            case "agent_completed":
                // 后台任务真正完成的信号，只有它才弹「已完成」。
                store?.recordSessionEnd(sessionId: sessionId)
                notifyFinished(event)
                refreshImmediately = true
            default:
                break
            }
        }
        if refreshImmediately {
            store?.refresh()
        } else {
            store?.refreshDebounced()
        }
        onChange?()
        respond(.empty)
    }

    // MARK: - 入队与展示

    private func enqueue(
        event: [String: Any],
        kind: RequestKind,
        toolName: String,
        respond: @escaping (HookHTTPResult) -> Void,
        registerCancel: @escaping (@escaping () -> Void) -> Void
    ) {
        let sessionId = event["session_id"] as? String ?? ""
        let cwd = event["cwd"] as? String ?? ""
        let sessionName = sessionName(for: sessionId, cwd: cwd)
        let input = event["tool_input"] as? [String: Any] ?? [:]

        let questions: [QuestionItem] = kind == .question ? parseQuestions(input["questions"]) : []

        let human: HumanDescription
        let detail: String
        switch kind {
        case .permission:
            human = Humanizer.describePermission(toolName: toolName, input: input)
            detail = human.rawDetail
        case .plan:
            human = Humanizer.describePlan()
            detail = input["plan"] as? String ?? "（计划内容为空）"
        case .question:
            human = Humanizer.describeQuestion()
            detail = ""
        }

        let attentionLabel: String
        switch kind {
        case .permission: attentionLabel = "等你确认"
        case .question: attentionLabel = "等你回答"
        case .plan: attentionLabel = "等待批准计划"
        }
        store?.markAttention(sessionId: sessionId, label: attentionLabel)

        let live = store?.sessions.first { $0.sessionId == sessionId }
        let isBackground = backgroundProvider?(sessionId) ?? (live?.isBackground ?? false)
        let attachId = live?.jobId ?? String(sessionId.prefix(8))

        let request = PendingRequest(
            id: UUID().uuidString,
            kind: kind,
            sessionId: sessionId,
            sessionName: sessionName,
            cwd: cwd,
            toolName: toolName,
            human: human,
            detailText: detail,
            questions: questions,
            hasSuggestions: !(event["permission_suggestions"] as? [[String: Any]] ?? []).isEmpty,
            receivedAt: Date(),
            rawEvent: event,
            isBackground: isBackground,
            attachId: attachId,
            respond: { body, success in
                if success, let body {
                    respond(.json(body))
                } else {
                    respond(.fail)
                }
            }
        )

        queue.append(request)

        // 连接先断开时，registerCancel 会立刻回调；先入队保证 cancel 能找到它。
        registerCancel { [weak self] in
            DispatchQueue.main.async {
                self?.cancel(id: request.id)
            }
        }

        pulseLog("enqueue kind=\(kind.rawValue) session=\(sessionId) bg=\(isBackground) pending=\(pendingCount)")
        scheduleTimeout(for: request)
        scheduleEscalation(for: request)
        rebuildSnapshot()
        onChange?()
        playAttentionSound()
        showNextIfNeeded()
        refreshChips()
    }

    /// 底层 hook 连接已断开（会话结束、进程被杀、hook 超时）：
    /// 丢掉这条请求，不要留下一个终端里根本不存在、却挡住后续请求的幽灵弹窗。
    private func cancel(id: String) {
        guard !settledIds.contains(id) else { return }
        settledIds.insert(id)
        cancelTimers(for: id)
        panels[id]?.close()
        panels[id] = nil
        urgentIds.remove(id)

        if let active, active.id == id {
            self.active = nil
            clearAttentionIfNoPending(sessionId: active.sessionId)
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let request = queue.remove(at: index)
            clearAttentionIfNoPending(sessionId: request.sessionId)
        } else {
            return
        }

        refreshChips()
        rebuildSnapshot()
        onChange?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showNextIfNeeded()
        }
    }

    private func clearAttentionIfNoPending(sessionId: String) {
        if active?.sessionId == sessionId { return }
        if queue.contains(where: { $0.sessionId == sessionId }) { return }
        store?.clearAttention(sessionId: sessionId)
    }

    private func showNextIfNeeded() {
        guard active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        activate(request)
    }

    private func activate(_ request: PendingRequest) {
        active = request
        let panel = panels[request.id] ?? makePanel(for: request)
        panels[request.id] = panel
        // 其他卡只隐藏、不销毁，切回来时已填内容还在。
        for (id, other) in panels where id != request.id {
            other.hide()
        }
        panel.show()
        refreshChips()
        rebuildSnapshot()
    }

    private func makePanel(for request: PendingRequest) -> RequestPanelController {
        RequestPanelController(
            request: request,
            chips: chips,
            activeId: request.id,
            anchor: anchorProvider?(),
            onSelect: { [weak self] id in self?.switchTo(id: id) },
            onAction: { [weak self] action in self?.apply(action, to: request) }
        )
    }

    /// chips 切换：当前卡放回队列，目标卡出队显示。
    private func switchTo(id: String) {
        guard active?.id != id else { return }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        pulseLog("switch to \(id)")
        let target = queue.remove(at: index)
        if let current = active {
            queue.insert(current, at: 0)
        }
        active = nil
        activate(target)
        onChange?()
    }

    private func refreshChips() {
        let currentChips = chips
        let activeId = active?.id ?? ""
        for panel in panels.values {
            panel.updateChips(currentChips, activeId: activeId)
        }
    }

    // MARK: - 超时与提醒升级（每请求独立）

    private func scheduleTimeout(for request: PendingRequest) {
        timeoutTimers[request.id]?.invalidate()
        // 后台会话没有可回落的终端：永不自动超时，一直等并提醒升级。
        guard !request.isBackground else {
            timeoutTimers[request.id] = nil
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: AppConfig.fallbackTimeout, repeats: false) { [weak self] _ in
            self?.apply(.fallback, to: request)
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimers[request.id] = timer
    }

    /// 先视觉和声音提醒；45 秒后抬到最前并移动到鼠标所在屏幕；不抢键盘焦点。
    /// 排队中的请求只把 chip 标红并发声，不抢当前卡的注意力。
    private func scheduleEscalation(for request: PendingRequest) {
        cancelEscalation(for: request.id)

        var stages: [(TimeInterval, Int)]
        if request.isBackground {
            // 后台任务：15s 脉冲 → 45s 置顶 → 之后每 5 分钟 → 55 分钟提示 hook 超时。
            stages = [(15, 0), (45, 1)]
            stages += stride(from: 345.0, through: 3045.0, by: 300.0).map { ($0, 2) }
            stages.append((3300, 3))
        } else {
            stages = [(15, 0), (45, 1), (120, 2), (180, 2), (240, 2)]
        }

        for (delay, stage) in stages {
            let work = DispatchWorkItem { [weak self] in
                self?.escalate(request.id, stage: stage)
            }
            escalationWork[request.id, default: []].append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func escalate(_ id: String, stage: Int) {
        guard !settledIds.contains(id) else { return }
        guard allPending.contains(where: { $0.id == id }) else { return }

        if stage == 3 {
            ToastPanelController.shared.show(
                title: "请求即将超时",
                body: "1 小时后 hook 会超时，任务会转入 agents 列表继续等你，不会丢。",
                accent: .systemOrange,
                autoDismiss: 8
            )
            return
        }

        if active?.id == id, let panel = panels[id] {
            if stage == 1 {
                panel.raiseToFront()
                panel.moveToScreenUnderMouse()
            } else {
                panel.escalatePulse()
            }
            NSSound(named: "Ping")?.play()
        } else {
            urgentIds.insert(id)
            NSSound(named: "Ping")?.play()
            refreshChips()
            rebuildSnapshot()
            onChange?()
        }
    }

    private func cancelEscalation(for id: String) {
        escalationWork[id]?.forEach { $0.cancel() }
        escalationWork[id] = nil
    }

    private func cancelTimers(for id: String) {
        timeoutTimers[id]?.invalidate()
        timeoutTimers[id] = nil
        cancelEscalation(for: id)
    }

    // MARK: - 用户决策

    private func apply(_ action: UserAction, to request: PendingRequest) {
        // 五个出口统一幂等：超时 timer 与用户点击同时到达时只结算一次。
        guard !settledIds.contains(request.id) else { return }
        settledIds.insert(request.id)
        cancelTimers(for: request.id)
        pulseLog("settle kind=\(request.kind.rawValue) session=\(request.sessionId)")

        var body: [String: Any]?
        var success = true
        var attachAfter = false

        let isPreToolUse = request.rawEvent["hook_event_name"] as? String == "PreToolUse"

        switch (request.kind, action) {
        case (.permission, .allow(let always)), (.plan, .allow(let always)):
            if isPreToolUse {
                // ExitPlanMode：echo 原始输入并允许，跳过终端计划确认。
                body = [
                    "hookSpecificOutput": [
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow",
                        "updatedInput": request.rawEvent["tool_input"] as? [String: Any] ?? [:]
                    ]
                ]
            } else {
                var decision: [String: Any] = ["behavior": "allow"]
                if always,
                   let suggestions = request.rawEvent["permission_suggestions"] as? [[String: Any]],
                   !suggestions.isEmpty {
                    decision["updatedPermissions"] = suggestions
                }
                body = [
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": decision
                    ]
                ]
            }

        case (.permission, .deny(let message)), (.plan, .deny(let message)):
            if isPreToolUse {
                var output: [String: Any] = [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny"
                ]
                if let message, !message.isEmpty {
                    output["permissionDecisionReason"] = message
                }
                body = ["hookSpecificOutput": output]
            } else {
                var decision: [String: Any] = ["behavior": "deny"]
                if let message, !message.isEmpty { decision["message"] = message }
                body = [
                    "hookSpecificOutput": [
                        "hookEventName": "PermissionRequest",
                        "decision": decision
                    ]
                ]
            }

        case (.question, .answer(let answers)):
            var updatedInput = request.rawEvent["tool_input"] as? [String: Any] ?? [:]
            updatedInput["answers"] = answers
            body = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": updatedInput
                ]
            ]

        case (_, .attach):
            // 后台会话：先释放 hook 让任务回到可交互状态，再 attach 进终端。
            success = false
            attachAfter = true

        case (_, .fallback):
            success = false

        default:
            success = false
        }

        request.respond(body, success)
        finish(request)
        if attachAfter, let attachId = request.attachId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                TerminalLauncher.openTask(attachId: attachId, name: request.sessionName)
            }
        }
    }

    private func finish(_ request: PendingRequest) {
        panels[request.id]?.close()
        panels[request.id] = nil
        urgentIds.remove(request.id)

        if active?.id == request.id {
            active = nil
        } else {
            queue.removeAll { $0.id == request.id }
        }
        clearAttentionIfNoPending(sessionId: request.sessionId)
        refreshChips()
        rebuildSnapshot()
        store?.refreshDebounced()
        onChange?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showNextIfNeeded()
        }
    }

    // MARK: - /status 快照

    /// 由主线程在每次状态迁移后重建；HTTP 线程只读取序列化好的 Data。
    private func rebuildSnapshot() {
        let pending = allPending
        var dict: [String: Any] = [
            "ok": true,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "pending_count": pending.count,
            "active_id": active?.id ?? "",
            "data_degraded": dataDegradedProvider?() ?? false,
            "health": healthName(healthProvider?() ?? .ok),
            "queue": pending.map { snapshotEntry($0) },
            "sessions": (store?.sessions ?? []).map { session -> [String: Any] in
                [
                    "session_id": session.sessionId,
                    "name": session.displayName,
                    "cwd": session.cwd,
                    "kind": session.kind ?? "",
                    "status": session.status ?? "",
                    "short_id": session.shortId
                ]
            }
        ]
        if let request = active {
            dict["active"] = snapshotEntry(request)
        }
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        snapshotLock.lock()
        cachedSnapshot = data
        snapshotLock.unlock()
    }

    private func snapshotEntry(_ request: PendingRequest) -> [String: Any] {
        [
            "id": request.id,
            "kind": request.kind.rawValue,
            "session_id": request.sessionId,
            "session_name": request.sessionName,
            "cwd": request.cwd,
            "tool": request.toolName,
            "summary": request.human.summary,
            "risk": riskName(request.human.risk),
            "received_at": request.receivedAt.timeIntervalSince1970,
            "urgent": urgentIds.contains(request.id)
        ]
    }

    private func riskName(_ risk: RiskLevel) -> String {
        switch risk {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    private func healthName(_ health: HookHealthLevel) -> String {
        switch health {
        case .ok: return "ok"
        case .degraded: return "degraded"
        case .broken: return "broken"
        }
    }

    // MARK: - 辅助

    private func sessionName(for id: String, cwd: String) -> String {
        let folder = (cwd as NSString).lastPathComponent
        let fallback = folder.isEmpty ? String(id.prefix(8)) : "\(folder) · \(String(id.prefix(4)))"
        guard let match = store?.sessions.first(where: { $0.sessionId == id }) else {
            return fallback
        }
        let name = match.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // 后台会话生成标题前，注册表会把首条 prompt 当作名字，不适合直接当卡片标题。
        if name.isEmpty || name.count > 24 || name.contains("\n") {
            return fallback
        }
        return name
    }

    private func parseQuestions(_ raw: Any?) -> [QuestionItem] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.map { item in
            let options = (item["options"] as? [[String: Any]] ?? []).map {
                QuestionOption(
                    label: $0["label"] as? String ?? "",
                    detail: $0["description"] as? String ?? ""
                )
            }
            return QuestionItem(
                question: item["question"] as? String ?? "",
                header: item["header"] as? String ?? "",
                options: options,
                multiSelect: item["multiSelect"] as? Bool ?? false
            )
        }
    }

    private func playAttentionSound() {
        NSSound(named: "Glass")?.play()
    }

    private func notifyFinished(_ event: [String: Any]) {
        let cwd = event["cwd"] as? String ?? ""
        let sessionId = event["session_id"] as? String ?? ""
        let name = sessionName(for: sessionId, cwd: cwd)
        ToastPanelController.shared.show(
            title: "\(name) · 已完成",
            body: "任务已经结束。点击脉搏条可以看到这个会话的最新状态。",
            accent: .systemGreen,
            autoDismiss: 4.5
        )
    }

    private func notifyWaiting(_ event: [String: Any]) {
        let cwd = event["cwd"] as? String ?? ""
        let sessionId = event["session_id"] as? String ?? ""
        ToastPanelController.shared.show(
            title: "\(sessionName(for: sessionId, cwd: cwd)) · 等你处理",
            body: "Claude 正在等你输入或确认，点击脉搏条查看。",
            accent: .systemOrange,
            autoDismiss: 6
        )
    }
}
