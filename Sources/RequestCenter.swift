import AppKit

enum UserAction {
    case allow(always: Bool)
    case deny(message: String?)
    case answer([String: String])
    case fallback
}

/// 串行处理所有等待用户的请求：一次只弹一张浮层，避免多会话同时弹窗造成混乱。
final class RequestCenter {
    private(set) var queue: [PendingRequest] = []
    private(set) var active: PendingRequest?
    private var panel: RequestPanelController?
    private var timeoutTimer: Timer?
    private var escalationWork: [DispatchWorkItem] = []

    var store: SessionStore?
    var onChange: (() -> Void)?
    /// 由悬浮条提供，让确认卡出现在脉搏条下方，而不是永远固定在屏幕右上角。
    var anchorProvider: (() -> NSRect?)?

    var pendingCount: Int { queue.count + (active == nil ? 0 : 1) }
    var activeRequest: PendingRequest? { active }
    var queuedRequests: [PendingRequest] { queue }

    func focusActive() {
        panel?.raiseToFront()
    }

    var pendingSessionIds: Set<String> {
        var ids = Set(queue.map(\.sessionId))
        if let active { ids.insert(active.sessionId) }
        return ids
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
            store?.refresh()
            onChange?()
            respond(.empty)
            return
        }

        if hookName == "PostToolUse" {
            store?.recordPostTool(sessionId: sessionId, toolName: toolName, input: input)
            store?.refresh()
            onChange?()
            respond(.empty)
            return
        }

        // 非阻塞事件：只更新状态，空 body 放行。
        // Stop 是「一轮回复结束」，不是任务完成——每个回合弹提示只会变成噪音。
        if hookName == "Stop" {
            store?.recordTurnEnd(sessionId: sessionId)
        } else if hookName == "SessionStart" {
            store?.clearAttention(sessionId: sessionId)
        } else if hookName == "SessionEnd" {
            store?.recordSessionEnd(sessionId: sessionId)
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
            default:
                break
            }
        }
        store?.refresh()
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

        onChange?()
        playAttentionSound()
        showNextIfNeeded()
    }

    /// 底层 hook 连接已断开（会话结束、进程被杀、hook 超时）：
    /// 丢掉这条请求，不要留下一个终端里根本不存在、却挡住后续请求的幽灵弹窗。
    private func cancel(id: String) {
        if let active, active.id == id {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
            cancelEscalation()

            let sessionId = active.sessionId
            panel?.close()
            panel = nil
            self.active = nil
            clearAttentionIfNoPending(sessionId: sessionId)
            store?.refresh()
            onChange?()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showNextIfNeeded()
            }
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let request = queue.remove(at: index)
            clearAttentionIfNoPending(sessionId: request.sessionId)
            onChange?()
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
        active = request

        let controller = RequestPanelController(
            request: request,
            queueRemaining: queue.count,
            anchor: anchorProvider?(),
            onAction: { [weak self] action in
                self?.apply(action, to: request)
            }
        )
        panel = controller
        controller.show()

        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: AppConfig.fallbackTimeout, repeats: false) { [weak self] _ in
            self?.apply(.fallback, to: request)
        }
        if let timer = timeoutTimer { RunLoop.main.add(timer, forMode: .common) }

        startEscalation(for: request, panel: controller)
    }

    // MARK: - 提醒升级

    /// 先视觉和声音提醒；45 秒后抬到最前并移动到鼠标所在屏幕；不抢键盘焦点。
    private func startEscalation(for request: PendingRequest, panel: RequestPanelController) {
        cancelEscalation()

        schedule(15) {
            panel.escalatePulse()
            NSSound(named: "Ping")?.play()
        }
        schedule(45) {
            panel.raiseToFront()
            panel.moveToScreenUnderMouse()
            NSSound(named: "Ping")?.play()
        }
        schedule(120) {
            panel.escalatePulse()
            NSSound(named: "Ping")?.play()
        }
        schedule(180) {
            panel.escalatePulse()
            NSSound(named: "Ping")?.play()
        }
        schedule(240) {
            panel.escalatePulse()
            NSSound(named: "Ping")?.play()
        }
    }

    private func schedule(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        guard let id = active?.id else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active?.id == id else { return }
            block()
        }
        escalationWork.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelEscalation() {
        escalationWork.forEach { $0.cancel() }
        escalationWork.removeAll()
    }

    // MARK: - 用户决策

    private func apply(_ action: UserAction, to request: PendingRequest) {
        guard active?.id == request.id else { return }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        cancelEscalation()

        var body: [String: Any]?
        var success = true

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

        case (_, .fallback):
            success = false

        default:
            success = false
        }

        request.respond(body, success)
        finish(request)
    }

    private func finish(_ request: PendingRequest) {
        cancelEscalation()
        panel?.close()
        panel = nil
        active = nil
        clearAttentionIfNoPending(sessionId: request.sessionId)
        store?.refresh()
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.showNextIfNeeded()
        }
    }

    // MARK: - 辅助

    private func sessionName(for id: String, cwd: String) -> String {
        if let match = store?.sessions.first(where: { $0.sessionId == id }) {
            return match.displayName
        }
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? String(id.prefix(8)) : last
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
