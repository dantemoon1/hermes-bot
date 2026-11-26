import Foundation
import Testing
@testable import HermesKit

@Suite(.timeLimit(.minutes(1)))
struct BotDetailsTests {
    @Test func routinesAreReadWhateverIsMissingFromThem() async throws {
        let reply = #"{"success":true,"count":3,"scoped":"garden","jobs":[{"job_id":"a","name":"[bot:garden] Morning brief","schedule":"0 7 * * *","enabled":true,"next_run_at":"2026-11-25T07:00:00+00:00"},{"job_id":"b","enabled":false},{"name":"no id"}]}"#
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(reply)}"#] }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        let routines = try await client.routines(of: "garden")
        #expect(routines.map(\.id) == ["a", "b"])
        // Shown without the tag that says whose it is.
        #expect(routines[0].name == "Morning brief")
        #expect(routines[0].schedule == "0 7 * * *")
        #expect(routines[0].isEnabled)
        #expect(routines[1].name == "Routine")
        #expect(!routines[1].isEnabled)
        let asked = try #require(gateway.params(of: "cron.manage").first)
        #expect(asked["action"] as? String == "list")
        #expect(asked["profile"] as? String == "garden")
    }

    @Test func anOlderGatewaysAnswerIsNarrowedToTheBotAskedFor() async throws {
        // No "scoped": the gateway ignored the bot and listed everyone's.
        let reply = #"{"success":true,"jobs":[{"job_id":"a","name":"[bot:garden] Watering"},{"job_id":"b","name":"[bot:books] Reading list"},{"job_id":"c","name":"Backup"},{"job_id":"d","name":"[bot:Garden]Weeding"}]}"#
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(reply)}"#] }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        #expect(try await client.routines(of: "garden").map(\.name) == ["Watering", "Weeding"])
        #expect(try await client.routines(of: "books").map(\.name) == ["Reading list"])
        // One with no tag is the main bot's.
        #expect(try await client.routines(of: "default", isMain: true).map(\.name) == ["Backup"])
        #expect(try await client.routines(of: "health").isEmpty)
    }

    @Test func aGatewayThatSaysItKeptToTheBotIsBelievedHoweverItSaysSo() async throws {
        let reply = #"{"success":true,"scoped":true,"jobs":[{"job_id":"a","name":"Watering"}]}"#
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(reply)}"#] }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        #expect(try await client.routines(of: "garden").map(\.name) == ["Watering"])
    }

    @Test func aGatewayThatSaysItCouldNotListRoutinesIsAFailure() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"success":false,"error":"cron store unavailable"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.rejected(code: 0, message: "cron store unavailable")) {
            try await client.routines(of: "garden")
        }
    }

    @Test func deletingAsksForThatBotOnlyAndNeverTheMainOne() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"blocked":false,"code":0,"output":"deleted"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        try await client.deleteBot(id: "meal-plans")
        #expect(gateway.params(of: "cli.exec").first?["argv"] as? [String] == ["profile", "delete", "meal-plans", "--yes"])
        await #expect(throws: GatewayError.self) { try await client.deleteBot(id: "default") }
        // Nor anything that could not be a bot's name, which might read as something else
        // on a command line.
        for id in ["", " Default ", "DEFAULT", "--all", "a b", "-x", "Garden", String(repeating: "a", count: 65)] {
            await #expect(throws: GatewayError.self) { try await client.deleteBot(id: id) }
        }
        #expect(gateway.params(of: "cli.exec").first?["timeout"] as? Int == 60)
        #expect(gateway.params(of: "cli.exec").count == 1)
    }

    @Test func aDeleteTheGatewayBlocksOrFailsIsReportedWithItsWords() async throws {
        for reply in [#"{"blocked":true,"code":0,"output":"","hint":"Not allowed from here"}"#, #"{"blocked":false,"code":1,"hint":"","output":"No such profile\n"}"#, #"{"blocked":false,"code":0.5,"output":"No such profile"}"#] {
            let (gateway, endpoint) = try await FakeGateway.start { id, _ in [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(reply)}"#] }
            defer { gateway.stop() }
            let client = GatewayClient(endpoint: endpoint, token: "t")
            await client.connect()
            do {
                try await client.deleteBot(id: "meal-plans")
                Issue.record("Expected a failure")
            } catch GatewayError.rejected(_, let message) {
                #expect(message == "Not allowed from here" || message == "No such profile")
            }
        }
    }

    @Test func aConfigureReplyMustSayEachPartWasSaved() async throws {
        // Success overall, but the soul is not among what was applied: an older gateway
        // that does not know the field, or one that could not write the file.
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            method == "profiles.configure"
                ? [#"{"jsonrpc":"2.0","id":\#(id),"result":{"ok":true,"applied":{"description":true}}}"#]
                : [#"{"jsonrpc":"2.0","id":\#(id),"result":{"ok":true}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        try await client.savePersonality(description: "Vegetables", forBot: "garden")
        await #expect(throws: GatewayError.rejected(code: 0, message: "")) {
            try await client.savePersonality(description: "Vegetables", soul: "Short answers.", forBot: "garden")
        }
        let sent = try #require(gateway.params(of: "profiles.configure").last)
        #expect(sent["name"] as? String == "garden")
        #expect(sent["soul"] as? String == "Short answers.")
        // Nothing of ours rides along: our notes are written whole elsewhere, one at a time.
        #expect(sent["ui_meta"] == nil)
        // Nothing to save asks nothing.
        try await client.savePersonality(forBot: "garden")
        #expect(gateway.params(of: "profiles.configure").count == 2)
    }

    @Test func usageBeforeTheModelWasCalledIsNotKnown() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"calls":0,"total":0,"context_used":0,"context_max":200000}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        let usage = try await client.usage(of: LiveChat(sessionID: "live-1"), profile: "garden")
        #expect(usage == ChatUsage(contextUsed: nil, contextMax: nil, tokens: nil))
        #expect(usage.contextFraction == nil)
    }

    @Test func onlyAPlainChatIDGoesOnTheCommandLine() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"blocked":false,"code":0,"output":"{}"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        for chat in ["--all", "a b", "", "x;y"] {
            await #expect(throws: GatewayError.self) { try await client.renewInstructions(ofChat: chat, forBot: "garden") }
        }
        await #expect(throws: GatewayError.self) { try await client.renewInstructions(ofChat: "20261125_1", forBot: "--yes") }
        #expect(gateway.params(of: "cli.exec").isEmpty)
        try await client.renewInstructions(ofChat: "20261125_120000_ab12", forBot: "garden")
        let argv = try #require(gateway.params(of: "cli.exec").first?["argv"] as? [String])
        #expect(argv == ["--profile", "garden", "sessions", "refresh-prompts", "--session", "20261125_120000_ab12", "--json"])
        // A chat the session authority made has an id like this.
        let local = "local-" + String(repeating: "ab12", count: 16)
        try await client.renewInstructions(ofChat: local, forBot: "garden")
        #expect((gateway.params(of: "cli.exec").last?["argv"] as? [String])?[5] == local)
    }
}
