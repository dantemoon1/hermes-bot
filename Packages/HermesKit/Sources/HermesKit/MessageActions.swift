import Foundation

/// A reaction on a stored message: one emoji, from the person or from the bot.
public struct Reaction: Sendable, Equatable, Hashable {
    public let emoji: String
    /// `user` for the person, `agent` for the bot.
    public let author: String

    public init(emoji: String, author: String) {
        self.emoji = emoji
        self.author = author
    }

    public var isPersons: Bool { author == "user" }
}

/// Where a chat is taken back to: the person's stored message `rowID` and everything after it
/// go. The gateway asks for the row itself, never a count of turns, so another device's turn
/// arriving meanwhile cannot move the cut.
public struct Rewind: Sendable, Equatable {
    public let rowID: Int
    /// The message is the chat's first, so nothing at all is left. The gateway asks for this
    /// to be said outright.
    public let emptiesChat: Bool

    public init(rowID: Int, emptiesChat: Bool) {
        self.rowID = rowID
        self.emptiesChat = emptiesChat
    }

    /// What `prompt.submit` takes on the older route to cut before sending: consent, and the
    /// row. A deeper cut than the one turn is not consented to, so the gateway may refuse it.
    var submitFields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["confirm_truncate": .bool(true), "truncate_before_row_id": .number(Double(rowID))]
        if emptiesChat { fields["confirm_empty_truncate"] = .bool(true) }
        return fields
    }
}

extension GatewayClient {
    /// Sets the person's reaction on a stored row of an open chat, in place of any they had
    /// there; nil takes it off. Returns the row's reactions as the gateway now keeps them.
    public func react(_ emoji: String?, toRow rowID: Int, in chat: LiveChat, profile: String) async throws -> [Reaction] {
        let result = try await request("message.react", .object([
            "session_id": .string(chat.sessionID),
            "profile": .string(profile),
            "row_id": .number(Double(rowID)),
            "emoji": emoji.map(JSONValue.string) ?? .null,
            "author": .string("user"),
        ]))
        guard case .array(let rows)? = result["reactions"] else { throw GatewayError.unexpectedReply(method: "message.react") }
        return rows.compactMap { entry in
            guard let emoji = entry["emoji"]?.stringValue, !emoji.isEmpty else { return nil }
            return Reaction(emoji: emoji, author: entry["author"]?.stringValue ?? "user")
        }
    }

    /// Where the session authority handles chats, the chat's revision and the generation of
    /// its work as they stand now, from a fresh `session.resume` on the same connection (the
    /// gateway takes it as a look at a chat already open). A cut made with it is refused if
    /// anything was said or done in the chat since, so take it before checking what the chat
    /// holds. Nil on the older route, which has no such fence.
    public func rewindFence(in chat: LiveChat, profile: String) async throws -> RewindFence? {
        guard usesSessionAuthority else { return nil }
        let kind = await interfaceKindOnceGreeted()
        let state = try await request("session.resume", .object([
            "session_id": .string(chat.sessionID),
            "profile": .string(profile),
            "omit_messages": .bool(true),
            "source": .string(kind),
        ]), timeout: .seconds(90))
        guard let revision = state["revision"]?.numberValue, let generation = state["execution_generation"]?.numberValue else {
            throw GatewayError.unexpectedReply(method: "session.resume")
        }
        return RewindFence(revision: revision, generation: generation)
    }

    /// Takes the person's message back out of an open chat, with everything after it.
    ///
    /// Where the session authority handles chats, the cut is made at that row, fenced by
    /// `fence`. On the older route the gateway has no such cut without sending something, so
    /// its own undo is used, which takes back the person's latest turn and refuses while the
    /// bot is at work in the chat; the caller must have just seen that this is the row.
    public func undo(_ rewind: Rewind, fence: RewindFence?, in chat: LiveChat, profile: String) async throws {
        if usesSessionAuthority {
            try await authorityRewind(rewind, fence: fence, in: chat, profile: profile)
            return
        }
        let result = try await request("session.undo", .object([
            "session_id": .string(chat.sessionID),
            "profile": .string(profile),
            "intent": .string("undo"),
        ]))
        guard let removed = result["removed"]?.numberValue else { throw GatewayError.unexpectedReply(method: "session.undo") }
        guard removed > 0 else { throw GatewayError.rejected(code: 0, message: "There was nothing to undo.") }
    }

    /// The session authority's cut: `session.mutate` with `rewind`, fenced.
    func authorityRewind(_ rewind: Rewind, fence: RewindFence?, in chat: LiveChat, profile: String) async throws {
        guard let fence else { throw GatewayError.unexpectedReply(method: "session.mutate") }
        _ = try await request("session.mutate", .object([
            "session_id": .string(chat.sessionID),
            // Which bot's chat it is goes with every request, as Hermes's own app sends it.
            "profile": .string(profile),
            "request_id": .string(UUID().uuidString),
            "expected_revision": .number(fence.revision),
            "expected_generation": .number(fence.generation),
            "operation": .string("rewind"),
            "payload": .object(["target_message_id": .number(Double(rewind.rowID))]),
        ]))
    }
}

/// What a cut on the session authority's route must still find for it to go ahead.
public struct RewindFence: Sendable, Equatable {
    let revision: Double
    let generation: Double
}
