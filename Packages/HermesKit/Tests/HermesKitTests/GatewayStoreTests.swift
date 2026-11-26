import Foundation
import Security
import Testing
@testable import HermesKit

@Suite(.serialized)
struct GatewayStoreTests {
    /// A store of its own, cleared afterwards, so the real saved gateway is never touched.
    private func withStore(_ body: (GatewayStore, String) throws -> Void) rethrows {
        let name = "HermesBotTests.\(UUID().uuidString)"
        let store = GatewayStore(suite: name, service: name)
        defer {
            try? store.clear()
            UserDefaults().removePersistentDomain(forName: name)
        }
        try body(store, name)
    }

    private func tokensInKeychain(_ service: String) -> Int {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true,
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return 0 }
        return (found as? [Any])?.count ?? 0
    }

    @Test func thisMacIsSavedWithNoTokenAndTakesThePlaceOfAServer() throws {
        try withStore { store, name in
            try store.save(SavedGateway(address: "http://nas.local:9119", token: "s3cret-token"), plainHTTPChosen: true)
            try store.saveThisMac()
            #expect(store.read() == .thisMac)
            #expect(store.hasGateway)
            #expect(store.address == nil)
            #expect(!store.plainHTTPChosen)
            // The server's token went with it.
            #expect(tokensInKeychain(name) == 0)
            // And a server takes the place of this Mac.
            try store.save(SavedGateway(address: "http://nas.local:9119", token: "t"))
            #expect(!store.isThisMac)
            #expect(store.read() == .gateway(SavedGateway(address: "http://nas.local:9119", token: "t")))
            try store.saveThisMac()
            try store.clear()
            #expect(store.read() == .nothing)
            #expect(!store.hasGateway)
        }
    }

    @Test func aSignInIsSavedWithItsTokenInTheKeychainAndReplacedWhenRenewed() throws {
        try withStore { store, name in
            let first = SavedSignIn(address: "https://hermes.example.com", provider: "basic", username: "sam", refreshToken: "refresh-one")
            try store.save(first)
            #expect(GatewayStore(suite: name, service: name).read() == .signedIn(first))
            let preferences = UserDefaults(suiteName: name)!.dictionaryRepresentation()
            #expect(!preferences.values.contains { "\($0)".contains("refresh-one") })
            #expect(!"\(first)".contains("refresh-one"))
            let second = SavedSignIn(address: "https://hermes.example.com", provider: "basic", username: "sam", refreshToken: "refresh-two")
            try store.save(second)
            #expect(store.read() == .signedIn(second))
            #expect(tokensInKeychain(name) == 1)
            // A token gateway in its place is no longer a sign-in.
            try store.save(SavedGateway(address: "https://hermes.example.com", token: "t"))
            #expect(store.read() == .gateway(SavedGateway(address: "https://hermes.example.com", token: "t")))
            try store.save(second)
            try store.saveThisMac()
            #expect(store.read() == .thisMac)
            #expect(tokensInKeychain(name) == 0)
        }
    }

    @Test func aNameForTheGatewayStaysWithItAndGoesWhenAnotherTakesItsPlace() throws {
        try withStore { store, name in
            #expect(store.nickname == nil)
            try store.save(SavedGateway(address: "http://100.100.1.2:9119", token: "t"))
            store.setNickname("  Home server ")
            #expect(GatewayStore(suite: name, service: name).nickname == "Home server")
            // The same gateway saved again, as a renewed sign-in is, keeps its name.
            try store.save(SavedGateway(address: "http://100.100.1.2:9119", token: "newer"))
            #expect(store.nickname == "Home server")
            // Nothing but spaces takes the name away.
            store.setNickname("   ")
            #expect(store.nickname == nil)
            store.setNickname("Home server")
            // Another gateway, this Mac, or none at all: the name does not carry over.
            try store.save(SavedGateway(address: "http://nas.local:9119", token: "t"))
            #expect(store.nickname == nil)
            store.setNickname("NAS")
            try store.saveThisMac()
            #expect(store.nickname == nil)
            store.setNickname("Here")
            try store.saveThisMac()
            #expect(store.nickname == "Here")
            try store.clear()
            #expect(store.nickname == nil)
        }
    }

    @Test func nothingIsSavedAtFirst() {
        withStore { store, _ in
            #expect(store.read() == .nothing)
            #expect(store.address == nil)
        }
    }

    @Test func whetherPlainHttpWasChosenIsKeptWithTheAddressAndGoesWithIt() throws {
        try withStore { store, name in
            #expect(!store.plainHTTPChosen)
            try store.save(SavedGateway(address: "http://hermes.example.com", token: "t"), plainHTTPChosen: true)
            #expect(GatewayStore(suite: name, service: name).plainHTTPChosen)
            // Another gateway saved without it does not inherit the choice.
            try store.save(SavedGateway(address: "http://nas.local:9119", token: "t"))
            #expect(!store.plainHTTPChosen)
            try store.save(SavedGateway(address: "http://hermes.example.com", token: "t"), plainHTTPChosen: true)
            try store.clear()
            #expect(!store.plainHTTPChosen)
        }
    }

    @Test func aSavedGatewayComesBackAndTheTokenIsNotInPreferences() throws {
        try withStore { store, name in
            let gateway = SavedGateway(address: "http://nas.local:9119", token: "s3cret-token")
            try store.save(gateway)
            // A second store on the same names reads what the first saved, as a relaunch would.
            #expect(GatewayStore(suite: name, service: name).read() == .gateway(gateway))
            #expect(store.address == "http://nas.local:9119")
            let preferences = UserDefaults(suiteName: name)!.dictionaryRepresentation()
            #expect(!preferences.values.contains { "\($0)".contains("s3cret-token") })
        }
    }

    @Test func theTokenIsLeftOutWhenAGatewayIsPrinted() {
        let gateway = SavedGateway(address: "http://nas.local:9119", token: "s3cret-token")
        #expect(!"\(gateway)".contains("s3cret"))
        #expect(!String(reflecting: gateway).contains("s3cret"))
        #expect(!String(describing: GatewayStore.Saved.gateway(gateway)).contains("s3cret"))
    }

    @Test func savingAgainReplacesTheGatewayAndLeavesNoOldToken() throws {
        try withStore { store, name in
            try store.save(SavedGateway(address: "http://old.local:9119", token: "old"))
            try store.save(SavedGateway(address: "http://new.local:9119", token: "new"))
            #expect(store.read() == .gateway(SavedGateway(address: "http://new.local:9119", token: "new")))
            #expect(tokensInKeychain(name) == 1)
            try store.save(SavedGateway(address: "http://new.local:9119", token: "newer"))
            #expect(store.read() == .gateway(SavedGateway(address: "http://new.local:9119", token: "newer")))
            #expect(tokensInKeychain(name) == 1)
        }
    }

    /// A token left in the Keychain with no address beside it, as when preferences are wiped,
    /// must not stop the same gateway being saved again.
    @Test func aTokenLeftBehindDoesNotBlockSavingThatGatewayAgain() throws {
        try withStore { store, name in
            try store.save(SavedGateway(address: "http://nas.local:9119", token: "first"))
            UserDefaults(suiteName: name)!.removeObject(forKey: "gateway.address")
            #expect(store.read() == .nothing)
            try store.save(SavedGateway(address: "http://nas.local:9119", token: "second"))
            #expect(store.read() == .gateway(SavedGateway(address: "http://nas.local:9119", token: "second")))
        }
    }

    @Test func anAddressWhoseTokenIsGoneIsReportedNotForgotten() throws {
        try withStore { store, name in
            try store.save(SavedGateway(address: "http://nas.local:9119", token: "t"))
            let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: name]
            #expect(SecItemDelete(item as CFDictionary) == errSecSuccess)
            #expect(store.read() == .unreadable(address: "http://nas.local:9119"))
        }
    }

    @Test func clearingForgetsTheAddressAndEveryToken() throws {
        try withStore { store, name in
            try store.save(SavedGateway(address: "http://one.local:9119", token: "a"))
            // A token under another address, left over from some earlier mishap.
            UserDefaults(suiteName: name)!.removeObject(forKey: "gateway.address")
            try store.save(SavedGateway(address: "http://two.local:9119", token: "b"))
            #expect(tokensInKeychain(name) == 2)
            try store.clear()
            #expect(store.read() == .nothing)
            #expect(tokensInKeychain(name) == 0)
            // Clearing when nothing is saved is not a failure.
            try store.clear()
        }
    }
}
