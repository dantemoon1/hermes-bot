import Foundation
import Testing
@testable import HermesKit

@Test func endpointAcceptsWhatPeopleType() {
    #expect(GatewayEndpoint("100.64.0.1:9119")?.baseURL.absoluteString == "http://100.64.0.1:9119")
    #expect(GatewayEndpoint(" https://hermes.example.com/ ")?.baseURL.absoluteString == "https://hermes.example.com")
    #expect(GatewayEndpoint("") == nil)
    #expect(GatewayEndpoint("ftp://example.com") == nil)
    #expect(GatewayEndpoint("mailto:a@b.com") == nil)
    #expect(GatewayEndpoint("http://user:pass@nas:9119") == nil)
    #expect(GatewayEndpoint("nas:9119?next=https://example.com")?.baseURL.absoluteString == "http://nas:9119")
}

@Test func socketURLKeepsPathPrefixAndEscapesToken() {
    let plain = GatewayEndpoint("http://nas:9119")!.webSocketURL(token: "a+b/c d")
    #expect(plain.absoluteString == "ws://nas:9119/api/ws?token=a%2Bb/c%20d")
    let secure = GatewayEndpoint("https://example.com/hermes/")!.webSocketURL(token: "t")
    #expect(secure.absoluteString == "wss://example.com/hermes/api/ws?token=t")
}

@Test func pastedBrowserAddressLosesItsQueryAndFragment() {
    let endpoint = GatewayEndpoint("HTTP://host:9119/hermes/?view=bots#/chat")!
    #expect(endpoint.baseURL.absoluteString == "http://host:9119/hermes")
    #expect(endpoint.webSocketURL(token: "t").absoluteString == "ws://host:9119/hermes/api/ws?token=t")
}

@Test func botDecodesFromProfilesList() throws {
    let json = """
    [{"name": "default", "path": "/opt/data", "is_default": true, "model": "some-model", "provider": "p",
      "description": "", "display_name": "", "skill_count": 3, "last_session": null,
      "canonical_session": {"id": "s1", "title": "Bot Chat", "preview": "Hello there",
                            "last_active": 1795466252.72, "message_count": 398},
      "ui_meta_revisions": {"hermes-bots": 4},
      "ui_meta": {"hermes-bots": {"title": "Maia", "shape": "circle"}}, "has_avatar": false},
     {"name": "health", "is_default": false, "description": "Fitness"}]
    """
    let bots = try JSONDecoder().decode([Bot].self, from: Data(json.utf8))
    #expect(bots[0].title == "Maia")
    #expect(bots[0].chat?.preview == "Hello there")
    #expect(bots[0].chat?.lastActive == Date(timeIntervalSince1970: 1795466252.72))
    #expect(bots[1].title == "health")
    #expect(bots[1].chat == nil)
    #expect(bots[1].model == nil)
}

@Test func unnamedMainBotIsCalledHermes() throws {
    let bot = try JSONDecoder().decode(Bot.self, from: Data(#"{"name": "default", "is_default": true}"#.utf8))
    #expect(bot.title == "Hermes")
}

@Test func requestBeforeConnectFails() async {
    let client = GatewayClient(endpoint: GatewayEndpoint("localhost:1")!, token: "t")
    await #expect(throws: GatewayError.notConnected) { try await client.request("profiles.list") }
}
