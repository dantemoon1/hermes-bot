import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// A bot's row menu: Pin, and Mark as Unread, which never moves back how far a chat was
/// read. Against the pretend gateway; a second roster stands for another device.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RowMenuTests {
    private func open(_ pretend: SendingTests.Pretend, selecting id: String = "default") async throws -> RosterModel {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        roster.selectedID = id
        let bot = try #require(roster.bots.first { $0.id == id })
        await roster.chat(for: bot).load(bot, from: roster)
        return roster
    }

    private func soon(_ what: String, within seconds: Double = 10, _ isSo: () async -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !(await isSo()) {
            try #require(Date.now < deadline, "Still waiting after \(seconds) seconds: \(what)")
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Our notes on a bot as the gateway holds them, read as another device would.
    private func held(_ id: String, at pretend: SendingTests.Pretend) async throws -> Bot {
        let other = RosterModel(gateway: (pretend.address, "demo"))
        await other.load()
        return try #require(other.bots.first { $0.id == id })
    }

    /// Waits until the first reading of every bot has been noted (two seconds after load),
    /// so that the notes compared are settled.
    private func settled(_ id: String, at pretend: SendingTests.Pretend) async throws {
        try await soon("the bot's reading is noted") { (try? await held(id, at: pretend).readThrough) != nil }
    }

    @Test func pinnedBotsComeFirstUnderTheMainOneInTheirOwnOrder() throws {
        let names = ["default", "garden", "books", "trips", "notes"]
        let bots = try names.map { name in
            try JSONDecoder().decode(Bot.self, from: Data(#"{"name": "\#(name)", "is_default": \#(name == "default")}"#.utf8))
        }
        let pinned: Set = ["trips", "notes"]
        #expect(RosterModel.others(of: bots, pinned: { pinned.contains($0.id) }).map(\.id) == ["trips", "notes", "garden", "books"])
        #expect(RosterModel.others(of: bots, pinned: { _ in false }).map(\.id) == ["garden", "books", "trips", "notes"])
    }

    /// Taking a mark off takes only one made before the look: one another device made since
    /// stays, even though this device asked to take a mark off.
    @Test func takingAMarkOffLeavesOneMadeSinceTheLook() {
        let look = Date(timeIntervalSince1970: 1_000)
        var older: [String: JSONValue] = ["title": .string("Trips"), "unread": .number(900), "read": .number(800)]
        RosterModel.apply(.off(before: look), to: &older)
        #expect(older == ["title": .string("Trips"), "read": .number(800)])
        var newer: [String: JSONValue] = ["unread": .number(1_100)]
        RosterModel.apply(.off(before: look), to: &newer)
        #expect(newer == ["unread": .number(1_100)])
        var none: [String: JSONValue] = [:]
        RosterModel.apply(.on(look), to: &none)
        #expect(none == ["unread": .number(1_000)])
    }

    @Test func aPinIsKeptOnTheGatewayBesideEverythingElseAndUnpinningTakesItOut() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = try await open(pretend)
        try await settled("trips", at: pretend)
        let before = try await held("trips", at: pretend)
        let trips = try #require(roster.bots.first { $0.id == "trips" })
        #expect(await roster.pin(trips, true) == nil)
        #expect(roster.otherBots.map(\.id) == ["trips", "garden", "books"])
        // ⌘1–9 go by the same order.
        #expect(BotOrder.bot(at: 2, in: roster.order) == "trips")
        let there = try await held("trips", at: pretend)
        #expect(there.isPinned)

        #expect(await roster.pin(try #require(roster.bots.first { $0.id == "trips" }), false) == nil)
        #expect(roster.otherBots.map(\.id) == ["garden", "books", "trips"])
        let after = try await held("trips", at: pretend)
        #expect(!after.isPinned)
        #expect(after.uiMeta["hermes-bot"]?["pinned"] == nil)
        // Everything else in our notes, and Hermes's own app's notes, exactly as they were.
        #expect(after.uiMeta == before.uiMeta)
        #expect(after.uiMeta["hermes-bots"]?["title"]?.stringValue == "Trips")
    }

    @Test func markedUnreadShowsEverywhereWithoutMovingReadBackAndGoesWhenLookedAt() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = try await open(pretend)
        try await settled("garden", at: pretend)
        // Another device, open from before the mark.
        let other = try await open(pretend)
        let before = try await held("garden", at: pretend).readThrough
        #expect(!roster.unread.contains("garden"))

        let garden = try #require(roster.bots.first { $0.id == "garden" })
        #expect(await roster.markAsUnread(garden) == nil)
        #expect(roster.unread.contains("garden"))
        let marked = try await held("garden", at: pretend)
        #expect(marked.markedUnread != nil)
        // How far it was read is just as it was: another device goes by it.
        #expect(marked.readThrough == before)
        // The other device shows the dot once it reads the roster again.
        _ = await other.refreshBots()
        #expect(other.unread.contains("garden"))

        // Read in again, it keeps the mark; turned to, the mark goes, here and on the gateway.
        _ = await roster.refreshBots()
        #expect(roster.unread.contains("garden"))
        roster.selectedID = "garden"
        await roster.chat(for: garden).load(garden, from: roster)
        #expect(!roster.unread.contains("garden"))
        try await soon("the mark is taken off on the gateway") {
            guard let bot = try? await held("garden", at: pretend) else { return false }
            return bot.markedUnread == nil
        }
        #expect(try await held("garden", at: pretend).readThrough.map { $0 >= before! } == true)

        // The other device, which never turned to it, shows no dot once it reads the roster
        // again: the mark is gone.
        _ = await other.refreshBots()
        #expect(!other.unread.contains("garden"))
    }

    /// Two devices open at once: one marks, the other has not heard of it yet when it turns
    /// to the bot. Once it does hear, the mark is taken off, since it has looked since.
    @Test func aDeviceThatLookedSinceTheMarkTakesItOffWhenItHears() async throws {
        let pretend = try await SendingTests.Pretend()
        let marker = try await open(pretend)
        let looker = try await open(pretend)
        try await settled("trips", at: pretend)
        #expect(await marker.markAsUnread(try #require(marker.bots.first { $0.id == "trips" })) == nil)
        try await Task.sleep(for: .milliseconds(50))
        looker.selectedID = "trips"
        looker.selectedID = "default"
        _ = await looker.refreshBots()
        #expect(!looker.unread.contains("trips"))
        try await soon("the mark is taken off on the gateway") {
            guard let bot = try? await held("trips", at: pretend) else { return false }
            return bot.markedUnread == nil
        }
        // And the device that made it, reading the roster again, shows no dot either.
        _ = await marker.refreshBots()
        #expect(!marker.unread.contains("trips"))
    }

    /// Marked while it is the chat showing: the dot stays, through the roster being read
    /// again, until the person turns away and back.
    @Test func theChatShowingKeepsItsMarkUntilTurnedToAgain() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = try await open(pretend, selecting: "trips")
        let trips = try #require(roster.selected)
        #expect(await roster.markAsUnread(trips) == nil)
        #expect(roster.unread.contains("trips"))
        _ = await roster.refreshBots()
        #expect(roster.unread.contains("trips"))
        // Mark as Read takes it off without turning to it.
        #expect(await roster.markAsRead(try #require(roster.selected)) == nil)
        #expect(!roster.unread.contains("trips"))
        #expect(try await held("trips", at: pretend).markedUnread == nil)

        #expect(await roster.markAsUnread(try #require(roster.selected)) == nil)
        roster.selectedID = "garden"
        #expect(roster.unread.contains("trips"))
        roster.selectedID = "trips"
        #expect(!roster.unread.contains("trips"))
    }

    /// Another device marks a bot, and this one has not read the roster since: Mark as Read
    /// here still takes that mark off, since it was made before the ask.
    @Test func markAsReadTakesOffAMarkThisDeviceHadNotHeardOf() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = try await open(pretend)
        let other = try await open(pretend)
        try await settled("garden", at: pretend)
        #expect(await other.markAsUnread(try #require(other.bots.first { $0.id == "garden" })) == nil)
        #expect(!roster.unread.contains("garden"))
        try await Task.sleep(for: .milliseconds(20))

        #expect(await roster.markAsRead(try #require(roster.bots.first { $0.id == "garden" })) == nil)
        #expect(!roster.unread.contains("garden"))
        #expect(try await held("garden", at: pretend).markedUnread == nil)
        _ = await roster.refreshBots()
        #expect(!roster.unread.contains("garden"))
    }

    /// A gateway that answers but says it kept nothing: a pin the person asked for is
    /// refused and said, and pins, marks and names are no longer offered.
    /// Taking a mark off, the app's
    /// own doing, puts nothing away.
    @Test func aGatewayThatSaysItKeptNothingPutsEditingAwayOnlyWhenAsked() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "not-kept")
        let roster = try await open(pretend)
        // The first readings are noted two seconds on, and not kept: nothing is put away.
        try await Task.sleep(for: .seconds(3))
        #expect(!roster.cannotEditBots)
        let trips = try #require(roster.bots.first { $0.id == "trips" })
        let problem = await roster.pin(trips, true)
        #expect(problem?.contains("didn't keep") == true)
        #expect(!roster.isPinned(trips))
        #expect(roster.cannotEditBots)
    }

    /// A gateway that could not be reached is not a refusal: what is offered stays.
    @Test func aSaveThatDoesNotGetThroughPutsNothingAway() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = try await open(pretend)
        let trips = try #require(roster.bots.first { $0.id == "trips" })
        pretend.process.terminate()
        pretend.process.waitUntilExit()
        let problem = await roster.pin(trips, true)
        #expect(problem != nil)
        #expect(!roster.isPinned(trips))
        #expect(!roster.cannotEditBots)
    }

    /// A Mark as Read the gateway will not keep gives the dot back, and is said.
    @Test func aMarkAsReadThatDoesNotStayGivesTheDotBack() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-edits")
        let roster = try await open(pretend)
        // Garden speaks while another device is talking to it.
        let other = try await open(pretend, selecting: "garden")
        let chat = other.chat(for: try #require(other.selected))
        chat.draft = "quick nudge garden please"
        chat.send(to: try #require(other.selected), through: other)
        try await soon("Garden is unread") { roster.unread.contains("garden") }

        let garden = try #require(roster.bots.first { $0.id == "garden" })
        let problem = await roster.markAsRead(garden)
        #expect(problem?.contains("pins and marks") == true)
        #expect(roster.unread.contains("garden"))
        // Asked for by the person and refused: no longer offered.
        #expect(roster.cannotEditBots)
    }
}
