import Foundation
import Testing
@testable import HermesKit

@Suite(.timeLimit(.minutes(1)))
struct SlashCommandsTests {
    private let chat = LiveChat(sessionID: "live-1")

    private func client(_ respond: @escaping FakeGateway.Responder) async throws -> (FakeGateway, GatewayClient) {
        let (gateway, endpoint) = try await FakeGateway.start(respond: respond)
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        return (gateway, client)
    }

    private func answering(_ result: String) async throws -> (FakeGateway, GatewayClient) {
        try await client { id, _ in [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#] }
    }

    @Test func theCommandsOfferedAreTheCatalogsNames() async throws {
        let (gateway, client) = try await answering(#"{"pairs":[["/status","Show status"],["/Undo","Back up [N]"],["/","?"],[42],"/plain"],"categories":[]}"#)
        defer { gateway.stop() }
        #expect(try await client.offeredCommands() == ["status", "undo"])
        // Its own commands are every bot's: none is named, which an older gateway would refuse.
        #expect(gateway.params(of: "commands.catalog").first?.isEmpty == true)
    }

    @Test func aGatewayWithoutTheCatalogOffersNoCommands() async throws {
        let (gateway, client) = try await client { id, _ in [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown method"}}"#] }
        defer { gateway.stop() }
        await #expect(throws: GatewayError.unsupported(method: "commands.catalog")) { try await client.offeredCommands() }
    }

    @Test func whatACommandPrintsIsSaid() async throws {
        let (gateway, client) = try await answering(#"{"output":"  Model: orbit-mini\n","warning":"live session sync failed"}"#)
        defer { gateway.stop() }
        #expect(try await client.runCommand("/status", in: chat, profile: "garden") == .said("  Model: orbit-mini\n", warning: "live session sync failed"))
        let sent = try #require(gateway.params(of: "slash.exec").first)
        #expect(sent["command"] as? String == "status")
        #expect(sent["session_id"] as? String == "live-1")
        #expect(sent["profile"] as? String == "garden")
    }

    @Test func nothingPrintedIsNothingSaid() async throws {
        let (gateway, client) = try await answering(#"{"output":"(no output)"}"#)
        defer { gateway.stop() }
        #expect(try await client.runCommand("fast", in: chat, profile: "garden") == .said("", warning: nil))
    }

    @Test func aCommandCanHandBackAMessageToSendOrToEdit() async throws {
        let (gateway, client) = try await client { id, _ in
            [id == 1
                ? #"{"jsonrpc":"2.0","id":1,"result":{"type":"send","message":"move the bakery order","notice":""}}"#
                : #"{"jsonrpc":"2.0","id":\#(id),"result":{"type":"prefill","message":"thanks","notice":"↶ Undid 1 turn"}}"#]
        }
        defer { gateway.stop() }
        #expect(try await client.runCommand("/retry", in: chat, profile: "default") == .send("move the bakery order", notice: nil))
        #expect(try await client.runCommand("/undo", in: chat, profile: "default") == .prefill("thanks", notice: "↶ Undid 1 turn"))
    }

    /// An alias could stand for a command this app asks about first, and a skill's message
    /// is a prompt for the bot: neither is acted on.
    @Test func anAliasOrASkillIsNotFollowed() async throws {
        let (gateway, client) = try await client { id, _ in
            [id == 1 ? #"{"jsonrpc":"2.0","id":1,"result":{"type":"alias","target":"approvals off"}}"#
                     : #"{"jsonrpc":"2.0","id":\#(id),"result":{"type":"skill","name":"x","message":"scaffolding"}}"#]
        }
        defer { gateway.stop() }
        for line in ["/retry", "/plan"] {
            await #expect(throws: GatewayError.unexpectedReply(method: "slash.exec")) {
                try await client.runCommand(line, in: chat, profile: "default")
            }
        }
        #expect(gateway.params(of: "slash.exec").compactMap { $0["command"] as? String } == ["retry", "plan"])
    }

    @Test func aSideQuestionWaitsForItsOwnAnswer() async throws {
        let (gateway, client) = try await client { id, method in
            guard method == "prompt.btw" else { return [] }
            return [
                #"{"jsonrpc":"2.0","id":\#(id),"result":{"task_id":"btw-7"}}"#,
                // Another question's answer, then this one's.
                #"{"jsonrpc":"2.0","method":"event","params":{"type":"btw.complete","session_id":"live-1","payload":{"task_id":"btw-6","text":"not this"}}}"#,
                #"{"jsonrpc":"2.0","method":"event","params":{"type":"btw.complete","session_id":"live-1","payload":{"task_id":"btw-7","question":"port?","text":" Port 80. "}}}"#,
            ]
        }
        defer { gateway.stop() }
        #expect(try await client.askAside("port?", in: chat, profile: "default") == "Port 80.")
        #expect(gateway.params(of: "prompt.btw").first?["text"] as? String == "port?")
    }

    @Test func aSideQuestionThatFailedSaysWhy() async throws {
        let (gateway, client) = try await client { id, method in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"task_id":"b"}}"#,
             #"{"jsonrpc":"2.0","method":"event","params":{"type":"btw.complete","session_id":"live-1","payload":{"task_id":"b","text":"error: no model"}}}"#]
        }
        defer { gateway.stop() }
        await #expect(throws: GatewayError.rejected(code: 0, message: "no model")) {
            try await client.askAside("x", in: chat, profile: "default")
        }
    }

    /// Before 0.21.6 a stale session id turned approvals off for the whole gateway.
    @Test func onlyAHermesThatKeepsYoloToOneChatIsTrustedWithIt() {
        for good in ["0.21.6", "v0.23.4", "0.23.3+canary.20261120T064609Z", "1.0.0"] {
            #expect(GatewayClient.keepsYoloToOneChat(version: good), "\(good)")
        }
        for old in ["0.21.5", "v0.21.4+canary.20260925T065930Z", "v2026.9.21", "2026.12.1", "demo", "0.22", "", nil] as [String?] {
            #expect(!GatewayClient.keepsYoloToOneChat(version: old), "\(old ?? "nil")")
        }
    }

    @Test func approvalsAreTurnedOffAndOnByNameNeverToggled() async throws {
        let (gateway, client) = try await client { id, _ in
            [id == 1 ? #"{"jsonrpc":"2.0","id":1,"result":{"key":"yolo","value":"1","scope":"session"}}"#
                     : #"{"jsonrpc":"2.0","id":\#(id),"result":{"key":"yolo","value":"0","scope":"session"}}"#]
        }
        defer { gateway.stop() }
        #expect(try await client.setApprovalsSkipped(true, in: chat, profile: "garden"))
        #expect(try await client.setApprovalsSkipped(false, in: chat, profile: "garden") == false)
        let asked = gateway.params(of: "config.set")
        #expect(asked.map { $0["value"] as? String } == ["on", "off"])
        #expect(asked.allSatisfy { $0["key"] as? String == "yolo" && $0["session_id"] as? String == "live-1" && $0["scope"] == nil })
    }
}
