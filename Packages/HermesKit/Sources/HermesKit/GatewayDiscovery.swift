import Foundation

/// A gateway that Hermes's own desktop app on this Mac already connects to, found in the
/// file where that app keeps its connections. Offered at setup so there is nothing to type.
public struct SavedHermesConnection: Sendable, Equatable, Identifiable {
    public let id: String
    /// The name the person gave it in Hermes's app.
    public let label: String
    public let address: String
    /// Kept out of anything printed.
    public let token: String

    public var endpoint: GatewayEndpoint? { GatewayEndpoint(address) }
}

extension SavedHermesConnection: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "SavedHermesConnection(\(label), \(address), token: <redacted>)" }
    public var debugDescription: String { description }
}

public enum HermesDesktopConnections {
    #if os(macOS)
    /// Where Hermes's desktop app keeps its connections. Only a Mac has that app.
    public static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/gateway-connections.json")
    }
    #endif

    /// The remote gateways in that file that are reached with a token this app can read,
    /// the one last used first. Empty when there is no such file, or none of that kind:
    /// this is an offer of convenience, never a failure.
    public static func read(from file: URL) -> [SavedHermesConnection] {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let connections)? = root["connections"]
        else { return [] }
        var found: [SavedHermesConnection] = []
        for connection in connections {
            // Only what is known how to use: a remote gateway, by a token written plainly.
            guard connection["kind"]?.stringValue == "remote",
                  connection["authMode"]?.stringValue == "token",
                  connection["token"]?["encoding"]?.stringValue == "plain",
                  let token = connection["token"]?["value"]?.stringValue.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }), !token.isEmpty,
                  // Only an address that says how it is reached: one without would be taken
                  // for plain http, and the token sent that way without anyone having chosen it.
                  let endpoint = connection["url"]?.stringValue.flatMap({ GatewayProbe.namesScheme($0) ? GatewayEndpoint($0) : nil }),
                  let id = connection["id"]?.stringValue, !found.contains(where: { $0.id == id })
            else { continue }
            let label = connection["label"]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            // The address as this app understands it: scheme, host, port and path, and no
            // query that might hold something not meant to be shown.
            found.append(SavedHermesConnection(id: id, label: label ?? endpoint.label, address: endpoint.baseURL.absoluteString, token: token))
        }
        // The one Hermes's app used last is the likeliest to be wanted.
        let first = [root["lastUsed"]?.stringValue, root["primary"]?.stringValue].compactMap { $0 }
        return found.sorted { a, b in
            (first.firstIndex(of: a.id) ?? .max, found.firstIndex(of: a)!) < (first.firstIndex(of: b.id) ?? .max, found.firstIndex(of: b)!)
        }
    }
}

/// What was found at an address before anything is signed in to: asked of the gateway
/// itself, so the person is asked only for what that gateway takes. Nothing secret is ever
/// sent in the asking.
public enum GatewayProbe: Sendable, Equatable {
    /// A Hermes gateway answered.
    case found(Found)
    /// Something answered at the first address named, and it is not Hermes: most often
    /// another service on the same machine. `tried` is every address that was asked.
    case notHermes(GatewayEndpoint, tried: [GatewayEndpoint])
    /// Nothing answered at any of the addresses tried.
    case unreachable(tried: [GatewayEndpoint])
    /// The text is not an address.
    case badAddress

    public struct Found: Sendable, Equatable {
        /// The address that answered as Hermes, and the only one a token may be sent to.
        public let endpoint: GatewayEndpoint
        public let version: String?
        /// The ways of signing in it says it takes, by its own names for them, such as
        /// "Username & Password". A gateway that takes only a token lists none.
        public let signInWays: [String]
        public let takesPassword: Bool
        /// The gateway's name for the way in that takes a username and password, to sign
        /// in with. Nil when there is none.
        public var passwordProvider: String?
        /// Whether a token is one of the ways in. Nil on a gateway too old to say.
        public let takesToken: Bool?
        /// The person asked for plain http themselves, by typing it or by having saved it.
        public var plainHTTPChosen = false
    }

    /// Hermes's usual port, tried when the person typed none.
    public static let usualPort = 9119

