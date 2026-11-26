import Foundation

/// One stored row of a bot's chat, as the gateway keeps it.
public struct ChatMessage: Sendable, Identifiable, Equatable, Decodable {
    public let id: Int
    /// `user`, `assistant`, `tool`, or something newer this app does not know.
    public let role: String
    public let text: String
    public let date: Date?
    /// The tools an assistant row asked for.
    public let toolCalls: [String]
    /// What the gateway marks a row as beyond its role: `hidden` for a turn no person typed
    /// (such as a page talking to its bot), `steer` for words sent mid-answer, and others.
    public let displayKind: String?
    /// Reactions on the row, the person's and the bot's, as the gateway keeps them.
    public let reactions: [Reaction]

    public init(
        id: Int, role: String, text: String, date: Date? = nil, toolCalls: [String] = [],
        displayKind: String? = nil, reactions: [Reaction] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
        self.toolCalls = toolCalls
        self.displayKind = displayKind
        self.reactions = reactions
    }

    /// Sent where no one sees it. The bot was told it; the chat does not show it as said.
    public var isHidden: Bool { displayKind == "hidden" }

    /// Something the person said: a user row the gateway counts as a turn of theirs, as its
    /// own undo does. A row of any other kind (a hidden turn, a notice) is not.
    public var isPersons: Bool {
        role == "user" && ((displayKind ?? "").isEmpty || displayKind == "steer")
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
        case displayContent = "display_content"
        case toolCalls = "tool_calls"
        case displayKind = "display_kind"
        case displayMetadata = "display_metadata"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        // What the person saw wins over what the model was sent, when the gateway kept both.
        let shown = (try? container.decodeIfPresent(String.self, forKey: .displayContent)) ?? nil
        let content = (try? container.decodeIfPresent(JSONValue.self, forKey: .content)) ?? nil
        if let shown, !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = shown
        } else {
            text = Self.plainText(content)
        }
        date = ((try? container.decodeIfPresent(Double.self, forKey: .timestamp)) ?? nil)
            .map(Date.init(timeIntervalSince1970:))
        let calls = (try? container.decodeIfPresent([JSONValue].self, forKey: .toolCalls)) ?? nil
        toolCalls = (calls ?? []).compactMap { $0["function"]?["name"]?.stringValue }
        displayKind = (try? container.decodeIfPresent(String.self, forKey: .displayKind)) ?? nil
        // Kept as an object, or by older stores as that object written out as a string.
        var metadata = (try? container.decodeIfPresent(JSONValue.self, forKey: .displayMetadata)) ?? nil
        if case .string(let written)? = metadata {
            metadata = try? JSONDecoder().decode(JSONValue.self, from: Data(written.utf8))
        }
        if case .array(let found)? = metadata?["reactions"] {
            reactions = found.compactMap { entry in
                guard let emoji = entry["emoji"]?.stringValue, !emoji.isEmpty else { return nil }
                return Reaction(emoji: emoji, author: entry["author"]?.stringValue ?? "user")
            }
        } else {
            reactions = []
        }
    }

    /// Content is a string, or a list of parts of which only the text ones are words.
    private static func plainText(_ content: JSONValue?) -> String {
        switch content {
        case .string(let text): text
        case .array(let parts): parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        default: ""
        }
    }
}

extension GatewayClient {
    /// The latest stored messages of a chat, oldest first. Read-only: it does not wake the bot
    /// or open a session. Ask only for a chat the roster lists: a gateway that answers "not
    /// found" for one either has no such route or no such chat, and both are `unsupported`.
    /// How many of a chat's latest messages are read unless asked otherwise.
    public static let chatReadLimit = 100

    public func chatMessages(sessionID: String, profile: String, limit: Int = chatReadLimit) async throws -> [ChatMessage] {
        // Dots are escaped too, so an id can never act as a "." or ".." path step.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~"))
        let id = sessionID.addingPercentEncoding(withAllowedCharacters: safe) ?? sessionID
        let result = try await get("/api/sessions/\(id)/messages", query: [
            "profile": profile, "limit": String(limit), "order": "latest", "inline_images": "false",
        ], as: "sessions.messages")
        guard let result else { throw GatewayError.unsupported(method: "sessions.messages") }
        guard case .array(let rows)? = result["messages"] else {
            throw GatewayError.unexpectedReply(method: "sessions.messages")
        }
        let messages = rows.compactMap { try? $0.decode(ChatMessage.self) }
        // None readable means the gateway's shape changed, not that the chat is empty.
        guard rows.isEmpty || !messages.isEmpty else {
            throw GatewayError.unexpectedReply(method: "sessions.messages")
        }
        return messages
    }
}
