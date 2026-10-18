import Foundation
import Darwin

/// 轮询 Claude Code 的会话注册表，得到所有存活会话的实时状态。
/// 注册表由 Claude Code 自己维护，比解析 transcript 更准也更便宜。
final class SessionStore {
    private(set) var sessions: [SessionRecord] = []
    private var timer: Timer?
    private var lastSignature = ""
    var onChange: (() -> Void)?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let dir = AppConfig.home.appendingPathComponent(".claude/sessions")
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            update([])
            return
        }

        var loaded: [SessionRecord] = []
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let record = try? JSONDecoder().decode(SessionRecord.self, from: data)
            else { continue }
            guard isAlive(pid: record.pid) else { continue }
            loaded.append(record)
        }

        loaded.sort { lhs, rhs in
            if lhs.isWaiting != rhs.isWaiting { return lhs.isWaiting }
            if lhs.isBusy != rhs.isBusy { return lhs.isBusy }
            return lhs.lastActivity > rhs.lastActivity
        }
        update(loaded)
    }

    private func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func update(_ newSessions: [SessionRecord]) {
        let signature = newSessions
            .map { "\($0.sessionId)|\($0.status ?? "")|\($0.name ?? "")|\($0.updatedAt ?? 0)" }
            .joined(separator: ",")
        guard signature != lastSignature else { return }
        lastSignature = signature
        sessions = newSessions
        onChange?()
    }
}
