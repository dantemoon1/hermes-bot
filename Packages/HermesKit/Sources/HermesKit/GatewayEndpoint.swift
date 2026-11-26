import Foundation

/// The address of a Hermes gateway, as the user typed it.
public struct GatewayEndpoint: Sendable, Hashable {
    /// Scheme, host, port and any path prefix. Never a query, fragment or trailing slash.
    public let baseURL: URL

    /// Accepts `host:port`, `http://host:port`, or a URL pasted from a browser. A path prefix is
    /// kept; a query or fragment is dropped. Returns nil when the text is not an http(s) address.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Look for a scheme only at the start: "://" may also appear in a query we will drop.
        if trimmed.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\/\/.*/) == nil { trimmed = "http://" + trimmed }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        while components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath.removeLast() }
        guard let url = components.url else { return nil }
        baseURL = url
    }

    /// An HTTP address on the gateway. `path` starts with a slash and is already URL-safe.
    func url(path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath += path
        return components.url!
    }

    /// The gateway's host, and its port when it has one, for showing to the person.
    public var label: String {
        let host = baseURL.host() ?? baseURL.absoluteString
        return baseURL.port.map { "\(host):\($0)" } ?? host
    }

    /// The JSON-RPC socket. The gateway takes the token as a query item on this one request.
    /// With `ticket`, a single-use pass a signed-in session was given goes there instead.
    public func webSocketURL(token: String? = nil, ticket: String? = nil) -> URL {
        var components = URLComponents(url: url(path: "/api/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let value = token ?? ticket else { return components.url! }
        components.queryItems = [URLQueryItem(name: token != nil ? "token" : "ticket", value: value)]
        // URLComponents leaves "+" unescaped, which a server reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
