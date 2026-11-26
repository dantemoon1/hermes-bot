import Foundation

/// The models a bot could run on: those of the providers its gateway is signed in to.
public struct ModelOptions: Sendable, Equatable {
    public struct Provider: Sendable, Equatable, Identifiable {
        /// The provider's name on the gateway, as `profiles.configure` takes it.
        public let slug: String
        /// Its name to show.
        public let name: String
        public let models: [String]
        /// The ones the gateway puts forward, in its order. Also among `models`.
        public let featured: [String]
        /// Other names a bot's settings may give this provider by.
        let aliases: [String]
        let capabilities: [String: ModelCapabilities]

        public var id: String { slug }

        public init(slug: String, name: String, models: [String], featured: [String] = [], aliases: [String] = [], capabilities: [String: ModelCapabilities] = [:]) {
            self.slug = slug
            self.name = name
            self.models = models
            self.featured = featured
            self.aliases = aliases
            self.capabilities = capabilities
        }

        /// By its slug, its name or one of its aliases, exactly, as Hermes's own app matches
        /// a bot's provider (`catalogProviderMatches`).
        func isCalled(_ given: String) -> Bool {
            !given.isEmpty && (given == slug || given == name || aliases.contains(given))
        }
    }

    public let providers: [Provider]
    /// The model the bot runs on now, as the gateway reads its settings. Nil when it did not
    /// say, or when it cannot be trusted to be this bot's (see `modelOptions(forBot:)`).
    public internal(set) var current: ModelChoice?

    public init(providers: [Provider], current: ModelChoice?) {
        self.providers = providers
        self.current = current
    }

    /// What the gateway says a model can do. Nil when it says nothing, which is not taken
    /// to mean it can think.
    public func capabilities(of choice: ModelChoice) -> ModelCapabilities? {
        providers.first { $0.isCalled(choice.provider) }?.capabilities[choice.model]
    }

    /// The same choice under the provider's name in this list, for one a bot's settings
    /// give by another of its names.
    public func listed(_ choice: ModelChoice) -> ModelChoice {
        guard let provider = providers.first(where: { $0.isCalled(choice.provider) }) else { return choice }
        return ModelChoice(provider: provider.slug, model: choice.model)
    }

    /// Read from `model.options`. Only providers the gateway is signed in to are kept: one it
    /// is not signed in to cannot run the bot. A provider with no models is left out.
    init(_ result: JSONValue) {
        var providers: [Provider] = []
        if case .array(let rows)? = result["providers"] {
            for row in rows {
                guard let slug = row["slug"]?.stringValue, !slug.isEmpty else { continue }
                // Said to be not signed in. Gateways that do not say are taken at their word
                // that the provider is there to use, as Hermes's own picker does.
                if row["authenticated"] == .bool(false) { continue }
                let unavailable = Set(Self.strings(row["unavailable_models"]))
                // Bare names on current gateways; objects with an `id` on older ones.
                var seen = Set<String>()
                let models = Self.models(row["models"]).filter { !unavailable.contains($0) && seen.insert($0).inserted }
                guard !models.isEmpty else { continue }
                var featuredSeen = Set<String>()
                let featured = Self.strings(row["featured_models"]).filter { seen.contains($0) && featuredSeen.insert($0).inserted }
                var capabilities: [String: ModelCapabilities] = [:]
                if case .object(let given)? = row["capabilities"] {
                    for (model, value) in given {
                        // Hermes knows whether thinking can be turned off only for some providers,
                        // and says nothing for the rest; only a plain "no" keeps Off from being
                        // offered, as in Hermes's own app.
                        capabilities[model] = ModelCapabilities(
                            reasoning: value["reasoning"] == .bool(true),
                            canTurnOffReasoning: value["can_disable_reasoning"] != .bool(false))
                    }
                }
                let name = row["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? slug
                providers.append(Provider(slug: slug, name: name, models: models, featured: featured, aliases: Self.strings(row["aliases"]), capabilities: capabilities))
            }
        }
        self.providers = providers
        if let model = result["model"]?.stringValue, !model.isEmpty,
           let provider = result["provider"]?.stringValue, !provider.isEmpty {
            let given = ModelChoice(provider: provider, model: model)
            current = providers.first { $0.isCalled(provider) }.map { ModelChoice(provider: $0.slug, model: model) } ?? given
        } else {
            current = nil
        }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue).filter { !$0.isEmpty }
    }

