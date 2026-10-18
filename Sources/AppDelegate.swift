import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let agents = AgentListStore()
    private let center = RequestCenter()
    private var server: HookServer?
    private var menuBar: MenuBarController?
    private var floatingBar: FloatingBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let token = try loadOrCreateToken()
            let server = HookServer(port: AppConfig.port, token: token) { [weak self] event, respond, registerCancel in
                DispatchQueue.main.async {
                    self?.center.handle(event: event, respond: respond, registerCancel: registerCancel)
                }
            }
            try server.start()
            self.server = server
        } catch {
            showFatal("无法启动本地 hook 服务：\(error.localizedDescription)\n可能已有另一个 Claude Pulse 在运行。")
            return
        }

        store.start()
        agents.start()
        center.store = store
        menuBar = MenuBarController(store: store, center: center, agents: agents)
        floatingBar = FloatingBarController(store: store, center: center, agents: agents)
        floatingBar?.start()

        center.anchorProvider = { [weak self] in self?.floatingBar?.anchorRect }
        center.onChange = { [weak self] in
            self?.menuBar?.refresh()
            self?.floatingBar?.refresh()
        }
        store.onChange = { [weak self] in
            self?.menuBar?.refresh()
            self?.floatingBar?.refresh()
        }
        agents.onChange = { [weak self] in
            self?.menuBar?.refresh()
            self?.floatingBar?.refresh()
        }

        // 调试/演示用：启动时直接展开状态面板
        if CommandLine.arguments.contains("--show-status") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.menuBar?.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        agents.stop()
        server?.stop()
    }

    private func loadOrCreateToken() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: AppConfig.stateDir, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: AppConfig.tokenFile),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }

        let token = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        try token.write(to: AppConfig.tokenFile, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppConfig.tokenFile.path)
        return token
    }

    private func showFatal(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Claude Pulse 启动失败"
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
