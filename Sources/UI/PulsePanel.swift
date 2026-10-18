import AppKit

/// 无边框 NSPanel 默认 `canBecomeKey == false`，真实鼠标点击可能收不到。
/// 允许面板成为 key（仍然不会激活 App），这样按钮和自定义视图都能正常响应点击。
final class PulsePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
