import Foundation
import Network
@testable import HermesKit

/// A WebSocket server on localhost that plays the gateway. `respond` gets each request and
/// returns the frames to send back.
final class FakeGateway: @unchecked Sendable {
    typealias Responder = @Sendable (_ id: Int, _ method: String) -> [String]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeGateway")
    private let greeting: String?
    private let respond: Responder
    private var connections: [NWConnection] = []
    private var requests: [[String: Any]] = []
    private var answers: [[String: Any]] = []

    /// Every frame the client sent that answered a request of ours (no method), oldest first.
    var responses: [[String: Any]] { queue.sync { answers } }

    /// The params of every request received for `method`, oldest first.
    func params(of method: String) -> [[String: Any]] {
        queue.sync { requests.filter { $0["method"] as? String == method }.map { $0["params"] as? [String: Any] ?? [:] } }
    }

    private init(greeting: String?, respond: @escaping Responder) throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        self.greeting = greeting
        self.respond = respond
    }

    /// Starts a server and returns it with the endpoint that reaches it.
    static func start(
        // A gateway always greets; one that should not is given nil.
        greeting: String? = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#,
        respond: @escaping Responder = { id, method in [#"{"jsonrpc":"2.0","id":\#(id),"result":{"method":"\#(method)"}}"#] }
    ) async throws -> (FakeGateway, GatewayEndpoint) {
        let gateway = try FakeGateway(greeting: greeting, respond: respond)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            gateway.listener.stateUpdateHandler = { [listener = gateway.listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            gateway.listener.newConnectionHandler = { [gateway] connection in gateway.accept(connection) }
            gateway.listener.start(queue: gateway.queue)
        }
        return (gateway, GatewayEndpoint("127.0.0.1:\(port)")!)
    }

    var openConnections: Int {
        queue.sync { connections.filter { $0.state == .ready }.count }
    }

    /// Sends a frame to every connected client.
    func push(_ text: String) {
        queue.async { for connection in self.connections { self.send(text, on: connection) } }
    }

    /// Drops every client, as a gateway restart would.
    func dropClients() {
        queue.async {
            for connection in self.connections { connection.cancel() }
            self.connections.removeAll()
        }
    }

    func stop() {
        dropClients()
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            if let greeting = self.greeting { self.send(greeting, on: connection) }
            self.receive(on: connection)
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = request["id"] as? Int, let method = request["method"] as? String {
                self.requests.append(request)
                for frame in self.respond(id, method) { self.send(frame, on: connection) }
            } else if let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any], frame["method"] == nil {
                self.answers.append(frame)
            }
            self.receive(on: connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, completion: .idempotent)
    }

    /// A server that answers the WebSocket handshake with a plain HTTP status, as a gateway
    /// does for a bad token, and answers `/api/status` with whether it uses sign-in (nil: that
    /// request fails too). Returns the endpoint and a function that stops it.
    static func refusing(status: Int, usesSignIn: Bool? = nil) async throws -> (GatewayEndpoint, stop: @Sendable () -> Void) {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "FakeGateway.refusing")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    let asksStatus = String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("GET /api/status")
                    var reply = "HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    if asksStatus, let usesSignIn {
                        let body = #"{"version":"0.0.0","auth_required":\#(usesSignIn)}"#
                        reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    }
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
        return (GatewayEndpoint("127.0.0.1:\(port)")!, { listener.cancel() })
    }

    /// A plain HTTP server that answers every request with the same status and body, and
    /// remembers the first line and headers of the last request it saw.
    static func serving(status: Int = 200, body: String, location: String? = nil) async throws -> (GatewayEndpoint, lastRequest: @Sendable () -> String, stop: @Sendable () -> Void) {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "FakeGateway.serving")
        let seen = LastRequest()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    seen.set(String(decoding: data ?? Data(), as: UTF8.self))
                    let redirect = location.map { "Location: \($0)\r\n" } ?? ""
                    let reply = "HTTP/1.1 \(status) X\r\n\(redirect)Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            listener.start(queue: queue)
        }
        return (GatewayEndpoint("127.0.0.1:\(port)")!, { seen.get() }, { listener.cancel() })
    }

    private final class LastRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ value: String) { lock.withLock { text = value } }
        func get() -> String { lock.withLock { text } }
    }
}
