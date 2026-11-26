import Foundation

/// Something the gateway told us without being asked: a streamed reply, a status change.
public struct GatewayEvent: Sendable, Equatable {
    public let type: String
    public let payload: JSONValue
    /// The live session the event belongs to. Nil for events about the gateway as a whole.
    public let sessionID: String?
    /// Set when this is not an event but a request from the gateway that waits for the app's
    /// answer (`type` is then its method and `payload` its params): the id to answer it by.
    public let requestID: JSONValue?

    public init(type: String, payload: JSONValue, sessionID: String? = nil, requestID: JSONValue? = nil) {
        self.type = type
        self.payload = payload
        self.sessionID = sessionID
        self.requestID = requestID
    }
}

public enum GatewayError: Error, Sendable, Equatable {
    case notConnected
    /// The gateway refused the token, or a sign-in has ended. `gatewayUsesSignIn` is true
    /// when the gateway says it has sign-in turned on: a signed-in session, not a token, may
    /// be what it wants.
    case unauthorized(gatewayUsesSignIn: Bool)
    /// The socket failed or closed. The text names the kind of failure and never the address,
    /// which carries the token.
    case connectionLost(String)
    /// This gateway does not have the method. Hermes versions and ways of connecting differ
    /// in what they offer, so callers hide the feature rather than report a failure.
    case unsupported(method: String)
    /// The gateway answered the request with an error.
    case rejected(code: Int, message: String)
    case timedOut(method: String)
    /// The gateway answered, but not in the shape this method is known to return.
    case unexpectedReply(method: String)
}

