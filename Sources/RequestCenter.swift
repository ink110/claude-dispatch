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

    var store: SessionStore?
    var onChange: (() -> Void)?

    var pendingCount: Int { queue.count + (active == nil ? 0 : 1) }
    var activeRequest: PendingRequest? { active }
    var queuedRequests: [PendingRequest] { queue }

    func focusActive() {
        panel?.show()
    }
    var pendingSessionIds: Set<String> {
        var ids = Set(queue.map(\.sessionId))
        if let active { ids.insert(active.sessionId) }
        return ids
    }

    /// HookServer 的所有事件入口。阻塞型事件会留在队列里等用户操作。
    func handle(event: [String: Any], respond: @escaping (HookHTTPResult) -> Void) {
        let hookName = event["hook_event_name"] as? String ?? ""
        let toolName = event["tool_name"] as? String ?? ""

        if hookName == "PermissionRequest" {
            let kind: RequestKind = toolName == "ExitPlanMode" ? .plan : .permission
            enqueue(event: event, kind: kind, toolName: toolName, respond: respond)
            return
        }

        if hookName == "PreToolUse" && toolName == "AskUserQuestion" {
            enqueue(event: event, kind: .question, toolName: toolName, respond: respond)
            return
        }

        // ExitPlanMode 的终端确认不经过 PermissionRequest，必须用 PreToolUse 接管。
        if hookName == "PreToolUse" && toolName == "ExitPlanMode" {
            enqueue(event: event, kind: .plan, toolName: toolName, respond: respond)
            return
        }

        // 非阻塞事件：更新状态、提示完成，然后立刻放行。
        if hookName == "Stop" {
            notifyFinished(event)
        } else if hookName == "Notification" {
            let type = event["notification_type"] as? String ?? ""
            if type == "idle_prompt" || type == "agent_needs_input" {
                notifyWaiting(event)
            }
        }
        store?.refresh()
        onChange?()
        respond(.json(["continue": true]))
    }

    // MARK: - 入队与展示

    private func enqueue(
        event: [String: Any],
        kind: RequestKind,
        toolName: String,
        respond: @escaping (HookHTTPResult) -> Void
    ) {
        let sessionId = event["session_id"] as? String ?? ""
        let cwd = event["cwd"] as? String ?? ""
        let sessionName = sessionName(for: sessionId, cwd: cwd)
        let input = event["tool_input"] as? [String: Any] ?? [:]

        let questions: [QuestionItem] = kind == .question ? parseQuestions(input["questions"]) : []
        let detail: String
        switch kind {
        case .permission:
            detail = input["command"] as? String
                ?? input["file_path"] as? String
                ?? prettyJSON(input)
        case .plan:
            detail = input["plan"] as? String ?? "（计划内容为空）"
        case .question:
            detail = ""
        }

        let request = PendingRequest(
            id: UUID().uuidString,
            kind: kind,
            sessionId: sessionId,
            sessionName: sessionName,
            cwd: cwd,
            toolName: toolName,
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
        onChange?()
        playAttentionSound()
        showNextIfNeeded()
    }

    private func showNextIfNeeded() {
        guard active == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        active = request

        let controller = RequestPanelController(
            request: request,
            queueRemaining: queue.count,
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
    }

    // MARK: - 用户决策

    private func apply(_ action: UserAction, to request: PendingRequest) {
        guard active?.id == request.id else { return }
        timeoutTimer?.invalidate()
        timeoutTimer = nil

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
        panel?.close()
        panel = nil
        active = nil
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

    private func prettyJSON(_ value: [String: Any]) -> String {
        guard
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    private func playAttentionSound() {
        NSSound(named: "Glass")?.play()
    }

    private func notifyFinished(_ event: [String: Any]) {
        let cwd = event["cwd"] as? String ?? ""
        let sessionId = event["session_id"] as? String ?? ""
        let name = sessionName(for: sessionId, cwd: cwd)
        var text = event["last_assistant_message"] as? String ?? "任务已完成"
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > 90 { text = String(text.prefix(90)) + "…" }
        ToastPanelController.shared.show(
            title: "\(name) · 已完成",
            body: text,
            accent: .systemGreen,
            autoDismiss: 4.5
        )
    }

    private func notifyWaiting(_ event: [String: Any]) {
        let cwd = event["cwd"] as? String ?? ""
        let sessionId = event["session_id"] as? String ?? ""
        let message = event["message"] as? String ?? "Claude 正在等你"
        ToastPanelController.shared.show(
            title: "\(sessionName(for: sessionId, cwd: cwd)) · 等你处理",
            body: message,
            accent: .systemOrange,
            autoDismiss: 6
        )
    }
}
