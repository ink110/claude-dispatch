import AppKit
import QuartzCore

/// 任务状态图标：完成=绿色勾、运行中=蓝色旋转、空闲=灰色咖啡、警告=红色铃铛。
/// 静态图标使用 macOS 原生矢量图标（SF Symbols），支持 tint 和动画。
/// 运行中的旋转指示器是自绘圆弧（CAShapeLayer）：Apple 为旋转设计的
/// progress.activity 在 AppKit 的 NSImageView 里渲染不出内容（实测，
/// macOS 26），而 arrow.triangle.2.circlepath 的字形中心随 pointSize
/// 取整偏移（16pt 偏心 ~1px，旋转时质心漂移 2.2px；13/18pt 不漂）。
/// 自绘圆弧的圆心由构造保证在图层中心，旋转零漂移。
final class StatusIconView: NSView {
    private let imageView = NSImageView()
    private let iconSize: CGFloat
    private var currentState: TaskState?
    private var arcLayer: CAShapeLayer?

    init(size: CGFloat = 13) {
        self.iconSize = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        heightAnchor.constraint(equalToConstant: size + 2).isActive = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: size),
            imageView.heightAnchor.constraint(equalToConstant: size)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(state: TaskState) {
        guard state != currentState else { return }
        let hadState = currentState != nil
        currentState = state

        let symbol: String
        let color: NSColor
        var spins = false
        var pulses = false

        switch state {
        case .completed:
            symbol = "checkmark.circle.fill"
            color = .systemGreen
        case .running:
            symbol = ""
            color = .systemBlue
            spins = true
        case .idle:
            symbol = "cup.and.saucer.fill"
            color = .secondaryLabelColor
        case .needsInput:
            symbol = "bell.fill"
            color = .systemRed
            pulses = true
        case .waitingInput:
            symbol = "hourglass"
            color = .systemOrange
        case .stale:
            symbol = "exclamationmark.triangle.fill"
            color = .systemOrange
            pulses = true
        }

        imageView.layer?.removeAllAnimations()
        arcLayer?.removeAllAnimations()

        if state == .running {
            // 自绘旋转圆弧；SF Symbols 方案见类型注释。
            imageView.isHidden = true
            let arc = makeArcLayer()
            arc.isHidden = false
            arc.strokeColor = color.cgColor
        } else {
            arcLayer?.isHidden = true
            imageView.isHidden = false
            imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.label)
            imageView.contentTintColor = color
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
        }
        wantsLayer = true
        layoutSubtreeIfNeeded()

        // 状态切换时短促淡入淡出，替代生硬的图标跳变。
        if hadState, Theme.animationsEnabled {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(fade, forKey: "stateFade")
        }

        if spins, Theme.animationsEnabled {
            // 圆弧绕图层中心旋转：anchorPoint 默认 (0.5, 0.5)，
            // 圆心由构造放在中心，旋转中心不漂移。
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = CGFloat.pi * 2
            rotation.duration = 1.2
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            rotation.isRemovedOnCompletion = false
            arcLayer?.add(rotation, forKey: "statusSpin")
        }

        if pulses, Theme.animationsEnabled, !imageView.isHidden {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.65
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            imageView.layer?.add(pulse, forKey: "statusPulse")
        }
    }

    override func layout() {
        super.layout()
        updateArcPath()
    }

    /// 创建（或复用）旋转圆弧图层。缺口朝右上方，线帽圆角，视觉等同系统菊花。
    @discardableResult
    private func makeArcLayer() -> CAShapeLayer {
        if let arcLayer { return arcLayer }
        let arc = CAShapeLayer()
        arc.fillColor = nil
        arc.lineWidth = iconSize >= 16 ? 2.2 : 2.0
        arc.lineCap = .round
        arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        wantsLayer = true
        layer?.addSublayer(arc)
        self.arcLayer = arc
        updateArcPath()
        return arc
    }

    /// 圆弧路径按当前 bounds 重建：圆心 = bounds 中心。
    /// 放在 layout() 里而不是 layoutSubviews 之后，保证任意时刻都对齐。
    private func updateArcPath() {
        guard let arcLayer, !arcLayer.isHidden else { return }
        let b = bounds
        arcLayer.frame = b
        arcLayer.position = CGPoint(x: b.midX, y: b.midY)
        let radius = max(0, min(b.width, b.height) / 2 - arcLayer.lineWidth)
        let gap: CGFloat = 1.25  // 缺口弧度（约 72°）
        let start: CGFloat = -.pi / 2 + gap / 2
        let end: CGFloat = .pi * 3 / 2 - gap / 2
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: b.width / 2, y: b.height / 2),
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        arcLayer.path = path
    }
}
