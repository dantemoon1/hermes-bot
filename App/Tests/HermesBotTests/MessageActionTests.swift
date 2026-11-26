import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// Retry, Undo and reactions, against the pretend gateway, which keeps them as Hermes does.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct MessageActionTests {
    private func open(_ pretend: SendingTests.Pretend, bot name: String = "default") async throws -> (RosterModel, Bot, ChatModel) {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let bot = try #require(roster.bots.first { $0.name == name })
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        #expect(chat.phase == .loaded)
        return (roster, bot, chat)
    }

    private func settled(_ chat: ChatModel) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while chat.isWorking {
            try #require(Date.now < deadline, "The chat was still working")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func texts(_ chat: ChatModel) -> [String] {
        chat.items.compactMap { item in
            switch item {
            case .user(_, let text), .bot(_, let text): text
            default: nil
            }
        }
    }

    /// What the screen shows is what the gateway holds.
    private func matchesGateway(_ chat: ChatModel, _ bot: Bot, _ roster: RosterModel) async throws {
        let now = try #require(roster.bots.first { $0.id == bot.id })
        let stored = try await roster.messages(for: now)
        #expect(chat.items == Transcript.items(from: stored))
    }

    /// Someone on another device, with the same chat open.
    private func elsewhere(_ pretend: SendingTests.Pretend, _ bot: Bot) async throws -> (GatewayClient, LiveChat) {
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await client.connect()
        return (client, try await client.openChat(try #require(bot.chat), profile: bot.name))
    }

    @Test(arguments: ["interrupt", "authority"])
    func retryDropsTheAnswerAndAsksAgain(gateway: String) async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: gateway)
        let (roster, bot, chat) = try await open(pretend)
        // "thanks" is row 8 and "Anytime." row 9: the latest turn, and only it, has the actions.
        #expect(chat.canUndo(8) && chat.canRetry(9))
        #expect(!chat.canUndo(4) && !chat.canRetry(7) && !chat.canRetry(8) && !chat.canUndo(9))
        chat.draft = "half typed"

        chat.retry(bot, through: roster)
        #expect(chat.isWorking)
        #expect(!chat.canRetry(9) && !chat.canUndo(8))
        #expect(!texts(chat).contains("Anytime."))
        try await settled(chat)

        #expect(chat.sendProblem == nil)
        #expect(chat.draft == "half typed")
        let said = texts(chat)
        #expect(said.filter { $0 == "thanks" }.count == 1)
        #expect(!said.contains("Anytime."))
        #expect(said.last?.contains("everything arrived") == true)
        try await matchesGateway(chat, bot, roster)
        // The new turn is the latest one now.
        #expect(chat.latest?.asked != 8)
        #expect(chat.latest.map { chat.canRetry($0.answer ?? -1) } == true)
    }

    @Test(arguments: ["interrupt", "authority"])
    func undoTakesTheMessageBackAndPutsItsWordsInTheBox(gateway: String) async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: gateway)
        let (roster, bot, chat) = try await open(pretend)

        chat.undo(bot, through: roster)
        #expect(chat.isWorking)
        try await settled(chat)

        #expect(chat.sendProblem == nil)
        #expect(chat.draft == "thanks")
        #expect(!texts(chat).contains("thanks"))
        #expect(!texts(chat).contains("Anytime."))
        try await matchesGateway(chat, bot, roster)
        // The turn before is now the latest.
        #expect(chat.latest?.asked == 5)
    }

    @Test func undoLeavesWhatIsAlreadyTypedAndSaysSo() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "something new"

        chat.undo(bot, through: roster)
        try await settled(chat)

        #expect(chat.draft == "something new")
        #expect(chat.sendProblem?.contains("already typed") == true)
        #expect(!texts(chat).contains("thanks"))
    }

    /// Another device said something after the chat on screen was read: neither Undo nor
    /// Retry takes it, and the chat then shows what the gateway has.
    @Test(arguments: [false, true])
    func aTurnFromElsewhereIsNeverTakenBack(retrying: Bool) async throws {
        let pretend = try await SendingTests.Pretend()
        // Not the bot showing, whose chat would be read in again as soon as it changed.
        let (roster, bot, chat) = try await open(pretend, bot: "trips")
        #expect(roster.selectedID != bot.id)
        let (client, theirs) = try await elsewhere(pretend, bot)
        try await client.send("quick from elsewhere", in: theirs, profile: bot.name)
        let deadline = Date.now.addingTimeInterval(10)
        while try await !roster.messages(for: bot).contains(where: { $0.text.contains("pretend bot") && $0.id > 100 }) {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(chat.latest?.asked == 1)

        if retrying { chat.retry(bot, through: roster) } else { chat.undo(bot, through: roster) }
        try await settled(chat)

        #expect(chat.sendProblem?.contains("Something new was said") == true)
        #expect(chat.draft.isEmpty)
        let stored = try await roster.messages(for: bot)
        #expect(stored.contains { $0.text == "quick from elsewhere" })
        #expect(stored.contains { $0.text == "plan lisbon for me, three days" })
        try await matchesGateway(chat, bot, roster)
    }

    /// A turn no person typed (a page talking to its bot) is not the latest turn; taking the
    /// person's message back takes it with it.
    @Test func aHiddenTurnIsPassedOver() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "quick, then a page"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        // The hidden turn comes after the answer, and in with the next read.
        try await until { try await roster.messages(for: bot).contains { $0.displayKind == "hidden" } }
        await chat.load(bot, from: roster)
        let stored = try await roster.messages(for: bot)
        let mine = try #require(stored.last { $0.text == "quick, then a page" })
        let hidden = try #require(stored.last { $0.displayKind == "hidden" })
        #expect(hidden.id > mine.id)
        #expect(chat.latest?.asked == mine.id)
        #expect(chat.latest?.answer == stored.last?.id)
        #expect(!chat.canUndo(hidden.id))

        chat.undo(bot, through: roster)
        try await settled(chat)
        #expect(chat.draft == "quick, then a page")
        let after = try await roster.messages(for: bot)
        #expect(!after.contains { $0.id >= mine.id })
        #expect(chat.latest?.asked == 8)
    }

    /// The chat's only exchange can be asked again, leaving nothing before it.
    @Test(arguments: ["interrupt", "authority"])
    func theFirstMessageCanBeRetried(gateway: String) async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: gateway)
        let (roster, bot, chat) = try await open(pretend, bot: "trips")
        #expect(chat.latest?.isFirst == true)

        chat.retry(bot, through: roster)
        try await settled(chat)

        #expect(chat.sendProblem == nil)
        let said = texts(chat)
        #expect(said.first == "plan lisbon for me, three days")
        #expect(said.count == 2)
        #expect(said.last?.contains("everything arrived") == true)
    }

    @Test func noActionsWhileTheBotIsWorking() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "quick but slow"
        chat.send(to: bot, through: roster)
        #expect(!chat.canUndo(8) && !chat.canRetry(9) && !chat.canReact(9))
        chat.retry(bot, through: roster)
        chat.undo(bot, through: roster)
        chat.stop(bot)
        try await settled(chat)
        #expect(texts(chat).contains("thanks"))
        #expect(texts(chat).contains("Anytime."))
    }

    @Test(arguments: ["interrupt", "authority"])
    func aReactionIsKeptOnTheGatewayAndTakenOffAgain(gateway: String) async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: gateway)
        let (roster, bot, chat) = try await open(pretend)
        // The bot's own reaction to "thanks" comes with the chat.
        #expect(chat.reactions[8] == [Reaction(emoji: "👍", author: "agent")])

        chat.react("😂", to: 9, of: bot, through: roster)
        #expect(chat.myReaction(on: 9) == "😂")
        try await until { try await roster.messages(for: bot).first { $0.id == 9 }?.reactions.count == 1 }
        await chat.load(bot, from: roster)
        #expect(chat.reactions[9] == [Reaction(emoji: "😂", author: "user")])

        // Another one takes its place; the same one again takes it off.
        chat.react("👀", to: 9, of: bot, through: roster)
        try await until { try await roster.messages(for: bot).first { $0.id == 9 }?.reactions.first?.emoji == "👀" }
        chat.react("👀", to: 9, of: bot, through: roster)
        #expect(chat.myReaction(on: 9) == nil)
        try await until { try await roster.messages(for: bot).first { $0.id == 9 }?.reactions.isEmpty == true }
        #expect(chat.sendProblem == nil)
    }

    @Test func aGatewayWithoutThemOffersNone() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-rewind")
        let (roster, bot, chat) = try await open(pretend)

        chat.react("👍", to: 9, of: bot, through: roster)
        try await until { chat.cannotReact }
        #expect(chat.myReaction(on: 9) == nil)
        #expect(!chat.canReact(9))

        chat.undo(bot, through: roster)
        try await settled(chat)
        #expect(chat.cannotRewind)
        // A missing method takes the feature away; it is not shown as a failure.
        #expect(chat.sendProblem == nil)
        #expect(!chat.canUndo(8) && !chat.canRetry(9))
        #expect(chat.draft.isEmpty)
        #expect(texts(chat).contains("thanks"))
    }

    /// The session authority's fence is taken before the check, so a turn said after it
    /// makes the gateway refuse the cut.
    @Test func aCutFencedBeforeSomethingNewIsRefused() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "authority")
        let (roster, bot, _) = try await open(pretend)
        let client = try await roster.liveClient()
        let open = try await client.openChat(try #require(bot.chat), profile: bot.name)
        let fence = try await client.rewindFence(in: open, profile: bot.name)
        #expect(fence != nil)
        let (other, theirs) = try await elsewhere(pretend, bot)
        try await other.send("quick from elsewhere", in: theirs, profile: bot.name)

        await #expect(throws: GatewayError.self) {
            try await client.undo(Rewind(rowID: 8, emptiesChat: false), fence: fence, in: open, profile: bot.name)
        }
        #expect(try await roster.messages(for: bot).contains { $0.text == "thanks" })
    }

    /// The session authority cuts, then the message asked again is refused: its words come
    /// back to the box, ahead of what is typed there.
    @Test func aCutWhoseMessageIsRefusedGivesTheWordsBack() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "authority")
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "quick, and refuse a retry"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        chat.draft = "typed meanwhile"

        chat.retry(bot, through: roster)
        try await settled(chat)

        #expect(chat.sendProblem?.hasPrefix("Couldn't retry.") == true)
        #expect(chat.draft == "quick, and refuse a retry\ntyped meanwhile")
        #expect(!texts(chat).contains("quick, and refuse a retry"))
        try await matchesGateway(chat, bot, roster)
    }

    /// A retry that cannot even start leaves the turn on screen, even when the chat cannot be
    /// read again either.
    @Test func aRetryThatCannotStartLeavesTheTurnShown() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        pretend.process.terminate()
        pretend.process.waitUntilExit()

        chat.retry(bot, through: roster)
        try await settled(chat)

        #expect(chat.sendProblem?.hasPrefix("Couldn't retry.") == true)
        #expect(texts(chat).suffix(2) == ["thanks", "Anytime."])
        #expect(chat.draft.isEmpty)
    }

    /// A picture the gateway gives only as a stand-in still went with the message.
    @Test func aPictureStandInIsNotRetriedAsWords() {
        let messages = [ChatMessage(id: 1, role: "user", text: "what is this\n[image]"), ChatMessage(id: 2, role: "assistant", text: "A cat.")]
        let latest = ChatModel.latestTurn(in: messages, shown: Transcript.items(from: messages))
        #expect(latest?.hadAttachments == true)
        // A typed line reads the same, so Undo puts the words back whole.
        #expect(latest?.words == "what is this\n[image]")
        // A stand-in typed in the middle of the words is words.
        let typed = [ChatMessage(id: 1, role: "user", text: "the tag is\n[image]\nas shown"), ChatMessage(id: 2, role: "assistant", text: "Yes.")]
        let read = ChatModel.latestTurn(in: typed, shown: Transcript.items(from: typed))
        #expect(read?.hadAttachments == false && read?.words == "the tag is\n[image]\nas shown")
        let alone = [ChatMessage(id: 1, role: "user", text: "[image]")]
        #expect(ChatModel.latestTurn(in: alone, shown: Transcript.items(from: alone))?.hadAttachments == true)
    }

    /// Reactions that do not go leave the row as the gateway last said it was, not as an
    /// earlier pick that never went either.
    @Test func failedReactionsFallBackToWhatTheGatewayHas() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.react("😂", to: 9, of: bot, through: roster)
        try await until { try await roster.messages(for: bot).first { $0.id == 9 }?.reactions.first?.emoji == "😂" }
        try await Task.sleep(for: .milliseconds(100))
        pretend.process.terminate()
        pretend.process.waitUntilExit()

        chat.react("👀", to: 9, of: bot, through: roster)
        chat.react("🙏", to: 9, of: bot, through: roster)
        try await until { chat.sendProblem != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.myReaction(on: 9) == "😂")
    }

    /// Reactions picked quickly one after another reach the gateway in order and end as shown.
    @Test func quickReactionsEndAsShown() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.react("😂", to: 9, of: bot, through: roster)
        chat.react("👀", to: 9, of: bot, through: roster)
        chat.react("🙏", to: 9, of: bot, through: roster)
        #expect(chat.myReaction(on: 9) == "🙏")
        // A read of the chat meanwhile leaves the row as set.
        await chat.load(bot, from: roster)
        #expect(chat.myReaction(on: 9) == "🙏")
        try await until { try await roster.messages(for: bot).first { $0.id == 9 }?.reactions.first?.emoji == "🙏" }
        try await Task.sleep(for: .milliseconds(200))
        #expect(chat.myReaction(on: 9) == "🙏")
        #expect(chat.sendProblem == nil)
    }

    private func until(_ condition: () async throws -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while try await !condition() {
            try #require(Date.now < deadline, "Waited too long")
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}
