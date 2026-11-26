import Foundation
import Testing
@testable import HermesKit

@Suite(.timeLimit(.minutes(1)))
struct GatewayClientTests {
    @Test func concurrentRequestsGetTheirOwnReplies() async throws {
        let (gateway, endpoint) = try await FakeGateway.start()
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        async let first = client.request("one")
        async let second = client.request("two")
        #expect(try await first["method"]?.stringValue == "one")
        #expect(try await second["method"]?.stringValue == "two")
    }

    @Test func gatewayErrorIsThrown() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"Not allowed"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.rejected(code: -32000, message: "Not allowed")) {
            try await client.request("nope")
        }
    }

    /// Frames a broken or hostile gateway could send must neither crash the app nor answer
    /// the wrong request.
    @Test func oddFramesAreIgnoredAndNullErrorIsSuccess() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [
                #"{"jsonrpc":"2.0","id":1e300,"result":{"wrong":true}}"#,
                #"{"jsonrpc":"2.0","id":\#(id).5,"result":{"wrong":true}}"#,
                #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":1e300,"message":"m"},"result":null}"#,
            ]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.rejected(code: 0, message: "m")) { try await client.request("x") }

        let (second, secondEndpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"ok":true},"error":null}"#]
        }
        defer { second.stop() }
        let other = GatewayClient(endpoint: secondEndpoint, token: "t")
        await other.connect()
        #expect(try await other.request("x")["ok"] == .bool(true))
    }

    @Test func cancellingTheCallerAbandonsTheRequestAtOnce() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { _, _ in [] }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        let call = Task { try await client.request("never-answered", timeout: .seconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func unansweredRequestTimesOut() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { _, _ in [] }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.timedOut(method: "slow")) {
            try await client.request("slow", timeout: .milliseconds(200))
        }
    }

    @Test func subscriberBeforeConnectSeesTheGreeting() async throws {
        let (gateway, endpoint) = try await FakeGateway.start(
            greeting: #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"v":1}}}"#
        )
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        let events = await client.events()
        await client.connect()
        let first = await events.first { _ in true }
        #expect(first == GatewayEvent(type: "gateway.ready", payload: .object(["v": .number(1)])))
    }

    @Test func lostConnectionFailsRequestsAndFinishesEvents() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { _, _ in [] }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        let events = await client.events()
        await client.connect()
        let waiting = Task { try await client.request("waiting") }
        try await Task.sleep(for: .milliseconds(200))
        gateway.dropClients()

        let failure = await #expect(throws: GatewayError.self) { try await waiting.value }
        guard let failure, case .connectionLost = failure else {
            Issue.record("Expected connectionLost, got \(String(describing: failure))")
            return
        }
        for await _ in events {}
        #expect(await client.isConnected == false)
        // The reason outlives the socket, so a later request still says what happened.
        await #expect(throws: failure) { try await client.request("later") }
    }

    @Test func failedConnectIsReportedEvenAfterTheFact() async throws {
        let (gateway, endpoint) = try await FakeGateway.start()
        gateway.stop()
        let client = GatewayClient(endpoint: endpoint, token: "secret-token")
        let events = await client.events()
        await client.connect()
        for await _ in events {}
        let failure = await #expect(throws: GatewayError.self) { try await client.request("x") }
        guard case .connectionLost(let text) = failure else {
            Issue.record("Expected connectionLost, got \(String(describing: failure))")
            return
        }
        #expect(!text.contains("secret-token"))
    }

    @Test func releasingTheClientClosesItsSocket() async throws {
        let (gateway, endpoint) = try await FakeGateway.start()
        defer { gateway.stop() }
        do {
            let client = GatewayClient(endpoint: endpoint, token: "t")
            await client.connect()
            _ = try await client.request("hello")
            #expect(gateway.openConnections == 1)
        }
        for _ in 0..<50 where gateway.openConnections > 0 {
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(gateway.openConnections == 0)
    }

    @Test func rosterSkipsABotItCannotReadAndRejectsAnUnknownShape() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"profiles":[{"name":"side"},{"is_default":1},{"name":"default","is_default":true,"canonical_session":{"id":"s","last_active":"2026-11-23"},"ui_meta":[]}]}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        let bots = try await client.listBots()
        #expect(bots.map(\.name) == ["default", "side"])
        #expect(bots[0].chat?.id == "s")
        #expect(bots[0].chat?.lastActive == nil)

        let (second, secondEndpoint) = try await FakeGateway.start { id, _ in [#"{"jsonrpc":"2.0","id":\#(id),"result":[]}"#] }
        defer { second.stop() }
        let other = GatewayClient(endpoint: secondEndpoint, token: "t")
        await other.connect()
        await #expect(throws: GatewayError.unexpectedReply(method: "profiles.list")) { try await other.listBots() }
    }

    @Test(arguments: [401, 403]) func refusedTokenIsUnauthorized(status: Int) async throws {
        let (endpoint, stop) = try await FakeGateway.refusing(status: status, usesSignIn: false)
        defer { stop() }
        let client = GatewayClient(endpoint: endpoint, token: "wrong")
        await client.connect()
        await #expect(throws: GatewayError.unauthorized(gatewayUsesSignIn: false)) {
            try await client.request("profiles.list")
        }
    }

    /// A refusal from a gateway with sign-in turned on says so, so the app can explain it.
    @Test func refusalFromASignInGatewaySaysSo() async throws {
        let (endpoint, stop) = try await FakeGateway.refusing(status: 401, usesSignIn: true)
        defer { stop() }
        let client = GatewayClient(endpoint: endpoint, token: "wrong")
        await client.connect()
        await #expect(throws: GatewayError.unauthorized(gatewayUsesSignIn: true)) {
            try await client.request("profiles.list")
        }

        // When the gateway won't say, the refusal is still reported, as a plain one.
        let (silent, stopSilent) = try await FakeGateway.refusing(status: 401)
        defer { stopSilent() }
        let other = GatewayClient(endpoint: silent, token: "wrong")
        await other.connect()
        await #expect(throws: GatewayError.unauthorized(gatewayUsesSignIn: false)) {
            try await other.request("profiles.list")
        }
    }

    @Test func missingMethodIsUnsupportedNotAFailure() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown method"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.unsupported(method: "runtime.describe")) {
            try await client.request("runtime.describe")
        }
    }

    /// A frame that only looks like a reply must not use up the request it names.
    @Test func incompleteFrameDoesNotConsumeTheRequest() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [
                #"{"jsonrpc":"2.0","id":\#(id)}"#,
                #"{"jsonrpc":"2.0","id":\#(id),"error":null}"#,
                #"{"jsonrpc":"2.0","id":\#(id),"method":"server.asks","params":{}}"#,
                #"{"jsonrpc":"2.0","id":\#(id),"result":{"ok":true}}"#,
            ]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        #expect(try await client.request("x")["ok"] == .bool(true))
    }

    @Test func disconnectForgetsAFailureAndLateSubscribersAreNotStranded() async throws {
        let (gateway, endpoint) = try await FakeGateway.start()
        gateway.stop()
        let client = GatewayClient(endpoint: endpoint, token: "t")
        let events = await client.events()
        await client.connect()
        for await _ in events {}

        // After a failure, a new subscriber is told at once that nothing is coming.
        for await _ in await client.events() {}

        await client.disconnect()
        await #expect(throws: GatewayError.notConnected) { try await client.request("x") }
        // And a subscriber waiting for a connection is released by an explicit disconnect.
        let waiting = await client.events()
        await client.disconnect()
        for await _ in waiting {}
    }

    @Test func rosterWithNoReadableBotIsAnError() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"profiles":[{}]}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.unexpectedReply(method: "profiles.list")) { try await client.listBots() }

        let (empty, emptyEndpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"profiles":[]}}"#]
        }
        defer { empty.stop() }
        let other = GatewayClient(endpoint: emptyEndpoint, token: "t")
        await other.connect()
        #expect(try await other.listBots().isEmpty)
    }

    // MARK: Passes in place of a token

    /// Hands out a pass after a wait, or fails, and counts how often it was asked.
    private actor Passes: TicketSource {
        let wait: Duration
        let fails: Bool
        private(set) var asked = 0
        init(wait: Duration = .zero, fails: Bool = false) {
            self.wait = wait
            self.fails = fails
        }
        func ticket(_ purpose: TicketPurpose, profile: String?) async throws -> String {
            asked += 1
            try await Task.sleep(for: wait)
            if fails { throw LocalHermes.Failure.notRunning }
            return "made-up-pass"
        }
    }

    @Test func withNoPassToBeHadNobodyIsLeftWaiting() async throws {
        let client = GatewayClient(endpoint: GatewayEndpoint("127.0.0.1:9")!, credential: .tickets(Passes(fails: true)))
        let events = await client.events()
        await client.connect()
        // The stream ends, as it does when a socket ends.
        for await _ in events {}
        await #expect(throws: GatewayError.connectionLost("No pass")) { try await client.request("profiles.list") }
        #expect(await !client.isConnected)
    }

    @Test func aSecondConnectJoinsTheFirstAndADisconnectCallsItOff() async throws {
        let passes = Passes(wait: .milliseconds(300))
        let client = GatewayClient(endpoint: GatewayEndpoint("127.0.0.1:9")!, credential: .tickets(passes))
        async let first: Void = client.connect()
        async let second: Void = client.connect()
        _ = await (first, second)
        #expect(await passes.asked == 1)
        await client.disconnect()

        // Disconnected while the pass is being fetched: no socket is opened when it comes.
        let slow = Passes(wait: .milliseconds(300))
        let other = GatewayClient(endpoint: GatewayEndpoint("127.0.0.1:9")!, credential: .tickets(slow))
        let connecting = Task { await other.connect() }
        try await Task.sleep(for: .milliseconds(100))
        await other.disconnect()
        await connecting.value
        #expect(await !other.isConnected)
        await #expect(throws: GatewayError.notConnected) { try await other.request("profiles.list") }
    }

    @Test func theSignInCookieIsKnownByEveryNameHermesGivesIt() {
        for name in ["hermes_session_pkce", "__Host-hermes_session_pkce", "__Secure-hermes_session_pkce",
                     "hermes_session_pkce_0123456789abcdef", "__Host-hermes_session_pkce_0123456789abcdef"] {
            #expect(GatewaySignIn.isSignInCookie(name), "\(name)")
        }
        // And nothing else that a server might set is sent back with the password.
        for name in ["hermes_session", "hermes_session_at", "tracking_hermes_session_pkce", "hermes_session_pkce_", "hermes_session_pkce_a b", "__Other-hermes_session_pkce", ""] {
            #expect(!GatewaySignIn.isSignInCookie(name), "\(name)")
        }
    }

    @Test func aCredentialNeverPrintsItsToken() {
        #expect(!"\(GatewayCredential.token("s3cret-token"))".contains("s3cret"))
        #expect(!String(reflecting: GatewayCredential.token("s3cret-token")).contains("s3cret"))
    }
}
