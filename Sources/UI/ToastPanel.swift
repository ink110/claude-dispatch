import AppKit

/// 任务完成 / 状态变化的轻提示，不抢焦点，几秒后自动消失。
final class ToastPanelController {
    static let shared = ToastPanelController()

    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?

    func show(title: String, body: String, accent: NSColor, autoDismiss: TimeInterval = 4.5) {
        dismissWork?.cancel()
        panel?.close()

        let width: CGFloat = 360
        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        header.addArrangedSubview(Theme.dot(color: accent))
        header.addArrangedSubview(Theme.label(title, size: 12.5, weight: .semibold))
        stack.addArrangedSubview(header)

        let bodyLabel = Theme.multilineLabel(body, size: 11.5, color: .secondaryLabelColor)
        bodyLabel.preferredMaxLayoutWidth = width - 32
        stack.addArrangedSubview(bodyLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: width)
        ])

        let panel = makePanel(root: root)
        let size = stack.fittingSize
        panel.setContentSize(NSSize(width: width, height: max(64, size.height)))
        position(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self, weak panel] in
            panel?.close()
            if self?.panel === panel { self?.panel = nil }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismiss, execute: work)
    }

    private func makePanel(root: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = root
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 18, y: frame.maxY - size.height - 18))
    }
}
