import Foundation
import Testing
@testable import HermesKit

private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Test func transcriptShowsWhatWasSaidAndFoldsToolWorkIntoOneLine() {
    let items = Transcript.items(from: [
        ChatMessage(id: 1, role: "user", text: "check the disks", date: at(0)),
        ChatMessage(id: 2, role: "assistant", text: "", date: at(5), toolCalls: ["terminal"]),
        ChatMessage(id: 3, role: "tool", text: "lots of output", date: at(6)),
        ChatMessage(id: 4, role: "assistant", text: "  ", date: at(7), toolCalls: ["web_search", "terminal"]),
        ChatMessage(id: 5, role: "tool", text: "more output", date: at(8)),
        ChatMessage(id: 6, role: "assistant", text: "All healthy.", date: at(9)),
    ])
    #expect(items == [
        .date(at(0)),
        .user(id: 1, text: "check the disks"),
        .activity(id: 2, tools: ["terminal", "web_search", "terminal"]),
        .bot(id: 6, text: "All healthy."),
    ])
}

@Test func transcriptStampsTheTimeOnlyAfterAnHourOfQuiet() {
    let items = Transcript.items(from: [
        ChatMessage(id: 1, role: "user", text: "a", date: at(0)),
        ChatMessage(id: 2, role: "assistant", text: "b", date: at(3599)),
        ChatMessage(id: 3, role: "user", text: "c", date: at(3599 + 3600)),
        ChatMessage(id: 4, role: "assistant", text: "d"),
    ])
    #expect(items == [
        .date(at(0)), .user(id: 1, text: "a"), .bot(id: 2, text: "b"),
        .date(at(7199)), .user(id: 3, text: "c"), .bot(id: 4, text: "d"),
    ])
}

@Test func transcriptHidesASilentTurnAndItsWorkAndKeepsTrailingWork() {
    let items = Transcript.items(from: [
        ChatMessage(id: 1, role: "assistant", text: "", toolCalls: ["memory"]),
        ChatMessage(id: 2, role: "assistant", text: "[SILENT]"),
        ChatMessage(id: 3, role: "system", text: "internal"),
        ChatMessage(id: 4, role: "assistant", text: "On it.", toolCalls: ["terminal", " "]),
    ])
    #expect(items == [.bot(id: 4, text: "On it."), .activity(id: 4, tools: ["terminal"])])
}

/// Work that starts after a quiet hour goes under the new time stamp, not the old one.
@Test func toolWorkIsStampedWithTheTimeItStarted() {
    let items = Transcript.items(from: [
        ChatMessage(id: 1, role: "user", text: "a", date: at(0)),
        ChatMessage(id: 2, role: "assistant", text: "", date: at(5000), toolCalls: ["calendar"]),
        ChatMessage(id: 3, role: "assistant", text: "b", date: at(5020)),
    ])
    #expect(items == [
        .date(at(0)), .user(id: 1, text: "a"),
        .date(at(5000)), .activity(id: 2, tools: ["calendar"]), .bot(id: 3, text: "b"),
    ])
}

@Test func aRowStoredOutOfOrderDoesNotEarnASecondStamp() {
    let items = Transcript.items(from: [
        ChatMessage(id: 1, role: "user", text: "a", date: at(10000)),
        ChatMessage(id: 2, role: "assistant", text: "b", date: at(0)),
        ChatMessage(id: 3, role: "user", text: "c", date: at(10000)),
    ])
    #expect(items == [.date(at(10000)), .user(id: 1, text: "a"), .bot(id: 2, text: "b"), .user(id: 3, text: "c")])
}

@Test func chatMessageDecodesTheShapesTheGatewaySends() throws {
    let json = """
    [{"id": 7, "role": "user", "content": "the full prompt", "display_content": "what I typed", "timestamp": 12.5},
     {"id": 8, "role": "assistant", "content": [{"type": "text", "text": "one"}, {"type": "image"}, {"type": "text", "text": "two"}],
      "tool_calls": [{"id": "c1", "function": {"name": "terminal", "arguments": "{}"}}, {"oops": true}]},
     {"id": 9, "role": "tool", "content": "raw", "display_content": "  ", "tool_name": "terminal", "timestamp": "soon"}]
    """
    let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(json.utf8))
    #expect(messages[0] == ChatMessage(id: 7, role: "user", text: "what I typed", date: at(12.5)))
    #expect(messages[1] == ChatMessage(id: 8, role: "assistant", text: "one\ntwo", toolCalls: ["terminal"]))
    #expect(messages[2] == ChatMessage(id: 9, role: "tool", text: "raw"))
}