    private static func models(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap { $0.stringValue ?? $0["id"]?.stringValue }.filter { !$0.isEmpty }
    }
}

/// A model on a provider, which together are what a bot runs on.
public struct ModelChoice: Sendable, Hashable {
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

public struct ModelCapabilities: Sendable, Equatable {
    /// The model can be asked to think before it answers, at a chosen level.
    public let reasoning: Bool
    /// Its thinking can be turned off altogether.
    public let canTurnOffReasoning: Bool

    public init(reasoning: Bool, canTurnOffReasoning: Bool) {
        self.reasoning = reasoning
        self.canTurnOffReasoning = canTurnOffReasoning
    }
}

/// How hard a bot thinks before answering, in the words Hermes takes
/// (`parse_reasoning_effort` in `hermes_constants.py`).
public enum ReasoningLevel: String, Sendable, CaseIterable {
    /// Thinking turned off.
    case off = "none"
    case minimal, low, medium, high, xhigh, max, ultra

    /// The levels offered to choose from. The others are shown when a bot already has one.
    public static let offered: [ReasoningLevel] = [.off, .low, .medium, .high, .xhigh]

    /// Read as Hermes reads it: "false" and "disabled" also mean off. Nil for anything else.
    public init?(word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["none", "false", "disabled"].contains(word) {
            self = .off
        } else if let level = ReasoningLevel(rawValue: word) {
            self = level
        } else {
            return nil
        }
    }
}

/// What came of asking for a bot's model to be changed.
public enum ModelChange: Sendable, Equatable {
    case saved
    /// The gateway wants the person to agree first, saying why (a model that costs far more,
    /// or one whose provider keeps what it is sent). Nothing was saved: ask again with
    /// `confirmed` once they agree.
    case needsConfirming(String)
}

extension GatewayClient {
    /// The models a bot could run on, and the one it runs on now. Bounded: the gateway can
    /// take a long time to gather its providers' lists, or never answer.
    /// The model it names as current is this bot's only where the gateway keeps to the bot
    /// named: Hermes before 0.21.6 answers with the main bot's whichever is named, as it does
    /// for settings (`keepsSettingsPerBot`). Where the session authority handles chats it
    /// refuses any bot but the one it serves, so an answer there is that bot's. Otherwise,
    /// or when that can't be found out just now, `current` is left out.
    public func modelOptions(forBot profile: String) async throws -> ModelOptions {
        // Vouched for only by what is found on the socket that answered.
        let socketAskedOn = sockets
        let result = try await outOfSync("model.options") {
            try await request("model.options", .object(["profile": .string(profile)]), timeout: .seconds(20))
        }
        var options = ModelOptions(result)
        let isThisBots = await sessionAuthorityOnceGreeted() ? true : ((try? await keepsSettingsPerBot()) ?? false)
        if !isThisBots || socketAskedOn != sockets { options.current = nil }
        return options
    }

