import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let agents = TaskStore()
    private let center = RequestCenter()
    private var server: HookServer?
    private var menuBar: MenuBarController?
    private var floatingBar: FloatingBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let token = try TokenStore.loadOrCreate()
            let server = HookServer(port: AppConfig.port, token: token) { [weak self] event, respond, registerCancel in
                DispatchQueue.main.async {
                    self?.center.handle(event: event, respond: respond, registerCancel: registerCancel)
                }
            }
            server.statusProvider = { [weak self] in self?.center.snapshotData() }
            try server.start()
            self.server = server
        } catch {
            showFatal("无法启动本地 hook 服务：\(error.localizedDescription)\n可能已有另一个 Claude Pulse 在运行。")
            return
        }

        store.start()
        agents.start()
        center.store = store
        center.dataDegradedProvider = { [weak self] in self?.agents.isDegraded ?? false }
        center.healthProvider = { HookHealth.check() }
        center.backgroundProvider = { [weak self] sessionId in
            guard let self else { return false }
            if let record = self.store.sessions.first(where: { $0.sessionId == sessionId }) {
                return record.isBackground
            }
            return self.agents.items.first(where: { $0.sessionId == sessionId })?.isBackground ?? false
        }
        menuBar = MenuBarController(store: store, center: center, agents: agents)
        floatingBar = FloatingBarController(store: store, center: center, agents: agents)
        floatingBar?.start()
        menuBar?.onPopoverVisibilityChange = { [weak self] visible in
            self?.floatingBar?.setSuppressed(visible)
        }

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

        configureLaunchAtLoginIfNeeded()

        // 调试/演示用：启动时直接展开状态面板
        if CommandLine.arguments.contains("--show-status") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.menuBar?.showPopover()
            }
        }

        // 排障：在真实 App 进程里验证「点卡片 → 聚焦终端标签页」链路。
        if let raw = ProcessInfo.processInfo.environment["CLAUDE_PULSE_FOCUS_PID"],
           let pid = Int32(raw) {
            let sessionId = ProcessInfo.processInfo.environment["CLAUDE_PULSE_FOCUS_SESSION"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                TerminalLauncher.openTask(
                    attachId: nil,
                    name: "Claude Pulse 测试",
                    isBackground: false,
                    pid: pid,
                    sessionId: sessionId
                )
            }
        }
    }

    /// 首次从 ~/Applications 启动时默认开启登录自启；之后由状态面板里的开关控制。
    private func configureLaunchAtLoginIfNeeded() {
        let key = "ClaudePulseLaunchAtLoginInitialized"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let installedPath = AppConfig.home.appendingPathComponent("Applications/ClaudePulse.app").path
        guard Bundle.main.bundlePath == installedPath else { return }
        if SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        agents.stop()
        server?.stop()
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
