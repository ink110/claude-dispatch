import AppKit

/// Apple HIG 对齐的设计令牌：语义色、统一圆角、最小可读字号、克制的动效。
enum Theme {
    // MARK: - 设计令牌

    static let panelRadius: CGFloat = 14
    static let controlRadius: CGFloat = 7

    /// 半透明材质上的「填充层」：用语义色的低透明度代替白底卡片。
    static var fill: NSColor { .labelColor.withAlphaComponent(0.05) }
    static var fillStrong: NSColor { .labelColor.withAlphaComponent(0.08) }
    static var hoverFill: NSColor { .labelColor.withAlphaComponent(0.07) }
    /// 发丝分割线：比 separatorColor 更轻，不会在浅色界面上显得发黑。
    static var hairline: NSColor { .labelColor.withAlphaComponent(0.09) }

    /// 系统「减弱动态效果」开启时，所有装饰性动画都要让路。
    static var animationsEnabled: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 面板出现：淡入，不做位移动画，避免频繁交互时分散注意力。
    static func fadeIn(_ window: NSWindow?) {
        guard let window else { return }
        guard animationsEnabled else {
            window.alphaValue = 1
            return
        }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        // 同一轮 runloop 里的窗口排序（例如阴影窗口）可能打断动画，
        // 兜底确保面板最终一定可见。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak window] in
            window?.alphaValue = 1
        }
    }

    static func hairlineView(width: CGFloat? = nil) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = hairline.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        if let width {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return view
    }

    static func symbol(
        _ name: String,
        size: CGFloat,
        weight: NSFont.Weight = .medium,
        color: NSColor
    ) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        view.heightAnchor.constraint(equalToConstant: size + 2).isActive = true
        return view
    }

    // MARK: - 文本

    static func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    static func multilineLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.maximumNumberOfLines = 0
        return field
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    static func card(background: NSColor, radius: CGFloat = 9) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = background.cgColor
        view.layer?.cornerRadius = radius
        return view
    }

    static func dot(color: NSColor, size: CGFloat = 8) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.layer?.cornerRadius = size / 2
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size).isActive = true
        view.heightAnchor.constraint(equalToConstant: size).isActive = true
        return view
    }

    static func shortPath(_ path: String) -> String {
        let home = AppConfig.home.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    static func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    static func elapsed(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        if seconds < 86400 {
            let hours = Int(seconds / 3600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时"
        }
        let days = Int(seconds / 86400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)
        return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天"
    }
}
