import Foundation
import Testing
@testable import HermesKit

@Suite(.timeLimit(.minutes(1)))
struct BotCreationTests {
    @Test func aNameBecomesAnIdTheGatewayAccepts() {
        #expect(BotID.make(for: "Reading List", taken: []) == "reading-list")
        #expect(BotID.make(for: "  Gym & Health!! ", taken: []) == "gym-health")
        #expect(BotID.make(for: "Café Zoë 2", taken: []) == "cafe-zoe-2")
        #expect(BotID.make(for: "NAS_Ops", taken: []) == "nas-ops")
        #expect(BotID.make(for: "🌱", taken: []) == "bot")
        #expect(BotID.make(for: "", taken: []) == "bot")
        let long = BotID.make(for: String(repeating: "word ", count: 40), taken: [])
        #expect(long.count <= 56)
        #expect(long.last != "-")
        for id in ["reading-list", "gym-health", "cafe-zoe-2", "bot", long] {
            #expect(id.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,63}/) != nil)
        }
    }

    @Test func aTakenOrReservedIdGetsANumber() {
        #expect(BotID.make(for: "Garden", taken: ["garden"]) == "garden-2")
        #expect(BotID.make(for: "Garden", taken: ["garden", "garden-2", "garden-3"]) == "garden-4")
        #expect(BotID.make(for: "Default", taken: []) == "default-2")
        // Every id Hermes reserves, so none reaches the gateway to be refused.
        for name in ["hermes", "default", "test", "tmp", "root", "sudo"] {
            #expect(BotID.make(for: name.capitalized, taken: []) == "\(name)-2")
        }
        #expect(BotID.make(for: "tmp!", taken: []) == "tmp-2")
        #expect(BotID.make(for: "🌱", taken: ["bot"]) == "bot-2")
    }

    @Test func theNameGivenHereWinsOverHermessOwn() throws {
        func bot(_ meta: String) throws -> Bot {
            try JSONDecoder().decode(Bot.self, from: Data(#"{"name":"garden","display_name":"Display","ui_meta":\#(meta)}"#.utf8))
        }
        #expect(try bot(#"{"hermes-bot":{"title":"Ours"},"hermes-bots":{"title":"Theirs"}}"#).title == "Ours")
        #expect(try bot(#"{"hermes-bots":{"title":"Theirs"}}"#).title == "Theirs")
        #expect(try bot(#"{"hermes-bot":{"title":""}}"#).title == "Display")
    }

    @Test func aBotIsMadeThenGivenItsNameAndFaceUnderOurKeyOnly() async throws {
        let seen = Seen()
        let (gateway, endpoint) = try await FakeGateway.start(respond: seen.record)
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        try await client.createBot(id: "garden")
        try await client.saveMeta(.object(["title": .string("Garden")]), forBot: "garden")
        #expect(seen.methods == ["profiles.create", "profiles.configure"])
        #expect(gateway.params(of: "profiles.create").first?["name"] as? String == "garden")
        let saved = try #require(gateway.params(of: "profiles.configure").first)
        #expect(saved["name"] as? String == "garden")
        #expect(Set((saved["ui_meta"] as? [String: Any] ?? [:]).keys) == ["hermes-bot"])
    }

    /// The gateway can answer "done" while saying inside that the name and face were not saved.
    @Test func aSaveTheGatewaySaysDidNotHappenIsAFailure() async throws {
        for reply in [#"{"ok":false,"applied":{"ui_meta":false}}"#, #"{"ok":true,"applied":{"ui_meta":false}}"#] {
            let (gateway, endpoint) = try await FakeGateway.start { id, _ in
                [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(reply)}"#]
            }
            defer { gateway.stop() }
            let client = GatewayClient(endpoint: endpoint, token: "t")
            await client.connect()
            // Its own kind of error, never taken for a request that did not get through.
            await #expect(throws: GatewayClient.NotKept()) {
                try await client.saveMeta(.object(["title": .string("Garden")]), forBot: "garden")
            }
        }
    }

    @Test func aFirstChatIsStartedUnderTheOneTitleAndTitledAtOnce() async throws {
        let seen = Seen()
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            _ = seen.record(id, method)
            return method == "session.create"
                ? [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-9","stored_session_id":"s-9"}}"#]
                : [#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        // With the stored id, so the roster knows the chat before it is read again.
        #expect(try await client.startChat(profile: "garden") == LiveChat(sessionID: "live-9", storedID: "s-9"))
        #expect(seen.methods == ["session.create", "session.title"])
        let made = try #require(gateway.params(of: "session.create").first)
        #expect(made["profile"] as? String == "garden")
        #expect(made["title"] as? String == "Bot Chat")
        #expect(made["hidden"] as? Bool == true)
        #expect(made["follow_profile_config"] as? Bool == true)
        let titled = try #require(gateway.params(of: "session.title").first)
        #expect(titled["session_id"] as? String == "live-9")
        #expect(titled["title"] as? String == "Bot Chat")
        #expect(botChatTitle == "Bot Chat")
    }

    /// The bot already has a chat: the gateway refuses the title, and that reaches the caller.
    @Test func aRefusedTitleIsReported() async throws {
        let seen = Seen()
        let (second, secondEndpoint) = try await FakeGateway.start { id, method in
            _ = seen.record(id, method)
            return method == "session.title"
                ? [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4000,"message":"title already in use"}}"#]
                : [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-9"}}"#]
        }
        defer { second.stop() }
        let other = GatewayClient(endpoint: secondEndpoint, token: "t")
        await other.connect()
        await #expect(throws: GatewayError.rejected(code: 4000, message: "title already in use")) {
            try await other.startChat(profile: "garden")
        }
        // The chat that was not to be used is not left open.
        #expect(seen.methods == ["session.create", "session.title", "session.close"])
        #expect(second.params(of: "session.close").first?["session_id"] as? String == "live-9")
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var methods: [String] { lock.withLock { list } }
        @Sendable func record(_ id: Int, _ method: String) -> [String] {
            lock.withLock { list.append(method) }
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#]
        }
    }
}
