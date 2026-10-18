import Foundation

/// 轻量本地调试日志。默认关闭；设置 CLAUDE_PULSE_DEBUG=1 后写入
/// ~/.claude-pulse/debug.log，超过 1MB 自动清空重写，避免无限增长。
func pulseLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["CLAUDE_PULSE_DEBUG"] == "1" else { return }

    let url = AppConfig.stateDir.appendingPathComponent("debug.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    let fm = FileManager.default
    try? fm.createDirectory(at: AppConfig.stateDir, withIntermediateDirectories: true)

    if let attrs = try? fm.attributesOfItem(atPath: url.path),
       let size = attrs[.size] as? Int,
       size > 1_048_576 {
        try? fm.removeItem(at: url)
    }

    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}
