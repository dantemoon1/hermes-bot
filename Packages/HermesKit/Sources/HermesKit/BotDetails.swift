import Foundation

/// Something a bot does on a schedule. Bots make and change these themselves when asked in
/// chat; this app only shows them.
public struct Routine: Sendable, Equatable, Identifiable, Decodable {
    public let id: String
    /// The name to show, without the tag Hermes's own app puts in front to say whose it is.
    public let name: String
    /// The profile named in that tag. Nil for a routine that carries none.
    public let taggedBot: String?
    /// When it runs, as the gateway holds it: five cron fields, or words like `every 30m`.
    public let schedule: String
    public let isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id = "job_id"
        case name, schedule
        case isEnabled = "enabled"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        var given = ((try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        // "[bot:writer] Morning digest" is writer's "Morning digest".
        if given.hasPrefix("[bot:"), let end = given.firstIndex(of: "]") {
            taggedBot = String(given[given.index(given.startIndex, offsetBy: 5)..<end])
            given = String(given[given.index(after: end)...])
        } else {
            taggedBot = nil
        }
        given = given.trimmingCharacters(in: .whitespacesAndNewlines)
        name = given.isEmpty ? "Routine" : given
        schedule = ((try? container.decodeIfPresent(String.self, forKey: .schedule)) ?? nil) ?? ""
        isEnabled = ((try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil) ?? true
    }
}

extension GatewayClient {
    /// A bot's routines, paused ones included. Read-only.
    public func routines(of profile: String, isMain: Bool = false) async throws -> [Routine] {
        let result = try await request("cron.manage", .object([
            "action": .string("list"),
            "profile": .string(profile),
            "include_disabled": .bool(true),
        ]))
        if result["success"] == .bool(false) {
            throw GatewayError.rejected(code: 0, message: result["error"]?.stringValue ?? "")
        }
        guard case .array(let jobs)? = result["jobs"] else { return [] }
        let all = jobs.compactMap { try? $0.decode(Routine.self) }
        // A gateway that kept to the bot asked for says so. An older one answers with every
        // bot's routines, told apart by their tags; one without a tag is the main bot's.
        if result["scoped"]?.stringValue == profile || result["scoped"] == .bool(true) { return all }
        return all.filter { routine in
            routine.taggedBot.map { $0.lowercased() == profile.lowercased() } ?? isMain
        }
    }

    /// Whether a name is one a gateway could have given a bot. Anything else is never put
    /// on the gateway's command line.
    static func isBotID(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,63}/) != nil
    }

    /// Deletes a bot from the gateway, with its chat, memory and routines. It cannot be
    /// undone. The main bot is never deleted. The gateway has no method of its own for
    /// this; Hermes's own app does it the same way, through the gateway's command line.
    public func deleteBot(id: String) async throws {
        guard id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "default" else {
            throw GatewayError.rejected(code: 0, message: "The main bot can't be deleted.")
        }
        guard Self.isBotID(id) else {
            throw GatewayError.rejected(code: 0, message: "“\(id)” is not a bot's name on a gateway.")
        }
        // The gateway gives up after a minute; this side waits a little longer to hear so.
        let result = try await request("cli.exec", .object([
            "argv": .array([.string("profile"), .string("delete"), .string(id), .string("--yes")]),
            "timeout": .number(60),
        ]), timeout: .seconds(75))
        let code = result["code"]?.numberValue.flatMap { Int(exactly: $0) }
        if result["blocked"] == .bool(true) || code != 0 {
            let said = [result["hint"]?.stringValue, result["output"]?.stringValue]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && $0 != "(no output)" } ?? ""
            throw GatewayError.rejected(code: code ?? 0, message: said)
        }
    }
}

/// Who a bot is, beyond its name and face: the line saying what it is for, and its soul,
/// the few paragraphs that shape how it talks. Both belong to Hermes, not to this app.
public struct BotPersonality: Sendable, Equatable {
    public let description: String
    public let soul: String

    public init(description: String, soul: String) {
        self.description = description
        self.soul = soul
    }
}

/// How much of a bot's chat the gateway is holding in mind, and how much it has used, as
/// the bot's agent counts them while the chat is open on the gateway.
public struct ChatUsage: Sendable, Equatable {
    /// Tokens the chat now fills of the model's context window, and the window's size.
    /// Nil when the gateway can't tell, as before the bot has answered since it started.
    public let contextUsed: Int?
    public let contextMax: Int?
    /// Tokens sent and received since the bot's agent last started on the gateway. Nil
    /// before it has called the model.
    public let tokens: Int?

