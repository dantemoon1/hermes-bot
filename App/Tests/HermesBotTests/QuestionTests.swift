import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// A bot's questions mid-answer, against the pretend gateway, which asks them when a message
/// says "ask me" and names them.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct QuestionTests {
    typealias Pretend = SendingTests.Pretend

    /// Answers are given straight away here; the guard against keys pressed as a question
    /// arrives has a test of its own.
    init() { ChatQuestions.arrivalGuard = 0 }

    private func open(_ pretend: Pretend) async throws -> (RosterModel, Bot, ChatModel) {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let bot = try #require(roster.mainBot)
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        #expect(chat.phase == .loaded)
        return (roster, bot, chat)
    }

    private func until(_ what: String, within seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
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

    private func send(_ text: String, _ chat: ChatModel, _ bot: Bot, _ roster: RosterModel) {
        chat.draft = text
        chat.send(to: bot, through: roster)
    }

    @Test func leaveToRunACommandIsPutToThePersonAndTheirAnswerReachesTheBot() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me approve quick", chat, bot, roster)
        try await until("the card") { !chat.questions.open.isEmpty }
        let asked = try #require(chat.questions.open.first)
        guard case .approval(let approval) = asked.question.kind else { Issue.record("not an approval"); return }
        #expect(approval.subject == .command("rm -rf /pretend/tmp/build-cache && df -h /pretend"))
        // The bot is waiting on the person, not working: no "Thinking…" under the card.
        #expect(!chat.isWaitingForWords)
        #expect(roster.rowPreview(for: bot) == "Waiting for approval")

        chat.questions.answer(asked.instance, with: .approval(.once), for: bot)
        try await until("the answer") { !chat.questions.isWaiting }
        try await until("the turn to end", within: 20) { !chat.isWorking }
        let heard = try await answers(pretend)
        #expect((heard.last?["result"] as? [String: Any])?["choice"] as? String == "once")
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        // Sent over the older route, which acknowledges nothing: said as chosen, not as done.
        #expect(ending.text == "You chose Allow once")
        #expect(ending.mark == .allowed)
        // Its line sits among the stored rows, after the message that led to it.
        #expect(chat.settledQuestions.values.flatMap { $0 }.count == 1)
        #expect(chat.sendProblem == nil)
    }

    @Test func aQuestionTheGatewayStopsWaitingOnLeavesALineSayingSo() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me approve short quick", chat, bot, roster)
        try await until("the card") { !chat.questions.open.isEmpty }
        try await until("the deadline", within: 10) { !chat.questions.isWaiting }
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Timed out")
        // Too late now: an answer to it goes nowhere and changes nothing.
        chat.questions.answer(chat.questions.all[0].instance, with: .approval(.once), for: bot)
        #expect(chat.questions.all.first?.state == .settled(ending))
    }

    @Test func clarifyAndASecretAreAnsweredAndTheSecretIsNotKept() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me clarify secret quick", chat, bot, roster)
        try await until("the questions") { !chat.questions.open.isEmpty }
        let clarify = try #require(chat.questions.open.first)
        chat.questions.answer(clarify.instance, with: .clarify(["q1": .one("Time Machine"), "q2": .several(["Disk health", "Sync age"])]), for: bot)
        try await until("the secret") { chat.questions.open.contains { if case .secret = $0.question.kind { true } else { false } } }
        let secret = try #require(chat.questions.open.first)
        chat.questions.answer(secret.instance, with: .value("pretend-secret-123"), for: bot)
        try await until("the turn to end", within: 20) { !chat.isWorking }

        let heard = try await answers(pretend)
        let asked = try #require(heard.first { $0["method"] as? String == "clarify" })
        let sent = (asked["result"] as? [String: Any])?["answers"] as? [String: Any]
        #expect(sent?["q1"] as? String == "Time Machine")
        #expect(sent?["q2"] as? String == #"["Disk health","Sync age"]"#)
        let given = try #require(heard.first { $0["method"] as? String == "secret" })
        #expect(given["matches"] as? Bool == true)

        // Nothing here holds what was typed: the line says only that it was given.
        let kept = String(reflecting: chat.questions.all) + chat.items.map { "\($0)" }.joined()
        #expect(!kept.contains("pretend-secret-123"))
        guard case .settled(let ending)? = chat.questions.all.last?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Provided")
        #expect(ending.detail == "PRETEND_API_KEY")
    }

    @Test func clarifyIsAnsweredOneQuestionAtATimeFromTheMessageBox() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me clarify quick", chat, bot, roster)
        try await until("the questions") { chat.questions.clarifying != nil }
        let asked = try #require(chat.questions.clarifying)
        // Not a card in the chat: the panel over the message box asks it.
        #expect(chat.questions.cards.isEmpty)
        // Nothing typed and nothing picked: Return does nothing.
        #expect(!chat.questions.answerShowing(with: "  ", for: bot))
        // The first takes one answer: the last pick stands.
        chat.questions.toggle(0, in: asked.instance)
        chat.questions.toggle(1, in: asked.instance)
        #expect(chat.questions.answerShowing(with: "", for: bot))
        #expect(chat.questions.progress(of: asked).place == 1)
        // The second takes several, and words typed join what is picked.
        chat.questions.toggle(0, in: asked.instance)
        chat.questions.toggle(2, in: asked.instance)
        #expect(chat.questions.answerShowing(with: "and the UPS", for: bot))
        try await until("the turn to end", within: 20) { !chat.isWorking }

        let heard = try await answers(pretend)
        // The first was locked as it was given; the set went whole at the end.
        let lock = try #require(heard.first { $0["method"] as? String == "clarify.lock" })
        #expect(lock["question"] as? String == "q1")
        #expect(lock["answer"] as? String == "The pretend NAS")
        let set = try #require(heard.first { $0["method"] as? String == "clarify" })
        let sent = (set["result"] as? [String: Any])?["answers"] as? [String: Any]
        #expect(sent?["q1"] as? String == "The pretend NAS")
        #expect(sent?["q2"] as? String == #"["Disk health","Sync age","and the UPS"]"#)
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Answered · The pretend NAS · Disk health, Sync age, and the UPS")
    }

    @Test func requestsTheAppCannotShowAreAnsweredAtOnce() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let started = Date.now
        send("ask me bridges quick", chat, bot, roster)
        try await until("the turn to end", within: 30) { !chat.isWorking }
        let heard = try await answers(pretend)
        let methods = Set(heard.compactMap { $0["method"] as? String })
        for method in ["preview.read", "preview.act", "terminal.read", "window.read", "tour", "theme.apply", "theme.pick",
                       "setup_beat", "vault.code", "vault.unlock_prompt", "vault.save_login", "made.up.method"] {
            #expect(methods.contains(method), "\(method) went unanswered")
        }
        #expect(!heard.contains { $0["result"] as? String == "unanswered" })
        // Answered at once: twelve requests did not wait out a five-second deadline each.
        #expect(Date.now.timeIntervalSince(started) < 15)
        #expect(chat.questions.all.isEmpty)
    }

    @Test func theSessionAuthoritysLeaveAndQuestionsAreAnsweredToo() async throws {
        let pretend = try await Pretend(whenBusy: "authority")
        let (roster, bot, chat) = try await open(pretend)
        send("ask me approve clarify quick", chat, bot, roster)
        try await until("the card") { !chat.questions.open.isEmpty }
        let approval = try #require(chat.questions.open.first)
        #expect(approval.question.route == .prompt(generation: 7))
        chat.questions.answer(approval.instance, with: .approval(.deny), for: bot)
        // Clarify comes as one set, since the authority said it can.
        try await until("the questions") { chat.questions.open.contains { if case .clarify = $0.question.kind { true } else { false } } }
        let clarify = try #require(chat.questions.open.first)
        if case .request = clarify.question.route {} else { Issue.record("clarify should come as one request") }
        chat.questions.answer(clarify.instance, with: .skipped, for: bot)
        try await until("the turn to end", within: 20) { !chat.isWorking }
        let heard = try await answers(pretend)
        #expect((heard.first?["result"] as? [String: Any])?["choice"] as? String == "deny")
        #expect(heard.contains { $0["method"] as? String == "clarify" })
        // The gateway says the prompt is settled before it answers ours: still our answer.
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Denied")
    }

    @Test func aQuestionLostWithItsConnectionIsOpenAgainWhenPutAgain() throws {
        let questions = ChatQuestions()
        let first = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let second = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let question = BotQuestion(id: "srq-1", sessionID: "live-1", route: .request(.string("srq-1")), kind: .sudo(command: "sudo ls"))
        questions.ask(question, on: first)
        // The same question again changes nothing.
        questions.ask(question, on: first)
        #expect(questions.all.count == 1)
        questions.lost(on: first)
        #expect(!questions.isWaiting)
        #expect(questions.lost.count == 1)
        // Handed back by the gateway when the chat is opened on a new connection.
        questions.ask(question, on: second)
        #expect(questions.open.first?.client === second)
        #expect(questions.all.count == 1)
        // The gateway says it is over: the line says so, and a late repeat does not reopen it.
        questions.ended("srq-1", inSession: "live-1", on: second, reason: "resolved")
        guard case .settled(let ending)? = questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Answered elsewhere")
        questions.ask(question, on: second)
        #expect(!questions.isWaiting)
    }

    @Test func linesSayWhatWasDecidedAndNeverWhatWasTyped() {
        let secret = BotQuestion(id: "k", sessionID: "s", route: .request(.string("k")), kind: .secret(name: "KEY", prompt: "p"))
        #expect(ChatQuestions.ending(for: secret, .value("typed-secret")) == .init(mark: .none, text: "Provided", detail: "KEY"))
        #expect(ChatQuestions.ending(for: secret, .value("")).text == "Skipped")
        let sudo = BotQuestion(id: "s", sessionID: "s", route: .request(.string("s")), kind: .sudo(command: "sudo ls"))
        #expect(ChatQuestions.ending(for: sudo, .value("pw")).text == "Password provided")
        let site = BotQuestion(id: "a", sessionID: "s", route: .request(.string("a")),
                               kind: .approval(Approval(subject: .site(host: "x.example", label: nil), choices: [.once, .deny])))
        #expect(ChatQuestions.ending(for: site, .approval(.deny, reason: "not that")) == .init(mark: .denied, text: "Denied", detail: "x.example", quote: "not that"))
    }

    @Test func nothingIsAnsweredInTheMomentAQuestionArrives() async throws {
        let before = ChatQuestions.arrivalGuard
        ChatQuestions.arrivalGuard = 0.4
        defer { ChatQuestions.arrivalGuard = before }
        let questions = ChatQuestions()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let bot = try #require(try JSONDecoder().decode([Bot].self, from: Data(#"[{"name":"default","is_default":true}]"#.utf8)).first)
        questions.ask(BotQuestion(id: "srq-1", sessionID: "live-1", route: .request(.string("srq-1")),
                                  kind: .approval(Approval(subject: .command("ls"), choices: [.once, .deny]))), on: client)
        let asked = try #require(questions.open.first)
        questions.shown(asked.instance)
        // A key already on its way as the card came: neither an answer nor a dismissal.
        questions.answer(asked.instance, with: .approval(.once), for: bot)
        questions.answer(asked.instance, with: .skipped, for: bot)
        #expect(questions.open.first?.state == .open)
    }

    @Test func anEndIsTakenOnlyForTheChatAndConnectionItNames() throws {
        let questions = ChatQuestions()
        let one = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let other = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        questions.ask(BotQuestion(id: "p1", sessionID: "live-1", route: .prompt(generation: 1),
                                  kind: .approval(Approval(subject: .command("ls"), choices: [.once, .deny]))), on: one)
        questions.ended("p1", inSession: "live-2", on: one, reason: nil)
        questions.ended("p1", inSession: "live-1", on: other, reason: nil)
        #expect(questions.isWaiting)
        questions.ended("p1", inSession: "live-1", on: one, reason: nil)
        #expect(!questions.isWaiting)
    }

    @Test func aNumberThatPicksNothingIsLeftToBeTyped() throws {
        let questions = ChatQuestions()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        questions.ask(BotQuestion(id: "c", sessionID: "live-1", route: .request(.string("c")), kind: .clarify(Clarify(questions: [
            .init(id: "q1", text: "How many days?"),
        ]))), on: client)
        let asked = try #require(questions.clarifying)
        #expect(!questions.toggle(1, in: asked.instance))
    }

    @Test func whatWasBeingTypedIsPutAsideWhileClarifyingQuestionsAreOpen() throws {
        let chat = ChatModel()
        chat.draft = "half a message"
        let instance = UUID()
        chat.clarifyingChanged(to: instance)
        #expect(chat.draft.isEmpty)
        chat.draft = "an answer never sent"
        chat.clarifyingChanged(to: nil)
        #expect(chat.draft == "half a message")
    }

    @Test func textThatWouldTurnOrHideIsWrittenOut() {
        // A right-to-left override makes "exe.txt" read as "txt.exe".
        #expect(ShownText.visible("ls \u{202E}txt.exe", oneLine: false) == "ls ⟨U+202E⟩txt.exe")
        #expect(ShownText.visible("api.example.com\nevil.example", oneLine: true) == "api.example.com⏎evil.example")
        #expect(ShownText.visible("echo ok\nls", oneLine: false) == "echo ok\nls")
        #expect(ShownText.visible("a\u{200B}b\u{7}", oneLine: true) == "a⟨U+200B⟩b⟨U+0007⟩")
    }

    @Test func aQuestionForAChatNobodyOpenedIsRefusedNotLeftWaiting() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        roster.unclaimedWait = .milliseconds(300)
        send("ask me ghost short quick", chat, bot, roster)
        try await until("the turn to end", within: 20) { !chat.isWorking }
        let heard = try await answers(pretend)
        let ghost = try #require(heard.first { $0["method"] as? String == "ghost" })
        // Refused, well before the gateway's own 4 s.
        #expect(((ghost["result"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int == -32603)
        #expect(chat.questions.all.isEmpty)
    }

    @Test func aSecondSetDoesNotTakeWhatWasTypedForTheFirst() {
        let chat = ChatModel()
        chat.draft = "half a message"
        chat.clarifyingChanged(to: UUID())
        chat.draft = "words for the first set"
        chat.clarifyingChanged(to: UUID())
        #expect(chat.draft.isEmpty)
        chat.clarifyingChanged(to: nil)
        #expect(chat.draft == "half a message")
    }

    @Test func separatorsAndJoinersAreShownForWhatTheyDo() {
        #expect(ShownText.visible("a\u{2028}b", oneLine: true) == "a⏎b")
        #expect(ShownText.visible("a\u{2029}b", oneLine: false) == "a\nb")
        // An emoji made of joined parts stays one in a bot's sentence; in a name the joiner shows.
        #expect(ShownText.visible("👩\u{200D}💻", oneLine: false, prose: true) == "👩\u{200D}💻")
        #expect(ShownText.visible("KEY\u{200D}", oneLine: true) == "KEY⟨U+200D⟩")
        // In a command the joiner hides, so it is written out, however many lines.
        #expect(ShownText.visible("/bin/l\u{200D}s", oneLine: false) == "/bin/l⟨U+200D⟩s")
    }

    @Test func wordsGivenBackOrSuggestedGoToTheMessageNotTheAnswer() {
        let chat = ChatModel()
        chat.clarifyingChanged(to: UUID())
        chat.suggest("What's a routine?")
        #expect(chat.draft.isEmpty)
        chat.clarifyingChanged(to: nil)
        #expect(chat.draft == "What's a routine?")
    }

    @Test func aChoiceIsNotPickedInTheMomentASetArrives() throws {
        let before = ChatQuestions.arrivalGuard
        ChatQuestions.arrivalGuard = 0.4
        defer { ChatQuestions.arrivalGuard = before }
        let questions = ChatQuestions()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        questions.ask(BotQuestion(id: "c", sessionID: "live-1", route: .request(.string("c")), kind: .clarify(Clarify(questions: [
            .init(id: "q1", text: "Which?", choices: ["a", "b"]),
        ]))), on: client)
        let asked = try #require(questions.clarifying)
        // The key is taken (it is not typed), but nothing is picked.
        #expect(questions.toggle(0, in: asked.instance))
        #expect(questions.progress(of: asked).picked["q1", default: []].isEmpty)
    }

    @Test func aQuestionAskedBeforeTheAppStartedIsShownWithoutSendingAnything() async throws {
        let pretend = try await Pretend()
        let (first, bot, chat) = try await open(pretend)
        send("ask me approve quick", chat, bot, first)
        try await until("the card in the first app") { !chat.questions.cards.isEmpty }
        // Another run of the app, as after a restart: nothing sent, the question comes up.
        let (second, secondBot, secondChat) = try await open(pretend)
        try await until("the card in the second app") { !secondChat.questions.cards.isEmpty }
        let asked = try #require(secondChat.questions.cards.first)
        guard case .approval = asked.question.kind else { Issue.record("not the approval"); return }
        #expect(second.rowPreview(for: secondBot) == "Waiting for approval")
        // Answered from the second app, the bot carries on.
        secondChat.questions.answer(asked.instance, with: .approval(.once), for: secondBot)
        try await until("the first app to finish", within: 20) { !chat.isWorking }
        let heard = try await answers(pretend)
        #expect((heard.last?["result"] as? [String: Any])?["choice"] as? String == "once")
    }

    @Test func leaveAnsweredInAnotherAppIsNoLongerOfferedOnceTheTurnEnds() async throws {
        let pretend = try await Pretend()
        let (first, bot, chat) = try await open(pretend)
        send("ask me approve quick", chat, bot, first)
        try await until("the card in the first app") { !chat.questions.cards.isEmpty }
        let stale = try #require(chat.questions.cards.first)
        let (_, secondBot, secondChat) = try await open(pretend)
        try await until("the card in the second app") { !secondChat.questions.cards.isEmpty }
        let asked = try #require(secondChat.questions.cards.first)
        secondChat.questions.answer(asked.instance, with: .approval(.deny), for: secondBot)
        // The older route acknowledges nothing: the line says what was chosen, not that it was done.
        try await until("the second app's line") { secondChat.questions.cards.isEmpty }
        guard case .settled(let chosen)? = secondChat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(chosen.text == "You chose Deny")
        // The gateway tells the first app nothing; once the turn is over, its card goes.
        try await until("the first app to finish", within: 20) { !chat.isWorking }
        try await until("the first app's card to go") { chat.questions.cards.isEmpty }
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "No longer asked")
        #expect(!chat.questions.answer(stale.instance, with: .approval(.once), for: bot))
    }

    @Test func aBotListedWhileALookIsUnderWayIsLookedAtToo() async throws {
        // Each list of the chats at work comes 4 s after it was asked for, as it was then.
        let pretend = try await Pretend(whenBusy: "active-slow")
        let (first, _, _) = try await open(pretend)
        // While the first look is under way, another app starts a chat for a bot that had
        // none, and the bot asks; this app hears of the chat while still looking.
        let (other, _, _) = try await open(pretend)
        let books = try #require(other.bots.first { $0.name == "books" })
        let booksChat = other.chat(for: books)
        await booksChat.load(books, from: other)
        send("ask me approve quick", booksChat, books, other)
        try await until("the other app's card") { !booksChat.questions.cards.isEmpty }
        #expect(await first.refreshBots())
        let listed = try #require(first.bots.first { $0.name == "books" })
        #expect(listed.chat != nil)
        try await until("the card in the first app", within: 20) { !first.chat(for: listed).questions.cards.isEmpty }
    }

    /// Two bots of the first app asking for leave, garden's in its own chat.
    private func twoBotsAsking(_ pretend: Pretend, _ what: String = "approve") async throws {
        let (first, bot, chat) = try await open(pretend)
        send("ask me \(what) quick", chat, bot, first)
        let garden = try #require(first.bots.first { $0.name == "garden" })
        let gardenChat = first.chat(for: garden)
        await gardenChat.load(garden, from: first)
        send("ask me \(what) quick", gardenChat, garden, first)
        try await until("both cards in the first app") { !chat.questions.cards.isEmpty && !gardenChat.questions.cards.isEmpty }
    }

    @Test func questionsWaitingAtLaunchAreShownWhenTheChatsAtWorkComeSlowly() async throws {
        let pretend = try await Pretend(whenBusy: "active-slow")
        try await twoBotsAsking(pretend)
        // Another run of the app: its first look is asked for before its bots are read.
        let (second, _, mainChat) = try await open(pretend)
        let garden = try #require(second.bots.first { $0.name == "garden" })
        try await until("both cards in the second app", within: 20) {
            !mainChat.questions.cards.isEmpty && !second.chat(for: garden).questions.cards.isEmpty
        }
    }

    @Test func whereTheGatewayGreetsLateEachBotIsStillAskedAboutOnItsOwnAfterAReconnect() async throws {
        // The session authority, whose list of chats at work is one bot's, greets 0.3 s late.
        let pretend = try await Pretend(whenBusy: "authority+late-ready")
        let (second, _, _) = try await open(pretend)
        // Its first look, with nothing waiting yet, is over.
        try await Task.sleep(for: .milliseconds(500))
        try await twoBotsAsking(pretend, "secret")
        let garden = try #require(second.bots.first { $0.name == "garden" })
        // Only the bot showing is asked about as chats change, so garden's waits unseen here.
        try await Task.sleep(for: .milliseconds(500))
        #expect(second.chat(for: garden).questions.cards.isEmpty)
        // The connection drops and is made again; the gateway greets it late.
        var drop = URLRequest(url: URL(string: "http://\(pretend.address)/api/drop")!)
        drop.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: drop)
        try await until("garden's card in the second app", within: 20) { !second.chat(for: garden).questions.cards.isEmpty }
    }

    /// A chat the gateway let go of and `/yolo` opened again is taken up as any opening is:
    /// the question waiting in it, which this app was never sent, is put up from its snapshot.
    @Test func aChatYoloOpensAgainIsTakenUpWithItsQuestions() async throws {
        let pretend = try await Pretend()
        let (first, bot, chat) = try await open(pretend)
        await first.readCommands()
        chat.draft = "/status"
        chat.submit(to: bot, through: first)
        try await until("the status") { chat.notes.last?.text != nil }
        // The gateway lets go of every open chat; another app opens this one and its bot asks.
        var letGo = URLRequest(url: URL(string: "http://\(pretend.address)/api/let-go")!)
        letGo.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: letGo)
        let (second, secondBot, secondChat) = try await open(pretend)
        send("ask me approve quick", secondChat, secondBot, second)
        try await until("the card in the other app") { !secondChat.questions.cards.isEmpty }
        try await Task.sleep(for: .milliseconds(500))
        #expect(chat.questions.cards.isEmpty)
        chat.draft = "/yolo off"
        chat.submit(to: bot, through: first)
        try await until("the card in this app") { !chat.questions.cards.isEmpty }
        try await until("/yolo off to finish") { chat.notes.last?.text != nil }
        #expect(chat.notes.last?.text == "Approvals are no longer skipped in this chat.")
        let asked = try #require(secondChat.questions.cards.first)
        secondChat.questions.answer(asked.instance, with: .approval(.deny), for: secondBot)
        try await until("the other app to finish", within: 20) { !secondChat.isWorking }
    }
}
