import Foundation

/// Something a bot asks the person while it answers, and waits on: leave to run a command or
/// reach a folder or site, a clarifying question, a value for a setting it needs, or a
/// password for `sudo`.
///
/// Hermes asks in two ways. On the older route each is a request from the gateway to the app
/// (JSON-RPC with an id of the gateway's, answered with a response frame). Where the
/// gateway's session authority handles chats, leave and single questions are instead events
/// (`approval.request`, `clarify.request`) answered by calling `approval.respond` and
/// `clarify.respond`; values and passwords are still requests. `route` says which.
public struct BotQuestion: Sendable, Equatable, Identifiable {
    public enum Route: Sendable, Equatable {
        /// A request from the gateway, answered with a response frame carrying this id.
        case request(JSONValue)
        /// A prompt of the session authority's, answered by method, for the turn it belongs to.
        case prompt(generation: Int)
    }

    public enum Kind: Sendable, Equatable {
        case approval(Approval)
        case clarify(Clarify)
        /// A value for a setting (`name` is the environment variable it goes in), in the
        /// bot's own words. The value is never shown or kept.
        case secret(name: String, prompt: String)
        /// The person's password, for a command the bot runs with `sudo`. The command is as the
        /// gateway gives it, with anything that looks like a credential taken out.
        case sudo(command: String)
    }

    /// The gateway's id for the request or prompt.
    public let id: String
    /// The open chat (live session) it belongs to.
    public let sessionID: String
    public let route: Route
    public let kind: Kind
    /// How long the gateway waits for an answer, when it says.
    public let waits: Duration?

    public init(id: String, sessionID: String, route: Route, kind: Kind, waits: Duration? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.route = route
        self.kind = kind
        self.waits = waits
    }
}

/// What a bot asks leave for.
public struct Approval: Sendable, Equatable {
    public enum Subject: Sendable, Equatable {
        /// A command, as the gateway gives it with credentials taken out.
        case command(String)
        /// A folder. `canWrite` is nil when the gateway did not say.
        case folder(path: String, canWrite: Bool?)
        /// A site. `label` is the gateway's own name for it, when it gives one.
        case site(host: String, label: String?)
    }

    public let subject: Subject
    /// One short line from the gateway about what allowing it means.
    public let risk: String?
    /// What the bot says it is for. The bot's words, not the gateway's: shown as such.
    public let description: String?
    /// The answers on offer, in the order once, session, always, deny.
    public let choices: [ApprovalChoice]

    /// A refusal can say why. The gateway passes a reason on only for a folder or a site.
    public var takesReason: Bool {
        if case .command = subject { false } else { true }
    }

    public init(subject: Approval.Subject, risk: String? = nil, description: String? = nil, choices: [ApprovalChoice]) {
        self.subject = subject
        self.risk = risk
        self.description = description
        self.choices = choices
    }
}

public enum ApprovalChoice: String, Sendable, Equatable, CaseIterable {
    case once, session, always, deny
}

/// A bot's clarifying questions: one to five, each with choices or none.
public struct Clarify: Sendable, Equatable {
    public struct Question: Sendable, Equatable, Identifiable {
        public let id: String
        public let text: String
        /// Empty for a question answered in words.
        public let choices: [String]
        public let multiSelect: Bool

        public init(id: String, text: String, choices: [String] = [], multiSelect: Bool = false) {
            self.id = id
            self.text = text
            self.choices = choices
            self.multiSelect = multiSelect
        }
    }

    public let questions: [Question]
    /// Answers the gateway already holds, from before a reconnect. A nil answer is one skipped.
    public let locked: [String: String?]

    public init(questions: [Question], locked: [String: String?] = [:]) {
        self.questions = questions
        self.locked = locked
    }

    /// Hermes marks the choice it recommends with this after it.
    static let recommended = "(Recommended)"

