import AppKit

/// 等待用户处理的浮层：权限确认、Claude 提问、计划批准。
/// 非激活面板，不抢终端焦点；点击后才进入输入状态。
final class RequestPanelController: NSWindowController {
    private let request: PendingRequest
    private let queueRemaining: Int
    private let onAction: (UserAction) -> Void

    private var selections: [Int: Set<String>] = [:]
    private var optionButtons: [Int: [NSButton]] = [:]
    private var freeTextFields: [Int: NSTextField] = [:]
    private var planFeedbackField: NSTextField?
    private var rootStack: NSStackView!

    init(request: PendingRequest, queueRemaining: Int, onAction: @escaping (UserAction) -> Void) {
        self.request = request
        self.queueRemaining = queueRemaining
        self.onAction = onAction

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        super.init(window: panel)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let panel = window as? NSPanel else { return }
        panel.setContentSize(NSSize(width: 440, height: rootStack.fittingSize.height + 32))
        position(panel)
        panel.orderFrontRegardless()
    }

    // MARK: - 构建界面

    private func build() {
        guard let panel = window else { return }

        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true
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

        let (title, color, symbol): (String, NSColor, String) = {
            switch request.kind {
            case .permission:
                let risky = isRisky(request.detailText)
                return (risky ? "高风险操作，需要确认" : "需要你确认", risky ? .systemRed : .systemOrange, risky ? "exclamationmark.triangle.fill" : "lock.shield.fill")
            case .plan:
                return ("计划等待批准", .systemBlue, "doc.text.fill")
            case .question:
                return ("Claude 有问题要问你", .systemBlue, "questionmark.bubble.fill")
            }
        }()

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        row.addArrangedSubview(icon)

        let titleLabel = Theme.label(title, size: 13.5, weight: .semibold)
        titleLabel.textColor = color
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(Theme.spacer())

        if queueRemaining > 0 {
            row.addArrangedSubview(Theme.label("还有 \(queueRemaining) 个", size: 10.5, color: .secondaryLabelColor))
        }

        let fallback = NSButton(title: "转回终端", target: self, action: #selector(fallbackTapped))
        fallback.isBordered = false
        fallback.contentTintColor = .secondaryLabelColor
        fallback.font = .systemFont(ofSize: 10.5)
        fallback.keyEquivalent = "\u{1b}"
        fallback.keyEquivalentModifierMask = []
        row.addArrangedSubview(fallback)
        return row
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

        let toolLabel = Theme.label(request.toolName.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor)
        container.addArrangedSubview(toolLabel)
        container.addArrangedSubview(makeTextScroll(request.detailText, height: 110))

        if isRisky(request.detailText) {
            let warning = Theme.label("这条命令可能删除数据或影响远程仓库，请逐字核对。", size: 10.5, color: .systemRed)
            container.addArrangedSubview(warning)
        }
        return container
    }

    private func makePlanBody() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

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

        for (index, question) in request.questions.enumerated() {
            if index > 0 { stack.addArrangedSubview(makeDivider()) }

            if !question.header.isEmpty {
                stack.addArrangedSubview(Theme.label(question.header.uppercased(), size: 10, weight: .semibold, color: .secondaryLabelColor))
            }
            let questionLabel = Theme.multilineLabel(question.question, size: 13, weight: .medium)
            questionLabel.preferredMaxLayoutWidth = 404
            stack.addArrangedSubview(questionLabel)

            if question.multiSelect {
                stack.addArrangedSubview(Theme.label("可多选", size: 10, color: .tertiaryLabelColor))
            }

            for (optionIndex, option) in question.options.enumerated() {
                let button = NSButton(
                    title: option.detail.isEmpty ? option.label : "\(option.label)  —  \(option.detail)",
                    target: self,
                    action: #selector(optionTapped(_:))
                )
                button.tag = index * 1000 + optionIndex
                button.alignment = .left
                button.font = .systemFont(ofSize: 12)
                button.bezelStyle = .rounded
                (button.cell as? NSButtonCell)?.usesSingleLineMode = false
                (button.cell as? NSButtonCell)?.wraps = true
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: 404).isActive = true
                // 单选使用 radio 语义，多选使用 checkbox 语义，辅助功能也能正确朗读。
                button.setButtonType(question.multiSelect ? .switch : .radio)
                stack.addArrangedSubview(button)
                optionButtons[index, default: []].append(button)
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

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 404).isActive = true
        return stack
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
            let allow = makeButton("允许", action: #selector(allowTapped), primary: true)
            allow.keyEquivalent = "\r"
            allow.keyEquivalentModifierMask = [.command]
            row.addArrangedSubview(allow)

        case .plan:
            row.addArrangedSubview(makeButton("要求修改", action: #selector(reviseTapped), primary: false))
            let approve = makeButton("批准", action: #selector(allowTapped), primary: true)
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
        request.kind == .question ? "⌘↩ 提交 · Esc 转回终端" : "⌘↩ 允许 · Esc 转回终端"
    }

    private func makeButton(_ title: String, action: Selector, primary: Bool) -> NSButton {
        let button = PillButton(title: title, primary: primary, target: self, action: action)
        return button
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

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 18, y: frame.maxY - size.height - 18))
    }

    private func isRisky(_ command: String) -> Bool {
        let patterns = ["rm -rf", "rm -r ", "sudo ", "git push --force", "git reset --hard", "mkfs", "dd if=", ":(){", "truncate "]
        let lower = command.lowercased()
        return patterns.contains { lower.contains($0) }
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
            sender.state = current.contains(label) ? .on : .off
        } else {
            selections[questionIndex] = [label]
            for (index, button) in (optionButtons[questionIndex] ?? []).enumerated() {
                button.state = index == optionIndex ? .on : .off
            }
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
        let feedback = planFeedbackField?.stringValue ?? ""
        onAction(.deny(message: feedback.isEmpty ? "请根据我的批注修改计划" : feedback))
        close()
    }

    @objc private func submitTapped() {
        var answers: [String: String] = [:]
        for (index, question) in request.questions.enumerated() {
            let selected = Array(selections[index] ?? []).sorted()
            let typed = freeTextFields[index]?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let answer = selected.isEmpty ? typed : selected.joined(separator: ", ")
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

    @objc private func fallbackTapped() {
        onAction(.fallback)
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

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = highlightColor.cgColor
        super.mouseDown(with: event)
        layer?.backgroundColor = normalColor.cgColor
    }
}
