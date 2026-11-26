import Foundation

/// A bot's chat, opened so that messages can be sent to it and its replies followed.
public struct LiveChat: Sendable, Equatable {
    /// The gateway's id for the open chat. It is not the stored chat's id, and it does not
    /// outlive the connection.
    public let sessionID: String
    /// The stored chat's id, when the gateway said it on opening: a chat just started is
    /// not in the roster until it is read again.
    public let storedID: String?
    /// Questions the bot had put in this chat and was still waiting on when it was opened.
    public var waiting: [BotQuestion] = []

    public init(sessionID: String, storedID: String? = nil, waiting: [BotQuestion] = []) {
        self.sessionID = sessionID
        self.storedID = storedID
        self.waiting = waiting
    }
}

/// A chat whose bot is at work on the gateway (`GatewayClient.chatsAtWork`).
public struct ChatAtWork: Sendable, Equatable {
    /// The gateway's live id for it, or its stored id where the two are the same.
    public let id: String
    /// The stored chat's id.
    public let storedID: String
    public let status: String

    public init(id: String, storedID: String, status: String) {
        self.id = id
        self.storedID = storedID
        self.status = status
    }

    /// Its bot is running a turn, or waiting on the person in one: it may have asked something.
    public var mayBeAsking: Bool { ["waiting", "working", "starting"].contains(status) }
}

/// What the gateway did with a message.
public enum SendReceipt: Sendable, Equatable {
    /// The bot was free and is starting on it.
    case started
    /// The bot was working, and took the message into that work: it answers it as it goes.
    case joined
    /// The bot was working. The message runs as a turn of its own after that work ends,
    /// which the gateway may have cut short to get to it.
    case queued
}

/// One step of a bot answering.
public enum TurnEvent: Sendable, Equatable {
    /// A turn began.
    case started
    /// More of the reply.
    case text(String)
    /// The bot finished one stretch of talking and will say more after some work.
    case pause
    /// The bot began using a tool.
    case tool(String)
    /// The turn is over. `reply` is the whole reply when the gateway sends it.
    case finished(reply: String?, outcome: Outcome)
    /// Something failed in the chat outside a turn, such as the bot's agent not starting.
    case trouble(String)

    public enum Outcome: Sendable, Equatable {
        case complete
        /// Stopped before it was done, by this app or another.
        case stopped
        case failed(String)
    }

    /// Reads a gateway event. Nil for the many kinds a chat does not show.
    public init?(_ event: GatewayEvent) {
        // A request from the gateway is a question, never a step of the answer.
        guard event.requestID == nil else { return nil }
        let payload = event.payload
        switch event.type {
        case "message.start":
            self = .started
        case "message.delta":
            guard let text = payload["text"]?.stringValue, !text.isEmpty else { return nil }
            self = .text(text)
        case "message.interim":
            // Something said between two pieces of work. When it was streamed, the deltas
            // already carried it.
            if payload["already_streamed"] == .bool(true) {
                self = .pause
            } else {
                guard let text = payload["text"]?.stringValue, !text.isEmpty else { return nil }
                self = .text(text + "\n\n")
            }
        case "tool.start":
            guard let name = payload["name"]?.stringValue.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
                  !name.isEmpty else { return nil }
            self = .tool(name)
        case "message.complete":
            let text = payload["text"]?.stringValue
            switch payload["status"]?.stringValue {
            case "interrupted":
                self = .finished(reply: text, outcome: .stopped)
            case "error":
                // A failed turn's text is the error itself, unless it is marked as the part
                // of the reply that did arrive.
                let reason = payload["error"]?.stringValue ?? payload["failure_reason"]?.stringValue ?? text
                self = .finished(reply: payload["partial"] == .bool(true) ? text : nil, outcome: .failed(reason ?? ""))
            default:
                self = .finished(reply: text, outcome: .complete)
            }
        case "error":
            self = .trouble(payload["message"]?.stringValue ?? "")
        default:
            return nil
        }
    }
}

/// The answer to a message as it arrives, with anything more the person says while it does.
/// Start listening before sending: the turn is the first one to begin after that, so the
/// tail of an earlier turn is not taken for it.
public struct LiveTurn: Sendable, Equatable {
    /// What one stretch of the answer is.
    public enum Content: Sendable, Equatable {
        /// Something the bot said.
        case said(String)
        /// Tools the bot used, one after another.
        case used([String])
        /// Something more the person sent while the bot was answering.
        case added(String)
    }

    /// One stretch of what the chat shows for this turn. Its id never changes and is never
    /// reused, whatever is added or taken back around it.
    public struct Part: Sendable, Equatable, Identifiable {
        public let id: Int
        public var content: Content
    }

