import Foundation
import HermesBotUI
import HermesKit
import Testing
@testable import HermesBot

/// Making a bot and having its first chat, against the pretend gateway.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NewBotTests {
    private func open(_ pretend: SendingTests.Pretend) async -> RosterModel {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        return roster
    }

    private func settled(_ chat: ChatModel) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while chat.isWorking {
            try #require(Date.now < deadline, "The chat was still working")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aNewBotIsListedSelectedAndKeepsItsNameAndFace() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let before = roster.bots.count

        #expect(await roster.createBot(named: "  Meal Plans ", look: AvatarLook(shape: .heart, color: .pink)) == .made)
        #expect(roster.bots.count == before + 1)
        let bot = try #require(roster.selected)
        #expect(bot.name == "meal-plans")
        #expect(bot.title == "Meal Plans")
        #expect(roster.look(for: bot) == AvatarLook(shape: .heart, color: .pink))
        #expect(bot.chat == nil)

        // Another app, or this one tomorrow, sees the same bot.
        let again = await open(pretend)
        let same = try #require(again.bots.first { $0.name == "meal-plans" })
        #expect(same.title == "Meal Plans")
        #expect(again.look(for: same) == AvatarLook(shape: .heart, color: .pink))
    }

    @Test func aSecondBotOfTheSameNameGetsItsOwnId() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        #expect(await roster.createBot(named: "Garden", look: .main) == .made)
        #expect(roster.selected?.name == "garden-2")
        #expect(roster.selected?.title == "Garden")
        #expect(await roster.createBot(named: "   ", look: .main) == .failed("Give the bot a name."))
    }

    /// A gateway that cannot make bots: said once, then no longer offered, until another
    /// gateway is connected.
    @Test func aGatewayThatCannotMakeBotsStopsBeingAsked() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-bots")
        let roster = await open(pretend)
        #expect(!roster.cannotMakeBots)
        #expect(await roster.createBot(named: "Meal Plans", look: .main) == .failed("This gateway doesn't offer making bots."))
        #expect(roster.cannotMakeBots)
        #expect(roster.bots.count == 4)
        await roster.signOut()
        #expect(!roster.cannotMakeBots)
    }

    /// Only this app's own key is written: another app's notes on a bot are never touched.
    @Test func theNameAndFaceGoUnderOurKeyAlone() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        #expect(await roster.createBot(named: "Meal Plans", look: AvatarLook(shape: .heart, color: .pink)) == .made)
        let bot = try #require(roster.selected)
        #expect(Set(bot.uiMeta.keys) == ["hermes-bot"])
        #expect(bot.uiMeta["hermes-bot"]?["title"]?.stringValue == "Meal Plans")
    }

    /// Someone else made a bot of the same id after this app last read the roster. Theirs is
    /// left alone, and ours is made under another id, not taken for theirs.
    @Test func anIdTakenSinceTheRosterWasReadIsNotMistakenForOurBot() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let elsewhere = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await elsewhere.connect()
        try await elsewhere.createBot(id: "meal-plans")
        try await elsewhere.saveMeta(.object(["title": .string("Theirs")]), forBot: "meal-plans")

        #expect(await roster.createBot(named: "Meal Plans", look: .main) == .made)
        #expect(roster.selected?.name == "meal-plans-2")
        #expect(roster.selected?.title == "Meal Plans")
        #expect(roster.bots.first { $0.name == "meal-plans" }?.title == "Theirs")
        await elsewhere.disconnect()
    }

    /// The reply to making the bot was lost and the roster could not be read either, so the
    /// dialog kept the id it had tried. A bot of that id is there on the next try. It may be
    /// ours or someone else's, so the person is asked first; their Try Again then finishes
    /// it, and no second bot is made beside it.
    @Test func aBotFoundAfterALostReplyIsAskedAboutThenFinishedNotMadeTwice() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let unseen = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await unseen.connect()
        try await unseen.createBot(id: "meal-plans")
        try await unseen.saveMeta(.object(["title": .string("Whose?")]), forBot: "meal-plans")
        await unseen.disconnect()

        let look = AvatarLook(shape: .heart, color: .pink)
        guard case .madeButUnnamed(let id, let question) = await roster.createBot(named: "Meal Plans", look: look, finishing: "meal-plans", isConfirmed: false) else {
            Issue.record("Expected to be asked")
            return
        }
        #expect(id == "meal-plans")
        #expect(question.contains("is there now"))
        // Nothing was written while the question stood.
        #expect(roster.bots.first { $0.name == "meal-plans" }?.title == "Whose?")

        #expect(await roster.createBot(named: "Meal Plans", look: look, finishing: "meal-plans", isConfirmed: true) == .made)
        #expect(roster.selected?.name == "meal-plans")
        #expect(roster.selected?.title == "Meal Plans")
        #expect(!roster.bots.contains { $0.name == "meal-plans-2" })
    }

    /// The id kept from an unconfirmed try turns out never to have been made: trying again makes it.
    @Test func anUnconfirmedBotThatWasNeverMadeIsMadeOnTheNextTry() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        #expect(await roster.createBot(named: "Meal Plans", look: .main, finishing: "meal-plans", isConfirmed: false) == .made)
        #expect(roster.selected?.name == "meal-plans")
        #expect(roster.bots.filter { $0.name.hasPrefix("meal-plans") }.count == 1)
    }

    /// With the gateway out of reach, an unconfirmed bot's id is kept, and stays unconfirmed.
    @Test func anUnconfirmedBotKeepsItsIdWhileTheGatewayIsAway() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        pretend.process.terminate()
        pretend.process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(200))
        guard case .unconfirmed(let id, _) = await roster.createBot(named: "Meal Plans", look: .main, finishing: "meal-plans", isConfirmed: false) else {
            Issue.record("Expected the id to be kept, unconfirmed")
            return
        }
        #expect(id == "meal-plans")
        // A fresh try with the gateway away is unconfirmed too, with the id it tried.
        guard case .unconfirmed(let tried, _) = await roster.createBot(named: "Other Bot", look: .main) else {
            Issue.record("Expected the tried id to be kept")
            return
        }
        #expect(tried == "other-bot")
    }

    /// The gateway restarted since the roster was read: making a bot reconnects, as sending does.
    @Test func makingABotWorksAfterTheGatewayComesBack() async throws {
        var pretend: SendingTests.Pretend? = try await SendingTests.Pretend()
        let port = try #require(pretend).port
        let roster = await open(try #require(pretend))
        pretend?.process.terminate()
        pretend?.process.waitUntilExit()
        pretend = try await SendingTests.Pretend(port: port)

        var result = await roster.createBot(named: "Meal Plans", look: .main)
        if case .failed = result {
            // The first try may be the one that finds out the old connection is gone.
            result = await roster.createBot(named: "Meal Plans", look: .main)
        }
        #expect(result == .made)
        #expect(roster.selected?.title == "Meal Plans")
        _ = pretend
    }

    /// A bot that has never chatted: the first message starts its chat and is answered.
    @Test func theFirstMessageToANewBotStartsItsChat() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        #expect(await roster.createBot(named: "Meal Plans", look: .main) == .made)
        var bot = try #require(roster.selected)
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        #expect(chat.phase == .loaded)
        #expect(chat.items.isEmpty)

        chat.draft = "quick hello"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        bot = try #require(roster.bots.first { $0.name == "meal-plans" })
        #expect(bot.chat?.messageCount ?? 0 > 0)
        #expect(chat.items.count >= 2)

        // And the next message goes to the same chat.
        chat.draft = "quick again"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        #expect(chat.items.count >= 4)
    }

    /// The roster this app holds says a bot has no chat, but one was started elsewhere since.
    /// The gateway refuses a second, and the message goes to the one that exists.
    @Test func aChatStartedElsewhereIsUsedInsteadOfASecond() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let stale = try #require(roster.bots.first { $0.name == "books" })
        #expect(stale.chat == nil)

        let elsewhere = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await elsewhere.connect()
        _ = try await elsewhere.startChat(profile: "books")

        let chat = roster.chat(for: stale)
        await chat.load(stale, from: roster)
        chat.draft = "quick hello"
        chat.send(to: stale, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        #expect(roster.bots.first { $0.name == "books" }?.chat?.id == "chat-books")
        #expect(chat.items.count >= 2)
        await elsewhere.disconnect()
    }
}
