import AppKit

/// 常驻悬浮的「脉搏条」：一眼看到有几个任务、谁在等你。
/// 悬停展开会话列表，点击可固定/收起；不抢终端焦点。
final class FloatingBarController {
    private let store: SessionStore
    private let center: RequestCenter
    private let agents: AgentListStore
    private let compactPanel: NSPanel
    private let barView = FloatingBarView()

    private var expandedPanel: NSPanel?
    private var statusController: StatusViewController?
    private var hideWork: DispatchWorkItem?
    private var hoverTimer: Timer?
    private var healthTimer: Timer?
    private var health: HookHealthLevel = .ok
    private var pinned = false

    /// 确认卡会挂在这个区域下方。
    var anchorRect: NSRect? {
        guard compactPanel.isVisible else { return nil }
        return compactPanel.frame
    }

    init(store: SessionStore, center: RequestCenter, agents: AgentListStore) {
        self.store = store
        self.center = center
        self.agents = agents

        let panel = PulsePanel(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 40),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 脉搏条必须能收到真实鼠标点击；拖动由 FloatingBarView 自己处理。
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = barView
        compactPanel = panel

        barView.onClick = { [weak self] in
            guard let self else { return }
            pulseLog("bar onClick health=\(self.health)")
            if case .broken = self.health {
                self.repairHooks()
            } else {
                self.toggleExpanded()
            }
        }
        barView.onHover = { [weak self] inside in
            if inside {
                self?.showExpandedSoon()
            } else {
                self?.hideExpandedSoon()
            }
        }
    }