    public init(contextUsed: Int?, contextMax: Int?, tokens: Int?) {
        self.contextUsed = contextUsed
        self.contextMax = contextMax
        self.tokens = tokens
    }

    /// How full the context window is, from 0 to 1.
    public var contextFraction: Double? {
        guard let contextUsed, let contextMax, contextMax > 0 else { return nil }
        return min(1, max(0, Double(contextUsed) / Double(contextMax)))
    }
}

extension GatewayClient {
    /// A bot's description and soul as the gateway holds them now.
    public func personality(of id: String) async throws -> BotPersonality {
        let result = try await request("profiles.describe", .object(["name": .string(id)]))
        guard case .object = result else { throw GatewayError.unexpectedReply(method: "profiles.describe") }
        return BotPersonality(
            description: result["description"]?.stringValue ?? "",
            soul: result["soul"]?.stringValue ?? "")
    }

    /// Saves a bot's description, its soul, or both; nil leaves one as it is. The gateway
    /// answers each part apart, and can answer with success having saved nothing, so each
    /// part sent must say it was saved.
    public func savePersonality(description: String? = nil, soul: String? = nil, forBot id: String) async throws {
        var params: [String: JSONValue] = ["name": .string(id)]
        if let description { params["description"] = .string(description) }
        if let soul { params["soul"] = .string(soul) }
        guard params.count > 1 else { return }
        let result = try await request("profiles.configure", .object(params))
        let saved = (description == nil || result["applied"]?["description"] == .bool(true))
            && (soul == nil || result["applied"]?["soul"] == .bool(true))
        if result["ok"] == .bool(false) || !saved {
            throw GatewayError.rejected(code: 0, message: "")
        }
    }

    /// Asks the gateway to build a chat's instructions afresh on its next turn, so a new
    /// soul is taken up then. Without this a chat carries on with the soul it started with,
    /// to keep the model's cache warm, until its agent next starts. The gateway has no
    /// method for it; Hermes's own command line does it.
    public func renewInstructions(ofChat chatID: String, forBot id: String) async throws {
        guard Self.isBotID(id) else {
            throw GatewayError.rejected(code: 0, message: "“\(id)” is not a bot's name on a gateway.")
        }
        // Nothing that could be read as an option or more than one word goes on the command line.
        guard chatID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}/) != nil else {
            throw GatewayError.rejected(code: 0, message: "Not a chat's id.")
        }
        let result = try await request("cli.exec", .object([
            "argv": .array(["--profile", id, "sessions", "refresh-prompts", "--session", chatID, "--json"].map { .string($0) }),
            "timeout": .number(30),
        ]), timeout: .seconds(45))
        let code = result["code"]?.numberValue.flatMap { Int(exactly: $0) }
        if result["blocked"] == .bool(true) || code != 0 {
            throw GatewayError.rejected(code: code ?? 0, message: result["output"]?.stringValue ?? "")
        }
    }

    /// How full a bot's open chat is, and what it has used. Only an open chat can say.
    /// Where the session authority handles chats it answers `session.stats` and not the
    /// older route's `session.usage`, with the same counts under other names.
    public func usage(of chat: LiveChat, profile: String) async throws -> ChatUsage {
        let authority = usesSessionAuthority
        let method = authority ? "session.stats" : "session.usage"
        let result = try await request(method, .object([
            "session_id": .string(chat.sessionID),
            "profile": .string(profile),
        ]))
        guard case .object = result else { throw GatewayError.unexpectedReply(method: method) }
        func count(_ key: String) -> Int? {
            guard let value = result[key]?.numberValue, value.isFinite, value >= 0, value < 1e15 else { return nil }
            return Int(value)
        }
        let calls = count(authority ? "api_calls" : "calls") ?? 0
        let max = count(authority ? "context_length" : "context_max").flatMap { $0 > 0 ? $0 : nil }
        // Before the model has been called since the agent started, the gateway says none
        // of the window is used; that is not known, not empty.
        let used = calls > 0 ? count(authority ? "context_tokens" : "context_used") : nil
        let tokens = calls > 0 ? count(authority ? "total_tokens" : "total") : nil
        return ChatUsage(contextUsed: max == nil ? nil : used, contextMax: used == nil ? nil : max, tokens: tokens)
    }
}
