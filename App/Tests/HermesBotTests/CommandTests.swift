import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// Slash commands in the message box, against the pretend gateway.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CommandTests {
    private let everything = Set(SlashCommand.all.map(\.name))

    private func open(_ pretend: SendingTests.Pretend, bot name: String = "default", readingCommands: Bool = true) async throws -> (RosterModel, Bot, ChatModel) {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        if readingCommands { await roster.readCommands() }
        let bot = try #require(roster.bots.first { $0.name == name })
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        #expect(chat.phase == .loaded)
        return (roster, bot, chat)
    }

    /// Runs what is typed, as Return does, and waits for its last note to say how it went.
    @discardableResult
    private func type(_ text: String, in chat: ChatModel, _ bot: Bot, _ roster: RosterModel) async throws -> ChatNote? {
        let before = chat.notes.count
        chat.draft = text
        chat.submit(to: bot, through: roster)
        let deadline = Date.now.addingTimeInterval(10)
        while chat.notes.count > before, chat.notes.last?.text == nil {
            try #require(Date.now < deadline, "\(text) did not finish")
            try await Task.sleep(for: .milliseconds(20))
        }
        return chat.notes.count > before ? chat.notes.last : nil
    }

    private func settled(_ chat: ChatModel) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while chat.isWorking {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func said(_ chat: ChatModel) -> [String] {
        chat.items.compactMap { item in
            switch item {
            case .user(_, let text), .bot(_, let text): text
            default: nil
            }
        }
    }

    @Test func theMenuOpensForASlashAtTheStartAndNarrowsAsYouType() {
        #expect(SlashCommand.matching("/", offered: everything)?.count == SlashCommand.all.count)
        #expect(SlashCommand.matching("/co", offered: everything)?.map(\.name) == ["compress", "context"])
        #expect(SlashCommand.matching("/CO", offered: everything)?.map(\.name) == ["compress", "context"])
        // Not mid-sentence, not once words follow the name, and not for a path.
        #expect(SlashCommand.matching("so /co", offered: everything) == nil)
        #expect(SlashCommand.matching("/compress here", offered: everything) == nil)
        #expect(SlashCommand.matching("/Users/someone/notes.txt", offered: everything) == nil)
        #expect(SlashCommand.matching("/zzz", offered: everything) == nil)
        // Only what the gateway offers; nothing at all where it offers none.
        #expect(SlashCommand.matching("/b", offered: everything.subtracting(["btw"])) == nil)
        #expect(SlashCommand.matching("/", offered: []) == nil)
    }

    @Test func onlyOfferedCommandsOfOursAreRunAndTheRestIsAMessage() {
        #expect(SlashCommand.parse("/Status", offered: everything)?.command.name == "status")
        // The slash must come first, as the menu wants it.
        #expect(SlashCommand.parse("  /compress", offered: everything) == nil)
        let aside = SlashCommand.parse("/btw  which port\nfor the UI?  ", offered: everything)
        #expect(aside?.command.name == "btw")
        #expect(aside?.words == "which port\nfor the UI?")
        #expect(SlashCommand.parse("/new", offered: everything.union(["new"])) == nil)
        #expect(SlashCommand.parse("/statusx", offered: everything) == nil)
        #expect(SlashCommand.parse("/status", offered: everything.subtracting(["status"])) == nil)
        #expect(SlashCommand.parse("/Users/someone", offered: everything) == nil)
    }

    @Test func theGatewaysListDecidesWhatIsOffered() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, _, _) = try await open(pretend)
        #expect(roster.offeredCommands.isSuperset(of: everything))
    }

    @Test func aGatewayWithNoListOffersNoCommandsAndTheWordsGoAsAMessage() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-commands")
        let (roster, bot, chat) = try await open(pretend)
        #expect(roster.offeredCommands.isEmpty)
        chat.draft = "/status quick"
        chat.submit(to: bot, through: roster)
        #expect(chat.notes.isEmpty)
        #expect(said(chat).last == "/status quick")
        try await settled(chat)
    }

    @Test func aReadoutIsACardAndChangesNothing() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let before = said(chat)
        let note = try #require(try await type("/status", in: chat, bot, roster))
        #expect(note.kind == .readout)
        #expect(note.asked == "/status")
        #expect(note.text?.contains("Model: orbit-mini") == true)
        #expect(chat.draft.isEmpty)
        #expect(said(chat) == before)
        // After what the chat ended with, and gone when dismissed.
        #expect(note.after == chat.items.last?.id)
        chat.dismissNote(note.id)
        #expect(chat.notes.isEmpty)
    }

    @Test func undoTakesTheLastExchangeOutAndGivesTheWordsBack() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        #expect(said(chat).suffix(2) == ["thanks", "Anytime."])
        let shown = try #require(try await type("/status", in: chat, bot, roster))
        let note = try #require(try await type("/undo", in: chat, bot, roster))
        #expect(note.kind == .line)
        #expect(note.text?.contains("Undid 1 turn") == true)
        #expect(said(chat).last?.hasPrefix("Done. The order") == true)
        #expect(chat.draft == "thanks")
        // A note after what was taken out now follows what the chat ends with.
        let ids = Set(chat.items.map(\.id))
        #expect(chat.notes.allSatisfy { $0.after.map(ids.contains) == true })
        #expect(chat.notes.first?.id == shown.id)
    }

    /// Clarifying questions that come while /undo is on its way take the box: the words it
    /// gives back go to the message put aside, never into the answer being typed.
    @Test func undoneWordsGoToTheMessagePutAsideNotAnAnswer() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "/undo"
        chat.submit(to: bot, through: roster)
        chat.clarifyingChanged(to: UUID())
        chat.draft = "the blue one"
        try await waitForLast(chat)
        #expect(chat.notes.last?.text?.contains("Undid 1 turn") == true)
        #expect(chat.draft == "the blue one")
        #expect(chat.messageDraft == "thanks")
        chat.clarifyingChanged(to: nil)
        #expect(chat.draft == "thanks")
    }

    @Test func retrySendsTheLastMessageAgain() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, bot: "trips")
        #expect(said(chat).last?.hasPrefix("## Lisbon") == true)
        try await type("/retry", in: chat, bot, roster)
        let deadline = Date.now.addingTimeInterval(10)
        while !chat.isWorking {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        // What it took out is gone from the screen before it is asked again.
        #expect(!said(chat).contains { $0.hasPrefix("## Lisbon") })
        try await settled(chat)
        let now = said(chat)
        #expect(now.filter { $0 == "plan lisbon for me, three days" }.count == 1)
        #expect(now.last?.contains("plan lisbon") == true)
        #expect(chat.sendProblem == nil)
    }

    @Test func aSideQuestionIsAnsweredApartFromTheChat() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let before = said(chat)
        let note = try #require(try await type("/btw which port?", in: chat, bot, roster))
        #expect(note.kind == .aside(question: "which port?"))
        #expect(note.text?.contains("Nothing was added") == true)
        #expect(said(chat) == before)
        // One that fails says so in its card.
        let failed = try #require(try await type("/btw please fail", in: chat, bot, roster))
        #expect(failed.text == "no model for side questions")
        // Without a question, the command waits in the box for one.
        chat.draft = "/btw"
        chat.submit(to: bot, through: roster)
        #expect(chat.draft == "/btw ")
        #expect(chat.notes.count == 2)
    }

    @Test func yoloIsNeverRunWithoutThePersonAgreeing() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "/YOLO  on"
        chat.submit(to: bot, through: roster)
        let asked = try #require(chat.confirming)
        #expect(asked.action == "Turn Off Approvals")
        // It promises only what /yolo off does: this chat's skipping ends, and the bot's own
        // mode, which may be off too, applies again.
        #expect(asked.message.contains("own approval mode applies again"))
        #expect(!asked.message.contains("back on"))
        // Nothing has been done: the command waits in the box.
        #expect(chat.notes.isEmpty)
        #expect(chat.draft == "/YOLO  on")
        asked.cancel()
        chat.confirming = nil
        #expect(chat.notes.isEmpty)
        // And the gateway was never asked.
        #expect(try await type("/status", in: chat, bot, roster)?.text?.contains("Approvals: manual") == true)

        chat.draft = "/yolo"
        chat.submit(to: bot, through: roster)
        try #require(chat.confirming).run()
        chat.confirming = nil
        #expect(chat.draft.isEmpty)
        try await waitForLast(chat)
        #expect(chat.notes.last?.text?.hasPrefix("Approvals are skipped in this chat") == true)
        #expect(try await type("/status", in: chat, bot, roster)?.text?.contains("Approvals: skipped") == true)
        // Ending it needs no asking.
        let on = try #require(try await type("/yolo off", in: chat, bot, roster))
        #expect(on.text == "Approvals are no longer skipped in this chat.")
        #expect(chat.confirming == nil)
        // Words it does not take are refused here, not sent on.
        let odd = try #require(try await type("/yolo maybe", in: chat, bot, roster))
        #expect(odd.text?.hasSuffix("takes on or off.") == true)
    }

    /// An alert left up when the gateway is left, or the chat with it, agrees to nothing.
    @Test func anAgreementOutlivingItsGatewayDoesNothing() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "/yolo"
        chat.submit(to: bot, through: roster)
        let asked = try #require(chat.confirming)
        chat.abandon()
        #expect(chat.confirming == nil)
        asked.run()
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.notes.isEmpty)
    }

    @Test func approvalsOffIsAskedAboutAndOtherModesAreNot() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "/approvals off"
        chat.submit(to: bot, through: roster)
        #expect(chat.confirming?.title == "Turn off approvals for \(bot.title)?")
        #expect(chat.notes.isEmpty)
        chat.confirming = nil
        let smart = try #require(try await type("/approvals smart", in: chat, bot, roster))
        #expect(smart.text == "Approval mode set to smart.")
        #expect(chat.confirming == nil)
        let shown = try #require(try await type("/approvals", in: chat, bot, roster))
        #expect(shown.text == "Approval mode: smart")
        #expect(shown.kind == .readout)
        // However "off" is written, even with a character Hermes reads as a space, it is
        // asked about, and only "off" itself goes on.
        for odd in ["/approvals OFF", "/approvals off\u{1C}", "/approvals \u{1F}off"] {
            chat.draft = odd
            chat.submit(to: bot, through: roster)
            #expect(chat.confirming != nil, "\(odd.debugDescription) was not asked about")
            chat.confirming = nil
        }
        // Anything else is refused here.
        let other = try #require(try await type("/approvals off now", in: chat, bot, roster))
        #expect(other.text?.hasSuffix("takes manual, smart or off.") == true)
        #expect(chat.confirming == nil)
    }

    @Test func skillsOnlyReviewsWhatIsWaiting() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let pending = try #require(try await type("/skills", in: chat, bot, roster))
        #expect(pending.kind == .readout)
        #expect(pending.asked == "/skills pending")
        let install = try #require(try await type("/skills install something", in: chat, bot, roster))
        #expect(install.text?.contains("reviews skill changes") == true)
        #expect(install.kind == .line)
    }

    @Test func aGatewayWhoseAuthorityRefusesSomeDoesNotOfferThem() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "authority")
        let (roster, _, _) = try await open(pretend)
        #expect(roster.offeredCommands.contains("status"))
        #expect(roster.offeredCommands.isDisjoint(with: SlashCommand.refusedBySessionAuthority))
    }

    @Test func aCommandTypedBeforeTheListHasComeWaitsForIt() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, readingCommands: false)
        #expect(!roster.commandsKnown)
        chat.draft = "/status"
        chat.submit(to: bot, through: roster)
        let deadline = Date.now.addingTimeInterval(10)
        while chat.notes.last?.text == nil {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chat.notes.last?.kind == .readout)
        #expect(!chat.items.contains { if case .user(_, "/status") = $0 { true } else { false } })
    }

    /// A note made while the chat was empty stays before what is said after it.
    @Test func aNoteInAnEmptyChatStaysFirst() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, bot: "books")
        let note = try #require(try await type("/status", in: chat, bot, roster))
        #expect(note.after == nil)
        chat.draft = "quick hello"
        chat.submit(to: bot, through: roster)
        try await settled(chat)
        #expect(said(chat).first == "quick hello")
        #expect(chat.notes.first?.after == nil)
    }

    @Test func aModelNamedIsSavedOnTheBotAsThePickerSavesIt() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, bot: "garden")
        let saved = try #require(try await type("/model LUMEN-6", in: chat, bot, roster))
        #expect(saved.text == "Model set to lumen-6. Saved on Garden.")
        #expect(roster.bots.first { $0.name == "garden" }?.model == "lumen-6")
        let none = try #require(try await type("/model orbit-nine", in: chat, bot, roster))
        #expect(none.text?.hasPrefix("No model called") == true)

        // A costly one waits for the person, and Return is Cancel.
        chat.draft = "/model orbit-max"
        chat.submit(to: bot, through: roster)
        let deadline = Date.now.addingTimeInterval(10)
        while chat.confirming == nil {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(roster.bots.first { $0.name == "garden" }?.model == "lumen-6")
        try #require(chat.confirming).run()
        chat.confirming = nil
        try await waitForLast(chat)
        #expect(chat.notes.last?.text == "Model set to orbit-max. Saved on Garden.")
        #expect(roster.bots.first { $0.name == "garden" }?.model == "orbit-max")
    }

    @Test func reasoningNamedIsSavedOnTheBot() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, bot: "garden")
        let note = try #require(try await type("/reasoning extra high", in: chat, bot, roster))
        #expect(note.text == "Reasoning set to Extra high. Saved on Garden.")
        #expect(await roster.reasoning(of: bot) == .xhigh)
        #expect(roster.reasoningSaved["garden"] == .xhigh)
        let wrong = try #require(try await type("/reasoning hgih", in: chat, bot, roster))
        #expect(wrong.text?.hasPrefix("Reasoning can be") == true)
    }

    @Test func bareModelAndReasoningOpenTheDetails() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.draft = "/model"
        chat.submit(to: bot, through: roster)
        #expect(roster.modelPickAsks == 1)
        #expect(roster.detailsAsks == 1)
        chat.draft = "/reasoning"
        chat.submit(to: bot, through: roster)
        #expect(roster.modelPickAsks == 1)
        #expect(roster.detailsAsks == 2)
        #expect(chat.notes.isEmpty)
        #expect(chat.draft.isEmpty)
    }

    @Test func aRefusalIsSaidInHermessWords() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, bot: "books")
        // The Reading List has no chat yet: the command starts it, and there is nothing to undo.
        let note = try #require(try await type("/undo", in: chat, bot, roster))
        #expect(note.text == "undo: no user messages to undo")
        let stop = try #require(try await type("/stop", in: chat, bot, roster))
        #expect(stop.text == "Reading List isn't working on anything.")
    }

    @Test func aCommandCopiedFromANoteRunsAndHermessSpacesCount() {
        // The joiner written after a slash in notes, so a command never breaks at its slash.
        #expect(SlashCommand.parse(SlashCommand.unbroken("/yolo off"), offered: everything)?.command.name == "yolo")
        #expect(SlashCommand.parse(SlashCommand.unbroken("/yolo off"), offered: everything)?.words == "off")
        // A control character Hermes reads as a space ends the name, as it does for Hermes.
        let odd = SlashCommand.parse("/approvals\u{1C}off", offered: everything)
        #expect(odd?.command.name == "approvals")
        #expect(odd.map { SlashCommand.tokens($0.words) } == ["off"])
    }

    @Test func aSkillsNameKeepsItsCapitals() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let note = try #require(try await type("/skills APPROVE MySkill", in: chat, bot, roster))
        #expect(note.asked == "/skills approve MySkill")
    }

    @Test func aListThatCouldNotBeHadKeepsTheCommandInTheBox() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "commands-fail")
        let (roster, bot, chat) = try await open(pretend)
        #expect(!roster.commandsKnown)
        let before = said(chat)
        chat.draft = "/btw something private"
        chat.submit(to: bot, through: roster)
        try await waitForLast(chat)
        let note = try #require(chat.notes.last)
        #expect(note.text?.hasPrefix("Couldn't find out which commands") == true)
        #expect(chat.draft == "/btw something private")
        #expect(said(chat) == before)
        #expect(!chat.isWorking)
    }

    /// A question still being prepared when the chat is left is not asked on coming back,
    /// and one up when it is left is answered as Cancel.
    @Test func leavingTheChatDropsItsQuestions() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, readingCommands: false)
        chat.draft = "/approvals off"
        chat.submit(to: bot, through: roster)
        chat.leave()
        await roster.readCommands()
        try await Task.sleep(for: .milliseconds(200))
        #expect(chat.confirming == nil)

        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let gardenChat = roster.chat(for: garden)
        await gardenChat.load(garden, from: roster)
        gardenChat.draft = "/model orbit-max"
        gardenChat.submit(to: garden, through: roster)
        let deadline = Date.now.addingTimeInterval(10)
        while gardenChat.confirming == nil {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        gardenChat.leave()
        #expect(gardenChat.confirming == nil)
        #expect(gardenChat.notes.last?.text == "Not switched.")
        #expect(roster.bots.first { $0.name == "garden" }?.model == "orbit-mini")
    }

    /// A Hermes from before 0.21.6 could turn approvals off for every chat it runs.
    @Test func yoloIsRefusedWhereHermesCouldNotKeepItToOneChat() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "old-hermes")
        let (roster, bot, chat) = try await open(pretend)
        #expect(!roster.yoloKeptToOneChat)
        // Refused once the version has been read again and still says so.
        chat.draft = "/yolo"
        chat.submit(to: bot, through: roster)
        try await waitForLast(chat)
        let note = try #require(chat.notes.last)
        #expect(note.text?.contains("older than 0.21.6") == true)
        #expect(chat.draft.isEmpty)
        #expect(chat.confirming == nil)
        #expect(try await type("/status", in: chat, bot, roster)?.text?.contains("Approvals: manual") == true)
        // Turning it off again is never refused.
        #expect(try await type("/yolo off", in: chat, bot, roster)?.text == "Approvals are no longer skipped in this chat.")
    }

    /// A version that could not be read with the list is read again before /yolo is refused:
    /// one failed look must not keep it from a current Hermes for the whole connection.
    @Test func yoloAsksTheVersionAgainBeforeSayingHermesIsOld() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, readingCommands: false)
        func status(_ path: String) async throws {
            var request = URLRequest(url: URL(string: "http://\(pretend.address)\(path)")!)
            request.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
            _ = try await URLSession.shared.data(for: request)
        }
        try await status("/api/status-down")
        await roster.readCommands()
        #expect(roster.commandsKnown)
        #expect(!roster.yoloKeptToOneChat)
        try await status("/api/status-up")
        chat.draft = "/yolo"
        chat.submit(to: bot, through: roster)
        let deadline = Date.now.addingTimeInterval(10)
        while chat.confirming == nil {
            try #require(Date.now < deadline, "/yolo was not asked about")
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(chat.notes.isEmpty)
        #expect(chat.draft == "/yolo")
        #expect(roster.yoloKeptToOneChat)
    }

    /// A message sent straight after asking for approvals back waits for them.
    @Test func nothingIsSentWhileApprovalsAreChanging() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        #expect(roster.yoloKeptToOneChat)
        chat.draft = "/yolo off"
        chat.submit(to: bot, through: roster)
        #expect(chat.approvalsChanging == 1)
        chat.draft = "quick hello"
        #expect(!chat.send(to: bot, through: roster))
        #expect(chat.draft == "quick hello")
        try await waitForLast(chat)
        #expect(chat.approvalsChanging == 0)
        #expect(chat.send(to: bot, through: roster))
        try await settled(chat)
    }

    /// The menu takes "/ undo" for words, and so does Return.
    @Test func aSpaceAfterTheSlashIsWords() {
        for typed in ["/ undo", "/ plan for Friday", "/\nstatus", "/\u{1C}retry"] {
            #expect(SlashCommand.parse(typed, offered: everything) == nil, "\(typed.debugDescription)")
            #expect(SlashCommand.matching(typed, offered: everything) == nil)
        }
    }

    /// An open chat the gateway let go of is opened again once, not named for ever.
    @Test func aChatTheGatewayLetGoOfIsOpenedAgain() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "evicts")
        let (roster, bot, chat) = try await open(pretend)
        let note = try #require(try await type("/status", in: chat, bot, roster))
        #expect(note.kind == .readout)
        #expect(note.text?.contains("Model: orbit-mini") == true)
    }

    /// Changes to approvals land in the order asked, the last one asked being the one that stays.
    @Test func approvalChangesLandInTheOrderAsked() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, bot: "garden")
        chat.draft = "/approvals off"
        chat.submit(to: bot, through: roster)
        try #require(chat.confirming).run()
        chat.confirming = nil
        chat.draft = "/approvals manual"
        chat.submit(to: bot, through: roster)
        #expect(chat.approvalsChanging == 2)
        let deadline = Date.now.addingTimeInterval(10)
        while chat.approvalsChanging > 0 {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await type("/status", in: chat, bot, roster)?.text?.contains("Approvals: manual") == true)
    }

    /// Typed before the list has come, a change to approvals is not left to wait.
    @Test func anApprovalCommandTypedBeforeTheListStaysInTheBox() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend, readingCommands: false)
        chat.draft = "/yolo off"
        chat.submit(to: bot, through: roster)
        #expect(chat.draft == "/yolo off")
        #expect(chat.notes.last?.text?.contains("still being read") == true)
        #expect(chat.approvalsChanging == 0)
    }

    private func waitForLast(_ chat: ChatModel) async throws {
        let deadline = Date.now.addingTimeInterval(10)
        while chat.notes.last?.text == nil {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