    func start() {
        restorePosition()
        compactPanel.orderFrontRegardless()
        pulseLog("bar start frame=\(compactPanel.frame) ignoresMouse=\(compactPanel.ignoresMouseEvents) canKey=\(compactPanel.canBecomeKey)")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove),
            name: NSWindow.didMoveNotification,
            object: compactPanel
        )

        checkHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        if let healthTimer { RunLoop.main.add(healthTimer, forMode: .common) }

        refresh()
    }

    deinit {
        healthTimer?.invalidate()
        hoverTimer?.invalidate()
    }

    func refresh() {
        let tasks = TaskBuilder.tasks(
            agentItems: agents.items,
            store: store,
            pendingIds: center.pendingSessionIds
        )
        let pending = tasks.filter { $0.state == .needsInput }.count
        let running = tasks.filter { $0.state == .running }.count
        let stale = tasks.filter { $0.state == .stale }.count
        let completed = tasks.filter { $0.state == .completed }.count
        let idle = tasks.filter { $0.state == .idle }.count

        barView.update(
            pending: pending,
            running: running,
            stale: stale,
            completed: completed,
            idle: idle,
            total: tasks.count,
            health: health
        )

        if !tasks.isEmpty || health != .ok {
            compactPanel.orderFrontRegardless()
        } else {
            compactPanel.orderOut(nil)
            hideExpanded()
        }

        if expandedPanel?.isVisible == true {
            statusController?.refresh()
            positionExpanded()
        }
    }

    // MARK: - 位置

    private func restorePosition() {
        if let raw = UserDefaults.standard.string(forKey: "ClaudePulseFloatingOrigin") {
            let point = NSPointFromString(raw)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(point) }) {
                compactPanel.setFrameOrigin(point)
                return
            }
        }
        positionAtDefault()
    }

    private func positionAtDefault() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        compactPanel.setFrameOrigin(NSPoint(
            x: frame.maxX - compactPanel.frame.width - 18,
            y: frame.maxY - compactPanel.frame.height - 18
        ))
    }

    @objc private func panelDidMove() {
        UserDefaults.standard.set(NSStringFromPoint(compactPanel.frame.origin), forKey: "ClaudePulseFloatingOrigin")
        if expandedPanel?.isVisible == true {
            positionExpanded()
        }
    }

    // MARK: - 展开/收起

    private func toggleExpanded() {
        if let expanded = expandedPanel, expanded.isVisible {
            if pinned {
                hideExpanded()
            } else {
                // 悬停已经打开了列表：这次点击的意图是「固定住」，而不是关掉它。
                pinned = true
                pulseLog("pin expanded")
            }
        } else {
            showExpanded(pin: true)
        }
    }

    private func showExpandedSoon() {
        guard expandedPanel?.isVisible != true else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showExpanded(pin: false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func hideExpandedSoon() {
        guard !pinned else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let expanded = self.expandedPanel, expanded.isVisible {
                let mouse = NSEvent.mouseLocation
                if expanded.frame.contains(mouse) { return }
            }
            self.hideExpanded()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func showExpanded(pin: Bool) {
        pulseLog("showExpanded pin=\(pin)")
        if pin { pinned = true }
        if expandedPanel == nil {
            let controller = StatusViewController(store: store, center: center, agents: agents)
            let panel = PulsePanel(
                contentRect: NSRect(x: 0, y: 0, width: 392, height: 420),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.isMovableByWindowBackground = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.contentViewController = controller
            expandedPanel = panel
            statusController = controller
        }

        statusController?.refresh()
        positionExpanded()
        expandedPanel?.orderFrontRegardless()
        startHoverWatch()
    }

    private func hideExpanded() {
        pinned = false
        hoverTimer?.invalidate()
        hoverTimer = nil
        expandedPanel?.orderOut(nil)
    }

    private func positionExpanded() {
        guard let panel = expandedPanel else { return }
        let size = statusController?.preferredContentSize ?? NSSize(width: 392, height: 420)
        let barFrame = compactPanel.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(barFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? barFrame

        var x = barFrame.maxX - size.width
        var y = barFrame.minY - size.height - 8
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        if y < visible.minY + 8 {
            y = barFrame.maxY + 8
        }

        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 展开后如果鼠标离开脉搏条和面板，0.8 秒后自动收起。
    private func startHoverWatch() {
        hoverTimer?.invalidate()
        var outsideTicks = 0
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.expandedPanel?.isVisible == true else { return }
            let mouse = NSEvent.mouseLocation
            let inBar = self.compactPanel.frame.contains(mouse)
            let inExpanded = self.expandedPanel?.frame.contains(mouse) ?? false
            if inBar || inExpanded {
                outsideTicks = 0
            } else if !self.pinned {
                outsideTicks += 1
                if outsideTicks > 4 {
                    self.hideExpanded()
                }
            }
        }
        if let hoverTimer { RunLoop.main.add(hoverTimer, forMode: .common) }
    }

    // MARK: - 提醒失效检查

    private func checkHealth() {
        health = HookHealth.check()
        refresh()
    }

    private func repairHooks() {
        if HookInstaller.install() {
            health = HookHealth.check()
            refresh()
            ToastPanelController.shared.show(
                title: "提醒已修复",
                body: "新启动的 Claude Code 会话会生效；已经在跑的会话需要重启后才会使用新的提醒。",
                accent: .systemGreen,
                autoDismiss: 7
            )
        } else {
            ToastPanelController.shared.show(
                title: "修复失败",
                body: "请让 Claude Code 运行 ~/Desktop/claude-pulse/scripts/install.sh 重新安装提醒。",
                accent: .systemRed,
                autoDismiss: 9
            )
        }
    }
}

// MARK: - 脉搏条视图

private final class FloatingBarView: NSVisualEffectView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let icon = StatusIconView(size: 14)
    private let label = NSTextField(labelWithString: "")
    /// 活动流 hooks 缺失时显示的黄点（降级提示），不占用状态文案。
    private let degradedDot = Theme.dot(color: .systemOrange, size: 6)
    private var tracking: NSTrackingArea?
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var didDrag = false

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        setAccessibilityRole(.button)
        setAccessibilityLabel("Claude Pulse 任务状态")
        setAccessibilityHelp("点击展开任务列表")

        let stack = NSStackView(views: [icon, label, degradedDot])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        degradedDot.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(
        pending: Int,
        running: Int,
        stale: Int,
        completed: Int,
        idle: Int,
        total: Int,
        health: HookHealthLevel
    ) {
        // 决策 hooks 挂了 = 工具失去了核心能力，整条脉搏条只说这一件事。
        if case .broken = health {
            icon.configure(state: .needsInput)
            label.stringValue = "提醒服务异常 · 点击修复"
            degradedDot.isHidden = true
            return
        }

        let state: TaskState
        let text: String

        if pending > 0 {
            state = .needsInput
            text = "\(pending) 个请求等你处理"
        } else if stale > 0 {
            state = .stale
            text = "\(stale) 个任务可能卡住"
        } else if running > 0 {
            state = .running
            text = "\(running) 个任务运行中"
        } else if completed > 0 && idle == 0 {
            state = .completed
            text = "\(completed) 个任务已完成"
        } else if idle > 0 {
            state = .idle
            text = "\(idle) 个任务空闲"
        } else {
            state = .idle
            text = total > 0 ? "全部空闲" : "没有运行中的任务"
        }

        icon.configure(state: state)
        label.stringValue = text
        degradedDot.isHidden = health != .degraded
    }

    /// 让整条脉搏条都能响应点击，而不只是背景区域。
    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        pulseLog("bar mouseDown")
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart, let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStart.x
        let dy = current.y - dragStart.y
        if abs(dx) + abs(dy) > 3 { didDrag = true }
        window.setFrameOrigin(NSPoint(x: windowStart.x + dx, y: windowStart.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        pulseLog("bar mouseUp didDrag=\(didDrag)")
        let wasDrag = didDrag
        dragStart = nil
        windowStart = nil
        didDrag = false
        if !wasDrag { onClick?() }
    }
}