    public private(set) var parts: [Part] = []
    /// Nil while the bot is still working.
    public private(set) var outcome: TurnEvent.Outcome?
    /// The turn has begun. Until then everything but a failure is taken for an earlier turn's.
    public private(set) var hasStarted = false
    private var nextID = 0
    /// Where the gateway's current turn began among the parts: it moves only when a further
    /// turn begins, not when the person adds something, since the turn under way goes on
    /// until the gateway ends it. A reply that arrives whole belongs to the parts from here
    /// on, never in place of what an earlier turn said.
    private var turnStart = 0

    public init() {}

    public var isWorking: Bool { outcome == nil }

    /// The parts without their ids.
    public var contents: [Content] { parts.map(\.content) }

    /// Everything the bot has said so far.
    public var reply: String {
        contents.compactMap { content -> String? in
            if case .said(let text) = content { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    /// Tools used so far, in order.
    public var tools: [String] {
        contents.flatMap { content -> [String] in
            if case .used(let names) = content { return names }
            return []
        }
    }

    /// The person has added something to this answer.
    public var hasAdditions: Bool {
        contents.contains { if case .added = $0 { true } else { false } }
    }

    /// The last part, if the gateway's current turn made it. What a new turn says or does
    /// starts a part of its own, never carrying on one an earlier turn left.
    private var lastOfThisTurn: Content? {
        parts.count > turnStart ? parts.last?.content : nil
    }

    private mutating func append(_ content: Content) -> Int {
        nextID += 1
        parts.append(Part(id: nextID, content: content))
        return nextID
    }

    public mutating func apply(_ event: TurnEvent) {
        // Nothing follows the end of a turn; a late frame must not reopen it.
        guard outcome == nil else { return }
        switch event {
        case .started:
            hasStarted = true
        case .trouble(let reason):
            // Before the turn begins this is why it never will. Once it has begun, the
            // gateway also reports trouble that has nothing to do with the answer, and the
            // turn's own end says how it went.
            if !hasStarted { outcome = .failed(reason) }
        case .text(let more):
            guard hasStarted else { return }
            if case .said(let text)? = lastOfThisTurn {
                parts[parts.count - 1].content = .said(text + more)
            } else {
                // A fresh stretch does not open on blank lines.
                let opening = String(more.drop(while: \.isWhitespace))
                if !opening.isEmpty { _ = append(.said(opening)) }
            }
        case .pause:
            guard hasStarted, case .said(let text)? = lastOfThisTurn, text.last?.isNewline != true else { return }
            parts[parts.count - 1].content = .said(text + "\n\n")
        case .tool(let name):
            guard hasStarted else { return }
            if case .used(let names)? = lastOfThisTurn {
                parts[parts.count - 1].content = .used(names + [name])
            } else {
                _ = append(.used([name]))
            }
        case .finished(let whole, let outcome):
            // Before the turn begins, an end is the tail of an earlier turn, unless it is a
            // failure: the gateway ends a turn that way when the bot's agent could not start.
            if !hasStarted {
                if case .failed = outcome { self.outcome = outcome }
                return
            }
            // As a fresh stretch does not open on blank lines, nor does a whole reply.
            if let whole = whole.map({ String($0.drop(while: \.isWhitespace)) }), !whole.isEmpty {
                // The whole reply stands in for what arrived in pieces, where it is clear
                // which piece that is: this turn said nothing, or said it in one stretch.
                let said = parts.indices.filter { index in
                    guard index >= turnStart, case .said = parts[index].content else { return false }
                    return true
                }
                if said.isEmpty {
                    _ = append(.said(whole))
                } else if said.count == 1 {
                    parts[said[0]].content = .said(whole)
                }
            }
            self.outcome = outcome
        }
    }

    /// The person sent something more while the bot was answering. What the bot says next
    /// comes after it. Returns the new part's id, for taking it back if it does not arrive.
    @discardableResult
    public mutating func add(_ message: String) -> Int {
        append(.added(message))
    }

    /// Something the person sent did not reach the bot after all.
    public mutating func takeBack(_ id: Int) {
        guard let index = parts.firstIndex(where: { $0.id == id }) else { return }
        parts.remove(at: index)
        if index < turnStart { turnStart -= 1 }
    }

    /// The message went to a bot that was already working, and that work now answers it.
    public mutating func joinRunningTurn() {
        hasStarted = true
    }

    /// A further turn began after this one ended, to answer something sent meanwhile.
    public mutating func carryOn() {
        outcome = nil
        hasStarted = true
        turnStart = parts.count
    }

    /// Ends the turn here because it was stopped and the gateway will say no more about it.
    public mutating func endStopped() {
        if outcome == nil { outcome = .stopped }
    }
}

extension GatewayClient {
    /// Opens a bot's chat for sending. This starts the bot's agent on the gateway if it is
    /// not running, but sends it nothing.
    public func openChat(_ chat: BotChat, profile: String) async throws -> LiveChat {
        let kind = await interfaceKindOnceGreeted()
        // Questions asked in a chat go to the connections that had said they answer them.
        await questionsAdvertised()
        let result = try await request("session.resume", .object([
            "session_id": .string(chat.liveID),
            "profile": .string(profile),
            // The stored messages are read over HTTP, so they need not come twice.
            "omit_messages": .bool(true),
            "source": .string(kind),
        ]), timeout: .seconds(90))
        guard let sessionID = result["session_id"]?.stringValue, !sessionID.isEmpty else {
            throw GatewayError.unexpectedReply(method: "session.resume")
        }
        return LiveChat(sessionID: sessionID, waiting: takeWaiting(in: result, sessionID: sessionID))
    }

    /// The chats whose bots are at work on the gateway just now (`session.active_list`), each
    /// with its stored id and what it is doing: `working`, `waiting` (on a person), `starting`
    /// or `idle`. Only chats with a running agent are listed, so asking wakes no bot. Where the
    /// session authority handles chats, one bot's at a time (`profile`); on the older route
    /// every bot's at once.
    public func chatsAtWork(profile: String?) async throws -> [ChatAtWork] {
        let result = try await request("session.active_list", .object(profile.map { ["profile": .string($0)] } ?? [:]))
        guard case .array(let rows)? = result["sessions"] else { throw GatewayError.unexpectedReply(method: "session.active_list") }
        return rows.compactMap { row in
            guard let id = row["id"]?.stringValue else { return nil }
            return ChatAtWork(id: id, storedID: row["session_key"]?.stringValue ?? id, status: row["status"]?.stringValue ?? "")
        }
    }

    /// Sends a message to a bot. Its answer arrives as `turnEvents(in:)`; subscribe first.
    /// What happens when the bot is already working is the gateway's own setting
    /// (`display.busy_input_mode`): by default it turns the bot to the new message at once.
    /// `pictures` are those the session authority holds for this message (`attachImage`).
    /// A `hidden` message is stored as one no one sees, as a page in the chat sends. To a
    /// bot already working it waits its turn: Hermes keeps that it is hidden only for a
    /// message that waits, not for one steered into the work under way.
    /// `rewinding` takes the chat back first, to before that message of the person's, so the
    /// message is asked again in its place (Retry): in the same request on the older route,
    /// and just before it where the session authority handles chats, which has no such field
    /// and wants `fence` (`rewindFence`) taken before the caller checked the chat.
    @discardableResult
    public func send(
        _ text: String, in chat: LiveChat, profile: String, pictures: [StagedPicture] = [], hidden: Bool = false,
        rewinding: Rewind? = nil, fence: RewindFence? = nil
    ) async throws -> SendReceipt {
        if let rewinding, usesSessionAuthority { try await authorityRewind(rewinding, fence: fence, in: chat, profile: profile) }
        var params: [String: JSONValue] = [
            "session_id": .string(chat.sessionID),
            "profile": .string(profile),
            "text": .string(text),
        ]
        if hidden {
            params["display_kind"] = .string("hidden")
            params["queued"] = .bool(true)
        }
        // The session authority refuses a message without an id of its own. The older route
        // does not know the field, so it is sent only where the gateway said it is wanted.
        if usesSessionAuthority { params["submission_id"] = .string(UUID().uuidString) }
        // A bot's clarifying questions come as one set, as they do on the older route, where
        // the gateway said it can: a gateway that cannot refuses the field.
        if usesSessionAuthority, asksQuestionsTogether { params["clarify_batch"] = .bool(true) }
        if !pictures.isEmpty {
            params["attachments"] = .array(pictures.map { .object(["path": .string($0.path), "mime": .string($0.mime)]) })
        }
        if let rewinding, !usesSessionAuthority { params.merge(rewinding.submitFields) { $1 } }
        let result = try await request("prompt.submit", .object(params))
        // The bot's voice chat was ended instead, and nothing was queued.
        if result["voice_stopped"] == .bool(true) {
            throw GatewayError.rejected(code: 4090, message: "The bot's voice chat was ended instead. Nothing was sent.")
        }
        switch result["status"]?.stringValue {
        case "queued": return .queued
        case "steered", "redirected": return .joined
        default: return .started
        }
    }

    /// Asks the bot to stop what it is doing. The turn then ends with `.stopped`.
    public func stop(_ chat: LiveChat, profile: String) async throws {
        _ = try await request("session.interrupt", .object([
            "session_id": .string(chat.sessionID),
            "profile": .string(profile),
        ]))
    }

    /// The steps of the bot's answers in one open chat, from now until the connection ends.
    public func turnEvents(in chat: LiveChat) -> AsyncStream<TurnEvent> {
        let all = events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in all where event.sessionID == chat.sessionID {
                    if let step = TurnEvent(event) { continuation.yield(step) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
