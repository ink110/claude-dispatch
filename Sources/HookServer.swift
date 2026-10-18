import Foundation
import Network

enum HookHTTPResult {
    case json([String: Any])
    /// 2xx 空 body：成功、无决策，不参与多 hook 合并（活动流与非决策事件用）。
    case empty
    case fail
}

/// 只监听 127.0.0.1 的极小 HTTP 服务，用来接收 Claude Code hooks。
///
/// 线程模型（务必遵守）：
/// - 所有连接可变状态（解析缓冲、responded、cancelHandlers）只在 `queue` 上读写；
/// - App 层（主线程）拿到的 respond 闭包可以任意线程调用，本类负责切回 `queue`；
/// - 绝不在 queue 之外触碰 NWConnection 的 send/receive/cancel。
final class HookServer {
    typealias EventHandler = (
        [String: Any],
        @escaping (HookHTTPResult) -> Void,
        @escaping (@escaping () -> Void) -> Void
    ) -> Void

    private let port: UInt16
    private let token: String
    private let onEvent: EventHandler
    /// GET /status 的数据源。必须在任意线程安全（内部自带锁），因为在 `queue` 上被调用。
    var statusProvider: (() -> Data?)?
    fileprivate let queue = DispatchQueue(label: "com.ink.claudedispatch.http")
    private var listener: NWListener?
    private let connectionLock = NSLock()
    private var connections: [ObjectIdentifier: Connection] = [:]

    init(port: UInt16, token: String, onEvent: @escaping EventHandler) {
        self.port = port
        self.token = token
        self.onEvent = onEvent
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let handler = Connection(nw: connection, server: self)
            self.connectionLock.lock()
            self.connections[ObjectIdentifier(handler)] = handler
            self.connectionLock.unlock()
            handler.start()
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("[ClaudeDispatch] listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    fileprivate func dispatch(
        event: [String: Any],
        respond: @escaping (HookHTTPResult) -> Void,
        registerCancel: @escaping (@escaping () -> Void) -> Void
    ) {
        onEvent(event, respond, registerCancel)
    }

    fileprivate func release(_ connection: Connection) {
        connectionLock.lock()
        connections[ObjectIdentifier(connection)] = nil
        connectionLock.unlock()
    }

    fileprivate func isAuthorized(query: [String: String], headers: [String: String]) -> Bool {
        if query["token"] == token { return true }
        if let auth = headers["authorization"], auth == "Bearer \(token)" { return true }
        return false
    }

    fileprivate func statusSnapshot() -> Data? {
        statusProvider?()
    }
}

// MARK: - 单个连接

private final class Connection {
    private let nw: NWConnection
    private unowned let server: HookServer