@Suite(.timeLimit(.minutes(1)))
struct ChatMessagesTests {
    @Test func chatMessagesAsksForTheLatestPageWithTheToken() async throws {
        let (endpoint, lastRequest, stop) = try await FakeGateway.serving(
            body: #"{"session_id":"s 1","messages":[{"id":1,"role":"user","content":"hi"},{"nonsense":true}]}"#
        )
        defer { stop() }
        let client = GatewayClient(endpoint: endpoint, token: "secret")
        let messages = try await client.chatMessages(sessionID: "s 1/x", profile: "a+b", limit: 60)
        #expect(messages == [ChatMessage(id: 1, role: "user", text: "hi")])
        let request = lastRequest()
        #expect(request.hasPrefix("GET /api/sessions/s%201%2Fx/messages?inline_images=false&limit=60&order=latest&profile=a%2Bb HTTP/1.1"))
        #expect(request.localizedCaseInsensitiveContains("X-Hermes-Session-Token: secret"))
    }

    @Test func aGatewayWithoutChatHistorySaysUnsupported() async throws {
        let (endpoint, lastRequest, stop) = try await FakeGateway.serving(status: 404, body: #"{"detail":"not found"}"#)
        defer { stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await #expect(throws: GatewayError.unsupported(method: "sessions.messages")) {
            try await client.chatMessages(sessionID: "..", profile: "p")
        }
        #expect(lastRequest().hasPrefix("GET /api/sessions/%2E%2E/messages?"))
    }

    /// A redirect must not carry the token to wherever it points.
    @Test func aRedirectIsNotFollowed() async throws {
        let (elsewhere, elsewhereSaw, stopElsewhere) = try await FakeGateway.serving(body: #"{"messages":[]}"#)
        defer { stopElsewhere() }
        let (moved, _, stopMoved) = try await FakeGateway.serving(
            status: 302, body: "{}", location: elsewhere.baseURL.absoluteString + "/api/sessions/s/messages"
        )
        defer { stopMoved() }
        await #expect(throws: GatewayError.connectionLost("HTTP 302")) {
            try await GatewayClient(endpoint: moved, token: "t").chatMessages(sessionID: "s", profile: "p")
        }
        #expect(elsewhereSaw().isEmpty)
    }

    @Test func aChatReplyIsNotLeftInTheSharedCache() async throws {
        let (endpoint, _, stop) = try await FakeGateway.serving(body: #"{"messages":[{"id":1,"role":"user","content":"private"}]}"#)
        defer { stop() }
        _ = try await GatewayClient(endpoint: endpoint, token: "t").chatMessages(sessionID: "s", profile: "p", limit: 7)
        let url = URL(string: endpoint.baseURL.absoluteString + "/api/sessions/s/messages?inline_images=false&limit=7&order=latest&profile=p")!
        #expect(URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil)
    }

    @Test func anUnreadableChatIsAnErrorAndAnEmptyOneIsEmpty() async throws {
        let (odd, _, stopOdd) = try await FakeGateway.serving(body: #"{"messages":[{"id":"7","role":"user"}]}"#)
        defer { stopOdd() }
        await #expect(throws: GatewayError.unexpectedReply(method: "sessions.messages")) {
            try await GatewayClient(endpoint: odd, token: "t").chatMessages(sessionID: "s", profile: "p")
        }
        let (empty, _, stopEmpty) = try await FakeGateway.serving(body: #"{"messages":[]}"#)
        defer { stopEmpty() }
        #expect(try await GatewayClient(endpoint: empty, token: "t").chatMessages(sessionID: "s", profile: "p").isEmpty)
    }

    @Test func refusedAndMalformedHistoryAreErrors() async throws {
        let (refused, _, stopRefused) = try await FakeGateway.serving(status: 401, body: "{}")
        defer { stopRefused() }
        await #expect(throws: GatewayError.unauthorized(gatewayUsesSignIn: false)) {
            try await GatewayClient(endpoint: refused, token: "t").chatMessages(sessionID: "s", profile: "p")
        }
        let (odd, _, stopOdd) = try await FakeGateway.serving(body: #"{"messages":"none"}"#)
        defer { stopOdd() }
        await #expect(throws: GatewayError.unexpectedReply(method: "sessions.messages")) {
            try await GatewayClient(endpoint: odd, token: "t").chatMessages(sessionID: "s", profile: "p")
        }
    }
}

/// A row sent where no one sees it (by a page in the chat) is not the person's bubble; a
/// steered message, which the gateway types too, still is.
@Test func transcriptLeavesOutWhatWasSentHidden() throws {
    let rows = """
    [{"id": 1, "role": "user", "content": "show the chart", "timestamp": 0},
     {"id": 2, "role": "assistant", "content": "Here.", "timestamp": 1},
     {"id": 3, "role": "user", "content": "Show last 12 weeks", "display_kind": "hidden", "timestamp": 2},
     {"id": 4, "role": "assistant", "content": "Done.", "timestamp": 3},
     {"id": 5, "role": "user", "content": "[marker]", "display_content": "and make it blue", "display_kind": "steer", "timestamp": 4}]
    """
    let messages = try JSONDecoder().decode([ChatMessage].self, from: Data(rows.utf8))
    #expect(messages.map(\.isHidden) == [false, false, true, false, false])
    #expect(Transcript.items(from: messages) == [
        .date(at(0)), .user(id: 1, text: "show the chart"), .bot(id: 2, text: "Here."),
        .bot(id: 4, text: "Done."), .user(id: 5, text: "and make it blue"),
    ])
}
