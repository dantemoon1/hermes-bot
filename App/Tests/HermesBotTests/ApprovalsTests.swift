import AppKit
import Foundation
import HermesKit
import SwiftUI
import Testing
@testable import HermesBot

/// The approval mode in Settings (issue 43): proved against the gateway's own `profiles.list`,
/// per-bot scoped only, stopping at the first transport failure or cancel, and invalidated on
/// any roster or connection change.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ApprovalsTests {
    typealias Pretend = SendingTests.Pretend

    private func open(_ pretend: Pretend) async -> RosterModel {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        return roster
    }

    private func until(_ what: String, within seconds: Double = 15, _ condition: () async -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !(await condition()) {
            try #require(Date.now < deadline, "Waited \(seconds) s for \(what)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// What the pretend gateway heard back, oldest first.
    private func answers(_ pretend: Pretend) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "http://\(pretend.address)/api/status")!)
        request.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let status = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return status?["answers"] as? [[String: Any]] ?? []
    }

    /// The writes of the approval mode the pretend gateway took, in order.
    private func approvalWrites(_ pretend: Pretend) async throws -> [(profile: String, value: String)] {
        try await answers(pretend).compactMap { heard in
            guard heard["method"] as? String == "config.set",
                  let profile = heard["profile"] as? String,
                  let value = heard["value"] as? String else { return nil }
            return (profile, value)
        }
    }

    /// Drops every open socket on the pretend gateway.
    private func dropSockets(_ pretend: Pretend) async throws {
        var request = URLRequest(url: URL(string: "http://\(pretend.address)/api/drop")!)
        request.httpMethod = "POST"
        request.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: request)
    }

    /// However a reading or change ends, it never stays checking or setting.
    private func finished(_ roster: RosterModel, _ where: SourceLocation = #_sourceLocation) {
        #expect(roster.approvals != .checking, sourceLocation: `where`)
        #expect(!roster.isSettingApprovals, sourceLocation: `where`)
    }

    @Test func theApprovalModeIsShownAndSetForEveryBotAndHiddenWhereUnsupported() async throws {
        let pretend = try await Pretend()
        let roster = await open(pretend)
        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem == nil)

        await roster.setApprovals(.smart)
        finished(roster)
        #expect(roster.approvals == .every(.smart))
        #expect(roster.approvalsProblem == nil)

        await roster.setApprovals(.off)
        finished(roster)
        #expect(roster.approvals == .every(.off))
        #expect(roster.approvalsProblem == nil)

        // Unsupported gateways hide the setting on first discovery.
        for mode in ["no-config", "no-models", "unscoped", "authority"] {
            let otherPretend = try await Pretend(whenBusy: mode)
            let other = await open(otherPretend)
            await other.readApprovals()
            finished(other)
            #expect(other.approvals == .unavailable, "Expected unavailable for \(mode)")
        }
    }

    /// A bot created from another device before Settings opens is not
    /// in this client's cached roster, yet reading and changing MUST include it from `profiles.list`.
    @Test func aBotMadeElsewhereBeforeSettingsOpensIsIncludedInReadsAndChanges() async throws {
        let pretend = try await Pretend()
        let first = await open(pretend)
        let second = await open(pretend)

        // First client sets all current bots to off.
        await first.readApprovals()
        #expect(first.approvals == .every(.manual))
        await first.setApprovals(.off)
        #expect(first.approvals == .every(.off))

        // Another device, which never read the mode, creates a new bot (Hermes's default mode:
        // smart). First client does NOT refresh its roster.
        #expect(await second.createBot(named: "Meal Plans", look: .main) == .made)
        #expect(!first.bots.contains { $0.name == "meal-plans" })

        // First client opens Settings and reads: must see .mixed from the gateway's profiles.list,
        // NOT .every(.off) from its own stale roster.
        await first.readApprovals()
        finished(first)
        #expect(first.approvals == .mixed)

        // First client sets every bot to off without refreshing its cached roster: must write
        // to Meal Plans too, so a second client agrees it is .every(.off), not .mixed.
        await first.setApprovals(.off)
        finished(first)
        #expect(first.approvals == .every(.off))
        await second.readApprovals()
        finished(second)
        #expect(second.approvals == .every(.off))
    }

    /// A bot added on another device while a change is under way (even without this client
    /// refreshing its roster) is caught by the post-readback `profiles.list` bookend.
    @Test func aBotAddedElsewhereDuringAChangeEndsNotConfirmed() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-slow")
        let roster = await open(pretend)
        let before = Set(roster.bots.map(\.name))
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        let change = Task { await roster.setApprovals(.off) }
        try await until("the change to begin") { roster.isSettingApprovals }
        // Another device creates a bot (at Hermes's default, smart); this client does NOT call refreshBots().
        let other = await open(pretend)
        #expect(await other.createBot(named: "Meal Plans", look: .main) == .made)

        await change.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed meanwhile, so not every bot may have it.")
        // Only the bots listed when the change began were written.
        let writes = try await approvalWrites(pretend)
        #expect(writes.map(\.profile).sorted() == before.sorted())
        #expect(writes.allSatisfy { $0.value == "off" })

        // Try Again reads every bot now on the gateway, including the new one -> mixed.
        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .mixed)
    }

    /// A bot deleted elsewhere during a read ends Not confirmed, and Try Again confirms the rest.
    @Test func aBotDeletedElsewhereDuringAReadEndsNotConfirmed() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-slow")
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        let reading = Task { await roster.readApprovals() }
        try await until("the read to begin") { roster.approvals == .checking }
        let other = await open(pretend)
        let garden = try #require(other.bots.first { $0.name == "garden" })
        #expect(await other.delete(garden) == nil)

        await reading.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed while this was read.")

        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem == nil)
    }

    /// Deleting a bot locally (`forget` removes it before
    /// `take` runs) must invalidate a shown `.mixed` or `.every` mode immediately.
    @Test func deletingABotLocallyMakesAShownModeUnconfirmed() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-mixed")
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .mixed)

        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await roster.delete(garden) == nil)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed since this was read.")

        // Try Again now sees all remaining bots agree on manual.
        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem == nil)
    }

    /// Creating a bot locally or hearing of one via `refreshBots` invalidates a shown mode.
    @Test func addingABotLocallyOrRemotelyMakesAShownModeUnconfirmed() async throws {
        let pretend = try await Pretend()
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        #expect(await roster.createBot(named: "Trips", look: .main) == .made)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed since this was read.")

        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        let other = await open(pretend)
        #expect(await other.createBot(named: "Meal Plans", look: .main) == .made)
        #expect(await roster.refreshBots())
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed since this was read.")
    }

    /// After a connection drop and automatic reconnect to a gateway
    /// whose settings differ, an open Settings must NOT keep the old connection's mode.
    @Test func aDroppedConnectionAndAutoReconnectInvalidatesAShownMode() async throws {
        let pretend = try await Pretend()
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        // Drop the socket and change the mode from another client.
        try await dropSockets(pretend)
        let other = await open(pretend)
        await other.setApprovals(.smart)

        // Immediately upon connection loss, the old mode is Not confirmed.
        try await until("approvals invalidated on disconnect", within: 5) { roster.approvals == .unconfirmed }
        // Wait for the automatic reconnect to succeed.
        try await until("auto-reconnect", within: 10) { await roster.isConnectedNow }
        // Still Not confirmed after reconnecting: never keeps the old connection's mode.
        #expect(roster.approvals == .unconfirmed)

        // Try Again reads the new mode from the reconnected gateway.
        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .every(.smart))
    }

    /// Once offered, a readback refused as unsupported (and a later
    /// Try Again refused as unsupported) stays `.unconfirmed` with Try Again — never `.unavailable`.
    @Test func anUnsupportedReadbackAfterAWriteKeepsUnconfirmedAndTryAgain() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-readback-unsupported")
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        await roster.setApprovals(.off)
        finished(roster)
        #expect(roster.approvals == .unconfirmed)

        // Clicking Try Again still gets unsupported, and keeps Try Again rather than hiding the card.
        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
    }

    /// A failed readback (5001) after a write or on a plain read ends Not confirmed, never showing
    /// the previously cached mode.
    @Test func aModeTheGatewayDidNotConfirmIsNotShown() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-readback-fails")
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        await roster.setApprovals(.off)
        finished(roster)
        #expect(roster.approvalsProblem == nil)
        #expect(roster.approvals == .unconfirmed)

        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
    }

    /// Per-bot policy refusal (4030 managed) records the refused bots and reads back what the
    /// gateway still holds.
    @Test func aRefusedChangeShowsWhatTheGatewayStillHas() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-set-refused")
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        await roster.setApprovals(.off)
        finished(roster)
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem?.hasPrefix("Couldn't change it for \(main.title)") == true)
    }

    /// Stop a change at the first transport error or timeout and never
    /// multiply timeouts across bots.
    @Test func aChangeStopsAtTheFirstTimeoutWithoutMultiplyingTimeouts() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-hang-on-set")
        let roster = await open(pretend)
        #expect(roster.bots.count >= 3)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        roster.approvalRequestTimeout = .milliseconds(350)
        let started = ContinuousClock.now
        await roster.setApprovals(.smart)
        let elapsed = ContinuousClock.now - started
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The gateway stopped answering before the change reached every bot.")
        // Only the first bot was attempted; never multiplied by bots.count or readback.
        let writes = try await approvalWrites(pretend)
        #expect(writes.count == 1)
        #expect(elapsed < .milliseconds(1000))
    }

    /// Stop at the first connection drop during a change without
    /// attempting remaining bots.
    @Test func aChangeStopsAtTheFirstDroppedConnection() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-drop-on-set")
        let roster = await open(pretend)
        #expect(roster.bots.count >= 3)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        await roster.setApprovals(.smart)
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "Lost the connection before the change reached every bot.")
        let writes = try await approvalWrites(pretend)
        #expect(writes.count == 1)
    }

    /// Cancelling on the last bot ends cleanly without "Couldn't change it for ".
    @Test func cancellingAChangeOnTheLastBotReportsStoppedNotAnEmptyBotList() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-slow")
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        let botCount = roster.bots.count
        let change = Task { await roster.setApprovals(.smart) }
        // Wait until the writes for all bots before the last have landed, so the last bot is in flight.
        try await until("writes to reach the last bot", within: 10) {
            (try? await approvalWrites(pretend).count) ?? 0 >= botCount - 1
        }
        change.cancel()
        await change.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The change was stopped before it reached every bot.")
        #expect(roster.approvalsProblem?.contains("Couldn't change it for") != true)
    }

    /// Settings opened before the roster has loaded reads again once
    /// the roster finishes loading.
    @Test func settingsOpenedBeforeRosterLoadsReadsAgainOnceLoaded() async throws {
        let pretend = try await Pretend()
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        #expect(roster.phase == .loading)

        // Host SettingsView while the roster is still loading.
        _ = NSApplication.shared
        let window = OnScreenTesting.panel(in: NSRect(x: -10000, y: -10000, width: 520, height: 640))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(roster: roster, close: {}))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        // A direct read before load does not falsely mark the gateway unavailable or stuck checking.
        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .unknown)

        // Now the roster finishes loading: SettingsView's `.task(id: roster.phase)` reads approvals.
        await roster.load()
        try await until("Settings to read approvals once loaded", within: 10) {
            roster.approvals == .every(.manual)
        }
        finished(roster)
        #expect(roster.approvalsProblem == nil)
    }

    @Test func aChangeWithNoGatewayToMakeItEndsNotConfirmedAndCanBeAskedAgain() async throws {
        var pretend = try await Pretend(whenBusy: "tickets")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/fake-hermes.py")
        let command = folder.appendingPathComponent("hermes")
        func sayGatewayIsAt(_ origin: String) throws {
            try Data("#!/bin/sh\nexec /usr/bin/env python3 '\(script.path)' '\(origin)' \"$@\"\n".utf8).write(to: command)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        }
        try sayGatewayIsAt("http://\(pretend.address)")
        let name = "HermesBotTests.\(UUID().uuidString)"
        let store = GatewayStore(suite: name, service: name)
        defer { try? store.clear(); UserDefaults().removePersistentDomain(forName: name) }
        let roster = RosterModel(store: store, readsEnvironment: false, hermesCommand: command)
        #expect(await roster.connectToThisMac() == nil)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        let port = pretend.port
        pretend.process.terminate()
        pretend.process.waitUntilExit()
        try sayGatewayIsAt("none")
        try await until("socket to close", within: 10) { !(await roster.isConnectedNow) }
        await roster.setApprovals(.smart)
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "Couldn't change it: the gateway couldn't be reached.")

        pretend = try await Pretend(port: port, whenBusy: "tickets")
        try sayGatewayIsAt("http://\(pretend.address)")
        await roster.tryApprovalsAgain()
        finished(roster)
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem == nil)
    }

    @Test func aReadingCalledOffEndsNotConfirmedOrHiddenIfNeverOffered() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-slow")
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        let reading = Task { await roster.readApprovals() }
        try await until("the reading to begin") { roster.approvals == .checking }
        reading.cancel()
        await reading.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)

        // The first reading called off before anything answered stays hidden (.unknown), never stuck checking.
        let fresh = await open(pretend)
        let first = Task { await fresh.readApprovals() }
        try await Task.sleep(for: .milliseconds(250))
        first.cancel()
        await first.value
        finished(fresh)
        #expect(fresh.approvals == .unknown)
    }

    @Test func aReadingOvertakenByAChangeLeavesTheChangeToSayWhatIsShown() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-slow")
        let roster = await open(pretend)
        await roster.readApprovals()

        let reading = Task { await roster.readApprovals() }
        try await until("the reading to begin") { roster.approvals == .checking }
        await roster.setApprovals(.smart)
        await reading.value
        finished(roster)
        #expect(roster.approvals == .every(.smart))

        // A reading asked while a change is under way leaves it to the change's own readback.
        let change = Task { await roster.setApprovals(.manual) }
        try await until("the change to begin") { roster.isSettingApprovals }
        await roster.readApprovals()
        #expect(roster.isSettingApprovals)
        #expect(roster.approvals == .checking)
        await change.value
        finished(roster)
        #expect(roster.approvals == .every(.manual))
    }

    @Test func aChangeOvertakenByALoadOrNewConnectionEndsCleanly() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-slow")
        let roster = await open(pretend)
        await roster.readApprovals()

        let change = Task { await roster.setApprovals(.smart) }
        try await until("the change to begin") { roster.isSettingApprovals }
        // A second change meanwhile is ignored.
        await roster.setApprovals(.off)
        #expect(roster.isSettingApprovals)
        // Reload overtakes the change.
        await roster.load()
        await change.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The change was stopped before it reached every bot.")

        // Connected again to the same gateway while a change is on its way: resets cleanly and
        // serializes the next change after the old writes unwind.
        let suite = "HermesBotTests.\(UUID().uuidString)"
        let store = GatewayStore(suite: suite, service: suite)
        defer { try? store.clear(); UserDefaults().removePersistentDomain(forName: suite) }
        let reconnectRoster = RosterModel(store: store, readsEnvironment: false)
        #expect(await reconnectRoster.connect(address: pretend.address, token: "demo") == nil)
        await reconnectRoster.readApprovals()
        let again = Task { await reconnectRoster.setApprovals(.smart) }
        try await until("the second change to begin") { reconnectRoster.isSettingApprovals }
        #expect(await reconnectRoster.connect(address: pretend.address, token: "demo") == nil)
        #expect(!reconnectRoster.isSettingApprovals)
        #expect(reconnectRoster.approvals == .unknown)
        await reconnectRoster.setApprovals(.manual)
        await again.value
        finished(reconnectRoster)
        #expect(reconnectRoster.approvals == .every(.manual))
        let writes = try await approvalWrites(pretend)
        let last = Dictionary(writes.map { ($0.profile, $0.value) }, uniquingKeysWith: { _, later in later })
        #expect(last.values.allSatisfy { $0 == "manual" })
    }

    /// While Settings stays open, a bot created or mode changed
    /// on another client (with NO manual `refreshBots()` and NO `sessions.changed` event) updates
    /// Settings automatically via the quiet periodic recheck, and a gateway failure expires it.
    @Test func openSettingsRechecksRemoteBotAndModeChangesWithoutManualRefresh() async throws {
        let pretend = try await Pretend()
        let first = await open(pretend)
        let second = await open(pretend)
        first.approvalsRecheckInterval = .milliseconds(150)

        // Start with every bot on manual (a new bot starts at Hermes's default, smart).
        await first.setApprovals(.manual)
        #expect(first.approvals == .every(.manual))

        _ = NSApplication.shared
        let window = OnScreenTesting.panel(in: NSRect(x: -10000, y: -10000, width: 520, height: 640))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(roster: first, close: {}))
        window.orderBack(nil)
        window.layoutIfNeeded()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        // Wait for initial read on open to run and confirm .every(.smart).
        try await until("initial open read", within: 5) { first.approvals == .every(.manual) }

        // Second client creates a new bot (default manual). First client does NOT call refreshBots().
        #expect(await second.createBot(named: "Meal Plans", look: .main) == .made)
        try await until("Settings to notice remote bot creation", within: 5) { first.approvals == .mixed }

        // Second client changes every bot to off. First client does NOT call refreshBots().
        await second.setApprovals(.off)
        try await until("Settings to notice remote mode change", within: 5) { first.approvals == .every(.off) }
    }

    /// If the final `profiles.list` bookend captured the old roster and arrives
    /// after a refresh already applied a newer roster, `readApprovals()` must end `.unconfirmed`
    /// rather than publishing the stale claim.
    @Test func aDelayedFinalBookendCannotPublishAfterANewerRosterWasObserved() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-stale-bookend")
        let roster = await open(pretend)
        let other = await open(pretend)

        let reading = Task { await roster.readApprovals() }
        // Let beforeBots and per-bot config.get finish so the delayed afterBots snapshot is held.
        try await Task.sleep(for: .milliseconds(250))
        // Another client adds a bot and our roster observes it before the delayed bookend returns.
        #expect(await other.createBot(named: "Meal Plans", look: .main) == .made)
        #expect(await roster.refreshBots())
        #expect(roster.bots.contains { $0.name == "meal-plans" })

        await reading.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvals != .every(.manual))
    }

    /// A newer roster reading that contradicts the in-flight check counts even
    /// when it leaves the cached roster as it was. The gateway gains a bot before the check (the
    /// cached roster never hears of it), both bookends list it, it is deleted, and a refresh
    /// matching the cached roster arrives before the delayed final bookend.
    @Test func aRefreshMatchingTheCachedRosterStillContradictsAnInFlightCheck() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-stale-bookend")
        let roster = await open(pretend)
        let other = await open(pretend)
        let cached = Set(roster.bots.map(\.name))

        #expect(await other.createBot(named: "Meal Plans", look: .main) == .made)
        #expect(!roster.bots.contains { $0.name == "meal-plans" })

        let reading = Task { await roster.readApprovals() }
        // Both bookends' lists hold the new bot; the final one is held back.
        try await Task.sleep(for: .milliseconds(250))
        let added = try #require(other.bots.first { $0.name == "meal-plans" })
        #expect(await other.delete(added) == nil)
        #expect(await roster.refreshBots())
        #expect(Set(roster.bots.map(\.name)) == cached)

        await reading.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed while this was read.")
    }

    /// A quiet recheck keeps saying which bots a change could not reach while
    /// the gateway still does not hold what was asked for; asking again clears it.
    @Test func aQuietRecheckKeepsSayingWhereAChangeDidNotGo() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-set-refused")
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        await roster.readApprovals()
        await roster.setApprovals(.off)
        #expect(roster.approvals == .every(.manual))
        let refused = "Couldn't change it for \(main.title)"
        #expect(roster.approvalsProblem?.hasPrefix(refused) == true)

        await roster.recheckApprovals()
        finished(roster)
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem?.hasPrefix(refused) == true)

        // A reading the person did not ask for (Settings opening, the roster loading again)
        // keeps it too.
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem?.hasPrefix(refused) == true)

        // Try Again is the person moving on: what the gateway holds is shown on its own.
        await roster.tryApprovalsAgain()
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem == nil)
    }

    /// A `profiles.list` answer that never reaches the roster
    /// (here, the fresh read a rename makes before saving) still counts against a check.
    @Test func aListReadThatNeverReachesTheRosterStillContradictsAnInFlightCheck() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-stale-bookend")
        let roster = await open(pretend)
        let other = await open(pretend)
        let main = try #require(roster.mainBot)

        #expect(await other.createBot(named: "Meal Plans", look: .main) == .made)
        let reading = Task { await roster.readApprovals() }
        try await Task.sleep(for: .milliseconds(250))
        let added = try #require(other.bots.first { $0.name == "meal-plans" })
        #expect(await other.delete(added) == nil)
        #expect(await roster.update(main, title: "Home") == nil)

        await reading.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed while this was read.")
    }

    /// A bot list heard on the connection after a mode was confirmed withdraws
    /// the claim when it lists other bots, even when it never reaches the roster; so one heard in
    /// the moment a check confirms cannot leave a stale claim standing.
    @Test func aBotListHeardAfterConfirmingWithdrawsTheClaim() async throws {
        let pretend = try await Pretend()
        let roster = await open(pretend)
        let other = await open(pretend)
        let main = try #require(roster.mainBot)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        #expect(await other.createBot(named: "Meal Plans", look: .main) == .made)
        #expect(await roster.update(main, title: "Home") == nil)
        try await until("the claim to be withdrawn", within: 5) { roster.approvals == .unconfirmed }
        #expect(roster.approvalsProblem == "The bots on the gateway changed since this was read.")
    }

    /// A bot list heard after a check's last read and before it confirms
    /// stops it, though no claim was shown to withdraw when its word came.
    @Test func aBotListHeardJustBeforeConfirmingStopsTheCheck() async throws {
        let pretend = try await Pretend()
        let roster = await open(pretend)
        let other = await open(pretend)
        let main = try #require(roster.mainBot)
        roster.approvalsWillCommit = {
            roster.approvalsWillCommit = nil
            #expect(await other.createBot(named: "Meal Plans", look: .main) == .made)
            #expect(await roster.update(main, title: "Home") == nil)
            // Long enough for the list's word to reach the roster before the check goes on.
            try? await Task.sleep(for: .milliseconds(300))
        }
        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed while this was read.")
    }

    /// What kept the last change from a bot is still said beside the reason a
    /// shown mode stopped being confirmed.
    @Test func aChangesNoteIsSaidBesideWhyAModeIsNoLongerConfirmed() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-set-refused")
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        await roster.readApprovals()
        await roster.setApprovals(.off)
        let refused = try #require(roster.approvalsProblem)
        #expect(refused.hasPrefix("Couldn't change it for \(main.title)"))

        roster.approvalsChangedInChat()
        #expect(roster.approvals == .unconfirmed)
        // A chat change is the person moving on too, so the note goes with it.
        #expect(roster.approvalsProblem == "A bot's approval mode was changed in chat.")

        await roster.setApprovals(.off)
        #expect(roster.approvalsProblem == refused)
        try await dropSockets(pretend)
        try await until("the mode to stop being confirmed", within: 10) { roster.approvals == .unconfirmed }
        #expect(roster.approvalsProblem == "Lost the connection to the gateway. \(refused)")
    }

    /// A change some bots refused, stopped by something else before it is
    /// confirmed, says both, and leaves only the refusal as its note.
    @Test func aRefusedChangeThatIsInterruptedSaysBoth() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-set-refused")
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        await roster.readApprovals()
        roster.approvalsWillCommit = {
            roster.approvalsWillCommit = nil
            roster.approvalsChangedInChat()
        }
        await roster.setApprovals(.off)
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        let said = try #require(roster.approvalsProblem)
        #expect(said.hasPrefix("A bot's approval mode was changed in chat. Couldn't change it for \(main.title)"))

        // What stays said through a recheck is only which bots refused.
        await roster.readApprovals()
        #expect(roster.approvalsProblem?.hasPrefix("Couldn't change it for \(main.title)") == true)
    }

    /// While Settings writes a mode, no message goes in an open chat, as
    /// while chat's own `/approvals` is on its way, so none runs under the mode being left.
    @Test func noMessageGoesWhileSettingsChangesTheMode() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-slow")
        let roster = await open(pretend)
        let bot = try #require(roster.mainBot)
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        await roster.readApprovals()

        let change = Task { await roster.setApprovals(.smart) }
        try await until("the change to begin", within: 5) { roster.isSettingApprovals }
        #expect(chat.approvalsHeld)
        chat.draft = "quick hello"
        #expect(!chat.send(to: bot, through: roster))
        #expect(chat.draft == "quick hello")

        await change.value
        finished(roster)
        #expect(!chat.approvalsHeld)
    }

    /// A chat made while a change is written, here a new bot's, holds its
    /// messages too, since the hold is the roster's and not a list of chats taken at the start.
    @Test func aChatMadeWhileTheModeIsWrittenIsHeldToo() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-hang-on-set")
        let roster = await open(pretend)
        roster.approvalRequestTimeout = .seconds(3)
        await roster.readApprovals()

        let change = Task { await roster.setApprovals(.smart) }
        try await until("the change to begin", within: 5) { roster.isSettingApprovals }
        #expect(await roster.createBot(named: "Meal Plans", look: .main) == .made)
        let made = try #require(roster.bots.first { $0.name == "meal-plans" })
        #expect(roster.chat(for: made).approvalsHeld)

        await change.value
        try await until("the hold to lift", within: 5) { !roster.chat(for: made).approvalsHeld }
    }

    /// Hermes starts a new bot at its default mode, so a bot made here
    /// is given the mode every bot was shown to have, and every bot has it again.
    @Test func aBotMadeHereIsGivenTheModeEveryBotHas() async throws {
        let pretend = try await Pretend()
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        #expect(await roster.createBot(named: "Meal Plans", look: .main) == .made)
        let made = try #require(roster.bots.first { $0.name == "meal-plans" })
        try await until("the mode to be written", within: 5) { !roster.chat(for: made).approvalsHeld }

        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))
    }

    /// A bot that refused the change is still named when a later bot stops
    /// it, and stays as the note afterwards.
    @Test func aRefusalBeforeAStopIsStillSaid() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-refuse-then-hang")
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        try #require(roster.bots.count > 1)
        roster.approvalRequestTimeout = .milliseconds(300)
        await roster.readApprovals()

        await roster.setApprovals(.off)
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        let said = try #require(roster.approvalsProblem)
        #expect(said.hasPrefix("The gateway stopped answering before the change reached every bot."))
        #expect(said.contains("Couldn't change it for \(main.title)."))

        await roster.readApprovals()
        #expect(roster.approvalsProblem == "Couldn't change it for \(main.title).")
    }

    /// Two bots made one after another are both given the mode, though
    /// the first one's making leaves what is shown Not confirmed until Settings reads again.
    @Test func twoBotsMadeInTurnAreBothGivenTheMode() async throws {
        let pretend = try await Pretend()
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        #expect(await roster.createBot(named: "Meal Plans", look: .main) == .made)
        #expect(roster.approvals == .unconfirmed)
        #expect(await roster.createBot(named: "Running", look: .main) == .made)
        let made = try #require(roster.bots.first { $0.name == "running" })
        try await until("the modes to be written", within: 5) { !roster.chat(for: made).approvalsHeld }

        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))
    }

    /// A check stopped by a chat `/approvals` change says so, not that the bots changed.
    @Test func aCheckStoppedByAChatChangeSaysWhy() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-slow")
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))
        let reading = Task { await roster.readApprovals() }
        try await Task.sleep(for: .milliseconds(200))
        roster.approvalsChangedInChat()
        await reading.value
        finished(roster)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "A bot's approval mode was changed in chat.")
    }

    /// A first read that fails for a moment does not hide the
    /// setting for the rest of the visit; the quiet recheck asks again and finds it.
    @Test func aFirstReadThatFailsForAMomentIsAskedAgainQuietly() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-hang-once")
        let roster = await open(pretend)
        roster.approvalRequestTimeout = .milliseconds(300)

        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .unknown)

        await roster.recheckApprovals()
        finished(roster)
        #expect(roster.approvals == .every(.manual))
        #expect(roster.approvalsProblem == nil)
    }

    /// Running `/approvals <mode>` in chat invalidates a confirmed
    /// mode in Settings immediately and upon completion, without needing a roster refresh.
    @Test func changingApprovalsViaChatSlashCommandInvalidatesSettings() async throws {
        let pretend = try await Pretend()
        let roster = await open(pretend)
        await roster.readCommands()
        let bot = try #require(roster.mainBot)
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)

        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        chat.draft = "/approvals smart"
        chat.submit(to: bot, through: roster)
        // Invalidated immediately on start, and remains unconfirmed once the slash command lands.
        #expect(roster.approvals == .unconfirmed)
        try await until("slash command to finish", within: 10) { chat.approvalsChanging == 0 }
        #expect(roster.approvals == .unconfirmed)

        // Try Again now reads the updated mixed state from the gateway.
        await roster.readApprovals()
        finished(roster)
        #expect(roster.approvals == .mixed)
    }

    /// A first-discovery read overtaken by `load()` while awaiting
    /// `keepsSettingsPerBot()` or mid-read must stay `.unknown` (never `.unavailable` or `.unconfirmed`).
    @Test func anOvertakenFirstDiscoveryReadDoesNotCommitUnavailableOrOffered() async throws {
        // Case 1: overtaken during keepsSettingsPerBot() on a late-greeting session authority.
        let authPretend = try await Pretend(whenBusy: "authority+late-ready")
        let authRoster = await open(authPretend)
        let firstAuth = Task { await authRoster.readApprovals() }
        try await Task.sleep(for: .milliseconds(50))
        await authRoster.load()
        await firstAuth.value
        finished(authRoster)
        #expect(authRoster.approvals == .unknown)

        // Case 2: overtaken by load() while bot 1's first config.get (0.5 s) is still in flight.
        let slowPretend = try await Pretend(whenBusy: "approvals-slow")
        let slowRoster = await open(slowPretend)
        let firstSlow = Task { await slowRoster.readApprovals() }
        try await Task.sleep(for: .milliseconds(200))
        await slowRoster.load()
        await firstSlow.value
        finished(slowRoster)
        #expect(slowRoster.approvals == .unknown)
    }

    /// An uncertain `delete(_:)` failure where `refreshBots()` also fails
    /// (with the socket still open) must still invalidate a confirmed approval mode.
    @Test func anUncertainDeleteFailureWithFailedRefreshInvalidatesApprovals() async throws {
        let pretend = try await Pretend(whenBusy: "approvals-uncertain-delete")
        let roster = await open(pretend)
        await roster.readApprovals()
        #expect(roster.approvals == .every(.manual))

        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let problem = await roster.delete(garden)
        #expect(problem != nil)
        #expect(await roster.isConnectedNow)
        #expect(roster.approvals == .unconfirmed)
        #expect(roster.approvalsProblem == "The bots on the gateway changed since this was read.")
    }
}