    // 以下所有可变状态只在 server.queue 上读写。
    private var buffer = Data()
    private var headersDone = false
    private var contentLength = 0
    private var responded = false
    private var disposed = false
    private var cancelHandlers: [() -> Void] = []
    private var method = ""
    private var path = ""
    private var query: [String: String] = [:]
    private var headers: [String: String] = [:]

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    init(nw: NWConnection, server: HookServer) {
        self.nw = nw
        self.server = server
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                if let self {
                    // 客户端在回复前断开（进程退出、hook 超时、任务被停掉）：
                    // 通知上层把这条待处理请求移除，避免留下永远点不完的幽灵弹窗。
                    self.fireCancelIfNeeded()
                    self.server.release(self)
                }
            default:
                break
            }
        }
        nw.start(queue: server.queue)
        receive()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            self.process()
            if error == nil && !self.responded {
                if isComplete && self.buffer.isEmpty {
                    self.fireCancelIfNeeded()
                    self.nw.cancel()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func process() {
        guard !responded else { return }

        if !headersDone {
            guard let range = buffer.range(of: Self.headerTerminator) else { return }
            let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
            parseHead(head)
            buffer = Data(buffer[range.upperBound...])
            headersDone = true
        }

        guard headersDone, buffer.count >= contentLength else { return }
        let body = Data(buffer.prefix(contentLength))
        // 必须消费掉 body，否则连接关闭时 buffer 永远非空，
        // isComplete 分支不会触发，失效请求也就不会自动清理。
        buffer = Data(buffer.dropFirst(contentLength))
        handle(body: body)
    }

    private func parseHead(_ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        method = String(parts[0])
        let rawTarget = String(parts[1])

        if let comps = URLComponents(string: "http://127.0.0.1" + rawTarget) {
            path = comps.path
            for item in comps.queryItems ?? [] {
                if let value = item.value { query[item.name] = value }
            }
        }

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if let length = headers["content-length"], let n = Int(length) {
            contentLength = max(0, n)
        }
    }

    private func handle(body: Data) {
        // 排障端点：GET /status 返回 App 状态快照（只读）。
        if path == "/status" {
            guard method == "GET" else {
                respondJSON(status: 405, object: ["error": "method not allowed"])
                return
            }
            guard server.isAuthorized(query: query, headers: headers) else {
                respondJSON(status: 401, object: ["error": "unauthorized"])
                return
            }
            if let snapshot = server.statusSnapshot() {
                respondRaw(status: 200, contentType: "application/json", body: snapshot)
            } else {
                respondJSON(status: 503, object: ["error": "status unavailable"])
            }
            return
        }

        guard method == "POST" else {
            respondJSON(status: 405, object: ["error": "method not allowed"])
            return
        }
        guard server.isAuthorized(query: query, headers: headers) else {
            respondJSON(status: 401, object: ["error": "unauthorized"])
            return
        }
        guard path == "/hook" else {
            respondJSON(status: 404, object: ["error": "not found"])
            return
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            var event = object as? [String: Any]
        else {
            respondJSON(status: 400, object: ["error": "invalid json"])
            return
        }

        // 活动流 hook 与决策 hook 使用不同的 URL，避免同一事件被处理两次。
        if let mode = query["mode"] {
            event["_claude_dispatch_mode"] = mode
        }

        server.dispatch(
            event: event,
            respond: { [weak self] result in
                guard let self else { return }
                // App 层可能在主线程调用；统一切回连接队列再写 socket。
                self.server.queue.async {
                    self.apply(result)
                }
            },
            registerCancel: { [weak self] handler in
                guard let self else { return }
                // 注册也要在连接队列上落地，保证与 fireCancel 的先后关系可判定：
                // 已断开（disposed）则立即触发清理，否则登记等断开时触发。
                self.server.queue.async {
                    self.registerCancelOnQueue(handler)
                }
            }
        )
    }

    private func apply(_ result: HookHTTPResult) {
        switch result {
        case .json(let payload):
            respondJSON(status: 200, object: payload)
        case .empty:
            respondRaw(status: 200, contentType: "application/json", body: Data())
        case .fail:
            // 非 2xx 会让 hook 失效，Claude Code 自动回落到终端原生确认。
            respondJSON(status: 500, object: ["error": "no answer; fall back to terminal"])
        }
    }

    private func registerCancelOnQueue(_ handler: @escaping () -> Void) {
        if disposed {
            handler()
        } else {
            cancelHandlers.append(handler)
        }
    }

    private func fireCancelIfNeeded() {
        guard !responded, !disposed else { return }
        disposed = true
        let handlers = cancelHandlers
        cancelHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private func respondJSON(status: Int, object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        respondRaw(status: status, contentType: "application/json", body: body)
    }

    private func respondRaw(status: Int, contentType: String, body: Data) {
        guard !responded else { return }
        responded = true

        let reason = status == 200 ? "OK"
            : (status == 401 ? "Unauthorized"
            : (status == 404 ? "Not Found"
            : (status == 405 ? "Method Not Allowed" : "Internal Server Error")))
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)

        nw.send(content: out, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.nw.cancel()
            self.server.release(self)
        })
    }
}
