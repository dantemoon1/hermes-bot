import Foundation
import Testing
@testable import HermesKit

@Suite struct GatewayDiscoveryTests {
    private func file(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-connections-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test func remoteConnectionsWithAPlainTokenAreOfferedLastUsedFirst() throws {
        let url = try file(#"""
        {"version":3,"primary":"home","lastUsed":"work","connections":[
          {"id":"local","kind":"local","label":"This device"},
          {"id":"home","kind":"remote","label":"Home NAS","url":"http://nas.local:9119","authMode":"token","token":{"encoding":"plain","value":"t-home"}},
          {"id":"work","kind":"remote","label":"","url":"https://hermes.work.dev","authMode":"token","token":{"encoding":"plain","value":"t-work"}},
          {"id":"sealed","kind":"remote","label":"Sealed","url":"http://a.local:9119","authMode":"token","token":{"encoding":"keychain","value":"x"}},
          {"id":"login","kind":"remote","label":"Login","url":"http://b.local:9119","authMode":"session"},
          {"id":"ssh","kind":"ssh","label":"Over SSH","host":"c.local"},
          {"id":"empty","kind":"remote","label":"No token","url":"http://d.local:9119","authMode":"token","token":{"encoding":"plain","value":""}},
          {"id":"odd","kind":"remote","label":"Not an address","url":"ftp://e.local","authMode":"token","token":{"encoding":"plain","value":"t"}},
          {"id":"home","kind":"remote","label":"Twice","url":"http://f.local:9119","authMode":"token","token":{"encoding":"plain","value":"t"}}
        ]}
        """#)
        defer { try? FileManager.default.removeItem(at: url) }
        let found = HermesDesktopConnections.read(from: url)
        #expect(found.map(\.id) == ["work", "home"])
        #expect(found.map(\.label) == ["hermes.work.dev", "Home NAS"])
        #expect(found[1].address == "http://nas.local:9119")
        // Kept as this app understands an address: no query, which might hold anything.
        let odd = try file(#"{"connections":[{"id":"q","kind":"remote","label":"  Padded  ","url":"https://h.example/base/?token=secret","authMode":"token","token":{"encoding":"plain","value":" t \n"}}]}"#)
        defer { try? FileManager.default.removeItem(at: odd) }
        let kept = try #require(HermesDesktopConnections.read(from: odd).first)
        #expect(kept.address == "https://h.example/base")
        #expect(kept.label == "Padded")
        #expect(kept.token == "t")
        #expect(found[1].token == "t-home")
        // Never in anything printed.
        #expect(!"\(found[1])".contains("t-home"))
        #expect(!String(reflecting: found[1]).contains("t-home"))
    }

    @Test func aMissingOrUnreadableFileOffersNothing() throws {
        #expect(HermesDesktopConnections.read(from: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json")).isEmpty)
        for json in ["", "not json", "[]", #"{"connections":"none"}"#, #"{"connections":[42,{"kind":"remote"}]}"#] {
            let url = try file(json)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(HermesDesktopConnections.read(from: url).isEmpty)
        }
    }

    @Test func whatIsNotAnAddressOrDoesNotAnswerIsToldApart() async {
        #expect(await GatewayProbe.look(at: "   ") == .badAddress)
        #expect(await GatewayProbe.look(at: "ftp://nas.local") == .badAddress)
        // Nothing listens here.
        guard case .unreachable(let tried) = await GatewayProbe.look(at: "127.0.0.1:9", timeout: 2) else {
            Issue.record("Expected nothing to answer")
            return
        }
        #expect(tried.map(\.label) == ["127.0.0.1:9"])
    }

    @Test func aServerOutOnTheInternetIsAskedOverHttpsUnlessToldOtherwise() async {
        // What each name leads to, in place of asking the system.
        let leadsTo: @Sendable (String) async -> [String] = { host in
            switch host {
            case "box.tail1234.ts.net": ["100.101.102.103", "fd7a:115c:a1e0::1"]
            case "funnel.tail1234.ts.net": ["203.0.113.40"]
            case "both.example.com": ["192.168.1.9", "203.0.113.41"]
            case "home.example.com": ["192.168.1.9"]
            default: []
            }
        }
        func asked(_ text: String) async -> [String] {
            await GatewayProbe.candidates(for: text, addresses: leadsTo).map(\.baseURL.absoluteString)
        }
        // No scheme typed: a token is never sent in the clear to a public host by default.
        #expect(await asked("hermes.example.com") == ["https://hermes.example.com", "https://hermes.example.com:9119"])
        #expect(await asked("hermes.example.com:8443") == ["https://hermes.example.com:8443"])
        #expect(await asked("203.0.113.9") == ["https://203.0.113.9", "https://203.0.113.9:9119"])
        // Told otherwise.
        #expect(await asked("http://hermes.example.com") == ["http://hermes.example.com:9119", "http://hermes.example.com"])
        #expect(await asked("https://nas.local") == ["https://nas.local", "https://nas.local:9119"])
        // On the person's own network, or a private one, plain http and Hermes's port first.
        #expect(await asked("nas.local") == ["http://nas.local:9119", "http://nas.local"])
        #expect(await asked("nas") == ["http://nas:9119", "http://nas"])
        #expect(await asked("192.168.1.20") == ["http://192.168.1.20:9119", "http://192.168.1.20"])
        #expect(await asked("100.100.1.2:9119") == ["http://100.100.1.2:9119"])
        #expect(await asked("10.0.0.5:8080") == ["http://10.0.0.5:8080"])
        #expect(await asked("172.32.0.1").first == "https://172.32.0.1")
        #expect(await asked("100.128.0.1").first == "https://100.128.0.1")
        #expect(await asked("not an address").isEmpty)
    }

    @Test func aNameIsOnlyPrivateWhenEverythingItLeadsToIs() async {
        let leadsTo: @Sendable (String) async -> [String] = { host in
            switch host {
            case "box.tail1234.ts.net": ["100.101.102.103", "fd7a:115c:a1e0::1"]
            case "funnel.tail1234.ts.net": ["203.0.113.40"]
            case "both.example.com": ["192.168.1.9", "203.0.113.41"]
            case "home.example.com": ["192.168.1.9"]
            default: []
            }
        }
        func first(_ text: String) async -> String? {
            await GatewayProbe.candidates(for: text, addresses: leadsTo).first?.baseURL.absoluteString
        }
        // A Tailscale name is private only when it leads to a Tailscale address: the same
        // kind of name can be opened to the internet.
        #expect(await first("box.tail1234.ts.net") == "http://box.tail1234.ts.net:9119")
        #expect(await first("funnel.tail1234.ts.net") == "https://funnel.tail1234.ts.net")
        #expect(await first("home.example.com") == "http://home.example.com:9119")
        #expect(await first("both.example.com") == "https://both.example.com")
        // A name that leads nowhere is not taken for private.
        #expect(await first("gone.example.com") == "https://gone.example.com")
        // A short or local-looking name is looked up too: a network can complete it into
        // one out on the internet. Leading nowhere, it is left as local.
        let completed: @Sendable (String) async -> [String] = { ["hermes": ["203.0.113.50"], "box.lan": ["203.0.113.51"], "nas.internal": ["10.0.0.9"]][$0] ?? [] }
        func scheme(_ text: String) async -> String? { await GatewayProbe.candidates(for: text, addresses: completed).first?.baseURL.scheme }
        #expect(await scheme("hermes") == "https")
        #expect(await scheme("box.lan") == "https")
        #expect(await scheme("nas.internal") == "http")
        #expect(await scheme("offline.local") == "http")
        #expect(await scheme("localhost") == "http")
    }

    @Test func onlyAnAddressInItsPlainestFormCountsAsPrivate() async {
        for address in ["10.0.0.5", "127.0.0.1", "192.168.1.20", "172.16.0.1", "172.31.255.255", "169.254.1.1", "100.64.0.1", "100.127.255.255", "::1", "fe80::1", "fd7a:115c:a1e0::1", "[fd00::2]"] {
            #expect(GatewayProbe.isPrivate(address: address), "\(address)")
        }
        // Forms another parser might read as a different, public address, and public ones.
        for address in ["010.0.0.5", "10.0.0.05", "0x0a.0.0.5", "10.5", "167772165", "10.0.0.256", "192.168.1", "172.32.0.1", "100.128.0.1", "8.8.8.8", "2001:db8::1", "fe80::1%en0", "fc::1", "fd0:1::1", "fe8::1", ""] {
            #expect(!GatewayProbe.isPrivate(address: address), "\(address)")
        }
        // Typed without a scheme, the odd forms are asked over https and never resolved as names.
        let never: @Sendable (String) async -> [String] = { _ in ["10.0.0.5"] }
        #expect(await GatewayProbe.candidates(for: "010.0.0.5", addresses: never).first?.baseURL.scheme == "https")
        for odd in ["167772165", "0x01010101", "0x0a.0.0.5", "0x0a000005", "012.0.0.5", "10.0.0.5."] {
            #expect(await GatewayProbe.candidates(for: odd, addresses: never).first?.baseURL.scheme == "https", "\(odd)")
        }
    }

    @Test func anAddressAlreadyKnownIsAskedExactlyAndNowhereElse() async {
        // Nothing listens here; with a typed address the usual port would be tried as well.
        let endpoint = GatewayEndpoint("http://127.0.0.1:9")!
        guard case .unreachable(let tried) = await GatewayProbe.look(atExactly: endpoint, timeout: 2) else {
            Issue.record("Expected nothing to answer")
            return
        }
        #expect(tried == [endpoint])
        // With no port written, a typed address has Hermes's usual port tried as well. An
        // exact one never does, whatever is or is not listening.
        let portless = GatewayEndpoint("http://127.0.0.1")!
        switch await GatewayProbe.look(atExactly: portless, timeout: 2) {
        case .unreachable(let tried): #expect(tried == [portless])
        case .notHermes(let endpoint, let tried):
            #expect(endpoint == portless)
            #expect(tried == [portless])
        case .found(let found): #expect(found.endpoint == portless)
        case .badAddress: Issue.record("A good address was refused")
        }
    }

    @Test func anAnswerOfGoToHttpsIsOnlyTakenFromTheSameServer() {
        func secured(_ asked: String, _ location: String) -> String? {
            GatewayProbe.secured(GatewayEndpoint(asked)!, sentTo: location)?.baseURL.absoluteString
        }
        #expect(secured("http://nas.local", "https://nas.local/api/status") == "https://nas.local")
        // The port and the path it is served under, exactly as given; the host's case aside.
        #expect(secured("http://NAS.local:9119", "HTTPS://nas.local:8443/hermes/api/status") == "https://NAS.local:8443/hermes")
        #expect(secured("http://nas.local", "https://nas.local/a%2Fb/api/status?x=1") == "https://nas.local/a%2Fb")
        #expect(secured("http://[fd00::1]:9119", "https://[fd00::1]/api/status") == "https://[fd00::1]")
        // Another server, another page, no encryption, or a name and password slipped in.
        #expect(secured("http://nas.local", "https://other.example.com/api/status") == nil)
        #expect(secured("http://nas.local", "https://nas.local/login") == nil)
        #expect(secured("http://nas.local", "http://nas.local:8080/api/status") == nil)
        #expect(secured("http://nas.local", "https://someone:secret@nas.local/api/status") == nil)
        #expect(secured("http://nas.local", "/api/status") == nil)
        #expect(secured("https://nas.local", "https://nas.local/api/status") == nil)
    }

    @Test func aTokenGoesOverPlainHttpOnlyWhileTheAddressIsPrivate() async {
        let home: @Sendable (String) async -> [String] = { _ in ["192.168.1.9"] }
        let away: @Sendable (String) async -> [String] = { _ in ["203.0.113.60"] }
        let nowhere: @Sendable (String) async -> [String] = { _ in [] }
        func may(_ address: String, chosen: Bool = false, _ leads: @escaping @Sendable (String) async -> [String]) async -> Bool {
            await GatewayProbe.mayCarryToken(to: GatewayEndpoint(address)!, plainHTTPChosen: chosen, addresses: leads)
        }
        // The same saved address, at home and then on another network.
        #expect(await may("http://home.example.com:9119", home))
        #expect(await !may("http://home.example.com:9119", away))
        #expect(await !may("http://nas:9119", away))
        #expect(await !may("http://home.example.com:9119", nowhere))
        #expect(await may("http://nas.local:9119", nowhere))
        // Encrypted, in numbers, this Mac itself, or chosen by the person: as it stands.
        #expect(await may("https://home.example.com", away))
        #expect(await may("http://100.100.1.2:9119", away))
        #expect(await may("http://localhost:9119", away))
        // A public address in numbers, or one written oddly, only when http was chosen.
        #expect(await !may("http://203.0.113.9:9119", home))
        #expect(await !may("http://010.0.0.5:9119", home))
        #expect(await may("http://203.0.113.9:9119", chosen: true, home))
        #expect(await may("http://[fd00::2]:9119", away))
        #expect(await may("http://home.example.com:9119", chosen: true, away))
    }

    @Test func aSavedServerWithNoSchemeWrittenIsNotOffered() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("connections-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json = """
        {"connections": [
          {"id": "a", "kind": "remote", "label": "Bare", "url": "hermes.example.com", "authMode": "token", "token": {"encoding": "plain", "value": "made-up"}},
          {"id": "b", "kind": "remote", "label": "Plain", "url": "http://nas.local:9119", "authMode": "token", "token": {"encoding": "plain", "value": "made-up"}}
        ]}
        """
        try Data(json.utf8).write(to: file)
        #expect(HermesDesktopConnections.read(from: file).map(\.id) == ["b"])
    }
}
