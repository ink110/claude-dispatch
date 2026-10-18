import Foundation

/// 轻量本地调试日志，只在排查点击/状态问题时使用。
func pulseLog(_ message: String) {
    let url = AppConfig.stateDir.appendingPathComponent("debug.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url)
    }
}