    /// A choice as it is shown and sent: without the mark of the recommended one.
    public static func bare(_ choice: String) -> String {
        choice.hasSuffix(recommended) ? String(choice.dropLast(recommended.count)).trimmingCharacters(in: .whitespaces) : choice
    }
}

/// The person's answer to a question. Its description never shows a value typed into it.
public enum QuestionAnswer: Sendable, Equatable {
    case approval(ApprovalChoice, reason: String? = nil)
    /// Each question's answer by its id: words or a choice, several choices for one that takes
    /// several, or nil when skipped.
    case clarify([String: ClarifyAnswer?])
    /// A secret or a password. Empty means it was not given.
    case value(String)
    /// None of the questions answered: the bot is told the person passed.
    case skipped
}

public enum ClarifyAnswer: Sendable, Equatable {
    case one(String)
    case several([String])

    /// As the gateway takes it: a choice or words as they are, several as a JSON list.
    var wire: String {
        switch self {
        case .one(let text): return text
        case .several(let picks):
            let data = (try? JSONEncoder().encode(picks)) ?? Data("[]".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }
}

extension QuestionAnswer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .approval(let choice, let reason): "approval(\(choice.rawValue)\(reason == nil ? "" : ", with a reason"))"
        case .clarify(let answers): "clarify(\(answers.count) answers)"
        case .value(let value): value.isEmpty ? "value(none)" : "value(given)"
        case .skipped: "skipped"
        }
    }

    public var debugDescription: String { description }
    /// Nothing typed is reachable through a mirror either.
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// What the app says to a request from the gateway that it answers at once, with no one asked.
enum ImmediateReply: Equatable {
    case result(JSONValue)
    case error(code: Int, message: String)
}

/// How one request from the gateway is dealt with.
enum IncomingRequest: Equatable {
    /// Put to the person.
    case ask(BotQuestion)
    /// Answered at once.
    case reply(ImmediateReply)

    /// Asked of the person are leave, clarifying questions, secrets and `sudo`. Everything
    /// else Hermes may ask of a window (its browser preview, terminal, the window below it,
    /// a tour, the theme, onboarding cards, a vault, the password for installing the bot
    /// screen) is answered at once with a refusal or nothing, as the contract allows, so no
    /// bot waits out a deadline on an app that said it answers requests. A method this app
    /// does not know is "method not found", which Hermes takes as no answer, at once.
    /// The requests only the window showing the chat can answer are declined as not shown
    /// here (4404) where the gateway counts such declines (`declinesNotShown`, said in its
    /// answer to `client.capabilities` on the older route): it then waits for a window that
    /// does show the chat, such as Hermes's own app, and settles at once when none does. An
    /// empty answer there would beat that window's real one.
    static func read(method: String, id: JSONValue, params: JSONValue, declinesNotShown: Bool = false) -> IncomingRequest {
        let sessionID = params["session_id"]?.stringValue ?? ""
        let requestID: String = switch id {
        case .string(let text): text
        case .number(let number): String(number)
        default: ""
        }
        func refusal(_ why: String) -> IncomingRequest {
            .reply(.result(.object(["value": .string(encode(.object(["success": .bool(false), "error": .string(why)])))])))
        }
        // A question that names no chat belongs to none this app shows: refused, never kept.
        if ["approval", "clarify", "secret", "sudo"].contains(method), sessionID.isEmpty {
            return .reply(.error(code: -32602, message: "a question needs the session it belongs to"))
        }
        if declinesNotShown, windowOwned.contains(method) {
            return .reply(.error(code: notShownCode, message: "This window is not showing the session."))
        }
        switch method {
        case "approval":
            guard let approval = Approval(request: params) else {
                // As Hermes's own app does: a folder or site request that names none is refused.
                return .reply(.error(code: -32602, message: "an access request needs a path and a network request needs a host"))
            }
            return .ask(BotQuestion(id: requestID, sessionID: sessionID, route: .request(id), kind: .approval(approval)))
        case "clarify":
            guard let clarify = Clarify(batch: params) else {
                // Nothing that can be answered: a reply with no answers passes on all of it.
                return .reply(.result(.object([:])))
            }
            return .ask(BotQuestion(id: requestID, sessionID: sessionID, route: .request(id), kind: .clarify(clarify)))
        case "secret":
            let name = params["env_var"]?.stringValue ?? ""
            return .ask(BotQuestion(id: requestID, sessionID: sessionID, route: .request(id),
                                    kind: .secret(name: name, prompt: params["prompt"]?.stringValue ?? "")))
        case "sudo":
            return .ask(BotQuestion(id: requestID, sessionID: sessionID, route: .request(id),
                                    kind: .sudo(command: params["command"]?.stringValue ?? "")))
        case "preview.read", "terminal.read":
            // Nothing open: an empty answer, as Hermes's app gives with no preview or terminal.
            return .reply(.result(.object(["value": .string("")])))
        case "preview.act":
            return refusal("This chat is in Hermes Bot, which has no browser preview.")
        case "window.read":
            return .reply(.result(.object(["value": .string(encode(.object([
                "error": .string("read_window_below needs the Hermes desktop app: this chat is in Hermes Bot, which cannot see the windows around it."),
                "platform": .string("hermes-bot"),
            ])))])))
        case "tour":
            return refusal("This chat is in Hermes Bot, which has no guided tours. Do not retry tour in this session.")
        case "theme.apply":
            return refusal("This chat is in Hermes Bot, whose look cannot be changed by a bot.")
        case "theme.pick":
            return .reply(.result(.object(["cancelled": .bool(true)])))
        case "setup_beat":
            // A reply with none of its fields closes the card unanswered.
            return .reply(.result(.object([:])))
        case "display.install.sudo", "vault.code", "vault.save_login", "vault.unlock_prompt":
            // Empty is skipped or declined.
            return .reply(.result(.object(["value": .string("")])))
        default:
            return .reply(.error(code: -32601, message: "Hermes Bot does not answer \(method)"))
        }
    }

