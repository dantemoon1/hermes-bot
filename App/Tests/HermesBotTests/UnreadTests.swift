import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// Which bots have said something not yet looked at, against the pretend gateway. There,
/// a message holding "nudge garden" makes the Garden bot speak unasked once it is answered.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct UnreadTests {
    private func open(_ pretend: SendingTests.Pretend) async throws -> (RosterModel, Bot, ChatModel) {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let main = try #require(roster.mainBot)
        roster.selectedID = main.id
        let chat = roster.chat(for: main)
        await chat.load(main, from: roster)
        return (roster, main, chat)
    }

    /// Turns to a bot as clicking its row does: it is chosen, and its chat is read in.
    private func show(_ id: String, in roster: RosterModel) async throws {
        roster.selectedID = id
        let bot = try #require(roster.bots.first { $0.id == id })
        await roster.chat(for: bot).load(bot, from: roster)
    }

    private func soon(_ what: String, within seconds: Double = 10, _ isSo: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !isSo() {
            try #require(Date.now < deadline, "Still waiting after \(seconds) seconds: \(what)")
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Sends from an app of its own, as another device would, so the roster being watched
    /// is asked nothing and can only know by hearing the gateway.
    private func elsewhere(_ pretend: SendingTests.Pretend, say text: String, to botID: String = "default") async throws {
        let (other, _, _) = try await open(pretend)
        let bot = try #require(other.bots.first { $0.id == botID })
        other.selectedID = bot.id
        let chat = other.chat(for: bot)
        await chat.load(bot, from: other)
        chat.draft = text
        chat.send(to: bot, through: other)
        try await soon("the other app's message is answered") { !chat.isWorking }
    }

    @Test func aBotThatSpeaksUnaskedIsUnreadUntilItsChatIsLookedAt() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, _, _) = try await open(pretend)
        // Nothing is unread on first sight: there is no telling how far anything was read.
        #expect(roster.unread.isEmpty)

        // Garden, which has a chat, and Reading List, which has never said a word.
        try await elsewhere(pretend, say: "quick nudge garden please")
        try await elsewhere(pretend, say: "quick nudge books please")
        try await soon("Garden and Reading List are unread") { roster.unread.isSuperset(of: ["garden", "books"]) }
        #expect(roster.previews["garden"] == "Your routine ran. Nothing needs you.")

        // Chosen but not yet on screen, it is still unread; read in, it is read.
        roster.selectedID = "garden"
        #expect(roster.unread.contains("garden"))
        try await show("garden", in: roster)
        #expect(!roster.unread.contains("garden"))
        #expect(roster.unread.contains("books"))
    }

    /// The window closed and opened again loads the roster afresh on the connection it has.
    @Test func liveUpdatesGoOnAfterTheRosterIsLoadedAgain() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, _, _) = try await open(pretend)
        await roster.load()
        try await elsewhere(pretend, say: "quick nudge garden please")
        try await soon("Garden is unread") { roster.unread.contains("garden") }
        // And once more, since the watch of the first load has by now stood down.
        try await show("garden", in: roster)
        try await show("default", in: roster)
        try await elsewhere(pretend, say: "quick nudge garden again")
        try await soon("Garden is unread again") { roster.unread.contains("garden") }
    }

    /// A reading waiting its two seconds when the roster is loaded again is not lost, and
    /// does not stop later ones from being noted.
    @Test func aReadingIsStillNotedWhenTheRosterIsLoadedAgainMeanwhile() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, _, _) = try await open(pretend)
        try await show("garden", in: roster)
        await roster.load()
        try await show("garden", in: roster)
        try await soon("Garden's reading is saved") {
            roster.bots.first { $0.id == "garden" }?.readThrough != nil
        }
    }

    @Test func whatIsSaidInTheChatShowingAppearsThereAndIsThenRead() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, main, chat) = try await open(pretend)
        let before = chat.items.count
        // Said to the main bot from another device, while this app shows that chat and sends nothing.
        try await elsewhere(pretend, say: "quick hello from the phone")
        // All the while, the chat being read carries no dot, not even for a moment.
        var flashed = false
        try await soon("the exchange is on screen") {
            if roster.unread.contains(main.id) { flashed = true }
            return chat.items.count > before
        }
        #expect(!flashed)
        try await soon("it is read") { !roster.unread.contains(main.id) }
        #expect(chat.items.contains { if case .user(_, let text) = $0 { text == "quick hello from the phone" } else { false } })
    }

    @Test func theFirstWordInAnEmptyChatThatIsShowingAppearsThere() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, _, _) = try await open(pretend)
        // Reading List has never said anything, and its empty chat is on screen.
        try await show("books", in: roster)
        let books = try #require(roster.bots.first { $0.id == "books" })
        let chat = roster.chat(for: books)
        #expect(chat.items.isEmpty)

        try await elsewhere(pretend, say: "quick nudge books please")
        try await soon("its first word is on screen") { !chat.items.isEmpty }
        try await soon("and read") { !roster.unread.contains("books") }
    }

    @Test func aGatewayThatWillNotKeepOurNotesIsNotAskedAgainAndAgain() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-edits")
        let (roster, _, _) = try await open(pretend)
        // The first reading is noted two seconds on, and refused.
        try await Task.sleep(for: .seconds(3.5))
        // That was the app's own doing, so nothing the person is offered goes away for it.
        #expect(!roster.cannotEditBots)
        #expect(roster.unread.isEmpty)
        // Asked for by the person, the same refusal is told, and renaming is then put away.
        let garden = try #require(roster.bots.first { $0.id == "garden" })
        #expect(await roster.update(garden, title: "Allotment") != nil)
        #expect(roster.cannotEditBots)
    }

    @Test func howFarAChatWasReadIsKeptOnTheGatewayForTheNextLaunch() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, main, chat) = try await open(pretend)
        // Looked at once, so how far Garden is read gets noted on the gateway.
        try await show("garden", in: roster)
        try await soon("Garden's reading is saved") {
            roster.bots.first { $0.id == "garden" }?.readThrough != nil
        }
        // Its face and Hermes's own notes on it are untouched by that.
        let garden = try #require(roster.bots.first { $0.id == "garden" })
        #expect(garden.uiMeta["hermes-bots"]?["title"]?.stringValue == "Garden")
        #expect(garden.uiMeta["hermes-bot"]?["avatar"] != nil)

        try await show(main.id, in: roster)
        chat.draft = "quick nudge garden please"
        chat.send(to: main, through: roster)
        try await soon("Garden is unread") { roster.unread.contains("garden") }

        // The answer just read on this side is noted on the gateway a moment later.
        try await soon("the main bot's reading is saved") {
            guard let now = roster.mainBot, let last = now.chat?.lastActive, let read = now.readThrough else { return false }
            return !roster.isWorking(now) && last.timeIntervalSince(read) <= 1
        }

        // Another launch, or another device: Garden is unread there too, and Hermes is not.
        let again = RosterModel(gateway: (pretend.address, "demo"))
        again.isLookedAt = false
        await again.load()
        #expect(again.unread == ["garden"])
    }

    /// A bot never opened here still keeps its dot over a restart: how far it was read
    /// when first seen is noted on the gateway, not only remembered while the app runs.
    @Test func aBotNeverOpenedIsStillUnreadAfterARestart() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, _, _) = try await open(pretend)
        // Loaded again at once, as when the window is closed and reopened: the noting that
        // was waiting is made afresh, not lost.
        await roster.load()
        try await soon("the first sight of Garden and of Reading List is noted", within: 12) {
            roster.bots.first { $0.id == "garden" }?.readThrough != nil && roster.bots.first { $0.id == "books" }?.readThrough != nil
        }
        try await elsewhere(pretend, say: "quick nudge garden please")
        try await elsewhere(pretend, say: "quick nudge books please")
        try await soon("both are unread") { roster.unread.isSuperset(of: ["garden", "books"]) }

        let again = RosterModel(gateway: (pretend.address, "demo"))
        again.isLookedAt = false
        await again.load()
        #expect(again.unread.isSuperset(of: ["garden", "books"]))
    }

    @Test func aChatShowingBehindAnotherAppIsUnreadUntilTheWindowComesForward() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, main, chat) = try await open(pretend)
        roster.isLookedAt = false
        chat.draft = "quick hello"
        chat.send(to: main, through: roster)
        try await soon("the main bot is unread") { roster.unread.contains(main.id) }

        roster.isLookedAt = true
        try await soon("it is read once the window is in front") { roster.unread.isEmpty }
    }
}
