import Foundation
import Security

/// The gateway the person connected to: where it is and the token that opens it.
public struct SavedGateway: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let address: String
    public let token: String

    public init(address: String, token: String) {
        self.address = address
        self.token = token
    }

    // The token must not reach a log or a failed test's output by way of a print.
    public var description: String { "SavedGateway(\(address), token: hidden)" }
    public var debugDescription: String { description }
}

/// A gateway the person signed in to with a username and password. The password is never
/// kept: what is kept is the token that renews the session.
public struct SavedSignIn: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let address: String
    /// The gateway's name for the way of signing in, such as "basic".
    public let provider: String
    public let username: String
    public let refreshToken: String

    public init(address: String, provider: String, username: String, refreshToken: String) {
        self.address = address
        self.provider = provider
        self.username = username
        self.refreshToken = refreshToken
    }

    public var description: String { "SavedSignIn(\(address), \(username), token: hidden)" }
    public var debugDescription: String { description }
}

/// Remembers the gateway between launches. The address is a preference; the token is an item
/// in the login Keychain and nowhere else.
public struct GatewayStore: Sendable {
    public enum Failure: Error, Equatable {
        /// The Keychain refused, with its status code.
        case keychain(Int32)
    }

    /// What is saved.
    public enum Saved: Sendable, Equatable {
        case nothing
        case gateway(SavedGateway)
        /// An address is saved, but its token is missing from the Keychain or can't be read.
        case unreadable(address: String)
        /// Hermes on this Mac, which takes no token: nothing secret is kept for it.
        case thisMac
        /// Signed in with a username and password.
        case signedIn(SavedSignIn)
    }

    private let suite: String?
    private let service: String
    private static let addressKey = "gateway.address"
    private static let plainHTTPKey = "gateway.plainHTTPChosen"
    private static let thisMacKey = "gateway.thisMac"
    private static let nicknameKey = "gateway.nickname"
    private static let providerKey = "gateway.signIn.provider"
    private static let usernameKey = "gateway.signIn.username"
    private static let lateKey = "pictures.mayLandLate"

    /// `suite` and `service` are for tests, so they don't touch the real saved gateway.
    public init(suite: String? = nil, service: String = "HermesBot gateway token") {
        self.suite = suite
        self.service = service
    }

    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    /// Whether Hermes on this Mac is what was connected to.
    public var isThisMac: Bool { defaults.bool(forKey: Self.thisMacKey) }

