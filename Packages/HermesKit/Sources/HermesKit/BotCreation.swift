import Foundation

/// The id a new bot gets on the gateway, worked out from the name the person gave it.
public enum BotID {
    /// Ids the gateway refuses: `_RESERVED_NAMES` in Hermes's `hermes_cli/profiles.py`. And
    /// "main", which it would take but which reads as the main bot.
    static let reserved: Set<String> = ["default", "hermes", "main", "root", "sudo", "test", "tmp"]

    /// A valid, free id for a bot called `title`: lower-case letters, digits, hyphens and
    /// underscores, starting with a letter or digit, at most 64 long. A name with nothing
    /// usable in it becomes "bot". A number is added when the id is taken.
    public static func make(for title: String, taken: Set<String>) -> String {
        var id = ""
        for scalar in title.lowercased().applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?.unicodeScalars ?? title.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                id.unicodeScalars.append(scalar)
            } else if !id.isEmpty, id.last != "-" {
                id.append("-")
            }
        }
        while id.last == "-" { id.removeLast() }
        id = String(id.prefix(56))
        while id.last == "-" { id.removeLast() }
        if id.isEmpty { id = "bot" }

        let unavailable = taken.union(reserved)
        guard unavailable.contains(id) else { return id }
        var number = 2
        while unavailable.contains("\(id)-\(number)") { number += 1 }
        return "\(id)-\(number)"
    }
}

/// The title every bot's one chat has on the gateway. Hermes finds a bot's chat by this
/// exact title, so it is the chat's identity: never start one under another.
public let botChatTitle = "Bot Chat"

extension GatewayClient {
    /// Makes a new bot on the gateway, with nothing about it saved yet: follow with
    /// `saveMeta`. Throws `GatewayError.rejected` if the gateway refuses, as it does when a
    /// bot of that id already exists.
    public func createBot(id: String) async throws {
        _ = try await request("profiles.create", .object(["name": .string(id)]), timeout: .seconds(120))
    }

    /// The gateway answered that it did not keep what this app saves about a bot: said in a
    /// reply that is otherwise a success. Its own kind, so it is never mistaken for a request
    /// that did not get through.
    public struct NotKept: Error, Sendable, Equatable {}

    /// Saves what this app keeps about a bot (its shown name and face), under this app's key
    /// and no other. Throws `NotKept` if the gateway said it did not save it, which it can
    /// report in a reply that is otherwise a success.
    public func saveMeta(_ uiMeta: JSONValue, forBot id: String) async throws {
        let result = try await request("profiles.configure", .object([
            "name": .string(id),
            "ui_meta": .object(["hermes-bot": uiMeta]),
        ]))
        if result["ok"] == .bool(false) || result["applied"]?["ui_meta"] == .bool(false) {
            throw NotKept()
        }
    }

    /// Starts a bot's chat, for a bot that has never had one, and returns it open. If the
    /// bot turns out to have a chat already, the gateway refuses the title and this throws
    /// `GatewayError.rejected`: read the roster again and open that chat.
    public func startChat(profile: String) async throws -> LiveChat {
        let kind = await interfaceKindOnceGreeted()
        await questionsAdvertised()
        let result = try await request("session.create", .object([
            "profile": .string(profile),
            "title": .string(botChatTitle),
            "source": .string(kind),
            // Kept out of Hermes's own list of sessions, as its bot chats are.
            "hidden": .bool(true),
            // Answers with the bot's current model, not one pinned when the chat was made.
            "follow_profile_config": .bool(true),
        ]), timeout: .seconds(90))
        guard let sessionID = result["session_id"]?.stringValue, !sessionID.isEmpty else {
            throw GatewayError.unexpectedReply(method: "session.create")
        }
        // The chat is only stored once it has a message. Titling it now stores it under the
        // one title a bot's chat is found by, before the first message can be given another.
        do {
            _ = try await request("session.title", .object([
                "session_id": .string(sessionID),
                "profile": .string(profile),
                "title": .string(botChatTitle),
            ]))
        } catch GatewayError.unsupported {
            // A gateway that titles the chat as it makes it, or an older one that applies the
            // title given at creation with the first message.
        } catch {
            // Refused: most likely the bot already has its chat. This one is not to be used,
            // so don't leave it open on the gateway.
            _ = try? await request("session.close", .object(["session_id": .string(sessionID), "profile": .string(profile)]))
            throw error
        }
        let stored = result["stored_session_id"]?.stringValue
        return LiveChat(sessionID: sessionID, storedID: stored?.isEmpty == false ? stored : nil)
    }
}
