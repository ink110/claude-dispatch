import AppKit

/// NSVisualEffectView 的材质层默认不会跟随 layer.cornerRadius 裁剪。
/// 只设圆角时会出现「方形材质 + 圆角内容」叠在一起、边缘发黑的观感。
/// 用 maskImage 按圆角裁掉材质，窗口四角才是真正的透明圆角。
class RoundedEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = Theme.panelRadius {
        didSet { needsLayout = true }
    }

    override func layout() {
        super.layout()
        updateMask()
    }

    private func updateMask() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let radius = cornerRadius
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        maskImage = image
    }
}
