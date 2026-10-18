import AppKit
import QuartzCore

/// 任务状态图标：完成=绿色勾、运行中=蓝色旋转、空闲=灰色咖啡、警告=红色铃铛。
/// 使用 macOS 原生矢量图标（SF Symbols），支持 tint 和动画，效果等同 SVG。
final class StatusIconView: NSView {
    private let imageView = NSImageView()
    private let iconSize: CGFloat
    private var currentState: TaskState?

    init(size: CGFloat = 13) {
        self.iconSize = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size + 2).isActive = true
        heightAnchor.constraint(equalToConstant: size + 2).isActive = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
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
            symbol = "arrow.triangle.2.circlepath"
            color = .systemBlue
            spins = true
        case .idle:
            symbol = "cup.and.saucer.fill"
            color = .secondaryLabelColor
        case .needsInput:
            symbol = "bell.fill"
            color = .systemRed
            pulses = true
        case .stale:
            symbol = "exclamationmark.triangle.fill"
            color = .systemOrange
            pulses = true
        }

        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.label)
        imageView.contentTintColor = color
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
        imageView.wantsLayer = true
        imageView.layer?.removeAllAnimations()

        if spins {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = CGFloat.pi * 2
            rotation.duration = 1.4
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = false
            imageView.layer?.add(rotation, forKey: "statusSpin")
        }

        if pulses {
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
}
