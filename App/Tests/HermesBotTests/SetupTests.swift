import Foundation
import Security
import HermesKit
import Testing
@testable import HermesBot

/// Setting up, remembering and forgetting a gateway, against the pretend gateway.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SetupTests {
    /// A store of its own, so the real saved gateway is never touched.
    private func store() -> (GatewayStore, cleanUp: () -> Void) {
        let (store, _, cleanUp) = namedStore()
        return (store, cleanUp)
    }

    private func namedStore() -> (GatewayStore, service: String, cleanUp: () -> Void) {
        let name = "HermesBotTests.\(UUID().uuidString)"
        let store = GatewayStore(suite: name, service: name)
        return (store, name, {
            try? store.clear()
            UserDefaults().removePersistentDomain(forName: name)
        })
    }

    @Test func aWrongTokenOrAddressIsExplainedAndNothingIsSaved() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        await roster.load()

        #expect(await roster.setUp(address: pretend.address, token: "wrong") == "The gateway refused the token.")
        #expect(await roster.setUp(address: "not an address", token: "demo")?.contains("address") == true)
        #expect(await roster.setUp(address: pretend.address, token: " \n") == "Enter the gateway's token.")
        #expect(await roster.setUp(address: "127.0.0.1:9", token: "demo") == "Couldn't reach the gateway.")
        #expect(roster.phase == .needsSetup)
        #expect(store.read() == .nothing)
    }

    /// The gateway just set up is listened to from that moment, not from the next launch.
    @Test func aGatewayJustSetUpIsHeardWhenABotSpeaksUnasked() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        await roster.load()
        #expect(await roster.setUp(address: pretend.address, token: "demo") == nil)
        #expect(roster.unread.isEmpty)

        // From another app, as another device: this one is asked nothing.
        let other = RosterModel(gateway: (pretend.address, "demo"))
        await other.load()
        let main = try #require(other.mainBot)
        let chat = other.chat(for: main)
        await chat.load(main, from: other)
        chat.draft = "quick nudge garden please"
        chat.send(to: main, through: other)

        let deadline = Date.now.addingTimeInterval(10)
        while !roster.unread.contains("garden") {
            try #require(Date.now < deadline, "Garden never showed as unread after setup")
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// What Hermes's own app on this Mac connects to is offered, and connecting to one
    /// saves it as this app's own, as typing it in would.
    @Test func aServerSavedByHermesItselfIsOfferedAndConnectsWithNothingTyped() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("connections-\(UUID().uuidString).json")
        try Data(#"{"lastUsed":"demo","connections":[{"id":"local","kind":"local","label":"This device"},{"id":"demo","kind":"remote","label":"Demo NAS","url":"http://\#(pretend.address)","authMode":"token","token":{"encoding":"plain","value":"demo"}}]}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let roster = RosterModel(store: store, readsEnvironment: false, hermesConnections: file)
        #expect(roster.phase == .needsSetup)
        let saved = try #require(roster.savedConnections.first)
        #expect(roster.savedConnections.count == 1)
        #expect(saved.label == "Demo NAS")

        #expect(await roster.setUp(address: saved.address, token: saved.token) == nil)
        #expect(roster.phase == .loaded)
        #expect(roster.mainBot != nil)
        // Kept as this app's own, so the next launch needs neither Hermes's file nor a choice.
        if case .gateway(let kept) = store.read() { #expect(kept.token == "demo") } else { Issue.record("The gateway was not saved") }
        // With no file named, none is read: tests never see the real one.
        #expect(RosterModel(store: self.store().0, readsEnvironment: false).savedConnections.isEmpty)
    }

    /// The address alone is enough to learn what a server is and what it asks for.
    @Test func anAddressIsAskedWhatIsThereBeforeAnythingIsSignedInTo() async throws {
        let pretend = try await SendingTests.Pretend()
        guard case .found(let found) = await GatewayProbe.look(at: pretend.address) else {
            Issue.record("The pretend gateway was not found")
            return
        }
        #expect(found.endpoint.label == pretend.address)
        #expect(found.version == "0.23.4")
        #expect(found.signInWays.isEmpty)
        #expect(!found.takesPassword)
        #expect(found.takesToken == true)
    }

    /// What answers must be the address itself and must be Hermes: that is where a token goes.
    @Test func anAddressThatSendsOnOrOnlyLooksLikeHermesIsNotTakenForIt() async throws {
        let real = try await SendingTests.Pretend()
        // Sends every asker on to the real one: it is not itself a gateway.
        let onward = try await SendingTests.Pretend(whenBusy: "redirects", extra: String(real.port))
        guard case .notHermes(let endpoint, _) = await GatewayProbe.look(at: onward.address) else {
            Issue.record("A redirecting address was taken for Hermes")
            return
        }
        #expect(endpoint.label == onward.address)
        for mode in ["not-hermes", "lookalike"] {
            let other = try await SendingTests.Pretend(whenBusy: mode)
            if case .notHermes = await GatewayProbe.look(at: other.address) {} else { Issue.record("\(mode) was taken for Hermes") }
        }
    }

    /// The token rides in the address of the connection, so a server that answers "go
    /// elsewhere" is not followed there with it.
    @Test func aConnectionCarryingTheTokenIsNeverSentOnToAnotherAddress() async throws {
        let real = try await SendingTests.Pretend()
        let onward = try await SendingTests.Pretend(whenBusy: "redirects", extra: String(real.port))
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(await roster.connect(address: onward.address, token: "demo") != nil)
        #expect(roster.phase == .needsSetup)
        #expect(store.read() == .nothing)
    }

    @Test func aServerSaysWhetherATokenIsOneOfItsWaysIn() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "password-only")
        guard case .found(let found) = await GatewayProbe.look(at: pretend.address) else {
            Issue.record("The pretend gateway was not found")
            return
        }
        #expect(found.takesToken == false)
        #expect(found.takesPassword)
        #expect(found.signInWays == ["Username & Password"])
    }

    @Test func aRefusedTokenIsToldApartFromOtherTrouble() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(await roster.connect(address: pretend.address, token: "wrong")?.tokenRefused == true)
        #expect(await roster.connect(address: "127.0.0.1:9", token: "demo")?.tokenRefused == false)
        #expect(await roster.connect(address: pretend.address, token: "demo") == nil)
    }

    /// A link pasted from a browser can carry the token in its query. Only the gateway's
    /// own address may be kept in preferences.
    @Test func aPastedLinkIsSavedWithoutItsQuery() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)

        #expect(await roster.setUp(address: "http://\(pretend.address)/?token=demo&x=1#frag", token: "demo") == nil)
        #expect(store.address == "http://\(pretend.address)")
        #expect(roster.gatewayAddress == pretend.address)
    }

    /// The address is saved but its token has gone from the Keychain. The person is told,
    /// can still see which gateway it was, and can disconnect from it.
    @Test func aSavedGatewayWhoseTokenIsGoneCanStillBeDisconnected() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, service, cleanUp) = namedStore()
        defer { cleanUp() }
        try store.save(SavedGateway(address: "http://\(pretend.address)", token: "demo"))
        // Remove the token only, leaving the address. This store's own item and no other.
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        #expect(SecItemDelete(item as CFDictionary) == errSecSuccess)

        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(roster.phase == .loading)
        await roster.load()
        guard case .failed(let problem) = roster.phase else {
            Issue.record("Expected a failure, got \(roster.phase)")
            return
        }
        #expect(problem.contains("Keychain"))
        #expect(roster.gatewayAddress == pretend.address)
        await roster.signOut()
        #expect(roster.phase == .needsSetup)
        #expect(store.read() == .nothing)
    }

    /// A saved gateway that can't be reached at launch: a failure with a way out, not setup.
    @Test func aSavedGatewayThatIsDownCanStillBeDisconnected() async throws {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        try store.save(SavedGateway(address: "http://127.0.0.1:9", token: "demo"))
        let roster = RosterModel(store: store, readsEnvironment: false)
        await roster.load()
        #expect(roster.phase == .failed("Couldn't reach the gateway."))
        #expect(roster.gatewayAddress == "127.0.0.1:9")
        await roster.signOut()
        #expect(roster.phase == .needsSetup)
    }

    /// Leaving a gateway mid-answer: the chat that was answering must not go on to read
    /// from the gateway connected next.
    @Test func disconnectingMidAnswerLeavesNothingRunning() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(await roster.setUp(address: pretend.address, token: "demo") == nil)
        let bot = try #require(roster.mainBot)
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        chat.draft = "quick but slow"
        chat.send(to: bot, through: roster)
        try await Task.sleep(for: .milliseconds(400))

        await roster.signOut()
        let deadline = Date.now.addingTimeInterval(5)
        while chat.isWorking {
            try #require(Date.now < deadline, "The abandoned chat was still working")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(roster.phase == .needsSetup)
        #expect(roster.bots.isEmpty)
    }

    /// Disconnecting and connecting again at once: the disconnect's clearing of the Keychain
    /// must not take the newly saved gateway's token with it.
    @Test func connectingStraightAfterDisconnectingKeepsTheNewGateway() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(await roster.setUp(address: pretend.address, token: "demo") == nil)

        async let leaving: Void = roster.signOut()
        // Wait until the leaving has begun: its first act is to show setup, before the
        // Keychain is cleared. One yield may not be enough on a busy machine.
        for _ in 0..<10_000 {
            if roster.phase != .loaded { break }
            await Task.yield()
        }
        #expect(roster.phase == .needsSetup, "the disconnecting never showed setup")
        #expect(await roster.setUp(address: pretend.address, token: "demo") == nil)
        await leaving

        #expect(roster.phase == .loaded)
        #expect(roster.setupNotice == nil)
        #expect(store.read() == .gateway(SavedGateway(address: "http://\(pretend.address)", token: "demo")))
        // And it is still there at the next launch.
        let relaunched = RosterModel(store: store, readsEnvironment: false)
        await relaunched.load()
        #expect(relaunched.phase == .loaded)
    }

    @Test func withNothingSavedTheFirstThingShownIsSetup() async {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        // Before anything is loaded, and all through loading: no flash of an empty main window.
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(roster.phase == .needsSetup)
        let loading = Task { await roster.load() }
        await Task.yield()
        #expect(roster.phase == .needsSetup)
        await loading.value
        #expect(roster.phase == .needsSetup)
    }

    @Test func aGatewayThatWorksIsSavedUsedAndRememberedUntilDisconnected() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        await roster.load()

        #expect(await roster.setUp(address: "  \(pretend.address) ", token: " demo\n") == nil)
        #expect(roster.phase == .loaded)
        #expect(roster.bots.count == 4)
        #expect(roster.gatewayAddress == pretend.address)
        #expect(store.read() == .gateway(SavedGateway(address: "http://\(pretend.address)", token: "demo")))

        // The next launch.
        let relaunched = RosterModel(store: store, readsEnvironment: false)
        await relaunched.load()
        #expect(relaunched.phase == .loaded)
        #expect(relaunched.mainBot != nil)

        await roster.signOut()
        #expect(roster.phase == .needsSetup)
        #expect(roster.bots.isEmpty)
        #expect(roster.gatewayAddress == nil)
        #expect(store.read() == .nothing)
    }

    // MARK: Hermes on this Mac

    /// A pretend `hermes` command that says the gateway is at `origin`, or with "none"
    /// that none is running. Returns it with what removes it.
    private func hermesCommand(sayingGatewayIsAt origin: String) throws -> (URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/fake-hermes.py")
        let command = folder.appendingPathComponent("hermes")
        try Data("#!/bin/sh\nexec /usr/bin/env python3 '\(script.path)' '\(origin)' \"$@\"\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        return (command, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test func hermesRunningOnThisMacIsOfferedFirstAndOnlyWhenItIsRunning() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "tickets")
        let (command, remove) = try hermesCommand(sayingGatewayIsAt: "http://\(pretend.address)")
        defer { remove() }
        let (store, cleanUp) = store()
        defer { cleanUp() }
        // With a server Hermes's app saved, to be listed after it.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("connections-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"connections": [{"id": "a", "kind": "remote", "label": "Home NAS", "url": "http://nas.local:9119", "authMode": "token", "token": {"encoding": "plain", "value": "made-up"}}]}"#.utf8).write(to: file)
        let roster = RosterModel(store: store, readsEnvironment: false, hermesConnections: file, hermesCommand: command)
        #expect(roster.setupOffers.map(\.label) == ["Home NAS"])
        await roster.settleThisMac()
        #expect(roster.thisMacIsRunning)
        #expect(roster.setupOffers.map(\.label) == ["This Mac", "Home NAS"])

        let (stopped, removeStopped) = try hermesCommand(sayingGatewayIsAt: "none")
        defer { removeStopped() }
        let other = RosterModel(store: self.store().0, readsEnvironment: false, hermesCommand: stopped)
        await other.settleThisMac()
        #expect(!other.thisMacIsRunning)
        #expect(other.setupOffers.isEmpty)
    }

    @Test func thisMacConnectsWithNoTokenAndStaysConnectedAcrossLaunches() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "tickets")
        let (command, remove) = try hermesCommand(sayingGatewayIsAt: "http://\(pretend.address)")
        defer { remove() }
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false, hermesCommand: command)
        #expect(await roster.connectToThisMac() == nil)
        #expect(roster.phase == .loaded)
        #expect(roster.gatewayAddress == "This Mac")
        #expect(store.read() == .thisMac)
        // A chat's messages are read over HTTP, each read with a pass of its own.
        let bot = try #require(roster.mainBot)
        #expect(bot.chat != nil)
        let once = try await roster.messages(for: bot)
        let twice = try await roster.messages(for: bot)
        #expect(once == twice)
        #expect(roster.isThisMac)

        // The next launch: nothing was saved but that it is this Mac.
        let again = RosterModel(store: store, readsEnvironment: false, hermesCommand: command)
        #expect(again.phase != .needsSetup)
        await again.load()
        #expect(again.phase == .loaded)
        #expect(again.bots.map(\.id) == roster.bots.map(\.id))

        // Disconnecting forgets it.
        await again.signOut()
        #expect(store.read() == .nothing)
        #expect(again.phase == .needsSetup)
    }

    @Test func thisMacSaysSoWhenHermesIsNotRunningOrWillNotTakeThePass() async throws {
        let (stopped, removeStopped) = try hermesCommand(sayingGatewayIsAt: "none")
        defer { removeStopped() }
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false, hermesCommand: stopped)
        #expect(await roster.connectToThisMac()?.text == "Hermes isn't running on this Mac. Start it and try again.")
        #expect(store.read() == .nothing)

        // A gateway that knows nothing of passes refuses them; nothing is saved.
        let plain = try await SendingTests.Pretend()
        let (command, remove) = try hermesCommand(sayingGatewayIsAt: "http://\(plain.address)")
        defer { remove() }
        let refused = RosterModel(store: store, readsEnvironment: false, hermesCommand: command)
        #expect(await refused.connectToThisMac()?.text == "Hermes on this Mac didn't let the app in. Update Hermes and try again.")
        #expect(refused.phase == .needsSetup)
        #expect(store.read() == .nothing)
        // The same at a later launch, when this Mac is what was saved.
        try store.saveThisMac()
        let relaunched = RosterModel(store: store, readsEnvironment: false, hermesCommand: command)
        await relaunched.load()
        #expect(relaunched.phase == .failed("Hermes on this Mac didn't let the app in. Update Hermes and try again."))
        // Still known as this Mac, so what is said about it speaks of no token.
        #expect(relaunched.isThisMac)

        // Saved as this Mac, and Hermes is not running at the next launch: said, not setup.
        try store.saveThisMac()
        let later = RosterModel(store: store, readsEnvironment: false, hermesCommand: stopped)
        await later.load()
        #expect(later.phase == .failed("Hermes isn't running on this Mac. Start it and try again."))
    }

    @Test func aPassIsOnlyEverSentToThisMacItself() async throws {
        // A command that names another computer is not believed.
        let (command, remove) = try hermesCommand(sayingGatewayIsAt: "http://203.0.113.9:9119")
        defer { remove() }
        let helper = LocalHermes(command: command, patience: .seconds(5))
        await #expect(throws: LocalHermes.Failure.unexpected) { try await helper.endpoint() }
        await #expect(throws: LocalHermes.Failure.unexpected) { try await helper.ticket(.interactive, profile: nil) }
        // Nor one that names this Mac by a name, or adds a path, or gives no port.
        for said in ["http://localhost:9129", "http://127.0.0.1:9129/elsewhere", "http://127.0.0.1", "https://127.0.0.1:9129"] {
            let (odd, removeOdd) = try hermesCommand(sayingGatewayIsAt: said)
            defer { removeOdd() }
            await #expect(throws: LocalHermes.Failure.unexpected, "\(said)") { try await LocalHermes(command: odd, patience: .seconds(5)).endpoint() }
        }
    }

    /// The setup screen's look and a connection's helper can be alive at once.
    @Test func twoHelpersCanRunAtOnceAndEachPassIsNew() async throws {
        let (command, remove) = try hermesCommand(sayingGatewayIsAt: "http://127.0.0.1:9129")
        defer { remove() }
        let first = LocalHermes(command: command, patience: .seconds(5))
        let second = LocalHermes(command: command, patience: .seconds(5))
        #expect(try await first.endpoint().label == "127.0.0.1:9129")
        #expect(try await second.endpoint().label == "127.0.0.1:9129")
        async let one = first.ticket(.http, profile: "coder")
        async let two = first.ticket(.http, profile: "coder")
        let passes = try await [one, two]
        #expect(passes[0] != passes[1])
        #expect(passes[0].hasPrefix("pass.native-http.coder."))
        // The socket's pass names no bot.
        #expect(try await second.ticket(.interactive, profile: "coder").hasPrefix("pass.interactive.."))
    }

    /// A helper serves one connection: ended, it is never started again, since the gateway
    /// may be somewhere else by then and its connection still holds the old address.
    @Test func aHelperThatHasEndedGivesNoMorePasses() async throws {
        let (command, remove) = try hermesCommand(sayingGatewayIsAt: "http://127.0.0.1:9129")
        defer { remove() }
        let stopped = LocalHermes(command: command, patience: .seconds(5))
        _ = try await stopped.ticket(.interactive, profile: nil)
        await stopped.stop()
        await #expect(throws: LocalHermes.Failure.notRunning) { try await stopped.ticket(.interactive, profile: nil) }
        await #expect(throws: LocalHermes.Failure.notRunning) { try await stopped.endpoint() }

        // One that ends by itself after saying where the gateway is: asking it is a
        // failure to report, not a write to a closed pipe that ends the app.
        let (leaving, removeLeaving) = try hermesCommand(sayingGatewayIsAt: "gone:http://127.0.0.1:9129")
        defer { removeLeaving() }
        let gone = LocalHermes(command: leaving, patience: .seconds(5))
        _ = try await gone.endpoint()
        // Asked at once, it may still be closing; either way the asker is told.
        await #expect(throws: LocalHermes.Failure.notRunning) { try await gone.ticket(.http, profile: "coder") }
        // And once it has surely gone, when the write itself is what fails.
        let later = LocalHermes(command: leaving, patience: .seconds(5))
        _ = try await later.endpoint()
        try await Task.sleep(for: .milliseconds(300))
        await #expect(throws: LocalHermes.Failure.notRunning) { try await later.ticket(.http, profile: "coder") }

        // One that never says anything is given up on, and not asked again.
        let (quiet, removeQuiet) = try hermesCommand(sayingGatewayIsAt: "silent")
        defer { removeQuiet() }
        let silent = LocalHermes(command: quiet, patience: .milliseconds(400))
        await #expect(throws: LocalHermes.Failure.timedOut) { try await silent.endpoint() }
        await #expect(throws: LocalHermes.Failure.timedOut) { try await silent.endpoint() }
        // Also when whoever was waiting stopped waiting first.
        let abandoned = LocalHermes(command: quiet, patience: .milliseconds(400))
        let asking = Task { try await abandoned.endpoint() }
        try await Task.sleep(for: .milliseconds(100))
        asking.cancel()
        _ = await asking.result
        try await Task.sleep(for: .milliseconds(500))
        await #expect(throws: LocalHermes.Failure.timedOut) { try await abandoned.endpoint() }
    }

    @Test func aServerAndThisMacTakeEachOthersPlace() async throws {
        let local = try await SendingTests.Pretend(whenBusy: "tickets")
        let remote = try await SendingTests.Pretend()
        let (command, remove) = try hermesCommand(sayingGatewayIsAt: "http://\(local.address)")
        defer { remove() }
        let (store, service, cleanUp) = namedStore()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false, hermesCommand: command)
        #expect(await roster.connect(address: remote.address, token: "demo") == nil)
        #expect(!roster.isThisMac)
        #expect(await roster.connectToThisMac() == nil)
        #expect(roster.isThisMac)
        #expect(store.read() == .thisMac)
        // The server's token did not stay behind.
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecMatchLimit: kSecMatchLimitOne]
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
        // And back.
        #expect(await roster.connect(address: remote.address, token: "demo") == nil)
        #expect(!roster.isThisMac)
        #expect(roster.gatewayAddress == remote.address)
        #expect(store.read() == .gateway(SavedGateway(address: "http://\(remote.address)", token: "demo")))
        // Straight after disconnecting.
        await roster.signOut()
        #expect(await roster.connectToThisMac() == nil)
        #expect(roster.phase == .loaded)
    }

    /// Disconnecting while a connection to this Mac is being made calls it off, even when
    /// Hermes had already let it in.
    @Test func disconnectingCallsOffAConnectionToThisMacStillBeingMade() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "tickets")
        let (command, remove) = try hermesCommand(sayingGatewayIsAt: "http://\(pretend.address)")
        defer { remove() }
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false, hermesCommand: command)
        roster.beforeSavingThisMac = { [weak roster] in await roster?.signOut() }
        #expect(await roster.connectToThisMac()?.text == "Disconnected.")
        #expect(roster.phase == .needsSetup)
        #expect(!roster.isThisMac)
        #expect(roster.bots.isEmpty)
        #expect(store.read() == .nothing)
        // And it can be connected to afterwards as usual.
        roster.beforeSavingThisMac = nil
        #expect(await roster.connectToThisMac() == nil)
        #expect(store.read() == .thisMac)
    }

    // MARK: A username and password

    private func found(at pretend: SendingTests.Pretend) async throws -> GatewayProbe.Found {
        guard case .found(let found) = await GatewayProbe.look(at: pretend.address) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return found
    }

    @Test func signingInConnectsAndKeepsNoPassword() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "password-only")
        let found = try await found(at: pretend)
        #expect(found.passwordProvider == "basic")
        let (store, service, cleanUp) = namedStore()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)

        // Wrong, and nothing is saved; the screen is told it was the password.
        let wrong = await roster.signIn(to: found, username: "tester", password: "not-it")
        #expect(wrong?.text == "That username or password wasn't accepted.")
        #expect(wrong?.tokenRefused == true)
        #expect(await roster.signIn(to: found, username: " ", password: "hunter2")?.text == "Enter your username and password.")
        #expect(store.read() == .nothing)

        #expect(await roster.signIn(to: found, username: " tester ", password: "hunter2") == nil)
        #expect(roster.phase == .loaded)
        #expect(roster.isSignedIn)
        #expect(roster.gatewayAddress == pretend.address)
        guard case .signedIn(let saved) = store.read() else {
            Issue.record("The sign-in was not saved")
            return
        }
        #expect(saved.username == "tester")
        #expect(saved.provider == "basic")
        #expect(saved.address == "http://\(pretend.address)")
        // The password is nowhere: not in preferences, and not what the Keychain holds.
        #expect(saved.refreshToken != "hunter2")
        #expect(!UserDefaults(suiteName: service)!.dictionaryRepresentation().values.contains { "\($0)".contains("hunter2") })
        // Chats are read over HTTP as the person signed in.
        let bot = try #require(roster.mainBot)
        #expect(try await !roster.messages(for: bot).isEmpty)

        // The next launch renews the session and saves what it was given in its place.
        let again = RosterModel(store: store, readsEnvironment: false)
        #expect(again.phase != .needsSetup)
        await again.load()
        #expect(again.phase == .loaded)
        #expect(again.isSignedIn)
        #expect(try await !again.messages(for: bot).isEmpty)
        guard case .signedIn(let renewed) = store.read() else {
            Issue.record("The renewed sign-in was not saved")
            return
        }
        #expect(renewed.refreshToken != saved.refreshToken)
        #expect(renewed.username == "tester")

        // Disconnecting forgets it, and a renewal after that saves nothing.
        await again.signOut()
        #expect(store.read() == .nothing)
        #expect(!again.isSignedIn)
    }

    /// A session that lasts no time at all is renewed for every use, and each renewal is kept.
    @Test func aSessionRunningOutIsRenewedAsItGoes() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "password-only", extra: "1")
        let found = try await found(at: pretend)
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(await roster.signIn(to: found, username: "tester", password: "hunter2") == nil)
        guard case .signedIn(let first) = store.read() else {
            Issue.record("Not saved")
            return
        }
        let bot = try #require(roster.mainBot)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(try await !roster.messages(for: bot).isEmpty)
        #expect(try await !roster.messages(for: bot).isEmpty)
        guard case .signedIn(let later) = store.read() else {
            Issue.record("Not saved")
            return
        }
        #expect(later.refreshToken != first.refreshToken)
    }

    /// Connecting can renew a session that has almost run out before setup has saved
    /// anything. What is saved must be what the session then holds: the token first given
    /// has been used, and a launch with it would be turned away.
    @Test func whatIsSavedAtSignInIsWhatTheSessionHoldsThen() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "password-only", extra: "1")
        let found = try await found(at: pretend)
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(await roster.signIn(to: found, username: "tester", password: "hunter2") == nil)
        // Straight away, with nothing read in between to put it right.
        let again = RosterModel(store: store, readsEnvironment: false)
        await again.load()
        #expect(again.phase == .loaded)
    }

    /// A gateway whose clock is ahead turns away a token this Mac thinks is good. It is
    /// renewed and the read made again, not taken for the end of the sign-in.
    @Test func aTokenTurnedAwayEarlyIsRenewedAndNotTakenForTheEnd() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "password-only", extra: "-1")
        let found = try await found(at: pretend)
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(await roster.signIn(to: found, username: "tester", password: "hunter2") == nil)
        let bot = try #require(roster.mainBot)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(try await !roster.messages(for: bot).isEmpty)
        // And a launch after it, when the socket's pass is what is asked for first.
        try await Task.sleep(for: .milliseconds(1300))
        let again = RosterModel(store: store, readsEnvironment: false)
        await again.load()
        #expect(again.phase == .loaded)
    }

    /// A gateway that cannot be reached at launch is that, and not an ended sign-in: the
    /// saved sign-in is left alone for when it can be.
    @Test func anUnreachableGatewayIsNotTakenForAnEndedSignIn() async throws {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let saved = SavedSignIn(address: "http://127.0.0.1:9", provider: "basic", username: "tester", refreshToken: "still-good")
        try store.save(saved)
        let roster = RosterModel(store: store, readsEnvironment: false)
        await roster.load()
        #expect(roster.phase == .failed("Couldn't reach the gateway."))
        #expect(store.read() == .signedIn(saved))
    }

    /// A renewal that arrives after the gateway was left, or after another took its place,
    /// saves nothing: the check is made where the saving is done.
    @Test func aRenewalNeverUndoesADisconnectOrOverwritesWhatCameAfter() async throws {
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let keeper = SavedGatewayKeeper(store: store)
        let first = SavedSignIn(address: "https://one.example.com", provider: "basic", username: "sam", refreshToken: "one")
        let renewed = SavedSignIn(address: "https://one.example.com", provider: "basic", username: "sam", refreshToken: "two")
        let generation = try await keeper.save(first, plainHTTPChosen: false)
        #expect(try await keeper.keep(renewed, for: generation))
        #expect(store.read() == .signedIn(renewed))
        // Left.
        try await keeper.clear()
        #expect(try await !keeper.keep(first, for: generation))
        #expect(store.read() == .nothing)
        // Another in its place.
        let other = SavedGateway(address: "https://two.example.com", token: "t")
        let next = try await keeper.save(other, plainHTTPChosen: false)
        #expect(try await !keeper.keep(renewed, for: generation))
        #expect(store.read() == .gateway(other))
        #expect(next != generation)
    }

    @Test func aSignInThatHasEndedIsSaidToBeThat() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "password-only")
        let (store, cleanUp) = store()
        defer { cleanUp() }
        try store.save(SavedSignIn(address: "http://\(pretend.address)", provider: "basic", username: "tester", refreshToken: "long-gone"))
        let roster = RosterModel(store: store, readsEnvironment: false)
        await roster.load()
        #expect(roster.phase == .failed("Your sign-in to this gateway has ended. Disconnect in Settings and sign in again."))
        // Still saved, for the person to disconnect from.
        #expect(store.hasGateway)
    }

    @Test func aTokenAndASignInTakeEachOthersPlace() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "password")
        let found = try await found(at: pretend)
        #expect(found.takesToken == true)
        let (store, cleanUp) = store()
        defer { cleanUp() }
        let roster = RosterModel(store: store, readsEnvironment: false)
        #expect(await roster.connect(address: pretend.address, token: "demo") == nil)
        #expect(!roster.isSignedIn)
        #expect(await roster.signIn(to: found, username: "tester", password: "hunter2") == nil)
        #expect(roster.isSignedIn)
        #expect(await roster.connect(address: pretend.address, token: "demo") == nil)
        #expect(!roster.isSignedIn)
        #expect(store.read() == .gateway(SavedGateway(address: "http://\(pretend.address)", token: "demo")))
    }
}
