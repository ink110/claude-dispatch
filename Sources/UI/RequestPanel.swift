import AppKit
import QuartzCore

/// 等待用户处理的浮层：权限确认、Claude 提问、计划批准。
/// 默认只显示中文描述和需要你做的动作；原始命令收在「查看技术细节」里。
/// 非激活面板，不抢终端焦点；点击后才进入输入状态。
final class RequestPanelController: NSWindowController {
    let requestId: String
    private let request: PendingRequest
    private let anchor: NSRect?
    private let onSelect: (String) -> Void
    private let onAction: (UserAction) -> Void

    private var chips: [RequestChip]
    private var activeChipId: String
    private let chipsStack = NSStackView()

    private var selections: [Int: Set<String>] = [:]
    private var optionButtons: [Int: [NSButton]] = [:]
    private var freeTextFields: [Int: NSTextField] = [:]
    private var planFeedbackField: NSTextField?
    private var rawContainer: NSView?
    private var rawButton: NSButton?
    private var rootStack: NSStackView!
    private var isShowingRaw = false

    init(
        request: PendingRequest,
        chips: [RequestChip],
        activeId: String,
        anchor: NSRect?,
        onSelect: @escaping (String) -> Void,
        onAction: @escaping (UserAction) -> Void
    ) {
        self.requestId = request.id
        self.request = request
        self.chips = chips
        self.activeChipId = activeId
        self.anchor = anchor
        self.onSelect = onSelect
        self.onAction = onAction

        let panel = PulsePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 确认卡必须高于脉搏条展开面板，避免互相遮挡。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 确认卡上的按钮必须能用真实鼠标点中；固定在锚点位置，不靠拖动背景移动。
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        super.init(window: panel)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let panel = window as? NSPanel else { return }
        relayout()
        panel.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func updateChips(_ chips: [RequestChip], activeId: String) {
        self.chips = chips
        self.activeChipId = activeId
        rebuildChipButtons()
        relayout()
    }

    private func relayout() {
        guard let panel = window as? NSPanel else { return }
        rootStack.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 440, height: rootStack.fittingSize.height + 32))
        position(panel)
    }

    // MARK: - 提醒升级

    func escalatePulse() {
        guard let view = window?.contentView else { return }
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.systemRed.cgColor

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.55
        animation.duration = 0.35
        animation.autoreverses = true
        animation.repeatCount = 3
        view.layer?.add(animation, forKey: "claudePulse")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak view] in
            view?.layer?.borderWidth = 0
        }
    }

    func raiseToFront() {
        window?.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window?.orderFrontRegardless()
    }

    func moveToScreenUnderMouse() {
        guard let panel = window as? NSPanel, let screen = screenUnderMouse() else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.maxX - size.width - 18,
            y: frame.maxY - size.height - 18
        ))
    }

    // MARK: - 构建界面

    private func build() {
        guard let panel = window else { return }

        // 确认卡承担主要阅读内容，用实色背景保证正文对比度。
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        panel.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        rootStack = stack

        stack.addArrangedSubview(makeHeader())

        chipsStack.orientation = .horizontal
        chipsStack.alignment = .centerY
        chipsStack.spacing = 6
        stack.addArrangedSubview(chipsStack)
        rebuildChipButtons()

        stack.addArrangedSubview(makeSessionLine())

        switch request.kind {
        case .permission:
            stack.addArrangedSubview(makePermissionBody())
        case .plan:
            stack.addArrangedSubview(makePlanBody())
        case .question:
            stack.addArrangedSubview(makeQuestionBody())
        }

        stack.addArrangedSubview(makeFooter())
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!)
    }

    private func makeHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let color: NSColor = {
            switch request.kind {
            case .permission:
                switch request.human.risk {
                case .high: return .systemRed
                case .medium: return .systemOrange
                case .low: return .systemBlue
                }
            case .plan, .question:
                return .systemBlue
            }
        }()

        let symbol: String = {
            switch request.kind {
            case .permission:
                return request.human.risk == .high
                    ? "exclamationmark.triangle.fill"
                    : "lock.shield.fill"
            case .plan:
                return "doc.text.fill"
            case .question:
                return "questionmark.bubble.fill"
            }
        }()

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        row.addArrangedSubview(icon)

        let titleLabel = Theme.label(request.human.title, size: 13.5, weight: .semibold)
        titleLabel.textColor = color
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(Theme.spacer())

        let fallback = NSButton(
            title: request.isBackground ? "在终端打开" : "转回终端",
            target: self,
            action: #selector(fallbackTapped)
        )
        fallback.isBordered = false
        fallback.contentTintColor = .secondaryLabelColor
        fallback.font = .systemFont(ofSize: 10.5)
        fallback.keyEquivalent = "\u{1b}"
        fallback.keyEquivalentModifierMask = []
        row.addArrangedSubview(fallback)
        return row
    }

    // MARK: - 队列 chips

    private func rebuildChipButtons() {
        for view in chipsStack.arrangedSubviews {
            chipsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // 只有一张卡时不显示 chips，避免占用视觉空间。
        chipsStack.isHidden = chips.count <= 1
        for chip in chips {
            let isActive = chip.id == activeChipId
            let color: NSColor = chip.urgent
                ? .systemRed
                : (isActive ? .controlAccentColor : .secondaryLabelColor)
            let font = NSFont.systemFont(ofSize: 10.5, weight: isActive ? .semibold : .regular)
            let button = ChipButton(title: chipLabel(chip.label), target: self, action: #selector(chipTapped(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(chip.id)
            button.isBordered = false
            button.attributedTitle = NSAttributedString(
                string: chipLabel(chip.label),
                attributes: [.foregroundColor: color, .font: font]
            )
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.layer?.backgroundColor = (isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.16)
                : NSColor.secondaryLabelColor.withAlphaComponent(0.10)).cgColor
            chipsStack.addArrangedSubview(button)
        }
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onSelect(id)
    }

    private func chipLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "未命名" }
        return trimmed.count <= 10 ? trimmed : String(trimmed.prefix(9)) + "…"
    }

    private func makeSessionLine() -> NSView {
        let text = "\(request.sessionName)  ·  \(Theme.shortPath(request.cwd))"
        let label = Theme.label(text, size: 11, color: .secondaryLabelColor)
        label.toolTip = request.cwd
        return label
    }

    private func makePermissionBody() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        container.addArrangedSubview(makeSummary(request.human.summary))
        if !request.human.segments.isEmpty {
            container.addArrangedSubview(makeSegments(request.human.segments))
        }
        container.addArrangedSubview(makeDetail(request.human.detail))

        let actionColor: NSColor = request.human.risk == .high ? .systemRed : .controlAccentColor
        container.addArrangedSubview(makeDetail(request.human.action, color: actionColor, weight: .medium))

        if request.human.risk == .high {
            container.addArrangedSubview(
                makeDetail("请确认目标无误，再决定是否允许。", color: .systemRed, size: 10.5)
            )
        }

        if !request.human.rawDetail.isEmpty {
            let button = NSButton(
                title: request.human.rawLabel.isEmpty ? "查看技术细节" : request.human.rawLabel,
                target: self,
                action: #selector(toggleRawTapped(_:))
            )
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.font = .systemFont(ofSize: 10.5)
            button.alignment = .left
            container.addArrangedSubview(button)
            rawButton = button

            let raw = makeTextScroll(request.human.rawDetail, height: 90)
            raw.isHidden = true
            container.addArrangedSubview(raw)
            rawContainer = raw
        }

        return container
    }

    private func makePlanBody() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        container.addArrangedSubview(makeSummary(request.human.summary))
        container.addArrangedSubview(makeDetail(request.human.detail))
        container.addArrangedSubview(makeDetail(request.human.action, color: .controlAccentColor, weight: .medium))
        container.addArrangedSubview(makeTextScroll(request.detailText, height: 230))

        let field = NSTextField()
        field.placeholderString = "要求修改时填写意见（可选）"
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 404).isActive = true
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        container.addArrangedSubview(field)
        planFeedbackField = field
        return container
    }

    private func makeQuestionBody() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeSummary(request.human.summary))
        stack.addArrangedSubview(makeDetail(request.human.detail))
        stack.addArrangedSubview(makeDetail(request.human.action, color: .controlAccentColor, weight: .medium))

        for (index, question) in request.questions.enumerated() {
            if index > 0 { stack.addArrangedSubview(makeDivider()) }

            if !question.header.isEmpty {
                stack.addArrangedSubview(
                    Theme.label(question.header.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor)
                )
            }
            let questionLabel = Theme.multilineLabel(question.question, size: 13, weight: .medium)
            questionLabel.preferredMaxLayoutWidth = 404
            stack.addArrangedSubview(questionLabel)

            if question.multiSelect {
                stack.addArrangedSubview(Theme.label("可多选", size: 10, color: .tertiaryLabelColor))
            }

            for (optionIndex, option) in question.options.enumerated() {
                // 自绘选项行：不用 AppKit 的 radio/switch，避免同一 superview 里的
                // 多个问题被当成一组单选；选中态完全由 selections 字典驱动。
                let row = OptionRowButton(
                    title: option.detail.isEmpty ? option.label : "\(option.label)  —  \(option.detail)",
                    tag: index * 1000 + optionIndex,
                    target: self,
                    action: #selector(optionTapped(_:))
                )
                stack.addArrangedSubview(row)
                optionButtons[index, default: []].append(row)
            }

            let field = NSTextField()
            field.placeholderString = question.options.isEmpty ? "输入你的回答" : "或自己输入回答（可选）"
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 404).isActive = true
            field.heightAnchor.constraint(equalToConstant: 26).isActive = true
            field.target = self
            field.action = #selector(submitTapped)
            stack.addArrangedSubview(field)
            freeTextFields[index] = field
        }

        stack.widthAnchor.constraint(equalToConstant: 404).isActive = true
        return stack
    }

    private func makeSummary(_ text: String) -> NSTextField {
        let label = Theme.multilineLabel(text, size: 14, weight: .semibold)
        label.preferredMaxLayoutWidth = 404
        return label
    }

    /// 复合命令的逐条说明：让用户一眼看清有几步、危险动作在哪一步。
    private func makeSegments(_ segments: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.widthAnchor.constraint(equalToConstant: 404).isActive = true

        stack.addArrangedSubview(
            Theme.label("将依次执行", size: 10, weight: .semibold, color: .tertiaryLabelColor)
        )
        for segment in segments {
            let label = Theme.multilineLabel(segment, size: 11.5, color: .secondaryLabelColor)
            label.preferredMaxLayoutWidth = 404
            stack.addArrangedSubview(label)
        }
        return stack
    }

    private func makeDetail(
        _ text: String,
        color: NSColor = .secondaryLabelColor,
        size: CGFloat = 11.5,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = Theme.multilineLabel(text, size: size, weight: weight, color: color)
        label.preferredMaxLayoutWidth = 404
        return label
    }

    private func makeFooter() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let hint = Theme.label(keyboardHint, size: 10, color: .tertiaryLabelColor)
        row.addArrangedSubview(hint)
        row.addArrangedSubview(Theme.spacer())

        switch request.kind {
        case .permission:
            if request.hasSuggestions {
                let always = NSButton(checkboxWithTitle: "以后都允许同类操作", target: nil, action: nil)
                always.font = .systemFont(ofSize: 10.5)
                row.addArrangedSubview(always)
                always.tag = 9001
            }
            row.addArrangedSubview(makeButton("拒绝", action: #selector(denyTapped), primary: false))
            let allow = makeButton("允许执行", action: #selector(allowTapped), primary: true)
            allow.keyEquivalent = "\r"
            allow.keyEquivalentModifierMask = [.command]
            row.addArrangedSubview(allow)

        case .plan:
            row.addArrangedSubview(makeButton("要求修改", action: #selector(reviseTapped), primary: false))
            let approve = makeButton("批准计划", action: #selector(allowTapped), primary: true)
            approve.keyEquivalent = "\r"
            approve.keyEquivalentModifierMask = [.command]
            row.addArrangedSubview(approve)

        case .question:
            let submit = makeButton("提交回答", action: #selector(submitTapped), primary: true)
            submit.keyEquivalent = "\r"
            submit.keyEquivalentModifierMask = [.command]
            row.addArrangedSubview(submit)
        }
        return row
    }

    private var keyboardHint: String {
        let esc = request.isBackground ? "Esc 在终端打开" : "Esc 转回终端"
        switch request.kind {
        case .permission: return "点击卡片后可用 · ⌘↩ 允许 · \(esc)"
        case .plan: return "点击卡片后可用 · ⌘↩ 批准 · \(esc)"
        case .question: return "点击卡片后可用 · ⌘↩ 提交 · \(esc)"
        }
    }

    private func makeButton(_ title: String, action: Selector, primary: Bool) -> NSButton {
        PillButton(title: title, primary: primary, target: self, action: action)
    }

    private func makeTextScroll(_ text: String, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.35)
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 404).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 388, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 388, height: height)
        textView.maxSize = NSSize(width: 388, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 388, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        scroll.documentView = textView
        return scroll
    }

    private func makeDivider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        view.widthAnchor.constraint(equalToConstant: 404).isActive = true
        return view
    }

    /// 展开技术细节时保持顶部不动、向下生长，避免按钮跳到鼠标下面造成误点。
    private func resizeKeepingTop() {
        guard let panel = window as? NSPanel else { return }
        rootStack.layoutSubtreeIfNeeded()
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: 440, height: rootStack.fittingSize.height + 32))

        var origin = NSPoint(x: panel.frame.origin.x, y: top - panel.frame.height)
        if let screen = screenForAnchor() ?? screenUnderMouse() ?? NSScreen.main {
            let frame = screen.visibleFrame
            if origin.y < frame.minY + 18 {
                origin.y = frame.minY + 18
            }
        }
        panel.setFrameOrigin(origin)
    }

    private func position(_ panel: NSPanel) {
        let screen = screenForAnchor() ?? screenUnderMouse() ?? NSScreen.main
        guard let screenFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin: NSPoint

        if let anchor {
            let anchorFrame = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? screenFrame
            origin = NSPoint(
                x: min(anchor.maxX - size.width, anchorFrame.maxX - size.width - 18),
                y: anchor.minY - size.height - 10
            )
            if origin.y < anchorFrame.minY + 18 {
                origin.y = anchorFrame.maxY - size.height - 18
            }
        } else {
            origin = NSPoint(
                x: screenFrame.maxX - size.width - 18,
                y: screenFrame.maxY - size.height - 18
            )
        }

        panel.setFrameOrigin(origin)
    }

    private func screenForAnchor() -> NSScreen? {
        guard let anchor else { return nil }
        return NSScreen.screens.first { $0.frame.intersects(anchor) }
    }

    private func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    // MARK: - 交互

    @objc private func optionTapped(_ sender: NSButton) {
        let questionIndex = sender.tag / 1000
        let optionIndex = sender.tag % 1000
        guard
            questionIndex < request.questions.count,
            optionIndex < request.questions[questionIndex].options.count
        else { return }

        let question = request.questions[questionIndex]
        let label = question.options[optionIndex].label

        if question.multiSelect {
            var current = selections[questionIndex] ?? []
            if current.contains(label) { current.remove(label) } else { current.insert(label) }
            selections[questionIndex] = current
        } else {
            selections[questionIndex] = [label]
        }
        refreshOptionRows(questionIndex)
    }

    /// 选中态只由 selections 字典决定，每个问题各刷各的，互不影响。
    private func refreshOptionRows(_ questionIndex: Int) {
        let question = request.questions[questionIndex]
        let chosen = selections[questionIndex] ?? []
        for (optionIndex, button) in (optionButtons[questionIndex] ?? []).enumerated() {
            guard optionIndex < question.options.count else { continue }
            let label = question.options[optionIndex].label
            (button as? OptionRowButton)?.setChosen(chosen.contains(label))
        }
    }

    @objc private func allowTapped() {
        let always = (window?.contentView?.viewWithTag(9001) as? NSButton)?.state == .on
        onAction(.allow(always: always))
        close()
    }

    @objc private func denyTapped() {
        onAction(.deny(message: nil))
        close()
    }

    @objc private func reviseTapped() {
        let feedback = planFeedbackField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        onAction(.deny(message: feedback.isEmpty ? "请先不要执行，说明修改思路后再继续。" : feedback))
        close()
    }

    @objc private func submitTapped() {
        var answers: [String: String] = [:]
        for (index, question) in request.questions.enumerated() {
            // 按选项原始顺序拼接，避免按字母排序后答案顺序和界面不一致。
            let chosen = selections[index] ?? []
            let selected = question.options.map(\.label).filter { chosen.contains($0) }
            let typed = freeTextFields[index]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let answer = typed.isEmpty ? selected.joined(separator: ", ") : typed
            guard !answer.isEmpty else {
                NSSound.beep()
                freeTextFields[index]?.becomeFirstResponder()
                freeTextFields[index]?.placeholderString = "这道题还没回答"
                return
            }
            answers[question.question] = answer
        }
        onAction(.answer(answers))
        close()
    }

    @objc private func toggleRawTapped(_ sender: NSButton) {
        isShowingRaw.toggle()
        rawContainer?.isHidden = !isShowingRaw
        sender.title = isShowingRaw
            ? "收起技术细节"
            : (request.human.rawLabel.isEmpty ? "查看技术细节" : request.human.rawLabel)
        resizeKeepingTop()
    }

    @objc private func fallbackTapped() {
        // 交互式会话回落到终端原生提示；后台会话先释放 hook 再 attach 进入任务。
        onAction(request.isBackground ? .attach : .fallback)
        close()
    }
}