    /// Whether an address written out in numbers is on the person's own network or a
    /// private one, where plain http is the norm. Only an address in its plainest form
    /// counts: anything a parser might read another way is not taken for private.
    static func isPrivate(address: String) -> Bool {
        let address = address.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ $0.wholeMatch(of: /0|[1-9][0-9]{0,2}/) != nil }) {
            let numbers = parts.compactMap { Int($0) }
            guard numbers.allSatisfy({ (0...255).contains($0) }) else { return false }
            switch (numbers[0], numbers[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            // Carrier-grade NAT space, which is what Tailscale hands out.
            case (100, 64...127): return true
            default: return false
            }
        }
        // IPv6: loopback, link-local and unique-local.
        guard address.contains(":"), address.allSatisfy({ $0.isHexDigit || $0 == ":" }) else { return false }
        // The first group written out in full, so "fc::1" (which is 00fc::1) does not pass.
        let first = address.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return address == "::1" || first == "fe80" || (first.count == 4 && (first.hasPrefix("fc") || first.hasPrefix("fd")))
    }

    /// Whether what was typed as a host is an address in numbers at all.
    static func isAddress(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") { return true }
        // Every form a parser might read as numbers: decimal, octal and hexadecimal, in
        // one part or several.
        var parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        return !parts.isEmpty && parts.allSatisfy { $0.wholeMatch(of: /0[xX][0-9A-Fa-f]*|[0-9]+/) != nil }
    }

    /// Names that are meant for a machine nearby. Where they lead is still looked up: a
    /// short name can be completed by the network into one out on the internet.
    static func isLocalName(_ host: String) -> Bool {
        let host = host.lowercased()
        if !host.contains(".") { return true }
        return [".local", ".lan", ".home.arpa", ".internal", ".localdomain"].contains { host.hasSuffix($0) }
    }

    /// The addresses a name leads to, as the system finds them. Empty when it finds none.
    public static func addresses(of host: String) async -> [String] {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
            defer { freeaddrinfo(first) }
            var found: [String] = []
            var next: UnsafeMutablePointer<addrinfo>? = first
            while let entry = next {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                    // Without any "%en0" a link-local address carries.
                    found.append(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "%").first.map(String.init) ?? "")
                }
                next = entry.pointee.ai_next
            }
            return found
        }.value
    }

    /// Whether what was typed says how to reach the server, as in "http://".
    public static func namesScheme(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\/\/.*/) != nil
    }

    /// Whether a name leads, or may lead, to a server out on the internet. This Mac's own
    /// name for itself never does. A local name that leads nowhere just now is not held
    /// to be public (nothing can be sent to it); any other name that leads nowhere is.
    static func leadsSomewherePublic(_ host: String, addresses: @Sendable (String) async -> [String] = GatewayProbe.addresses(of:)) async -> Bool {
        if host.lowercased() == "localhost" { return false }
        let found = await addresses(host)
        if found.isEmpty { return !isLocalName(host) }
        return !found.allSatisfy { isPrivate(address: $0) }
    }

    /// Whether a token may be sent to an address as things stand right now. Always over
    /// https. Over plain http only to a private address, to a name that at this moment
    /// leads only to private addresses, or when the person chose http themselves. Asked
    /// again before every connection, since where a name leads changes with the network
    /// the Mac is on.
    public static func mayCarryToken(
        to endpoint: GatewayEndpoint, plainHTTPChosen: Bool,
        addresses: @Sendable (String) async -> [String] = GatewayProbe.addresses(of:)
    ) async -> Bool {
        guard endpoint.baseURL.scheme == "http", !plainHTTPChosen, let host = endpoint.baseURL.host() else { return true }
        // An address in numbers leads where it says, whatever network this is: only a
        // private one will do.
        if isAddress(host) { return isPrivate(address: host) }
        return await !leadsSomewherePublic(host, addresses: addresses)
    }

    /// Where an answer of "go to https" leads, when it is the same server's own: the same
    /// host, with the port and the path it is served under exactly as the answer gave them.
    static func secured(_ asked: GatewayEndpoint, sentTo location: String) -> GatewayEndpoint? {
        guard asked.baseURL.scheme == "http",
              let onward = URLComponents(string: location), onward.scheme?.lowercased() == "https",
              var components = URLComponents(url: asked.baseURL, resolvingAgainstBaseURL: false),
              let host = components.host, onward.host?.lowercased() == host.lowercased(),
              onward.user == nil, onward.password == nil,
              onward.percentEncodedPath.hasSuffix("/api/status")
        else { return nil }
        components.scheme = "https"
        components.port = onward.port
        components.percentEncodedPath = String(onward.percentEncodedPath.dropLast("/api/status".count))
        return components.url.flatMap { GatewayEndpoint($0.absoluteString) }
    }

    /// The addresses to ask for what the person typed, likeliest first. A scheme that was
    /// typed is kept. With none, plain http is used only for what is surely private: an
    /// address in a private range, or a name that leads only to private addresses (as a
    /// Tailscale machine's does, and a public one's does not). Everything else is asked over https, so that a token is never sent in the
    /// clear by default. With no port typed, Hermes's usual one is tried as well as the
    /// scheme's own.
    static func candidates(
        for text: String, addresses: @Sendable (String) async -> [String] = GatewayProbe.addresses(of:)
    ) async -> [GatewayEndpoint] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let typed = GatewayEndpoint(trimmed), let host = typed.baseURL.host() else { return [] }
        let namedScheme = namesScheme(trimmed)
        var base = typed
        if !namedScheme {
            let isPrivate: Bool
            if isAddress(host) {
                isPrivate = self.isPrivate(address: host)
            } else {
                isPrivate = await !leadsSomewherePublic(host, addresses: addresses)
            }
            if !isPrivate, var components = URLComponents(url: typed.baseURL, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                if let url = components.url, let secure = GatewayEndpoint(url.absoluteString) { base = secure }
            }
        }
        guard base.baseURL.port == nil, var components = URLComponents(url: base.baseURL, resolvingAgainstBaseURL: false) else { return [base] }
        components.port = usualPort
        guard let url = components.url, let usual = GatewayEndpoint(url.absoluteString) else { return [base] }
        // On a private network Hermes is most often on its own port; out on the internet,
        // behind a proxy on the usual https one.
        return base.baseURL.scheme == "https" ? [base, usual] : [usual, base]
    }

    /// Asks one address, exactly as it stands, whether Hermes is there: no other port and
    /// no other scheme is tried. For an address already known, such as one Hermes's own
    /// app saved, where a token is to go to that address or nowhere.
    public static func look(atExactly endpoint: GatewayEndpoint, timeout: TimeInterval = 5) async -> GatewayProbe {
        // Its scheme was written out where it was saved.
        await look(among: [endpoint], followingToHTTPS: false, plainHTTPChosen: true, timeout: timeout)
    }

    /// Looks for a gateway at what the person typed.
    public static func look(at text: String, timeout: TimeInterval = 5) async -> GatewayProbe {
        let candidates = await candidates(for: text)
        guard !candidates.isEmpty else { return .badAddress }
        return await look(among: candidates, followingToHTTPS: true, plainHTTPChosen: namesScheme(text), timeout: timeout)
    }

    private static func look(among first: [GatewayEndpoint], followingToHTTPS: Bool, plainHTTPChosen: Bool, timeout: TimeInterval) async -> GatewayProbe {
        var candidates = first
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Redirects are never followed: what answers must be the address itself, since
        // that is where the token will go.
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var tried: [GatewayEndpoint] = []
        var answered: GatewayEndpoint?
        var index = 0
        while index < candidates.count {
            let candidate = candidates[index]
            index += 1
            tried.append(candidate)
            guard let (data, response) = try? await session.data(from: candidate.url(path: "/api/status")),
                  let http = response as? HTTPURLResponse
            else { continue }
            // Sent on to the same place over https: that address is asked in its own right.
            if followingToHTTPS, (300..<400).contains(http.statusCode),
               let secure = http.value(forHTTPHeaderField: "Location").flatMap({ secured(candidate, sentTo: $0) }),
               !candidates.contains(secure) {
                candidates.append(secure)
            }
            // Hermes says its version and whether it asks for sign-in; little else does both.
            guard http.statusCode == 200, let status = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let version = status["version"]?.stringValue, !version.isEmpty,
                  status["auth_required"] != nil || status["gateway_running"] != nil
            else {
                answered = answered ?? candidate
                continue
            }
            var ways: [String] = []
            var takesPassword = false
            var passwordProvider: String?
            if let (data, response) = try? await session.data(from: candidate.url(path: "/api/auth/providers")),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let listed = try? JSONDecoder().decode(JSONValue.self, from: data),
               case .array(let providers)? = listed["providers"] {
                for provider in providers {
                    if let name = provider["display_name"]?.stringValue ?? provider["name"]?.stringValue { ways.append(name) }
                    if provider["supports_password"] == .bool(true) {
                        takesPassword = true
                        if passwordProvider == nil { passwordProvider = provider["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
                    }
                }
            }
            var takesToken: Bool?
            if case .array(let named)? = status["auth_providers"] { takesToken = named.contains(.string("session-token")) }
            return .found(Found(endpoint: candidate, version: version, signInWays: ways, takesPassword: takesPassword, passwordProvider: passwordProvider, takesToken: takesToken, plainHTTPChosen: plainHTTPChosen && candidate.baseURL.scheme == "http"))
        }
        return answered.map { .notHermes($0, tried: tried) } ?? .unreachable(tried: tried)
    }
}