    /// Saves the model a bot runs on, on the bot itself, so it lasts and follows the bot to
    /// Hermes's own app. Throws when the gateway says it did not save it, which it can say
    /// inside a reply that is otherwise a success.
    public func setModel(_ choice: ModelChoice, forBot profile: String, confirmed: Bool = false) async throws -> ModelChange {
        var params: [String: JSONValue] = [
            "name": .string(profile),
            "model": .string(choice.model),
            "provider": .string(choice.provider),
        ]
        if confirmed { params["confirm_expensive_model"] = .bool(true) }
        let result = try await outOfSync("profiles.configure") {
            try await request("profiles.configure", .object(params), timeout: .seconds(60))
        }
        if result["confirm_required"] == .bool(true), !confirmed {
            let said = result["confirm_message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .needsConfirming(said)
        }
        // Only a reply that says the model was written counts: a gateway too old to know
        // the field leaves it out, and one that could not write it says false.
        guard result["applied"]?["model"] == .bool(true) else {
            throw GatewayError.rejected(code: 0, message: Self.modelNotSaved)
        }
        return .saved
    }

    /// Said when the gateway answered without saving the model. Hermes does not say why: the
    /// provider may have turned the model down, or an administrator may have fixed it.
    public static let modelNotSaved = "Hermes didn't save that model. Its provider may not offer it, or the bot's model may be fixed by an administrator."

    /// How hard a bot thinks, as saved on the bot. Hermes takes medium when nothing is set.
    /// Nil for a word this app does not know. `unsupported` where it can't be had for one
    /// bot alone (see `keepsSettingsPerBot`).
    public func reasoning(ofBot profile: String) async throws -> ReasoningLevel? {
        try await requireSettingsPerBot()
        let result = try await outOfSync("config.get") {
            try await request("config.get", .object(["profile": .string(profile), "key": .string("reasoning")]))
        }
        return result["value"]?.stringValue.flatMap(ReasoningLevel.init(word:))
    }

    /// Saves how hard a bot thinks, on the bot itself and not only one chat: the gateway
    /// writes `agent.reasoning_effort` in that bot's own settings. A setting an administrator
    /// has fixed comes back as `GatewayError.rejected` with code 4030 and their words.
    public func setReasoning(_ level: ReasoningLevel, forBot profile: String) async throws {
        try await requireSettingsPerBot()
        _ = try await outOfSync("config.set") {
            try await request("config.set", .object([
                "profile": .string(profile),
                "key": .string("reasoning"),
                "value": .string(level.rawValue),
                // Never only this chat: with no chat named it is the bot's anyway, and saying
                // so keeps it that way should one ever be.
                "scope": .string("global"),
            ]))
        }
    }

    /// Whether this gateway reads and writes a bot's settings for that bot alone. Hermes
    /// before 0.21.6 takes no notice of `profile` on `config.get` and `config.set`, and a
    /// write meant for one bot would change the main bot's settings; it does not refuse the
    /// field either. So it is asked about a bot that does not exist: a gateway that keeps
    /// to the bot named refuses, and one that answers has read the main bot's settings.
    /// Where the gateway's session authority handles chats, its `config.set` takes the
    /// bot's settings only through an open chat, which this does not use yet: false there.
    /// Asked once per connection.
    public func keepsSettingsPerBot() async throws -> Bool {
        if let perBot = settingsPerBot { return perBot }
        // Kept only for the socket it was found on.
        let socketAskedOn = sockets
        let perBot: Bool
        if await sessionAuthorityOnceGreeted() {
            perBot = false
        } else {
            do {
                // Not knowing the field at all is not keeping to the bot: `outOfSync` says so.
                _ = try await outOfSync("config.get") {
                    try await request("config.get", .object(["profile": .string(Self.noSuchBot), "key": .string("reasoning")]))
                }
                perBot = false
            } catch GatewayError.rejected(code: 4064, let message) where message.contains("'\(Self.noSuchBot)'") {
                // Only Hermes's own refusal of that very bot is proof; any other refusal
                // (a moment's trouble, a settings store that is down) proves nothing, and
                // is not kept, so it is asked again next time.
                perBot = true
            }
        }
        // A socket opened meanwhile has proved nothing: what is sent next would go on it.
        guard socketAskedOn == sockets else { return false }
        settingsPerBot = perBot
        return perBot
    }

    /// A bot's name no gateway has, asked about to see whether a gateway keeps to the bot named.
    static let noSuchBot = "hermes-bot-no-such-bot"

    func requireSettingsPerBot(_ method: String = "config.set") async throws {
        guard try await keepsSettingsPerBot() else { throw GatewayError.unsupported(method: method) }
    }

    /// A gateway older than one of these calls' fields refuses them as being out of step
    /// with this app (4000, "invalid params"). That is a missing feature, not a failure.
    func outOfSync(_ method: String, _ call: () async throws -> JSONValue) async throws -> JSONValue {
        do {
            return try await call()
        } catch GatewayError.rejected(code: 4000, let message) where message.hasPrefix("invalid params") {
            throw GatewayError.unsupported(method: method)
        }
    }
}
