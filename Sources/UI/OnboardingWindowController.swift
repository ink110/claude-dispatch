import AppKit

/// 首次启动引导：说明应用做什么，并把 Claude Code hooks 一次装好。
/// 用普通 NSWindow（不是 nonactivating panel），用户可以正常阅读和操作。
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let completedKey = "ClaudeDispatchOnboardingCompleted"

    private let onClose: () -> Void
    private let stack = NSStackView()
    private let statusDot = NSImageView()
    private let statusLabel = Theme.label("", size: 12, weight: .medium)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var primaryButton: NSButton!
    private var didNotifyClose = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Dispatch"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.center()

        super.init(window: window)
        window.delegate = self
        build()
        refreshStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        refreshStatus()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 构建界面

    private func build() {
        guard let window else { return }

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = content

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        stack.addArrangedSubview(makeHeader())
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        for feature in [
            ("lock.shield", "本地运行", "只监听 127.0.0.1，不上传任何代码或对话内容。"),
            ("rectangle.stack.badge.plus", "集中处理", "权限确认、提问和计划批准都出现在浮层里，点一下就能批复。"),
            ("trash", "随时可卸载", "一条命令移除全部 hooks，修改 settings.json 前自动备份。")
        ] {
            stack.addArrangedSubview(makeFeature(symbol: feature.0, title: feature.1, detail: feature.2))
        }

        stack.addArrangedSubview(makeStatusBox())
        stack.setCustomSpacing(12, after: stack.arrangedSubviews.last!)

        messageLabel.font = .systemFont(ofSize: 11.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = true
        messageLabel.preferredMaxLayoutWidth = 464
        stack.addArrangedSubview(messageLabel)

        stack.addArrangedSubview(makeButtons())
        stack.addArrangedSubview(
            Theme.label(
                "提醒依赖 Claude Code 的 hooks；所有处理都在本机完成。",
                size: 10.5,
                color: .tertiaryLabelColor
            )
        )

        relayout()
    }

    private func makeHeader() -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = Theme.label("Claude Dispatch", size: 22, weight: .bold)
        let subtitle = Theme.multilineLabel(
            "集中查看 Claude Code 任务，在需要你确认时直接批复。",
            size: 12.5,
            color: .secondaryLabelColor
        )
        subtitle.preferredMaxLayoutWidth = 380

        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4

        let row = NSStackView(views: [icon, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 464).isActive = true
        return row
    }

    private func makeFeature(symbol: String, title: String, detail: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let titleLabel = Theme.label(title, size: 12.5, weight: .semibold)
        let detailLabel = Theme.multilineLabel(detail, size: 11.5, color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 430

        let texts = NSStackView(views: [titleLabel, detailLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2

        let row = NSStackView(views: [icon, texts])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 464).isActive = true
        return row
    }

    private func makeStatusBox() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 464).isActive = true

        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [statusDot, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        return box
    }

    private func makeButtons() -> NSView {
        let later = NSButton(title: "稍后", target: self, action: #selector(laterTapped))
        later.bezelStyle = .rounded

        primaryButton = NSButton(title: "启用提醒", target: self, action: #selector(primaryTapped))
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"

        let row = NSStackView(views: [Theme.spacer(), later, primaryButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 464).isActive = true
        return row
    }

    private func relayout() {
        guard let window else { return }
        stack.layoutSubtreeIfNeeded()
        let height = max(420, stack.fittingSize.height)
        window.setContentSize(NSSize(width: 520, height: height))
    }

    // MARK: - 状态与操作

    private func refreshStatus() {
        switch HookHealth.check() {
        case .ok:
            statusLabel.stringValue = "提醒服务已启用，可以开始使用。"
            statusDot.contentTintColor = .systemGreen
            primaryButton.title = "完成"
        case .degraded:
            statusLabel.stringValue = "提醒服务部分缺失：还能确认，但任务状态不完整。"
            statusDot.contentTintColor = .systemOrange
            primaryButton.title = "修复提醒"
        case .broken:
            statusLabel.stringValue = "提醒服务未启用：Claude Code 的确认还不会出现在这里。"
            statusDot.contentTintColor = .systemRed
            primaryButton.title = "启用提醒"
        }
    }

    @objc private func primaryTapped() {
        messageLabel.isHidden = false

        if HookHealth.check() == .ok {
            finish()
            return
        }

        if HookInstaller.install() {
            messageLabel.stringValue = "已启用。正在运行的 Claude Code 会话需要重启后才会加载新 hooks。"
            messageLabel.textColor = .systemGreen
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            refreshStatus()
            relayout()
        } else {
            messageLabel.stringValue = "启用失败：请检查 ~/.claude/settings.json 是否可写，然后重试。"
            messageLabel.textColor = .systemRed
            relayout()
        }
    }

    @objc private func laterTapped() {
        close()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didNotifyClose else { return }
        didNotifyClose = true
        onClose()
    }
}
