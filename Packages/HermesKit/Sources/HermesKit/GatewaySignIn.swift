import CryptoKit
import Foundation

/// A signed-in session on a gateway: what a username and password were exchanged for.
public struct SignedIn: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Opens the gateway for a few hours.
    public let accessToken: String
    /// Exchanged for a new pair when the access token runs out. Each works once.
    public let refreshToken: String
    public let expiresAt: Date
    /// The gateway's name for the way of signing in that was used, such as "basic".
    public let provider: String
    public let userID: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, provider: String, userID: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.provider = provider
        self.userID = userID
    }

    // Neither token may reach a log or a failed test's output by way of a print.
    public var description: String { "SignedIn(\(userID), \(provider), tokens: hidden)" }
    public var debugDescription: String { description }
}

/// Signing in to a gateway with a username and password, as Hermes's own desktop app
/// does (its "native" sign-in), without a browser.
///
/// The password is sent once, to the address the person chose, and never kept. What
/// comes back is a pair of tokens: one that opens the gateway for some hours, and one
/// that is exchanged for a new pair when that runs out.
public enum GatewaySignIn {
    public enum Failure: Error, Equatable {
        /// The username or password was not taken.
        case wrongPassword
        /// Too many tries; the gateway asks for a pause.
        case tooManyTries
        /// The session can no longer be renewed: the person must sign in again.
        case expired
        /// This gateway has no such way of signing in.
        case unsupported
        case unreachable
        /// It answered in a way this app does not understand.
        case unexpected
        /// The sign-in is good, and the gateway turned this one request away all the same.
        case turnedAway
        /// The address is reached without encryption and no longer leads somewhere
        /// private, so nothing secret was sent to it.
        case notPrivate
    }