/// One JSON-RPC connection to a Hermes gateway.
///
/// It does not reconnect. When the socket ends, every waiting request fails and every event
/// stream finishes; the owner decides whether to connect again.
public actor GatewayClient {
    private let endpoint: GatewayEndpoint
    private let credential: GatewayCredential
    private let session: URLSession
    /// Counts connects and disconnects, so a socket whose pass arrives after a disconnect
    /// is not opened.
    private var opens = 0
    private var socket: URLSessionWebSocketTask?
    /// The gateway said in its greeting that its newer session authority handles chats on
    /// this connection. That route wants some requests shaped differently.
    public private(set) var usesSessionAuthority = false
    /// The greeting has come on this socket, so which route chats take is known.
    private var isGreeted = false
    /// Whether the gateway keeps a bot's settings to that bot, once asked on this socket.
    var settingsPerBot: Bool?
    /// Counts sockets opened, so what was found out on one is not kept for the next.
    private(set) var sockets = 0
    private var awaitingGreeting: [CheckedContinuation<Void, Never>] = []
    /// Why the last socket ended, so a request made after a failed connect says what went wrong.
    private var lastFailure: GatewayError?
    private var nextID = 0
    /// Whoever owns this connection puts the bots' questions to the person, so the gateway is
    /// told this app answers requests (`answerQuestions()`).
    private var answersQuestions = false
    /// The telling of that on the socket now open, while it is under way or once done.
    private var advertising: Task<Void, Never>?
    /// The gateway said it can put a session authority's clarifying questions as one set.
    public private(set) var asksQuestionsTogether = false
    /// The gateway said it counts a "not shown here" decline of a window's request, rather
    /// than taking it as the answer.
    private var declinesNotShown = false
    private var pending: [Int: (method: String, continuation: CheckedContinuation<JSONValue, any Error>)] = [:]
    private var listeners: [UUID: AsyncStream<GatewayEvent>.Continuation] = [:]

    /// A session that keeps nothing: no cache and no cookies. Chats are private, and the
    /// shared session would store what it fetches in the shared URL cache.
    public static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // No request made on it is ever sent on to another address: each carries the token.
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    public init(endpoint: GatewayEndpoint, token: String, session: URLSession = GatewayClient.privateSession) {
        self.init(endpoint: endpoint, credential: .token(token), session: session)
    }

    public init(endpoint: GatewayEndpoint, credential: GatewayCredential, session: URLSession = GatewayClient.privateSession) {
        self.endpoint = endpoint
        self.credential = credential
        self.session = session
    }

    deinit {
        socket?.cancel(with: .goingAway, reason: nil)
        for listener in listeners.values { listener.finish() }
    }

    /// True from `connect()` until the socket ends, so also while it is still being opened.
    public var isConnected: Bool { socket != nil }

    /// Opens the socket. Does not wait for the gateway to answer; a refused or unreachable
    /// gateway shows up as the failure of every request until `connect()` or `disconnect()`
    /// is called again. With passes in place of a token, it waits for the pass; a second
    /// call while it waits joins the first.
    public func connect() async {
        guard socket == nil else { return }
        if let opening { return await opening.value }
        switch credential {
        case .token(let token):
            open(session.webSocketTask(with: endpoint.webSocketURL(token: token)))
        case .tickets(let source):
            lastFailure = nil
            opens += 1
            let thisOpen = opens
            let fetching = Task { [weak self] in
                let ticket = try? await source.ticket(.interactive, profile: nil)
                await self?.opened(thisOpen, with: ticket.map { .protocolName($0) })
            }
            opening = fetching
            await fetching.value
        case .signedIn(let signedIn):
            lastFailure = nil
            opens += 1
            let thisOpen = opens
            let fetching = Task { [weak self] in
                do {
                    let ticket = try await signedIn.socketTicket()
                    await self?.opened(thisOpen, with: .query(ticket))
                } catch {
                    // A session that can no longer be renewed is a refusal, not a lost line;
                    // and why else no pass was had is kept, to be said.
                    let failure = error as? GatewaySignIn.Failure
                    let why: GatewayError = switch failure {
                    case .expired: .unauthorized(gatewayUsesSignIn: true)
                    case .notPrivate: .rejected(code: 0, message: GatewayClient.notPrivate)
                    case .turnedAway: .rejected(code: 403, message: "The gateway turned the request away.")
                    default: .connectionLost("No pass")
                    }
                    await self?.opened(thisOpen, with: nil, failing: why)
                }
            }
            opening = fetching
            await fetching.value
        }
    }

    /// The fetching of a pass for a socket about to be opened, while it runs.
    private var opening: Task<Void, Never>?

    /// How a single-use pass is shown to the gateway when the socket is opened.
    private enum Pass {
        /// Hermes on the same Mac takes it as a second protocol name beside its own.
        case protocolName(String)
        /// A signed-in session's goes in the address, where it works once.
        case query(String)
    }

    /// Said when nothing was sent because the address is no longer a private one.
    public static let notPrivate = "This server's address now leads out onto the internet and isn't encrypted, so nothing was sent to it."

    private func opened(_ thisOpen: Int, with pass: Pass?, failing: GatewayError = .connectionLost("No pass")) {
        // Disconnected while the pass was being fetched: that socket is not wanted.
        guard thisOpen == opens else { return }
        opening = nil
        guard let pass else {
            lastFailure = failing
            // As when a socket ends: nobody is left waiting on events that cannot come.
            for listener in listeners.values { listener.finish() }
            listeners.removeAll()
            return
        }
        switch pass {
        case .protocolName(let ticket):
            open(session.webSocketTask(with: endpoint.webSocketURL(), protocols: ["hermes-gateway-v1", "hermes-gateway-ticket." + ticket]))
        case .query(let ticket):
            open(session.webSocketTask(with: endpoint.webSocketURL(ticket: ticket)))
        }
    }

    private func open(_ task: URLSessionWebSocketTask) {
        // The address carries the token, so the socket is never sent on to another one,
        // whatever session it was given.
        task.delegate = NoRedirects()
        // The greeting alone is tens of kilobytes and a chat history is far larger.
        task.maximumMessageSize = 32 * 1024 * 1024
        socket = task
        lastFailure = nil
        usesSessionAuthority = false
        asksQuestionsTogether = false
        declinesNotShown = false
        advertising = nil
        isGreeted = false
        settingsPerBot = nil
        sockets += 1
        task.resume()
        Task { [weak self] in
            do {
                while true {
                    let message = try await task.receive()
                    guard let self else { return task.cancel() }
                    await self.handle(message, from: task)
                }
            } catch {
                guard let self else { return }
                await self.ended(task, await self.diagnose(error, task))
            }
        }
    }

    public func disconnect() {
        opens += 1
        opening?.cancel()
        opening = nil
        if let task = socket { ended(task, .notConnected) }
        // With no socket there may still be a remembered failure and waiting subscribers.
        lastFailure = nil
        for listener in listeners.values { listener.finish() }
        listeners.removeAll()
    }

    /// Calls a gateway method and returns its result. Cancelling the calling task abandons the
    /// request at once; the gateway may still act on it.
    public func request(
        _ method: String,
        _ params: JSONValue = .object([:]),
        timeout: Duration = .seconds(30)
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let socket else { throw lastFailure ?? .notConnected }
        nextID += 1
        let id = nextID
        let frame: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .number(Double(id)),
            "method": .string(method), "params": params,
        ])
        let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)

        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.fail(id, GatewayError.timedOut(method: method))
        }
        defer { timer.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = (method, continuation)
                // The handler below may have run before the line above; catch that here.
                if Task.isCancelled { return fail(id, CancellationError()) }
                Task {
                    do {
                        try await socket.send(.string(text))
                    } catch {
                        // A socket that cannot send is dead; say so now rather than leave it
                        // looking connected until the receive side notices.
                        let reason = await self.diagnose(error, socket)
                        self.ended(socket, reason)
                        self.fail(id, reason)
                    }
                }
            }
        } onCancel: {
            Task { await self.fail(id, CancellationError()) }
        }
    }

    /// Events from now until the connection ends. Each caller gets its own stream. Subscribe
    /// before `connect()` to see the gateway's greeting. After a connection has failed, the
    /// stream is already finished until `connect()` or `disconnect()` is called.
    public func events() -> AsyncStream<GatewayEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        guard socket != nil || lastFailure == nil else {
            continuation.finish()
            return stream
        }
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, from task: URLSessionWebSocketTask) {
        // A frame still queued from a socket we have left must not reach its replacement.
        guard socket === task else { return }
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let frame = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }

        if frame["method"]?.stringValue == "event" {
            guard let type = frame["params"]?["type"]?.stringValue else { return }
            if type == "gateway.ready" {
                usesSessionAuthority = frame["params"]?["payload"]?["session_authority"] == .bool(true)
                isGreeted = true
                if answersQuestions { advertise() }
                greetingSettled()
            }
            let event = GatewayEvent(
                type: type, payload: frame["params"]?["payload"] ?? .null,
                sessionID: frame["params"]?["session_id"]?.stringValue)
            for listener in listeners.values { listener.yield(event) }
        } else if let method = frame["method"]?.stringValue, let id = frame["id"], id != .null,
                  frame["result"] == nil, frame["error"] == nil {
            // A request from the gateway, waiting on an answer from us.
            let params = frame["params"] ?? .object([:])
            switch IncomingRequest.read(method: method, id: id, params: params, declinesNotShown: declinesCount) {
            case .reply(let reply):
                send(reply, to: id, on: task)
            case .ask(let question):
                // Nobody here to put it to: said at once, rather than left to its deadline.
                guard answersQuestions, !listeners.isEmpty else {
                    return send(.error(code: -32603, message: "Nothing in Hermes Bot can show this question now."), to: id, on: task)
                }
                let event = GatewayEvent(type: method, payload: params, sessionID: question.sessionID, requestID: id)
                for listener in listeners.values { listener.yield(event) }
            }
        } else if frame["method"] == nil, frame["result"] != nil || (frame["error"] ?? .null) != .null,
                  let id = frame["id"]?.numberValue.flatMap(Int.init(exactly:)),
                  let (method, continuation) = pending.removeValue(forKey: id) {
            // Only a real reply may use up a waiting request: no method, and a result or error.
            if let error = frame["error"], error != .null {
                let code = error["code"]?.numberValue.flatMap(Int.init(exactly:)) ?? 0
                // -32601 is JSON-RPC's "method not found".
                continuation.resume(throwing: code == -32601 ? GatewayError.unsupported(method: method) : .rejected(
                    code: code,
                    message: error["message"]?.stringValue ?? "The gateway reported an error."
                ))
            } else {
                continuation.resume(returning: frame["result"] ?? .null)
            }
        }
    }

    /// Says this connection answers the gateway's requests. Until it is said, the gateway's
    /// older route treats every question as unanswered at once (and the bot does without);
    /// once said, every question must get an answer, which the owner sees to. Said again on
    /// each socket, after its greeting.
    public func answerQuestions() {
        answersQuestions = true
        if isGreeted, socket != nil, advertising == nil { advertise() }
    }

    private func advertise() {
        advertising = Task { [weak self] in
            guard let self else { return }
            let said = try? await self.request("client.capabilities", .object(["server_requests": .bool(true)]))
            await self.advertised(said)
        }
    }

    private func advertised(_ result: JSONValue?) {
        // Not said after all: it can be said again on this socket.
        if result == nil { advertising = nil }
        asksQuestionsTogether = result?["canonical_clarify_batch"] == .bool(true)
        declinesNotShown = result?["declines_not_shown"] == .bool(true)
    }

    /// Whether a window's request is declined as not shown here: only on the older route,
    /// whose requests wait for every window to decline. The session authority settles a
    /// request on the first answer or error of any kind.
    private var declinesCount: Bool { declinesNotShown && !usesSessionAuthority }

    /// The questions waiting in a chat's snapshot (`session.resume`), each read once: one
    /// that is not put to the person is answered now, as it would have been had it come live,
    /// and the rest are returned to be shown. An entry that names no chat is taken as this one's.
    func takeWaiting(in snapshot: JSONValue, sessionID: String) -> [BotQuestion] {
        var found: [BotQuestion] = []
        if case .array(let open)? = snapshot["open_requests"] {
            for entry in open {
                guard let method = entry["method"]?.stringValue, let id = entry["id"], id != .null else { continue }
                var params = entry["params"] ?? .object([:])
                if params["session_id"]?.stringValue?.isEmpty != false, case .object(var fields) = params {
                    fields["session_id"] = .string(sessionID)
                    params = .object(fields)
                }
                switch IncomingRequest.read(method: method, id: id, params: params, declinesNotShown: declinesCount) {
                case .ask(let question): found.append(question)
                case .reply(let reply): if let socket { send(reply, to: id, on: socket) }
                }
            }
        }
        if case .array(let prompts)? = snapshot["prompts"] {
            found += prompts.compactMap { BotQuestion(prompt: $0, sessionID: sessionID) }
        }
        // A connection card still open, with the gateway's own deadline.
        if let pending = snapshot["pending_connection"], let connection = ConnectionRequest(payload: pending) {
            found.append(BotQuestion(id: connection.opID, sessionID: sessionID, route: .connection, kind: .connection(connection)))
        }
        return found
    }

    /// The same as `decline`, from outside the client's own thread of work.
    public nonisolated func declineSoon(_ question: BotQuestion) {
        Task { await self.decline(question) }
    }

    /// Says to the gateway that a question it put cannot be shown here after all (its chat
    /// was never opened in this app), so the bot is not left waiting for its deadline. A
    /// session authority's prompt is not a request and cannot be refused; it waits its own.
    public func decline(_ question: BotQuestion) {
        guard case .request(let id) = question.route, let socket else { return }
        send(.error(code: -32603, message: "Nothing in Hermes Bot can show this question now."), to: id, on: socket)
    }

    /// Waits until the gateway has been told this app answers requests, so a chat opened
    /// after it is one whose questions come here.
    func questionsAdvertised() async {
        _ = await interfaceKindOnceGreeted()
        await advertising?.value
    }

    /// Answers a request from the gateway. The gateway does not reply to an answer.
    func respond(to id: JSONValue, with result: JSONValue) async throws {
        guard let socket else { throw lastFailure ?? .notConnected }
        try await sendFrame(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]), on: socket)
    }

    private func send(_ reply: ImmediateReply, to id: JSONValue, on task: URLSessionWebSocketTask) {
        let frame: JSONValue = switch reply {
        case .result(let result): .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        case .error(let code, let message): .object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
            "code": .number(Double(code)), "message": .string(message),
        ])])
        }
        Task { try? await sendFrame(frame, on: task) }
    }

    private func sendFrame(_ frame: JSONValue, on task: URLSessionWebSocketTask) async throws {
        let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
        do {
            try await task.send(.string(text))
        } catch {
            let reason = await diagnose(error, task)
            ended(task, reason)
            throw reason
        }
    }

    private func fail(_ id: Int, _ error: any Error) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: error)
    }

    /// The socket is gone: nothing sent on it will be answered.
    private func ended(_ task: URLSessionWebSocketTask, _ reason: GatewayError) {
        guard socket === task else { return }
        socket = nil
        lastFailure = reason == .notConnected ? nil : reason
        task.cancel(with: .goingAway, reason: nil)
        for waiting in pending.values { waiting.continuation.resume(throwing: reason) }
        pending.removeAll()
        greetingSettled()
        for listener in listeners.values { listener.finish() }
        listeners.removeAll()
    }

    /// Why a socket failed. For a refused handshake this asks the gateway, without
    /// credentials, whether it has sign-in turned on, so the caller can say so.
    private func diagnose(_ error: any Error, _ task: URLSessionWebSocketTask) async -> GatewayError {
        if let error = error as? GatewayError { return error }
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
            // Signed in, the socket was opened with a pass that works once and for half a
            // minute: one not taken (used, run out, or lost when the gateway restarted)
            // says nothing about the sign-in. Another is fetched at the next try.
            if case .signedIn = credential { return .connectionLost("Pass not taken") }
            return .unauthorized(gatewayUsesSignIn: await gatewayUsesSignIn())
        }
        let error = error as NSError
        return .connectionLost("\(error.domain) \(error.code)")
    }

    /// Puts on a request whatever opens the gateway for it: the token, a pass for this one
    /// request, or a signed-in session's access token. Returns that access token when signed
    /// in, so a refusal can be answered by renewing it.
    private func sign(_ request: inout URLRequest, forBot profile: String?) async throws -> String? {
        var sentWith: String?
        switch credential {
        case .token(let token):
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        case .tickets(let source):
            // One pass for this one request, for the bot it is about.
            let ticket: String
            do {
                ticket = try await source.ticket(.http, profile: profile)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GatewayError.connectionLost("No pass")
            }
            request.setValue(ticket, forHTTPHeaderField: "X-Hermes-Gateway-Ticket")
        case .signedIn(let signedIn):
            do {
                let token = try await signedIn.accessToken()
                sentWith = token
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } catch is CancellationError {
                throw CancellationError()
            } catch GatewaySignIn.Failure.expired {
                throw GatewayError.unauthorized(gatewayUsesSignIn: true)
            } catch GatewaySignIn.Failure.notPrivate {
                throw GatewayError.rejected(code: 0, message: GatewayClient.notPrivate)
            } catch {
                throw GatewayError.connectionLost("No session")
            }
        }
        return sentWith
    }

    /// What this app tells the gateway it is when it opens a chat. Hermes tells the bot
    /// what kind of interface it is talking through, and with nothing said takes it for
    /// its terminal one, where the bot is told there is no way to send a file. Said to be
    /// Hermes's graphical chat, the bot is told it can hand files over with `MEDIA:` and
    /// that Markdown is shown.
    /// Which of Hermes's two names says so depends on the route chats take. Where its
    /// session authority handles them, the name is "gui" (the only one that route takes)
    /// and it is turned into the bot's "desktop" surface. On the older route the name is
    /// passed to the bot's agent as it stands, and "desktop" is the one that has a
    /// description: "gui" there would leave the bot told nothing and not counted as being
    /// read by a person.
    public var interfaceKind: String { usesSessionAuthority ? "gui" : "desktop" }

    /// The same, once the gateway's greeting on this socket has said which route chats
    /// take: a request made straight after connecting would otherwise go by the older
    /// route's name before the gateway had said otherwise. Not waited for for ever: a
    /// socket that ends, or says nothing for a while, is answered as things stand.
    func interfaceKindOnceGreeted() async -> String {
        await sessionAuthorityOnceGreeted() ? "gui" : "desktop"
    }

    /// Whether the session authority handles chats, once the greeting has said.
    public func sessionAuthorityOnceGreeted() async -> Bool {
        if !isGreeted, socket != nil {
            let waited = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.greetingSettled()
            }
            await withCheckedContinuation { awaitingGreeting.append($0) }
            waited.cancel()
        }
        return usesSessionAuthority
    }

    private func greetingSettled() {
        let waiting = awaitingGreeting
        awaitingGreeting = []
        for one in waiting { one.resume() }
    }

    /// A file on the gateway that a bot handed over, with what kind it is.
    public struct File: Sendable, Equatable {
        public let data: Data
        /// Its kind as the gateway says it, such as "image/png".
        public let type: String
        public let name: String

        public init(data: Data, type: String, name: String) {
            self.data = data
            self.type = type
            self.name = name
        }
    }

    /// Reads a file a bot handed over in its chat. `path` is as the bot wrote it; the
    /// gateway decides whether it may be read. Nothing larger than `limit` bytes is taken.
    /// `chat` is the chat it was handed over in, when known: the gateway then reads the
    /// path as that chat's bot wrote it. Which files may be read at all is the gateway's
    /// to decide (its own boundary and its list of sensitive files), not this app's.
    public func file(at path: String, forBot profile: String, inChat chat: String? = nil, limit: Int = 30_000_000) async throws -> File {
        try await file(at: path, forBot: profile, inChat: chat, limit: limit, afterRenewing: false)
    }

    private func file(at path: String, forBot profile: String, inChat chat: String?, limit: Int, afterRenewing: Bool) async throws -> File {
        // The route that knows whose file it is: Hermes's other one takes no bot or chat.
        var components = URLComponents(url: endpoint.url(path: "/api/fs/download"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "profile", value: profile)]
            + (chat.map { [URLQueryItem(name: "session_id", value: $0)] } ?? [])
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        let sentWith = try await sign(&request, forBot: profile)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Taken in as it arrives, off this client's own thread of work, and stopped the
        // moment it is too large: the rest is not left arriving.
        let got = try await LimitedDownload.run(request, limit: limit)
        switch got.status {
        case 200: break
        case 404: throw GatewayError.rejected(code: 404, message: "This file is no longer on the gateway.")
        case 413: throw GatewayError.rejected(code: 413, message: Self.tooLarge)
        case 401:
            // Signed in, and the token was not taken: renewed once, as for any other read.
            // Only that: a file the gateway keeps to itself is a 403, and renewing for
            // each of those would spend a session to no purpose.
            if case .signedIn(let signedIn) = credential, let sentWith, !afterRenewing {
                do {
                    try await signedIn.renew(replacing: sentWith)
                } catch is CancellationError {
                    throw CancellationError()
                } catch GatewaySignIn.Failure.expired {
                    throw GatewayError.unauthorized(gatewayUsesSignIn: true)
                } catch GatewaySignIn.Failure.notPrivate {
                    throw GatewayError.rejected(code: 0, message: GatewayClient.notPrivate)
                } catch {
                    throw GatewayError.connectionLost("No session")
                }
                return try await file(at: path, forBot: profile, inChat: chat, limit: limit, afterRenewing: true)
            }
            if case .token = credential { throw GatewayError.unauthorized(gatewayUsesSignIn: false) }
            throw GatewayError.rejected(code: 403, message: "The gateway wouldn't give this file.")
        case 403: throw GatewayError.rejected(code: 403, message: "The gateway wouldn't give this file.")
        case let status: throw GatewayError.connectionLost("HTTP \(status)")
        }
        return File(data: got.data, type: got.type, name: got.name ?? (path as NSString).lastPathComponent)
    }

    static let tooLarge = "This file is too large to show here."

    /// Reads from the gateway's HTTP API with the token. Returns nil when the gateway has
    /// nothing at that address. `method` names the read in errors.
    func get(_ path: String, query: [String: String], as method: String) async throws -> JSONValue? {
        try await get(path, query: query, as: method, afterRenewing: false)
    }

    private func get(_ path: String, query: [String: String], as method: String, afterRenewing: Bool) async throws -> JSONValue? {
        /// The access token this request was sent with, when signed in.
        let sentWith: String?
        var components = URLComponents(url: endpoint.url(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLComponents leaves "+" unescaped, which a server reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        sentWith = try await sign(&request, forBot: query["profile"])
        request.timeoutInterval = 30
        // Never answered from a cache, even if the caller passed a session that has one.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw GatewayError.timedOut(method: method)
        } catch {
            let error = error as NSError
            throw GatewayError.connectionLost("\(error.domain) \(error.code)")
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                throw GatewayError.unexpectedReply(method: method)
            }
            return value
        case 404:
            return nil
        case 401, 403:
            // Signed in, and the token was not taken: this Mac's clock may be behind the
            // gateway's, or the token ran out on the way. It is renewed once and the read
            // made again; only a renewal that is refused means the sign-in has ended.
            if case .signedIn(let signedIn) = credential, let sentWith, !afterRenewing {
                do {
                    try await signedIn.renew(replacing: sentWith)
                } catch is CancellationError {
                    throw CancellationError()
                } catch GatewaySignIn.Failure.expired {
                    throw GatewayError.unauthorized(gatewayUsesSignIn: true)
                } catch GatewaySignIn.Failure.notPrivate {
                    throw GatewayError.rejected(code: 0, message: GatewayClient.notPrivate)
                } catch {
                    throw GatewayError.connectionLost("No session")
                }
                return try await get(path, query: query, as: method, afterRenewing: true)
            }
            // Renewed, and turned away again: the sign-in is good, and it is this request
            // the gateway will not have. Not said to be the end of the sign-in.
            if case .signedIn = credential { throw GatewayError.rejected(code: 403, message: "The gateway turned the request away.") }
            let usesSignIn = await gatewayUsesSignIn()
            try Task.checkCancellation()
            throw GatewayError.unauthorized(gatewayUsesSignIn: usesSignIn)
        case let status:
            throw GatewayError.connectionLost("HTTP \(status ?? 0)")
        }
    }

    /// The Hermes version the gateway says it runs, from its open status page, which needs
    /// no sign-in. Nil when it does not say or cannot be asked.
    public func hermesVersion() async -> String? {
        var request = URLRequest(url: endpoint.url(path: "/api/status"))
        request.timeoutInterval = 5
        guard let (data, _) = try? await session.data(for: request),
              let status = try? JSONDecoder().decode(JSONValue.self, from: data),
              let version = status["version"]?.stringValue, !version.isEmpty
        else { return nil }
        return version
    }

    /// Whether a Hermes of this version keeps `/yolo` to the chat named. From 0.21.6 a
    /// session id it no longer holds is refused (`ba5bec3f2c9`); before, `config.set` took
    /// it for no chat at all and turned approvals off for its whole process. Its releases
    /// named by date all came before that; a version that cannot be read is taken as old.
    public static func keepsYoloToOneChat(version: String?) -> Bool {
        guard let version else { return false }
        let bare = version.drop { $0 == "v" }.prefix { $0 != "+" && $0 != "-" && !$0.isWhitespace }
        let parts = bare.split(separator: ".").map { Int($0) }
        guard parts.count >= 3, let major = parts[0], let minor = parts[1], let patch = parts[2], major < 2000 else { return false }
        return (major, minor, patch) >= (0, 21, 6)
    }

    private func gatewayUsesSignIn() async -> Bool {
        var request = URLRequest(url: endpoint.url(path: "/api/status"))
        request.timeoutInterval = 5
        guard let (data, _) = try? await session.data(for: request),
              let status = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        // Asking for sign-in is not the same as refusing tokens: a gateway lists
        // "session-token" among its ways in when a token is one of them, and then a
        // refusal means the token itself was wrong.
        if case .array(let ways)? = status["auth_providers"], ways.contains(.string("session-token")) { return false }
        return status["auth_required"] == .bool(true)
    }
}

/// Refuses redirects, so a request carrying the token is never re-sent to another address.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
