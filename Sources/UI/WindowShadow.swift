import AppKit

/// 给透明无边框面板补一层圆角软阴影。
///
/// 不能直接用 `NSWindow.hasShadow`：系统按矩形窗口形状画阴影，
/// 会在圆角材质外侧留下一圈深色轮廓，看起来就是黑色描边。
/// 这里用一个更大的透明窗口承载圆角 `shadowPath`，主面板保持无阴影。
final class WindowShadow {
    private let gutter: CGFloat
    private let panel: NSPanel
    private weak var target: NSWindow?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?

    init(target: NSWindow, cornerRadius: CGFloat, gutter: CGFloat = 26) {
        self.target = target
        self.gutter = gutter

        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = target.collectionBehavior
        // 比主面板低一层，只露出周围的阴影，不遮挡内容。
        panel.level = NSWindow.Level(rawValue: target.level.rawValue - 1)
        panel.contentView = ShadowView(gutter: gutter, cornerRadius: cornerRadius)

        // 拖动、改变大小、切换屏幕时自动跟随，不用每个调用点手动同步。
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: target,
            queue: .main
        ) { [weak self] _ in self?.sync() }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: target,
            queue: .main
        ) { [weak self] _ in self?.sync() }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        panel.orderOut(nil)
    }

    func show() {
        guard let target, target.isVisible else { return }
        sync()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func sync() {
        guard let target else { return }
        panel.setFrame(target.frame.insetBy(dx: -gutter, dy: -gutter), display: false)
        panel.contentView?.needsLayout = true
        panel.contentView?.layer?.setNeedsLayout()
    }
}

private final class ShadowView: NSView {
    private let gutter: CGFloat
    private let cornerRadius: CGFloat

    init(gutter: CGFloat, cornerRadius: CGFloat) {
        self.gutter = gutter
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 20
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    private func updateShadowPath() {
        guard bounds.width > gutter * 2, bounds.height > gutter * 2 else { return }
        let rect = bounds.insetBy(dx: gutter, dy: gutter)
        layer?.shadowPath = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }
}
