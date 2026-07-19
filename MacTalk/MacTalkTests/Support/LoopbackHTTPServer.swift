import Foundation
import Network

final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    enum Body: Sendable {
        case fixed(Data)
        case chunked(Data, chunkSize: Int)
        case slow(Data, chunkSize: Int, delay: TimeInterval)
        case drop(Data, admittedBytes: Int)
    }

    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Body = .fixed(Data())
        var contentRange: String?
        var redirect: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.mactalk.loopback-http")
    private let response: @Sendable (Request) -> Response
    private let lock = NSLock()
    private var requests: [Request] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var ready = DispatchSemaphore(value: 0)
    private(set) var port: UInt16 = 0
    private(set) var isStopped = false

    init(response: @escaping @Sendable (Request) -> Response) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        self.listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                self?.ready.signal()
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            listener.cancel()
            throw ServerError.startFailed
        }
    }

    deinit { stop() }

    /// Idempotently shuts down the listener and every accepted connection.
    func stop() {
        let active: [NWConnection] = lock.withLock {
            guard !isStopped else { return [] }
            isStopped = true
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        listener.cancel()
        active.forEach { $0.cancel() }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/artifact")! }
    var requestLog: [Request] { lock.lock(); defer { lock.unlock() }; return requests }
    var activeConnectionCount: Int { lock.withLock { connections.count } }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state, let connection { self?.lock.withLock { self?.connections[ObjectIdentifier(connection)] = nil } }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 64 * 1024 else {
            connection.cancel()
            return
        }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let request = self.parseRequest(Data(buffer[..<headerEnd.lowerBound]))
                self.lock.lock(); self.requests.append(request); self.lock.unlock()
                self.respond(connection, request: request)
            } else if !isComplete && error == nil {
                self.receive(connection, buffer: buffer)
            } else { connection.cancel() }
        }
    }

    private func parseRequest(_ data: Data) -> Request {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ").map(String.init) ?? []
        var headers = [String: String]()
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return Request(method: first.first ?? "", path: first.dropFirst().first ?? "", headers: headers)
    }

    private func respond(_ connection: NWConnection, request: Request) {
        let response = self.response(request)
        if let redirect = response.redirect {
            let head = "HTTP/1.1 302 Found\r\nLocation: \(redirect)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            send(connection, data: Data(head.utf8), thenCancel: true); return
        }
        var headers = response.headers
        if let range = response.contentRange { headers["Content-Range"] = range }
        var bodyData = Data()
        switch response.body {
        case let .fixed(data): bodyData = data; headers["Content-Length"] = headers["Content-Length"] ?? String(data.count)
        case .chunked, .slow: headers["Transfer-Encoding"] = "chunked"
        case .drop: break // close-delimited body deliberately simulates an interrupted transfer
        }
        var head = "HTTP/1.1 \(response.status) Test\r\nConnection: close\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        send(connection, data: Data(head.utf8), thenCancel: false)
        switch response.body {
        case .fixed: send(connection, data: bodyData, thenCancel: true)
        case let .chunked(data, chunkSize):
            sendChunked(connection, data: data, chunkSize: chunkSize, offset: 0, delay: 0)
        case let .slow(data, chunkSize, delay):
            sendChunked(connection, data: data, chunkSize: chunkSize, offset: 0, delay: delay)
        case let .drop(data, admittedBytes):
            send(connection, data: data.prefix(min(admittedBytes, data.count)), thenCancel: true)
        }
    }

    private func sendChunked(_ connection: NWConnection, data: Data, chunkSize: Int, offset: Int, delay: TimeInterval) {
        guard offset < data.count else {
            send(connection, data: Data("0\r\n\r\n".utf8), thenCancel: true)
            return
        }
        let end = min(data.count, offset + max(1, chunkSize))
        let chunk = data[offset..<end]
        let frame = Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8) + chunk + Data("\r\n".utf8)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            if delay > 0 {
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.sendChunked(connection, data: data, chunkSize: chunkSize, offset: end, delay: delay)
                }
            } else {
                self.sendChunked(connection, data: data, chunkSize: chunkSize, offset: end, delay: delay)
            }
        })
    }

    private func send(_ connection: NWConnection, data: Data, thenCancel: Bool) {
        connection.send(content: data, completion: .contentProcessed { _ in if thenCancel { connection.cancel() } })
    }

    enum ServerError: Error { case startFailed }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