/// 自绘按钮：非激活面板里的系统按钮会被系统画成灰色，自绘保证始终清晰可读。
private final class PillButton: NSButton {
    private let normalColor: NSColor
    private let highlightColor: NSColor

    init(title: String, primary: Bool, target: AnyObject?, action: Selector?) {
        normalColor = primary ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.18)
        highlightColor = primary
            ? NSColor.controlAccentColor.blended(withFraction: 0.18, of: .black) ?? NSColor.controlAccentColor
            : NSColor.labelColor.withAlphaComponent(0.28)

        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = normalColor.cgColor

        let textColor: NSColor = primary ? .white : .labelColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: 12, weight: primary ? .semibold : .regular)
            ]
        )
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = highlightColor.cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = normalColor.cgColor
    }
}

/// 卡片头部的会话 chip：比操作按钮更小，整块可点，紧急状态由文字颜色体现。
private final class ChipButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 18, height: 22)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 自绘选项行：整行可点、选中态由代码维护，避免 NSButton radio 跨问题联动。
private final class OptionRowButton: NSButton {
    private let titleText: String
    private var chosen = false

    init(title: String, tag: Int, target: AnyObject?, action: Selector?) {
        titleText = title
        super.init(frame: .zero)
        self.tag = tag
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 404).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setChosen(_ value: Bool) {
        guard chosen != value else { return }
        chosen = value
        applyStyle()
    }

    private func applyStyle() {
        layer?.backgroundColor = (chosen
            ? NSColor.controlAccentColor.withAlphaComponent(0.14)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.06)).cgColor
        layer?.borderColor = (chosen
            ? NSColor.controlAccentColor.withAlphaComponent(0.55)
            : NSColor.separatorColor.withAlphaComponent(0.5)).cgColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 12
        paragraph.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(
            string: titleText,
            attributes: [
                .foregroundColor: chosen ? NSColor.controlAccentColor : NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 12, weight: chosen ? .semibold : .regular),
                .paragraphStyle: paragraph
            ]
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        super.mouseDown(with: event)
        applyStyle()
    }
}