    /// Requests only the window showing the chat answers (`WINDOW_OWNED_REQUESTS` in
    /// Hermes's own app).
    static let windowOwned: Set<String> = ["preview.act", "preview.read", "terminal.read", "theme.apply", "window.read", "tour"]
    /// Hermes's `NOT_SHOWN_CODE`.
    static let notShownCode = 4404

    private static func encode(_ value: JSONValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }
}

extension Approval {
    /// Reads the params of an `approval` request. Nil for a folder or site request that names
    /// no folder or site.
    init?(request params: JSONValue) {
        func text(_ key: String) -> String? {
            params[key]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        switch params["kind"]?.stringValue {
        case "access":
            guard let path = text("path") else { return nil }
            let access = params["access"]?.stringValue
            subject = .folder(path: path, canWrite: access == "read_write" ? true : access == "read" ? false : nil)
        case "network":
            guard let host = text("host") else { return nil }
            subject = .site(host: host, label: text("label"))
        default:
            subject = .command(params["command"]?.stringValue ?? "")
        }
        risk = text("risk")
        description = text("description")
        choices = Self.choices(params)
    }

    /// Reads a session authority's approval prompt.
    init(prompt: JSONValue) {
        subject = .command(prompt["command"]?.stringValue ?? "")
        risk = nil
        description = prompt["description"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        choices = Self.choices(prompt)
    }

    /// The answers on offer: those the gateway lists, else as Hermes works them out, with
    /// "for the session" and "always" left out where it says they are not allowed. Deny is
    /// always among them.
    static func choices(_ params: JSONValue) -> [ApprovalChoice] {
        var offered: Set<ApprovalChoice>
        if case .array(let listed)? = params["choices"] {
            offered = Set(listed.compactMap { $0.stringValue.flatMap(ApprovalChoice.init(rawValue:)) })
        } else {
            let smartDenied = params["smart_denied"] == .bool(true)
            offered = [.once, .deny]
            if params["allow_session"] != .bool(false), !smartDenied { offered.insert(.session) }
            if params["allow_permanent"] != .bool(false), !smartDenied { offered.insert(.always) }
        }
        offered.insert(.deny)
        return ApprovalChoice.allCases.filter(offered.contains)
    }
}

extension Clarify {
    /// Reads the params of a `clarify` request: up to five questions, any already answered.
    /// Nil when there is no question that can be shown.
    init?(batch params: JSONValue) {
        guard case .array(let rows)? = params["questions"] else { return nil }
        let questions = rows.compactMap(Question.init(row:))
        guard !questions.isEmpty else { return nil }
        var locked: [String: String?] = [:]
        if case .object(let answers)? = params["answers"] {
            for (id, value) in answers where questions.contains(where: { $0.id == id }) {
                switch value {
                case .string(let text): locked[id] = .some(text)
                case .null: locked[id] = .some(nil)
                default: break
                }
            }
        }
        self.init(questions: Array(questions.prefix(5)), locked: locked)
    }

    /// Reads a session authority's single clarifying question.
    init?(prompt: JSONValue, id: String) {
        guard let text = prompt["question"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let choices = Self.choices(prompt["choices"])
        self.init(questions: [Question(id: id, text: text, choices: choices, multiSelect: prompt["multi_select"] == .bool(true) && !choices.isEmpty)])
    }

    static func choices(_ value: JSONValue?) -> [String] {
        guard case .array(let listed)? = value else { return [] }
        return listed.compactMap { $0.stringValue }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 8000 }
    }
}

extension Clarify.Question {
    init?(row: JSONValue) {
        guard let id = row["qid"]?.stringValue, !id.isEmpty,
              let text = row["question"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let choices = Clarify.choices(row["choices"])
        self.init(id: id, text: text, choices: choices, multiSelect: row["multi_select"] == .bool(true) && !choices.isEmpty)
    }
}

extension BotQuestion {
    /// A question the gateway put to the app, from an event: a request (carried with its id)
    /// or a session authority's prompt. Nil for any other event.
    public init?(_ event: GatewayEvent) {
        if let requestID = event.requestID {
            guard case .ask(let question) = IncomingRequest.read(method: event.type, id: requestID, params: event.payload) else { return nil }
            self = question
            return
        }
        guard event.type == "approval.request" || event.type == "clarify.request" else { return nil }
        self.init(prompt: event.payload, sessionID: event.sessionID ?? "")
    }

    /// One of a session authority's prompts, from an event or a chat's snapshot.
    init?(prompt: JSONValue, sessionID: String) {
        guard let id = prompt["prompt_id"]?.stringValue, !id.isEmpty,
              let generation = prompt["execution_generation"]?.numberValue.flatMap(Int.init(exactly:))
        else { return nil }
        let waits = prompt["timeout_s"]?.numberValue.flatMap { $0 > 0 ? Duration.seconds($0) : nil }
        switch prompt["kind"]?.stringValue {
        case "approval":
            self.init(id: id, sessionID: sessionID, route: .prompt(generation: generation), kind: .approval(Approval(prompt: prompt)), waits: waits)
        case "clarify":
            guard let clarify = Clarify(prompt: prompt, id: id) else { return nil }
            self.init(id: id, sessionID: sessionID, route: .prompt(generation: generation), kind: .clarify(clarify), waits: waits)
        default:
            return nil
        }
    }

    /// The id of the question an event says is over: a request withdrawn (`request.cancel`),
    /// or a prompt settled. With why, when the gateway says.
    public static func ended(by event: GatewayEvent) -> (id: String, reason: String?)? {
        switch event.type {
        case "request.cancel":
            guard let id = event.payload["id"]?.stringValue else { return nil }
            return (id, event.payload["reason"]?.stringValue)
        case "approval.settled", "clarify.settled":
            // Settled says no more than that it is over: by an answer, a deadline or a stop.
            guard let id = event.payload["prompt_id"]?.stringValue else { return nil }
            return (id, nil)
        default:
            return nil
        }
    }
}

extension GatewayClient {
    /// Answers a question a bot put. Over the older route the answer is a response frame, which
    /// the gateway does not acknowledge; a prompt of the session authority's is answered by
    /// method and acknowledged. A secret goes only into the frame that carries it. Returns
    /// false when the gateway says the question was already settled, by someone else or its
    /// deadline, so this answer counted for nothing.
    @discardableResult
    public func answer(_ question: BotQuestion, with answer: QuestionAnswer, profile: String) async throws -> Bool {
        switch question.route {
        case .request(let id):
            try await respond(to: id, with: Self.result(for: question, answer))
            return true
        case .prompt(let generation):
            var params: [String: JSONValue] = [
                "session_id": .string(question.sessionID),
                "profile": .string(profile),
                "execution_generation": .number(Double(generation)),
                "prompt_id": .string(question.id),
            ]
            let method: String
            switch (question.kind, answer) {
            case (.approval, .approval(let choice, _)):
                method = "approval.respond"
                params["choice"] = .string(choice.rawValue)
            case (.approval, _):
                method = "approval.respond"
                params["choice"] = .string(ApprovalChoice.deny.rawValue)
            case (.clarify, .clarify(let answers)):
                method = "clarify.respond"
                // An empty answer is the documented skip.
                params["answer"] = .string(answers[question.id].flatMap { $0?.wire } ?? "")
            case (.clarify, _):
                method = "clarify.respond"
                params["answer"] = .string("")
            default:
                return false
            }
            // As long as Hermes's own app gives it: the gateway's writes can stall well past
            // the usual half minute while the turn is still live.
            let result = try await request(method, .object(params), timeout: .seconds(330))
            return result["status"]?.stringValue != "already_resolved"
        }
    }

    /// Locks one answer of a set of clarifying questions on the gateway before the rest are
    /// answered, so it stands if the gateway stops waiting before the set is sent. It can be
    /// locked again with another answer until every question is. Only for a set asked as a
    /// request; the gateway's own prompts take one answer each. Returns false when the
    /// gateway has stopped waiting.
    @discardableResult
    public func lock(_ answer: ClarifyAnswer?, for questionID: String, of question: BotQuestion, profile: String) async throws -> Bool {
        guard case .request = question.route else { return false }
        let result = try await request("clarify.lock", .object([
            "request_id": .string(question.id),
            "question_id": .string(questionID),
            "answer": answer.map { .string($0.wire) } ?? .null,
            "profile": .string(profile),
        ]))
        return result["status"]?.stringValue != "expired"
    }

    /// The `result` of a response frame for an answer.
    static func result(for question: BotQuestion, _ answer: QuestionAnswer) -> JSONValue {
        switch (question.kind, answer) {
        case (.approval(let approval), .approval(let choice, let reason)):
            var result: [String: JSONValue] = ["choice": .string(choice.rawValue)]
            if choice == .deny, approval.takesReason, let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                result["reason"] = .string(reason)
            }
            return .object(result)
        case (.approval, _):
            return .object(["choice": .string(ApprovalChoice.deny.rawValue)])
        case (.clarify(let clarify), .clarify(let answers)):
            var wire: [String: JSONValue] = [:]
            for question in clarify.questions {
                if let answer = answers[question.id] {
                    wire[question.id] = answer.map { .string($0.wire) } ?? .null
                }
            }
            return .object(["answers": .object(wire), "outcome": .string("submitted")])
        case (.clarify, _):
            // No answers at all: a pass on every question.
            return .object([:])
        case (.secret, .value(let value)), (.sudo, .value(let value)):
            return .object(["value": .string(value)])
        case (.secret, _), (.sudo, _):
            return .object(["value": .string("")])
        }
    }
}