    /// The person's own name for the saved gateway, shown in place of its address. It
    /// stays on this Mac and goes when another gateway takes this one's place.
    public var nickname: String? {
        defaults.string(forKey: Self.nicknameKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Names the saved gateway, or with nil or nothing but spaces takes its name away.
    public func setNickname(_ name: String?) {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty { defaults.removeObject(forKey: Self.nicknameKey) } else { defaults.set(String(name.prefix(60)), forKey: Self.nicknameKey) }
    }

    /// Open chats, by live session id, where a picture went to the gateway and no answer
    /// has come back: it may still be queued there. Kept over a quit, and whatever gateway
    /// is in use, since a gateway hands the same open chat back to whoever opens it.
    public var picturesMayLandLate: Set<String> { Set(defaults.stringArray(forKey: Self.lateKey) ?? []) }

    public func setPicturesMayLandLate(_ chats: Set<String>) {
        if chats.isEmpty { defaults.removeObject(forKey: Self.lateKey) } else { defaults.set(chats.sorted(), forKey: Self.lateKey) }
    }

    /// Whether what is saved was signed in to with a username and password.
    public var isSignIn: Bool { address != nil && !(defaults.string(forKey: Self.providerKey) ?? "").isEmpty }

    /// Whether anything is saved at all, without touching the Keychain.
    public var hasGateway: Bool { isThisMac || address != nil }

    /// Saves that Hermes on this Mac is the gateway, in place of any saved before, and
    /// removes that one's token.
    /// If the Keychain will not give that token up, nothing is changed.
    public func saveThisMac() throws {
        if let previous = address {
            let status = SecItemDelete(item(for: previous) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
        }
        if !isThisMac { defaults.removeObject(forKey: Self.nicknameKey) }
        defaults.set(true, forKey: Self.thisMacKey)
        defaults.removeObject(forKey: Self.addressKey)
        defaults.removeObject(forKey: Self.plainHTTPKey)
        defaults.removeObject(forKey: Self.providerKey)
        defaults.removeObject(forKey: Self.usernameKey)
    }

    /// Takes back `saveThisMac`, and nothing else that may have been saved since.
    public func forgetThisMac() {
        defaults.removeObject(forKey: Self.thisMacKey)
    }

    /// The saved address, without touching the Keychain.
    public var address: String? {
        defaults.string(forKey: Self.addressKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether the person chose plain http for the saved address themselves. When they did
    /// not, a token goes over http only while the address is a private one.
    public var plainHTTPChosen: Bool { defaults.bool(forKey: Self.plainHTTPKey) }

    /// Reads what is saved. The Keychain may stop to ask the person's leave, so don't call
    /// this on the main thread.
    public func read() -> Saved {
        if isThisMac { return .thisMac }
        guard let address else { return .nothing }
        var query = item(for: address)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return .unreadable(address: address) }
        if let provider = defaults.string(forKey: Self.providerKey), !provider.isEmpty {
            return .signedIn(SavedSignIn(address: address, provider: provider, username: defaults.string(forKey: Self.usernameKey) ?? "", refreshToken: token))
        }
        return .gateway(SavedGateway(address: address, token: token))
    }

    /// Saves the gateway in place of any saved before. If the Keychain refuses, what was
    /// saved before is left as it was.
    public func save(_ gateway: SavedGateway, plainHTTPChosen: Bool = false) throws {
        try keep(gateway.token, for: gateway.address, plainHTTPChosen: plainHTTPChosen)
        defaults.removeObject(forKey: Self.providerKey)
        defaults.removeObject(forKey: Self.usernameKey)
    }

    /// Saves a signed-in gateway in place of any saved before, or the new token of the one
    /// already saved. If the Keychain refuses, what was saved before is left as it was.
    public func save(_ signIn: SavedSignIn, plainHTTPChosen: Bool = false) throws {
        try keep(signIn.refreshToken, for: signIn.address, plainHTTPChosen: plainHTTPChosen)
        defaults.set(signIn.provider, forKey: Self.providerKey)
        defaults.set(signIn.username, forKey: Self.usernameKey)
    }

    private func keep(_ secret: String, for address: String, plainHTTPChosen: Bool) throws {
        let gateway = SavedGateway(address: address, token: secret)
        let previous = self.address
        // A name was given to the gateway it named, not to whatever comes after it.
        if previous != address || isThisMac { defaults.removeObject(forKey: Self.nicknameKey) }
        let token = Data(gateway.token.utf8)
        // An item may already be there for this address: the same gateway saved again, or one
        // left behind when preferences were cleared.
        var status = SecItemUpdate(item(for: gateway.address) as CFDictionary, [kSecValueData: token] as CFDictionary)
        if status == errSecItemNotFound {
            var new = item(for: gateway.address)
            new[kSecValueData] = token
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        defaults.set(gateway.address, forKey: Self.addressKey)
        defaults.set(plainHTTPChosen, forKey: Self.plainHTTPKey)
        defaults.removeObject(forKey: Self.thisMacKey)
        if let previous, previous != gateway.address { SecItemDelete(item(for: previous) as CFDictionary) }
    }

    /// Forgets the gateway and its token. Throws if the Keychain would not give the token up;
    /// the address is forgotten either way, so the app does not go on using it.
    public func clear() throws {
        defaults.removeObject(forKey: Self.addressKey)
        defaults.removeObject(forKey: Self.plainHTTPKey)
        defaults.removeObject(forKey: Self.thisMacKey)
        defaults.removeObject(forKey: Self.providerKey)
        defaults.removeObject(forKey: Self.usernameKey)
        defaults.removeObject(forKey: Self.nicknameKey)
        // Every token this store ever saved, not only the current address's.
        let all: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        // On the Mac's file keychain one call removes one item, so go on until none is left.
        var status = errSecSuccess
        var rounds = 0
        while status == errSecSuccess, rounds < 100 {
            status = SecItemDelete(all as CFDictionary)
            rounds += 1
        }
        // Only "none left" is success: a refusal, or still finding items after all that, is not.
        guard status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    private func item(for address: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: address]
    }
}
