import Foundation

/// A Hermes bot: a profile on a gateway, with one permanent chat.
public struct Bot: Sendable, Identifiable, Equatable, Decodable {
    /// The profile name. Stable, and unique on its gateway.
    public let name: String
    public let isDefault: Bool
    public private(set) var model: String?
    public private(set) var provider: String?
    /// What the bot is for, in a line. Hermes's own, not this app's.
    public private(set) var description: String
    public let displayName: String
    public let chat: BotChat?
    /// Per-app display metadata the gateway stores with the bot, keyed by app.
    public private(set) var uiMeta: [String: JSONValue]

    public var id: String { name }

    /// The name to show: the one given in this app, else the one Hermes's own bots screen
    /// stores, so a bot made there is called the same thing here.
    public var title: String {
        if let title = uiMeta["hermes-bot"]?["title"]?.stringValue, !title.isEmpty { return title }
        if let title = uiMeta["hermes-bots"]?["title"]?.stringValue, !title.isEmpty { return title }
        if !displayName.isEmpty { return displayName }
        return isDefault ? "Hermes" : name
    }

    /// The bot as it is once the gateway has taken new notes from this app, so a change
    /// shows without waiting to read every bot again.
    public func keeping(_ notes: JSONValue) -> Bot {
        var bot = self
        bot.uiMeta["hermes-bot"] = notes
        return bot
    }

    /// The bot as it is once the gateway has saved another model for it, so the change
    /// shows even if the roster cannot be read again just now.
    public func running(_ model: String, on provider: String) -> Bot {
        var bot = self
        bot.model = model
        bot.provider = provider
        return bot
    }

    /// The bot as it is once the gateway has taken a new description.
    public func describing(_ description: String) -> Bot {
        var bot = self
        bot.description = description
        return bot
    }

    enum CodingKeys: String, CodingKey {
        case name, model, provider, description
        case isDefault = "is_default"
        case displayName = "display_name"
        case chat = "canonical_session"
        case uiMeta = "ui_meta"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        model = try container.decodeIfPresent(String.self, forKey: .model)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        // Display extras from another Hermes version must not cost us the bot.
        chat = (try? container.decodeIfPresent(BotChat.self, forKey: .chat)) ?? nil
        uiMeta = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .uiMeta)) ?? [:]
    }
}

/// A bot's permanent chat, as summarised in the roster.
public struct BotChat: Sendable, Equatable, Decodable {
    public let id: String
    public let preview: String
    public let lastActive: Date?
    public let messageCount: Int
    /// Where the chat continues after the gateway has compacted it. Nil when it never has.
    public let resolvedID: String?

    /// The id to open the chat with, to carry it on.
    public var liveID: String { resolvedID ?? id }

    enum CodingKeys: String, CodingKey {
        case id, preview
        case resolvedID = "resolved_id"
        case lastActive = "last_active"
        case messageCount = "message_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        lastActive = ((try? container.decodeIfPresent(Double.self, forKey: .lastActive)) ?? nil)
            .map(Date.init(timeIntervalSince1970:))
        messageCount = (try? container.decodeIfPresent(Int.self, forKey: .messageCount)) ?? 0
        let resolved = (try? container.decodeIfPresent(String.self, forKey: .resolvedID)) ?? nil
        resolvedID = resolved.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension GatewayClient {
    /// Every bot on the gateway, the main bot first. A bot this app cannot read is left out
    /// rather than failing the whole list.
    public func listBots() async throws -> [Bot] {
        let result = try await request("profiles.list")
        guard case .array(let profiles)? = result["profiles"] else {
            throw GatewayError.unexpectedReply(method: "profiles.list")
        }
        let bots = profiles.compactMap { try? $0.decode(Bot.self) }
        // None readable means the gateway's shape changed, not that there are no bots.
        guard profiles.isEmpty || !bots.isEmpty else {
            throw GatewayError.unexpectedReply(method: "profiles.list")
        }
        return bots.filter(\.isDefault) + bots.filter { !$0.isDefault }
    }
}