    /// Exchanges a username and password for a session.
    public static func signIn(
        at endpoint: GatewayEndpoint, provider: String, username: String, password: String,
        session: URLSession = GatewayClient.privateSession,
        mayUse: @Sendable () async -> Bool = { true }
    ) async throws -> SignedIn {
        // A secret of this app's own for this one sign-in: only who holds it can redeem
        // the code the gateway gives.
        let verifier = try random(48)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = try random(16)
        // Hermes sends a native app back to an address on the same computer. Nothing
        // listens there: the answer is read from the reply instead of being followed.
        let comeBack = "http://127.0.0.1:49152/callback"
        var start = URLComponents(url: endpoint.url(path: "/auth/native/authorize"), resolvingAgainstBaseURL: false)!
        start.queryItems = [
            URLQueryItem(name: "provider", value: provider),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: comeBack),
            URLQueryItem(name: "state", value: state),
        ]
        // URLComponents leaves "+" unescaped, which a server reads as a space.
        start.percentEncodedQuery = start.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var asking = URLRequest(url: start.url!)
        asking.timeoutInterval = 15
        // Cookies are carried by hand, for this sign-in only: the session keeps none.
        asking.httpShouldHandleCookies = false
        let (_, began) = try await send(asking, with: session)
        switch began.statusCode {
        case 300..<400: break
        case 404, 400: throw Failure.unsupported
        case 500...: throw Failure.unreachable
        default: throw Failure.unexpected
        }
        // What ties the password about to be sent to the sign-in just begun.
        // Only that one cookie is sent back, whatever else was set.
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: began.allHeaderFields as? [String: String] ?? [:], for: asking.url!)
            .filter { isSignInCookie($0.name) }
        guard !cookies.isEmpty else { throw Failure.unexpected }

        var login = URLRequest(url: endpoint.url(path: "/auth/password-login"))
        login.httpMethod = "POST"
        login.timeoutInterval = 15
        login.httpShouldHandleCookies = false
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        login.httpBody = try JSONEncoder().encode(["provider": provider, "username": username, "password": password])
        // Asked at the moment the password is to go, not a round trip before it.
        guard await mayUse() else { throw Failure.notPrivate }
        let (said, answered) = try await send(login, with: session)
        switch answered.statusCode {
        case 200: break
        case 401: throw Failure.wrongPassword
        case 429: throw Failure.tooManyTries
        case 404: throw Failure.unsupported
        case 500...: throw Failure.unreachable
        default: throw Failure.unexpected
        }
        // The address it would send a browser on to, holding the code to redeem.
        guard let next = (try? JSONDecoder().decode(JSONValue.self, from: said))?["next"]?.stringValue,
              let onward = URLComponents(string: next), let expected = URLComponents(string: comeBack),
              // Exactly the address named, not merely one that begins like it.
              onward.scheme == expected.scheme, onward.host == expected.host, onward.port == expected.port,
              onward.path == expected.path, onward.user == nil, onward.fragment == nil,
              onward.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = onward.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty
        else { throw Failure.unexpected }
        guard await mayUse() else { throw Failure.notPrivate }
        return try await tokens(from: endpoint, path: "/auth/native/token", body: ["code": code, "code_verifier": verifier], provider: provider, session: session)
    }

    /// Whether a cookie is the one Hermes ties a sign-in under way to. Its name is
    /// `hermes_session_pkce`, with `__Host-` or `__Secure-` in front over https, and on a
    /// gateway's own web app a short name for that gateway after it.
    static func isSignInCookie(_ name: String) -> Bool {
        name.wholeMatch(of: /(__Host-|__Secure-)?hermes_session_pkce(_[A-Za-z0-9]{1,64})?/) != nil
    }

    /// Exchanges a session's refresh token for a new session. The old pair stops working.
    public static func renew(
        _ refreshToken: String, provider: String, at endpoint: GatewayEndpoint, session: URLSession = GatewayClient.privateSession
    ) async throws -> SignedIn {
        try await tokens(from: endpoint, path: "/auth/native/refresh", body: ["refresh_token": refreshToken, "provider": provider], provider: provider, session: session)
    }

    /// `provider` is the way of signing in that was asked for, used when the reply names none.
    private static func tokens(from endpoint: GatewayEndpoint, path: String, body: [String: String], provider: String, session: URLSession) async throws -> SignedIn {
        var request = URLRequest(url: endpoint.url(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await send(request, with: session)
        switch response.statusCode {
        case 200: break
        case 400, 401: throw Failure.expired
        case 404: throw Failure.unsupported
        case 500...: throw Failure.unreachable
        default: throw Failure.unexpected
        }
        guard let said = try? JSONDecoder().decode(JSONValue.self, from: data),
              let access = said["access_token"]?.stringValue, !access.isEmpty,
              let refresh = said["refresh_token"]?.stringValue, !refresh.isEmpty,
              case .number(let expires)? = said["expires_at"]
        else { throw Failure.unexpected }
        // When it runs out is told by the gateway's clock. Where the reply says what that
        // clock read, the time left is counted from this Mac's own, so a difference between
        // the two neither hands out a dead token nor renews a good one at every use.
        var runsOut = Date(timeIntervalSince1970: expires)
        if let stamp = response.value(forHTTPHeaderField: "Date"), let theirs = httpDate.date(from: stamp) {
            runsOut = Date().addingTimeInterval(runsOut.timeIntervalSince(theirs))
        }
        // A sign-in is told from a token by having this name; with none it is not one.
        let named = said["provider"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? provider
        guard !named.isEmpty else { throw Failure.unexpected }
        return SignedIn(accessToken: access, refreshToken: refresh, expiresAt: runsOut, provider: named, userID: said["user_id"]?.stringValue ?? "")
    }

    /// Sends a request that is never sent on to another address: each carries a secret.
    private static func send(_ request: URLRequest, with session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirects())
            guard let http = response as? HTTPURLResponse else { throw Failure.unexpected }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.unreachable
        }
    }

    /// The form of the `Date` an HTTP reply carries.
    private static var httpDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }

    private static func random(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        // With no randomness to be had, no sign-in is begun.
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.unexpected }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A signed-in session kept current: it hands out an access token that works now,
/// renewing the pair shortly before it runs out. One per gateway signed in to, whatever
/// comes and goes of the connections that use it: a refresh token works once, so there
/// must only ever be one holder of it.
public actor SignedInSession {
    public let endpoint: GatewayEndpoint
    private let session: URLSession
    private var current: SignedIn
    /// Whether the address may be sent something secret as things stand. Asked before
    /// every use, since a session lasts for days and the network under it changes.
    private let mayUse: @Sendable () async -> Bool
    /// Told of each new pair as soon as it is had, so it can be saved: the old refresh
    /// token no longer works, and one not saved is a session lost at the next launch.
    private let renewed: @Sendable (SignedIn) async -> Void
    private var renewing: Task<SignedIn, any Error>?

    public init(
        _ signedIn: SignedIn, at endpoint: GatewayEndpoint, session: URLSession = GatewayClient.privateSession,
        mayUse: @escaping @Sendable () async -> Bool = { true },
        renewed: @escaping @Sendable (SignedIn) async -> Void = { _ in }
    ) {
        current = signedIn
        self.endpoint = endpoint
        self.session = session
        self.mayUse = mayUse
        self.renewed = renewed
    }

    public var userID: String { current.userID }

    /// The pair held now, to be saved by whoever owns this.
    public var latest: SignedIn { current }

    /// An access token good for at least the next few minutes.
    public func accessToken() async throws -> String {
        guard await mayUse() else { throw GatewaySignIn.Failure.notPrivate }
        // From here to the starting of a renewal nothing is awaited but a renewal itself.
        // One under way is waited for: until it is over the old token may be the one the
        // gateway refused, and the new one is not yet saved.
        while let renewing { _ = try await renewing.value }
        if current.expiresAt.timeIntervalSinceNow > 300 { return current.accessToken }
        return try await beginRenewal().accessToken
    }

    /// Renews because the gateway would not take `token`. If the pair has been renewed
    /// since that token was handed out, nothing more is done: the new one is there to use.
    @discardableResult
    public func renew(replacing token: String) async throws -> SignedIn {
        guard await mayUse() else { throw GatewaySignIn.Failure.notPrivate }
        // A renewal under way is waited for and then judged by what it gave: if that is
        // the very token that was refused, it is not an answer to the refusal.
        while let renewing { _ = try await renewing.value }
        if current.accessToken != token { return current }
        return try await beginRenewal()
    }

    /// Renews now, whatever the clock says. Those who ask at once share the one renewal.
    @discardableResult
    public func renew() async throws -> SignedIn {
        guard await mayUse() else { throw GatewaySignIn.Failure.notPrivate }
        if let renewing { return try await renewing.value }
        return try await beginRenewal()
    }

    /// Nothing is awaited between finding no renewal under way and starting this one.
    private func beginRenewal() async throws -> SignedIn {
        let old = current
        // The one renewal takes the new pair into use and has it saved before anyone
        // waiting on it goes on, and is over the moment that is done.
        let task = Task { [endpoint, session] in
            do {
                let new = try await GatewaySignIn.renew(old.refreshToken, provider: old.provider, at: endpoint, session: session)
                await self.took(new)
                return new
            } catch {
                self.renewing = nil
                throw error
            }
        }
        renewing = task
        return try await task.value
    }

    private func took(_ new: SignedIn) async {
        current = new
        await renewed(new)
        renewing = nil
    }

    /// A single-use pass for opening the socket, so that the lasting token never rides
    /// in an address.
    func socketTicket() async throws -> String {
        var token = try await accessToken()
        for attempt in 0..<2 {
            // Asked again each time the token is about to go, also after a renewal.
            guard await mayUse() else { throw GatewaySignIn.Failure.notPrivate }
            var request = URLRequest(url: endpoint.url(path: "/api/auth/ws-ticket"))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request, delegate: NoRedirects())
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                throw GatewaySignIn.Failure.unreachable
            }
            let status = (response as? HTTPURLResponse)?.statusCode
            if status == 200, let ticket = (try? JSONDecoder().decode(JSONValue.self, from: data))?["ticket"]?.stringValue, !ticket.isEmpty {
                return ticket
            }
            // Not taken: this Mac's clock may be behind the gateway's, or the token ran
            // out on the way. Renewed once; a renewal refused is what ends a sign-in.
            // Turned away again with a token just renewed, the sign-in is good and it is
            // this request the gateway will not have.
            guard status == 401 || status == 403, attempt == 0 else {
                throw status == 401 || status == 403 ? GatewaySignIn.Failure.turnedAway : GatewaySignIn.Failure.unexpected
            }
            token = try await renew(replacing: token).accessToken
        }
        throw GatewaySignIn.Failure.unexpected
    }
}
