import AppKit

final class MenuBarController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: SessionStore
    private let center: RequestCenter
    private let content: StatusViewController

    init(store: SessionStore, center: RequestCenter) {
        self.store = store
        self.center = center
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.content = StatusViewController(store: store, center: center)

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = content

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Claude Pulse")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "Claude Pulse · 观测所有 Claude Code 会话"
        }
        refresh()
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        let pending = center.pendingCount
        let busy = store.sessions.filter { $0.isBusy }.count

        if pending > 0 {
            button.image = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: "有任务等你处理")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
            button.title = " \(pending)"
        } else {
            button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Claude Pulse")
            button.image?.isTemplate = true
            // 无待确认时，用运行中数量做弱提示；全部空闲则只留图标。
            if busy > 0 {
                button.contentTintColor = .systemOrange
                button.title = " \(busy)"
            } else {
                button.contentTintColor = nil
                button.title = ""
            }
        }
        if popover.isShown { content.refresh() }
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
}

// MARK: - 状态面板

final class StatusViewController: NSViewController {
    private let store: SessionStore
    private let center: RequestCenter
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    init(store: SessionStore, center: RequestCenter) {
        self.store = store
        self.center = center
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 392, height: 420))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
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

        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func refresh() {
        for subview in stack.arrangedSubviews {
            stack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let pending = center.activeRequest
        let queued = center.queuedRequests
        let sessions = store.sessions
        let pendingIds = center.pendingSessionIds

        stack.addArrangedSubview(header(total: sessions.count, pending: center.pendingCount))

        if let pending {
            stack.addArrangedSubview(sectionTitle("需要你处理"))
            stack.addArrangedSubview(requestRow(pending, extra: queued.count))
            for item in queued {
                stack.addArrangedSubview(requestRow(item, extra: nil))
            }
        }

        let busy = sessions.filter { !pendingIds.contains($0.sessionId) && $0.isBusy }
        let idle = sessions.filter { !pendingIds.contains($0.sessionId) && !$0.isBusy }

        if !busy.isEmpty {
            stack.addArrangedSubview(sectionTitle("运行中"))
            for session in busy { stack.addArrangedSubview(sessionRow(session, pending: false)) }
        }
        if !idle.isEmpty {
            stack.addArrangedSubview(sectionTitle("空闲"))
            for session in idle { stack.addArrangedSubview(sessionRow(session, pending: false)) }
        }

        if sessions.isEmpty && pending == nil {
            stack.addArrangedSubview(emptyState())
        }

        stack.addArrangedSubview(footer())

        // 先完成一次布局，否则 fittingSize 会偏小，弹层会被截断。
        stack.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        let contentHeight = stack.fittingSize.height
        let height = min(max(contentHeight, 180), 520)
        preferredContentSize = NSSize(width: 392, height: height)
        view.setFrameSize(NSSize(width: 392, height: height))
        view.layoutSubtreeIfNeeded()

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: 组件

    private func header(total: Int, pending: Int) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 392).isActive = true

        let title = Theme.label("Claude Pulse", size: 14, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = Theme.label(
            pending > 0 ? "\(pending) 个请求等你处理" : "\(total) 个会话在线",
            size: 10.5,
            color: pending > 0 ? .systemOrange : .secondaryLabelColor
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(subtitle)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    private func sectionTitle(_ text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 392).isActive = true
        let label = Theme.label(text.uppercased(), size: 9.5, weight: .semibold, color: .tertiaryLabelColor)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        return container
    }

    private func sessionRow(_ session: SessionRecord, pending: Bool) -> NSView {
        let statusText: String
        let color: NSColor
        if pending {
            statusText = "等你确认"; color = .systemRed
        } else if session.isWaiting {
            statusText = "等待输入"; color = .systemRed
        } else if session.isBusy {
            statusText = "运行中"; color = .systemOrange
        } else {
            statusText = "空闲"; color = .tertiaryLabelColor
        }

        let detailParts = [
            session.isBackground ? "后台" : "终端",
            Theme.shortPath(session.cwd)
        ]
        let row = ClickableRow(
            title: session.displayName,
            detail: detailParts.joined(separator: " · "),
            status: statusText,
            color: color,
            onClick: { [weak self] in self?.jump(to: session) }
        )
        row.toolTip = "\(session.cwd)\n点击跳到对应终端"
        return row
    }

    private func requestRow(_ request: PendingRequest, extra: Int?) -> NSView {
        let kindText: String
        switch request.kind {
        case .permission: kindText = "权限确认 · \(request.toolName)"
        case .question: kindText = "有问题要问你"
        case .plan: kindText = "计划待批准"
        }
        let suffix = extra.map { $0 > 0 ? "（另有 \($0) 个）" : "" } ?? ""
        let row = ClickableRow(
            title: request.sessionName,
            detail: Theme.shortPath(request.cwd) + " · " + kindText + suffix,
            status: "待处理",
            color: .systemRed,
            onClick: { [weak self] in self?.center.focusActive() }
        )
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

    private func footer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 392).isActive = true

        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshTapped))
        refresh.bezelStyle = .inline
        refresh.font = .systemFont(ofSize: 11)
        refresh.translatesAutoresizingMaskIntoConstraints = false

        let quit = NSButton(title: "退出", target: self, action: #selector(quitTapped))
        quit.bezelStyle = .inline
        quit.font = .systemFont(ofSize: 11)
        quit.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(refresh)
        container.addSubview(quit)
        NSLayoutConstraint.activate([
            refresh.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            refresh.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            refresh.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            quit.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            quit.centerYAnchor.constraint(equalTo: refresh.centerYAnchor)
        ])
        return container
    }

    // MARK: 动作

    @objc private func refreshTapped() {
        store.refresh()
        refresh()
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }

    private func jump(to session: SessionRecord) {
        if session.isBackground {
            let script = """
            tell application "Terminal"
                activate
                do script "claude attach \(session.shortId)"
            end tell
            """
            NSAppleScript(source: script)?.executeAndReturnError(nil)
            return
        }
        activateTerminal()
    }

    private func activateTerminal() {
        let bundleIDs = [
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty"
        ]
        for id in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 可点击行

private final class ClickableRow: NSView {
    private let onClick: () -> Void
    private var tracking: NSTrackingArea?

    init(title: String, detail: String, status: String, color: NSColor, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 392).isActive = true

        let dot = Theme.dot(color: color)
        let titleLabel = Theme.label(title, size: 12, weight: .medium)
        let detailLabel = Theme.label(detail, size: 10, color: .secondaryLabelColor)
        let statusLabel = Theme.label(status, size: 10, weight: .medium, color: color)

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [dot, text, Theme.spacer(), statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 7, left: 16, bottom: 7, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick()
    }
}
