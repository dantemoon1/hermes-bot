import Foundation
import Testing
@testable import HermesKit

@Suite(.timeLimit(.minutes(1)))
struct BotModelTests {
    /// Answers every request with `reply`; with `keepsToTheBot`, config.get about a bot that
    /// is not there is refused first, as Hermes since 0.21.6 does.
    private func client(answering reply: String, keepsToTheBot: Bool = false) async throws -> (FakeGateway, GatewayClient) {
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            if keepsToTheBot, method == "config.get" {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4064,"message":"Profile 'hermes-bot-no-such-bot' does not exist."}}"#]
            }
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(reply)}"#]
        }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        return (gateway, client)
    }

    @Test func onlySignedInProvidersWithModelsAreKept() async throws {
        let (gateway, client) = try await client(answering: #"""
        {"model":"m1","provider":"a","providers":[
          {"slug":"a","name":"A","authenticated":true,"models":["m1","m2","m3","m1"],"featured_models":["m2","gone","m2"],
           "unavailable_models":["m3"],"capabilities":{"m1":{"fast":true,"reasoning":true},"m2":{"fast":true,"reasoning":true,"can_disable_reasoning":false}}},
          {"slug":"old","name":"","models":[{"id":"x"},{"name":"no id"}]},
          {"slug":"b","name":"B","authenticated":false,"models":["b1"]},
          {"slug":"empty","name":"E","models":[]}]}
        """#, keepsToTheBot: true)
        defer { gateway.stop() }
        let options = try await client.modelOptions(forBot: "garden")
        #expect(gateway.params(of: "model.options").first?["profile"] as? String == "garden")
        #expect(options.providers.map(\.slug) == ["a", "old"])
        #expect(options.providers[0].models == ["m1", "m2"])
        // Featured only among what is offered.
        #expect(options.providers[0].featured == ["m2"])
        #expect(options.providers[1].name == "old")
        #expect(options.providers[1].models == ["x"])
        #expect(options.current == ModelChoice(provider: "a", model: "m1"))
        // Most providers do not say whether thinking can be turned off; only a plain no keeps Off away.
        #expect(options.capabilities(of: ModelChoice(provider: "a", model: "m1")) == ModelCapabilities(reasoning: true, canTurnOffReasoning: true))
        #expect(options.capabilities(of: ModelChoice(provider: "a", model: "m2")) == ModelCapabilities(reasoning: true, canTurnOffReasoning: false))
        #expect(options.capabilities(of: ModelChoice(provider: "old", model: "x")) == nil)
    }

    @Test func aProviderGivenByAnotherOfItsNamesIsTheSameOne() async throws {
        let (gateway, client) = try await client(answering: #"""
        {"model":"llama","provider":"custom:nvidia","providers":[
          {"slug":"nvidia","name":"NVIDIA","aliases":["custom:nvidia"],"models":["llama"],"capabilities":{"llama":{"fast":false,"reasoning":true}}}]}
        """#, keepsToTheBot: true)
        defer { gateway.stop() }
        let options = try await client.modelOptions(forBot: "garden")
        #expect(options.current == ModelChoice(provider: "nvidia", model: "llama"))
        #expect(options.capabilities(of: ModelChoice(provider: "custom:nvidia", model: "llama"))?.reasoning == true)
        #expect(options.listed(ModelChoice(provider: "custom:nvidia", model: "llama")) == ModelChoice(provider: "nvidia", model: "llama"))
        // Its name to show counts too, as a hand-written setting may give it.
        #expect(options.listed(ModelChoice(provider: "NVIDIA", model: "llama")) == ModelChoice(provider: "nvidia", model: "llama"))
    }

    /// Hermes before 0.21.6 names the main bot's model whichever bot is asked about.
    @Test func theCurrentModelIsLeftOutWhereTheGatewayDoesNotKeepToTheBot() async throws {
        let (gateway, client) = try await client(answering: #"{"model":"m1","provider":"a","providers":[{"slug":"a","name":"A","models":["m1"]}]}"#)
        defer { gateway.stop() }
        let options = try await client.modelOptions(forBot: "garden")
        #expect(options.current == nil)
        #expect(options.providers.map(\.slug) == ["a"])
    }

    @Test func aModelIsSavedOnTheBotByName() async throws {
        let (gateway, client) = try await client(answering: #"{"ok":true,"applied":{"model":true}}"#)
        defer { gateway.stop() }
        #expect(try await client.setModel(ModelChoice(provider: "a", model: "m1"), forBot: "garden") == .saved)
        let sent = try #require(gateway.params(of: "profiles.configure").first)
        #expect(sent["name"] as? String == "garden")
        #expect(sent["model"] as? String == "m1")
        #expect(sent["provider"] as? String == "a")
        #expect(sent["confirm_expensive_model"] == nil)
        // Nothing of ours or anyone's notes rides along.
        #expect(sent["ui_meta"] == nil)
    }

    @Test func aGuardedModelAsksAndIsSentAgainOnlyWhenAgreed() async throws {
        let (gateway, client) = try await client(answering: #"{"ok":true,"applied":{},"confirm_required":true,"confirm_message":" Costs more. "}"#)
        defer { gateway.stop() }
        #expect(try await client.setModel(ModelChoice(provider: "a", model: "big"), forBot: "garden") == .needsConfirming("Costs more."))
        // Agreed, and still not said to be applied: not a save.
        await #expect(throws: GatewayError.rejected(code: 0, message: GatewayClient.modelNotSaved)) {
            try await client.setModel(ModelChoice(provider: "a", model: "big"), forBot: "garden", confirmed: true)
        }
        #expect(gateway.params(of: "profiles.configure").last?["confirm_expensive_model"] as? Bool == true)
    }

    @Test func aReplyThatDoesNotSayTheModelWasWrittenIsAFailure() async throws {
        for reply in [#"{"ok":false,"applied":{"model":false}}"#, #"{"ok":true,"applied":{}}"#] {
            let (gateway, client) = try await client(answering: reply)
            defer { gateway.stop() }
            await #expect(throws: GatewayError.self) {
                try await client.setModel(ModelChoice(provider: "a", model: "m1"), forBot: "garden")
            }
        }
    }

    /// Answers config.get for a bot that is not there as Hermes since 0.21.6 does, by refusing.
    private func scopedGateway(greeting: String? = nil) async throws -> (FakeGateway, GatewayClient) {
        let asked = Counter()
        let respond: FakeGateway.Responder = { id, method in
            if method == "config.get", asked.next() == 1 {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4064,"message":"Profile 'hermes-bot-no-such-bot' does not exist."}}"#]
            }
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"key":"reasoning","value":"none"}}"#]
        }
        let (gateway, endpoint) = if let greeting {
            try await FakeGateway.start(greeting: greeting, respond: respond)
        } else {
            try await FakeGateway.start(respond: respond)
        }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        return (gateway, client)
    }

    @Test func reasoningIsTheBotsOwnAndNeverOneChats() async throws {
        let (gateway, client) = try await scopedGateway()
        defer { gateway.stop() }
        #expect(try await client.reasoning(ofBot: "garden") == .off)
        try await client.setReasoning(.xhigh, forBot: "garden")
        // Asked first about a bot that is not there, and only once.
        #expect(gateway.params(of: "config.get").count == 2)
        #expect(gateway.params(of: "config.get").first?["profile"] as? String == "hermes-bot-no-such-bot")
        let read = try #require(gateway.params(of: "config.get").last)
        #expect(read["profile"] as? String == "garden" && read["key"] as? String == "reasoning")
        let sent = try #require(gateway.params(of: "config.set").first)
        #expect(sent["profile"] as? String == "garden")
        #expect(sent["value"] as? String == "xhigh")
        #expect(sent["scope"] as? String == "global")
        #expect(sent["session_id"] == nil)
    }

    /// Hermes before 0.21.6 answers for the main bot whichever is named: nothing is written.
    @Test func aGatewayThatDoesNotKeepToTheBotNamedIsNeverWrittenTo() async throws {
        let (gateway, client) = try await client(answering: #"{"key":"reasoning","value":"medium"}"#)
        defer { gateway.stop() }
        await #expect(throws: GatewayError.unsupported(method: "config.set")) {
            try await client.reasoning(ofBot: "garden")
        }
        await #expect(throws: GatewayError.unsupported(method: "config.set")) {
            try await client.setReasoning(.low, forBot: "garden")
        }
        #expect(gateway.params(of: "config.set").isEmpty)
        #expect(gateway.params(of: "config.get").count == 1)
    }

    /// Only Hermes's refusal of that very bot is proof: any other refusal proves nothing.
    @Test func aRefusalOfAnotherKindNeverLetsAWriteThrough() async throws {
        let asked = Counter()
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            if method == "config.get", asked.next() == 1 {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":5001,"message":"settings store unavailable"}}"#]
            }
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"key":"reasoning","value":"medium"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: (any Error).self) { try await client.setReasoning(.low, forBot: "garden") }
        // Asked again, and this time answered as for the main bot: still nothing written.
        await #expect(throws: GatewayError.unsupported(method: "config.set")) {
            try await client.setReasoning(.low, forBot: "garden")
        }
        #expect(gateway.params(of: "config.set").isEmpty)
    }

    /// The session authority's config.set takes a bot's settings only through an open chat.
    @Test func reasoningIsNotOfferedWhereTheSessionAuthorityHandlesChats() async throws {
        let (gateway, client) = try await scopedGateway(
            greeting: #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"session_authority":true}}}"#)
        defer { gateway.stop() }
        await #expect(throws: GatewayError.unsupported(method: "config.set")) {
            try await client.setReasoning(.low, forBot: "garden")
        }
        #expect(gateway.params(of: "config.get").isEmpty)
        #expect(gateway.params(of: "config.set").isEmpty)
    }

    @Test func aGatewayOlderThanAFieldIsAMissingFeature() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4000,"message":"invalid params for config.set: scope: Extra inputs are not permitted"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.unsupported(method: "model.options")) {
            try await client.modelOptions(forBot: "garden")
        }
        // Refusing the bot's name as a field it does not know is not keeping to the bot.
        await #expect(throws: GatewayError.unsupported(method: "config.get")) {
            try await client.setReasoning(.low, forBot: "garden")
        }
        #expect(gateway.params(of: "config.set").isEmpty)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }
}
