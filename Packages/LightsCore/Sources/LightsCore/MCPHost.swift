import Foundation
import Network

/// Just enough HTTP/1.1 for the MCP endpoint: one request per connection,
/// a Content-Length body, then the reply and close. Claude Code is the only
/// client, and it handles a closed connection by opening another.
public final class HTTPServer: @unchecked Sendable {
    public struct Request: Sendable, Equatable {
        public var method: String
        public var path: String
        /// Names lowercased.
        public var headers: [String: String]
        public var body: Data
    }

    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func text(_ status: Int, _ text: String) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        }
    }

    public enum State: Equatable, Sendable {
        case ready(port: UInt16)
        case failed(String)
    }

    enum Parsed: Equatable {
        case incomplete
        case bad(Int)
        case complete(Request)
    }

    static let maxHeaderBytes = 16 * 1024
    /// A tool call is a few hundred bytes; anything near this is not one.
    static let maxBodyBytes = 1024 * 1024

    private let handler: @Sendable (Request) async -> Response
    private let queue = DispatchQueue(label: "org.hopejc.prism.http")
    private var listener: NWListener?

    public init(handler: @escaping @Sendable (Request) async -> Response) {
        self.handler = handler
    }

    /// Listens on every network, so Claude on another Mac can reach it.
    /// Port 0 picks a free one (the tests use that).
    public func start(port: UInt16, onState: @escaping @Sendable (State) -> Void) {
        queue.sync {
            listener?.cancel()
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let listener = try? NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any) else {
                onState(.failed("Couldn't listen on port \(port)."))
                return
            }
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready: onState(.ready(port: listener?.port?.rawValue ?? port))
                case .failed(let error):
                    if case .posix(.EADDRINUSE) = error {
                        onState(.failed("Port \(port) is in use by another app."))
                    } else {
                        onState(.failed("Stopped listening: \(error.localizedDescription)"))
                    }
                    listener?.cancel()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A client that opens a connection and says nothing doesn't keep it.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .complete(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    Self.send(response, on: connection)
                }
            case .bad(let status):
                Self.send(.text(status, "Bad request"), on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private static func send(_ response: Response, on connection: NWConnection) {
        connection.send(content: serialize(response), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    static func parse(_ data: Data) -> Parsed {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .bad(431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .bad(431) }
        let lines = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .bad(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .bad(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Clients send JSON with a length; a chunked body isn't worth parsing here.
        if headers["transfer-encoding"] != nil { return .bad(411) }
        let length: Int
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else { return .bad(400) }
            length = value
        } else {
            length = 0
        }
        guard length <= maxBodyBytes else { return .bad(413) }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let target = String(parts[1])
        return .complete(Request(
            method: String(parts[0]).uppercased(),
            path: String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""),
            headers: headers,
            body: Data(data[bodyStart..<(bodyStart + length)])))
    }

    static func serialize(_ response: Response) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                       405: "Method Not Allowed", 411: "Length Required", 413: "Content Too Large",
                       431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Status")\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + response.body
    }
}

/// The MCP server on the network: POST /mcp, with the key as a bearer token.
/// Anyone with the key can change the lights, so without one nothing gets in.
public final class MCPHost: @unchecked Sendable {
    /// Screens' Local API is on 6980; Prism sits next to it.
    public static let defaultPort: UInt16 = 6990

    private let server: MCPServer
    private let lock = NSLock()
    private var key: String
    private var http: HTTPServer?

    public init(server: MCPServer, key: String) {
        self.server = server
        self.key = key
    }

    public func setKey(_ key: String) {
        lock.withLock { self.key = key }
    }

    public func start(port: UInt16 = defaultPort, onState: @escaping @Sendable (HTTPServer.State) -> Void) {
        let http = HTTPServer { [weak self] request in
            guard let self else { return .text(503, "Prism is quitting") }
            return await self.respond(to: request)
        }
        lock.withLock {
            self.http?.stop()
            self.http = http
        }
        http.start(port: port, onState: onState)
    }

    public func stop() {
        let http = lock.withLock { () -> HTTPServer? in
            defer { self.http = nil }
            return self.http
        }
        http?.stop()
    }

    func respond(to request: HTTPServer.Request) async -> HTTPServer.Response {
        if request.path == "/" && request.method == "GET" {
            return .text(200, "Prism is running. Claude connects to /mcp with its key.")
        }
        guard request.path == "/mcp" else { return .text(404, "Not found") }
        // GET would open a stream of server messages; Prism has none to send.
        guard request.method == "POST" else {
            return HTTPServer.Response(status: 405, headers: ["Allow": "POST"])
        }
        let expected = lock.withLock { key }
        let given = request.headers["authorization"].flatMap { header -> String? in
            header.lowercased().hasPrefix("bearer ") ? String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil
        }
        guard let given, Self.matches(given, expected) else {
            return .text(401, "Prism needs its key: Prism › Settings › Claude.")
        }
        let (status, body) = await server.handle(body: request.body)
        return HTTPServer.Response(
            status: status, headers: body.isEmpty ? [:] : ["Content-Type": "application/json"], body: body)
    }

    /// Takes as long whichever character is wrong, so the key can't be
    /// guessed one character at a time. An empty key never matches.
    static func matches(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard !b.isEmpty, a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}
