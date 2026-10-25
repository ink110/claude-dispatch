import AppKit
import ServiceManagement

final class MenuBarController: NSObject, NSPopoverDelegate {
    /// 菜单栏弹层显示时收起常驻状态条，避免两个面板叠在一起。
    var onPopoverVisibilityChange: ((Bool) -> Void)?

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: SessionStore
    private let center: RequestCenter
    private let agents: TaskStore
    private let content: StatusViewController

    init(store: SessionStore, center: RequestCenter, agents: TaskStore) {
        self.store = store
        self.center = center
        self.agents = agents
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.content = StatusViewController(store: store, center: center, agents: agents)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = content

        if let button = statusItem.button {
            // 菜单栏高度 24pt，图标用 15pt 中等字重，视觉重量与系统状态项一致。
            button.image = Self.menuBarSymbol("waveform.path.ecg")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "Claude Dispatch · 观测所有 Claude Code 会话"
        }
        content.onOpenTask = { [weak self] in self?.popover.performClose(nil) }
        refresh()
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        button.toolTip = agents.isDegraded
            ? "Claude Dispatch · 数据降级（正在用会话注册表兜底）"
            : "Claude Dispatch · 观测所有 Claude Code 会话"
        let tasks = TaskBuilder.tasks(
            agentItems: agents.items,
            store: store,
            pendingIds: center.pendingSessionIds
        )
        // 只有真实的 hook 请求才算「等你处理」；终端里自己在等输入的不弹红点。
        let pending = tasks.filter(\.pending).count
        let busy = tasks.filter { $0.state == .running }.count

        if pending > 0 {
            // 只有「等你处理」用红色；其余状态保持模板图标 + 数字，符合菜单栏的克制用色。
            button.image = Self.menuBarSymbol("bell.badge.fill")
            button.contentTintColor = .systemRed
            button.title = " \(pending)"
        } else {
            button.image = Self.menuBarSymbol("waveform.path.ecg")
            button.contentTintColor = nil
            button.title = busy > 0 ? " \(busy)" : ""
        }
        if popover.isShown { content.refresh() }
    }

    /// 统一菜单栏 SF Symbol 的尺寸与模板属性，系统会随菜单栏外观自动着色。
    private static func menuBarSymbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Claude Dispatch")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        content.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            content.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        onPopoverVisibilityChange?(true)
    }

    func popoverDidClose(_ notification: Notification) {
        onPopoverVisibilityChange?(false)
    }
}

// MARK: - 状态面板

final class StatusViewController: NSViewController {
    /// 点击任务行后立即收起面板，避免看起来「点了没反应」。
    var onOpenTask: (() -> Void)?

    private let store: SessionStore
    private let center: RequestCenter
    private let agents: TaskStore
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let footerBar = NSView()
    private var launchCheckbox: NSButton?

    init(store: SessionStore, center: RequestCenter, agents: TaskStore) {
        self.store = store
        self.center = center
        self.agents = agents
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let effect = RoundedEffectView(frame: NSRect(x: 0, y: 0, width: 392, height: 420))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.cornerRadius = Theme.panelRadius
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Theme.panelRadius
        effect.layer?.masksToBounds = true
        view = effect
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildShell()
    }

