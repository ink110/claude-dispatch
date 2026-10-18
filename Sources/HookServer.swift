import Foundation
import Network

enum HookHTTPResult {
    case json([String: Any])
    case fail
}

/// 只监听 127.0.0.1 的极小 HTTP 服务，用来接收 Claude Code hooks。
/// 每个请求都校验 token；阻塞型请求会一直保持连接，直到用户在浮层上做出选择。
final class HookServer {
    typealias EventHandler = (
        [String: Any],
        @escaping (HookHTTPResult) -> Void,
        @escaping (@escaping () -> Void) -> Void
    ) -> Void

    private let port: UInt16
    private let token: String
    private let onEvent: EventHandler
    fileprivate let queue = DispatchQueue(label: "com.ink.claudepulse.http")
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
                NSLog("[ClaudePulse] listener failed: \(error)")
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
}

// MARK: - 单个连接

private final class Connection {
    private let nw: NWConnection
    private unowned let server: HookServer
    private var buffer = Data()
    private var headersDone = false
    private var contentLength = 0
    private var responded = false
    private var method = ""
    private var path = ""
    private var query: [String: String] = [:]
    private var headers: [String: String] = [:]
    private let cancelLock = NSLock()
    private var cancelHandlers: [() -> Void] = []
    private var disposed = false

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
            event["_claude_pulse_mode"] = mode
        }

        server.dispatch(
            event: event,
            respond: { [weak self] result in
                guard let self else { return }
                switch result {
                case .json(let payload):
                    self.respondJSON(status: 200, object: payload)
                case .fail:
                    // 非 2xx 会让 hook 失效，Claude Code 自动回落到终端原生弹窗。
                    self.respondJSON(status: 500, object: ["error": "no answer; fall back to terminal"])
                }
            },
            registerCancel: { [weak self] handler in
                self?.registerCancel(handler)
            }
        )
    }

    private func registerCancel(_ handler: @escaping () -> Void) {
        cancelLock.lock()
        if disposed {
            cancelLock.unlock()
            handler()
            return
        }
        cancelHandlers.append(handler)
        cancelLock.unlock()
    }

    private func fireCancelIfNeeded() {
        guard !responded else { return }
        fireCancel()
    }

    private func fireCancel() {
        cancelLock.lock()
        let handlers = cancelHandlers
        cancelHandlers.removeAll()
        disposed = true
        cancelLock.unlock()
        handlers.forEach { $0() }
    }

    private func respondJSON(status: Int, object: [String: Any]) {
        guard !responded else { return }
        responded = true

        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : "Internal Server Error"))
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
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