    private func buildShell() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: 392)
        ])

        footerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        view.addSubview(footerBar)
        buildFooter()
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerBar.topAnchor),
            footerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    func refresh(force: Bool = false) {
        // 鼠标停在面板上时冻结列表。刷新会重建每一行的视图并重置滚动位置，
        // 如果正好发生在按下鼠标的瞬间，用户会点到另一条任务（点了 A 却打开 B）。
        // 用户主动点「刷新」时例外。
        if !force, let window = view.window, window.isVisible, window.frame.contains(NSEvent.mouseLocation) {
            return
        }
        let previousScroll = scroll.contentView.bounds.origin

        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let tasks = TaskBuilder.tasks(
            agentItems: agents.items,
            store: store,
            pendingIds: center.pendingSessionIds
        )
        let needs = tasks.filter { $0.state == .needsInput }
        let waiting = tasks.filter { $0.state == .waitingInput }
        let stale = tasks.filter { $0.state == .stale }
        let running = tasks.filter { $0.state == .running }
        let completed = tasks.filter { $0.state == .completed }
        let idle = tasks.filter { $0.state == .idle }

        stack.addArrangedSubview(header(
            needs: needs.count,
            waiting: waiting.count,
            stale: stale.count,
            running: running.count,
            completed: completed.count,
            idle: idle.count
        ))
        stack.addArrangedSubview(hintRow())

        if !needs.isEmpty {
            stack.addArrangedSubview(sectionTitle("等你处理", count: needs.count))
            for task in needs { stack.addArrangedSubview(taskRow(task)) }
        }
        if !waiting.isEmpty {
            stack.addArrangedSubview(sectionTitle("等待输入", count: waiting.count))
            for task in waiting { stack.addArrangedSubview(taskRow(task)) }
        }
        if !stale.isEmpty {
            stack.addArrangedSubview(sectionTitle("可能卡住", count: stale.count))
            for task in stale { stack.addArrangedSubview(taskRow(task)) }
        }
        if !running.isEmpty {
            stack.addArrangedSubview(sectionTitle("运行中", count: running.count))
            for task in running { stack.addArrangedSubview(taskRow(task)) }
        }
        if !completed.isEmpty {
            stack.addArrangedSubview(sectionTitle("已完成", count: completed.count))
            for task in completed { stack.addArrangedSubview(taskRow(task)) }
        }
        if !idle.isEmpty {
            stack.addArrangedSubview(sectionTitle("空闲", count: idle.count))
            for task in idle { stack.addArrangedSubview(taskRow(task)) }
        }

        if tasks.isEmpty {
            stack.addArrangedSubview(emptyState())
        }

        launchCheckbox?.state = SMAppService.mainApp.status == .enabled ? .on : .off

        // 先完成一次布局，否则 fittingSize 会偏小，弹层会被截断。
        stack.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        let contentHeight = stack.fittingSize.height
        let height = min(max(contentHeight + 42, 180), 560)
        preferredContentSize = NSSize(width: 392, height: height)
        view.setFrameSize(NSSize(width: 392, height: height))
        view.layoutSubtreeIfNeeded()

        // 重建列表时保持滚动位置（任务多时需要往下滚才能看到已完成项）。
        let documentHeight = scroll.documentView?.frame.height ?? contentHeight
        let maxScrollY = max(0, documentHeight - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(previousScroll.y, maxScrollY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 自测：对每一行的中心点做一次真实 hitTest，打印「这一行 → 实际命中的行」。
    /// 走 window.contentView 的完整命中路径（和真实点击一致），不用自己猜坐标转换。
    /// 面板用 `CLAUDE_DISPATCH_DEMO_AGENTS` 的固定数据，不需要点击、不依赖真实会话。
    func debugHitTestReport() -> [String] {
        stack.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard let window = view.window, let content = window.contentView else {
            return ["no window"]
        }
        return stack.arrangedSubviews.compactMap { subview in
            guard let row = subview as? ClickableRow else { return nil }
            let centerInWindow = row.convert(
                NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil
            )
            let point = content.convert(centerInWindow, from: nil)
            let hitView = content.hitTest(point)
            let hitName = (hitView as? ClickableRow)?.rowTitle
                ?? (hitView.map { String(describing: type(of: $0)) } ?? "nil")
            return "\(row.rowTitle) -> \(hitName)"
        }
    }

    // MARK: - 组件

    private func header(needs: Int, waiting: Int, stale: Int, running: Int, completed: Int, idle: Int) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 392).isActive = true

        let title = Theme.label("Claude Dispatch", size: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        var parts: [String] = []
        if needs > 0 { parts.append("\(needs) 个等你处理") }
        if waiting > 0 { parts.append("\(waiting) 个等待输入") }
        if running > 0 { parts.append("\(running) 个运行中") }
        if completed > 0 { parts.append("\(completed) 个已完成") }
        if stale > 0 { parts.append("\(stale) 个可能卡住") }
        if parts.isEmpty { parts.append("\(idle) 个空闲") }
        let subtitleText = parts.joined(separator: " · ")
        let subtitleColor: NSColor = needs > 0
            ? .systemRed
            : (waiting > 0 ? .systemOrange : .secondaryLabelColor)
        let subtitle = Theme.label(subtitleText, size: 11, color: subtitleColor)
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(subtitle)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10)
        ])
        return container
    }

    private func hintRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 392).isActive = true

        let hint = Theme.label(
            "点击任务打开对应终端会话",
            size: 10,
            color: .tertiaryLabelColor
        )
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            hint.topAnchor.constraint(equalTo: container.topAnchor),
            hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        return container
    }

    private func sectionTitle(_ text: String, count: Int) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 392).isActive = true
        let label = Theme.label(
            "\(text) · \(count)",
            size: 10,
            weight: .semibold,
            color: .tertiaryLabelColor
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])
        return container
    }

    private func taskRow(_ task: TaskItem) -> NSView {
        var detailParts: [String] = [
            task.isBackground ? "后台" : "终端",
            Theme.shortPath(task.cwd)
        ]

        if task.state == .running {
            let start = task.startedAt ?? task.lastActivity ?? Date()
            detailParts.append("已运行 \(Theme.elapsed(start))")
        } else if task.state == .needsInput || task.state == .waitingInput {
            let waitingSince = task.lastActivity ?? task.startedAt ?? Date()
            detailParts.append("已等待 \(Theme.elapsed(waitingSince))")
        }

        let activityText: String?
        switch task.state {
        case .needsInput:
            activityText = "点击处理"
        case .waitingInput:
            activityText = "在终端等待输入 · 点击打开"
        case .stale:
            activityText = "可能卡住 · 最近活动 \(Theme.relativeTime(task.lastActivity ?? Date()))"
        case .running:
            let current = task.activityText ?? "正在运行"
            activityText = "\(current) · 最近活动 \(Theme.relativeTime(task.lastActivity ?? Date()))"
        case .completed:
            activityText = "点击重新打开"
        case .idle:
            activityText = "最近活动 \(Theme.relativeTime(task.lastActivity ?? Date()))"
        }

        let row = ClickableRow(
            title: task.name,
            detail: detailParts.joined(separator: " · "),
            activity: activityText,
            state: task.state,
            status: task.state.label,
            onClick: { [weak self] in self?.open(task) }
        )
        row.toolTip = task.pending
            ? "\(task.cwd)\n点击召回这张确认卡"
            : "\(task.cwd)\n点击打开对应终端会话"
        return row
    }

    private func emptyState() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 392).isActive = true

        let label = Theme.multilineLabel(
            "没有运行中的 Claude Code 会话。\n在终端里启动任务后，这里会自动出现。",
            size: 11.5,
            color: .secondaryLabelColor
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = 320
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    /// 底栏固定在最下方，不跟着列表滚动。
    private func buildFooter() {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.hairline.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(line)

        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .inline
        refresh.font = .systemFont(ofSize: 11)
        refresh.translatesAutoresizingMaskIntoConstraints = false

        let launch = NSButton(
            checkboxWithTitle: "登录时启动",
            target: self,
            action: #selector(launchAtLoginToggled(_:))
        )
        launch.font = .systemFont(ofSize: 10.5)
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launch.translatesAutoresizingMaskIntoConstraints = false
        launchCheckbox = launch

        let quit = NSButton(title: "退出", target: self, action: #selector(quitTapped))
        quit.bezelStyle = .inline
        quit.font = .systemFont(ofSize: 11)
        quit.translatesAutoresizingMaskIntoConstraints = false

        footerBar.addSubview(refresh)
        footerBar.addSubview(launch)
        footerBar.addSubview(quit)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor),
            line.topAnchor.constraint(equalTo: footerBar.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            refresh.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 14),
            refresh.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor),
            launch.centerXAnchor.constraint(equalTo: footerBar.centerXAnchor),
            launch.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor),
            quit.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -14),
            quit.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor)
        ])
    }

    // MARK: - 动作

    @objc private func refreshTapped() {
        store.refresh()
        agents.refresh()
        refresh(force: true)
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 注册失败时把开关恢复原状，避免 UI 状态与真实状态不一致。
            sender.state = sender.state == .on ? .off : .on
            NSSound.beep()
            dispatchLog("launchAtLogin toggle failed: \(error)")
        }
    }

    private func open(_ task: TaskItem) {
        // 先收起面板：交互反馈要立刻发生，后台动作再慢慢做。
        onOpenTask?()
        // 有存活卡片就召回；没有（例如后台任务已 block、hook 已断开）就 attach 进终端。
        if task.pending, center.focus(sessionId: task.sessionId) { return }
        TerminalLauncher.openTask(
            attachId: task.attachId,
            name: task.name,
            cwd: task.cwd,
            isBackground: task.isBackground,
            pid: task.pid,
            sessionId: task.sessionId,
            // 「已完成」只是这一轮跑完，后台会话通常还活着。
            // 对活着的后台会话执行 `claude --resume` 会被拒绝，必须用 attach 进入它的对话。
            resume: task.state == .completed && !task.isAttachable
        )
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 可点击行

private final class ClickableRow: NSView {
    private let onClick: () -> Void
    private let card = NSView()
    private var tracking: NSTrackingArea?
    /// 自测报告用：行标题。
    let rowTitle: String

    init(
        title: String,
        detail: String,
        activity: String?,
        state: TaskState,
        status: String,
        onClick: @escaping () -> Void
    ) {
        self.onClick = onClick
        self.rowTitle = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 392).isActive = true

        card.wantsLayer = true
        // 不做白底卡片：悬停时用极轻的语义色填充，让磨砂材质透出来。
        card.layer?.cornerRadius = 9
        card.layer?.backgroundColor = Self.cardBackground.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let icon = StatusIconView(size: 18)
        icon.configure(state: state)

        let titleLabel = Theme.label(title, size: 12.5, weight: .medium)
        let detailLabel = Theme.label(detail, size: 10.5, color: .secondaryLabelColor)
        let statusLabel = Theme.label(status, size: 10.5, weight: .medium, color: Self.statusColor(state))

        var textViews: [NSView] = [titleLabel, detailLabel]
        if let activity, !activity.isEmpty {
            let activityLabel = Theme.label(activity, size: 10.5, color: .secondaryLabelColor)
            activityLabel.lineBreakMode = .byTruncatingTail
            textViews.append(activityLabel)
        }

        let text = NSStackView(views: textViews)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [icon, text, Theme.spacer(), statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7)
        ])

        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title)，\(status)")
        setAccessibilityHelp("点击打开对应终端会话")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    private static func statusColor(_ state: TaskState) -> NSColor {
        switch state {
        case .needsInput: return .systemRed
        case .waitingInput: return .systemOrange
        case .stale: return .systemOrange
        case .running: return .systemBlue
        case .completed: return .systemGreen
        case .idle: return .tertiaryLabelColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 必须判断点是否落在自己内部。无条件返回 self 会让列表里最后一行吃掉
        // 整块内容区的点击——点任何任务都打开最后一条。
        // 注意：嵌在 flipped document view（滚动容器）里时，父视图链传给 hitTest 的点
        // 有时是父视图坐标系（frame 空间）、有时是自身 bounds 空间，两种都要认，
        // 否则列表只有最后一行能点、其余行点击落空。
        let inOwnBounds = bounds.contains(point)
        let inSuperviewFrame = frame.contains(point)
        return (inOwnBounds || inSuperviewFrame) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private static var cardBackground: NSColor {
        .clear
    }

    private static var cardHoverBackground: NSColor {
        Theme.hoverFill
    }

    override func mouseEntered(with event: NSEvent) {
        card.layer?.backgroundColor = Self.cardHoverBackground.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        card.layer?.backgroundColor = Self.cardBackground.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
