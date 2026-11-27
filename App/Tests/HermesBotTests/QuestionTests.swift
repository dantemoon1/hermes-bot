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

    /// The connection card shown in a chat, as it now stands.
    private func card(_ chat: ChatModel) -> (asked: ChatQuestions.Asked, card: ConnectionRequest)? {
        guard let asked = chat.questions.cards.first, case .connection(let card) = asked.question.kind else { return nil }
        return (asked, card)
    }

    private func row(_ name: String, _ chat: ChatModel) -> ConnectionTarget? {
        card(chat)?.card.targets.first { $0.name == name }
    }

    @Test func aConnectionCardFollowsTheGatewaysStatesAndLeavesALine() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me connect", chat, bot, roster)
        try await until("the card") { card(chat) != nil }
        let asked = try #require(card(chat)?.asked)
        #expect(card(chat)?.card.targets.map(\.name) == ["notion", "filesystem"])
        #expect(roster.rowPreview(for: bot) == "Waiting to connect")
        // The hosted app's link was minted before the card came: it is to be opened, and the
        // card has not been told the person opened it.
        #expect(row("notion", chat)?.state == .initiated)
        #expect(row("notion", chat)?.move == .open(URL(string: "https://auth.example.com/oauth/authorize?client=pretend&attempt=1")!))
        #expect(asked.opened.isEmpty)
        // What the server would run, where, and with which variables.
        #expect(row("filesystem", chat)?.launch?.cwd == "/pretend/work")
        #expect(row("filesystem", chat)?.launch?.env == ["ALLOWED_ROOT", "FS_INDEX_KEY"])

        #expect(chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["notion": .skip]), for: bot))
        try await until("the row to be skipped") { row("notion", chat)?.state == .skipped }
        try await until("the first move to land") { card(chat)?.asked.isMoving == false }

        // Without the secret: the row stays pending and says what it waits for.
        #expect(chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["filesystem": .approve(values: ["ALLOWED_ROOT": "/pretend/docs"])]), for: bot))
        try await until("the row to ask again") { row("filesystem", chat)?.detail == "waiting for FS_INDEX_KEY" }
        #expect(row("filesystem", chat)?.state == .pending)
        #expect(row("filesystem", chat)?.fields.map(\.name) == ["FS_INDEX_KEY"])
        try await until("the move to land") { card(chat)?.asked.isMoving == false }

        let secret = "pretend-secret-123"
        // As the card sends it: the plain value sent before, with the secret now typed.
        #expect(chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["filesystem": .approve(values: [
            "ALLOWED_ROOT": "/pretend/docs", "FS_INDEX_KEY": secret,
        ])]), for: bot))
        // Installing: nothing to press while the gateway works.
        try await until("the install to begin") { row("filesystem", chat)?.state == .initiated }
        #expect(row("filesystem", chat)?.move == ConnectionTarget.Move.none)
        try await until("the card to settle") { chat.questions.cards.isEmpty }
        try await until("the turn to end", within: 20) { !chat.isWorking }

        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Skipped Notion · Installed Filesystem")
        #expect(chat.questions.all.first?.isProvisional == false)
        let heard = try await answers(pretend)
        let installed = try #require(heard.last { ($0["moves"] as? [String: Any])?["filesystem"] != nil })
        #expect(installed["secret_matches"] as? Bool == true)
        // Nothing here holds the value typed.
        #expect(!String(reflecting: chat.questions.all).contains(secret))
    }

    @Test func anExpiredSignInIsTriedAgainAndItsNewLinkWaitsForAClick() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me connect expire", chat, bot, roster)
        try await until("the card") { card(chat) != nil }
        let asked = try #require(card(chat)?.asked)
        chat.questions.opened(asked.instance, row: "notion")
        try await until("the link to run out") { row("notion", chat)?.state == .expired }
        // Still waiting on the person: skippable, and tried again rather than reopened.
        #expect(row("notion", chat)?.isResolved == false)
        #expect(row("notion", chat)?.move == .retry)
        #expect(card(chat)?.asked.opened.isEmpty == true)
        #expect(chat.questions.retry(asked.instance, row: "notion", for: bot))
        try await until("a fresh link") { row("notion", chat)?.state == .initiated }
        #expect(row("notion", chat)?.move == .open(URL(string: "https://auth.example.com/oauth/authorize?client=pretend&attempt=2")!))
        #expect(card(chat)?.asked.opened.isEmpty == true)
        let heard = try await answers(pretend)
        #expect(heard.contains { $0["method"] as? String == "connectors.connect" && $0["reconnect"] as? Bool == true })
        chat.questions.respond(asked.instance, with: ConnectionAnswer(isContinue: true), for: bot)
        try await until("the card to settle") { chat.questions.cards.isEmpty }
    }

    @Test func aFailedSignInOffersNoDeadLink() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me connect fail", chat, bot, roster)
        try await until("the sign-in to fail") { row("notion", chat)?.state == .failed }
        // Hermes leaves the old link on the row; it is never offered.
        #expect(row("notion", chat)?.connectURL != nil)
        #expect(row("notion", chat)?.move == .retry)
        #expect(row("notion", chat)?.detail == "The vendor refused the sign-in.")
        let asked = try #require(card(chat)?.asked)
        chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["notion": .skip, "filesystem": .skip]), for: bot)
        try await until("the card to settle") { chat.questions.cards.isEmpty }
    }

    @Test func aFailedInstallAsksForItsValuesAgain() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me connect installfail", chat, bot, roster)
        try await until("the card") { card(chat) != nil }
        let asked = try #require(card(chat)?.asked)
        chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["notion": .skip, "filesystem": .approve(values: [
            "ALLOWED_ROOT": "/pretend/docs", "FS_INDEX_KEY": "pretend-secret-123",
        ])]), for: bot)
        try await until("the install to fail") { row("filesystem", chat)?.state == .failed }
        #expect(row("filesystem", chat)?.isResolved == false)
        #expect(row("filesystem", chat)?.move == .retry)
        #expect(row("filesystem", chat)?.fields.map(\.name) == ["ALLOWED_ROOT", "FS_INDEX_KEY"])
        try await until("the move to land") { card(chat)?.asked.isMoving == false }
        chat.questions.respond(asked.instance, with: ConnectionAnswer(isContinue: true), for: bot)
        try await until("the card to settle") { chat.questions.cards.isEmpty }
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        // Continue leaves a failed server not connected, as Hermes stamps it.
        #expect(ending.text == "Skipped Notion · Left Filesystem")
    }

    @Test func aCatalogCardShowsWhereItComesFromAndAFailedRowIsDone() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me connect catalogfail", chat, bot, roster)
        try await until("the card") { card(chat) != nil }
        let asked = try #require(card(chat)?.asked)
        let plugin = try #require(row("pretend-charts", chat))
        #expect(plugin.source?.sha == "0123456789abcdef0123456789abcdef01234567")
        #expect(plugin.source?.targetProfile == "default")
        #expect(plugin.tier == .verified)
        #expect(plugin.canBeApproved)
        chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["pretend-charts": .approve(values: [:])]), for: bot)
        try await until("the plugin to fail") { row("pretend-charts", chat)?.state == .failed }
        // Done for Hermes: it carries its reason, and the card waits only on the skill.
        #expect(row("pretend-charts", chat)?.isResolved == true)
        #expect(card(chat) != nil)
        try await until("the move to land") { card(chat)?.asked.isMoving == false }
        chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["@pretend/notes-skill": .approve(values: [:])]), for: bot)
        try await until("the card to settle") { chat.questions.cards.isEmpty }
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Pretend Charts didn't work · Installed Notes")
    }

    @Test func theDirectoryCardSaysWhatItWasWhenItSettles() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me connect directory", chat, bot, roster)
        try await until("the card") { card(chat) != nil }
        let asked = try #require(card(chat)?.asked)
        #expect(card(chat)?.card.suggested == ["notion", "linear"])
        chat.questions.respond(asked.instance, with: ConnectionAnswer(isContinue: true), for: bot)
        try await until("the card to settle") { chat.questions.cards.isEmpty }
        // The settling update carries no `display`: the card is still known as the directory.
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Saw the apps to connect")
    }

    @Test func aServerThatCannotSayWhatItRunsIsNotOffered() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me connect launchless short", chat, bot, roster)
        try await until("the card") { card(chat) != nil }
        #expect(row("filesystem", chat)?.launch == nil)
        #expect(row("filesystem", chat)?.canBeApproved == false)
        try await until("the card to time out", within: 20) { chat.questions.cards.isEmpty }
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.mark == .timedOut)
    }

    private func connectionQuestion(_ id: String, session: String, seq: Int = 1, settled: Bool = false, state: ConnectionTarget.State = .pending) -> (BotQuestion, ConnectionRequest) {
        let request = ConnectionRequest(opID: id, seq: seq, deadline: nil, targets: [
            ConnectionTarget(name: "notion", kind: .connector, action: .connect, state: state),
        ], settledBy: settled ? "all_resolved" : nil, isSettled: settled)
        return (BotQuestion(id: id, sessionID: session, route: .connection, kind: .connection(request)), request)
    }

    @Test func aCardWhoseTurnEndedIsOverAndTheGatewaysWordStillTakesItsPlace() throws {
        let questions = ChatQuestions()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let (question, _) = connectionQuestion("op-t", session: "live-1")
        questions.ask(question, on: client)
        #expect(questions.isWaiting)
        // The turn the card held has ended: its settling update was missed.
        questions.turnEnded(inSession: "live-1", on: client)
        #expect(!questions.isWaiting)
        #expect(questions.all.first?.isProvisional == true)
        // The gateway's own word comes after all, and says how.
        let (_, final) = connectionQuestion("op-t", session: "live-1", seq: 3, settled: true, state: .skipped)
        questions.connectionChanged(final, inSession: "live-1", on: client)
        guard case .settled(let ending)? = questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Skipped Notion")
        #expect(questions.all.first?.isProvisional == false)
        // An older word changes nothing now.
        let (_, older) = connectionQuestion("op-t", session: "live-1", seq: 2, settled: true, state: .connected)
        questions.connectionChanged(older, inSession: "live-1", on: client)
        if case .settled(let still)? = questions.all.first?.state { #expect(still.text == "Skipped Notion") }
    }

    @Test func aMoveOnACardTheGatewayClosedSaysAnsweredElsewhere() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        // A card the gateway no longer has open.
        let (question, _) = connectionQuestion("op-gone", session: "live-x")
        chat.questions.ask(question, on: client)
        let asked = try #require(chat.questions.cards.first)
        #expect(chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["notion": .skip]), for: bot))
        try await until("the card to close") { chat.questions.cards.isEmpty }
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Answered elsewhere")
        #expect(!chat.questions.isWaiting)
    }

    @Test func aCardChangedOrSettledWhileItsChatOpensIsShownAsItNowStands() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        // Asked in a chat not yet claimed, then settled before the chat is opened.
        let (gone, _) = connectionQuestion("op-a", session: "live-new")
        roster.asked(gone, on: client)
        let (_, settled) = connectionQuestion("op-a", session: "live-new", seq: 2, settled: true, state: .skipped)
        roster.connectionChanged(settled, inSession: "live-new", on: client)
        // And another changed meanwhile.
        let (moved, _) = connectionQuestion("op-b", session: "live-new")
        roster.asked(moved, on: client)
        let (_, skipped) = connectionQuestion("op-b", session: "live-new", seq: 2, state: .skipped)
        roster.connectionChanged(skipped, inSession: "live-new", on: client)
        // The opening's snapshot, taken earlier, still has both as first asked.
        roster.chatOpened(LiveChat(sessionID: "live-new", waiting: [gone, moved]), of: bot, on: client)
        #expect(chat.questions.all.map(\.question.id) == ["op-b"])
        #expect(row("notion", chat)?.state == .skipped)
    }

    private func installCard(_ id: String, seq: Int, state: ConnectionTarget.State = .pending, fields: [String], link: String? = nil) -> ConnectionRequest {
        ConnectionRequest(opID: id, seq: seq, deadline: nil, targets: [
            ConnectionTarget(name: "fs", kind: .mcp, action: .install, state: state, connectURL: link.flatMap(URL.init(string:)),
                             fields: fields.map { ConnectionTarget.Field(name: $0, isRequired: true, isSecret: true) },
                             launch: ConnectionTarget.Launch(isRemote: false, target: "npx fs")),
        ])
    }

    @Test func aCardAsksForEveryValueARowHasAskedFor() throws {
        let questions = ChatQuestions()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let first = installCard("op-f", seq: 1, fields: ["A", "B"])
        questions.ask(BotQuestion(id: "op-f", sessionID: "live-1", route: .connection, kind: .connection(first)), on: client)
        // Hermes asks again only for what is missing, and kept neither: both are asked for together.
        questions.connectionChanged(installCard("op-f", seq: 2, fields: ["B"]), inSession: "live-1", on: client)
        #expect(shownFields(questions)["fs"]?.map(\.name) == ["A", "B"])
        questions.connectionChanged(installCard("op-f", seq: 3, fields: ["A"]), inSession: "live-1", on: client)
        #expect(shownFields(questions)["fs"]?.map(\.name) == ["A", "B"])
    }

    @Test func aLinkMadeAfreshIsNotOneThePersonOpened() throws {
        let questions = ChatQuestions()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let card = installCard("op-o", seq: 1, state: .initiated, fields: [], link: "https://auth.example.com/1")
        questions.ask(BotQuestion(id: "op-o", sessionID: "live-1", route: .connection, kind: .connection(card)), on: client)
        let asked = try #require(questions.cards.first)
        questions.opened(asked.instance, row: "fs")
        // The same link again: still opened.
        questions.connectionChanged(installCard("op-o", seq: 2, state: .initiated, fields: [], link: "https://auth.example.com/1"), inSession: "live-1", on: client)
        #expect(questions.cards.first?.opened == ["fs"])
        // Made afresh elsewhere, still initiated: not one opened here.
        questions.connectionChanged(installCard("op-o", seq: 3, state: .initiated, fields: [], link: "https://auth.example.com/2"), inSession: "live-1", on: client)
        #expect(questions.cards.first?.opened.isEmpty == true)
    }

    @Test func theLineACardLeavesSaysWhatWasAmissAndAStop() {
        let caveat = ConnectionRequest(opID: "op-c", seq: 3, deadline: nil, targets: [
            ConnectionTarget(name: "pretend_mcp", kind: .mcp, action: .authorize, state: .connected, caveat: "its tools couldn't be listed"),
        ], settledBy: "all_resolved", isSettled: true)
        let line = ChatQuestions.ending(for: caveat)
        #expect(line.text == "Authorized Pretend MCP, but its tools couldn't be listed")
        #expect(line.mark == .none)
        let stopped = ConnectionRequest(opID: "op-d", seq: 2, deadline: nil, targets: [], suggested: ["notion"], settledBy: "interrupt", isSettled: true)
        #expect(ChatQuestions.ending(for: stopped).text == "Stopped")
    }

    @Test func aTurnThatEndsWhileItsChatOpensLeavesNoCardFromTheSnapshot() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        let (old, _) = connectionQuestion("op-old", session: "live-late")
        roster.asked(old, on: client)
        // The turn that card held ends before the chat is claimed; its settling update was missed.
        roster.turnEnded(inSession: "live-late", on: client)
        // A card asked after it is its own.
        let (fresh, _) = connectionQuestion("op-fresh", session: "live-late")
        roster.asked(fresh, on: client)
        roster.chatOpened(LiveChat(sessionID: "live-late", waiting: [old]), of: bot, on: client)
        #expect(chat.questions.all.map(\.question.id) == ["op-fresh"])
        // And one the gateway said was over is not put up again by a late request.
        let (_, settled) = connectionQuestion("op-fresh", session: "live-late", seq: 2, settled: true)
        roster.connectionChanged(settled, inSession: "live-late", on: client)
        let (again, _) = connectionQuestion("op-again", session: "live-late")
        roster.connectionChanged(ConnectionRequest(opID: "op-again", seq: 5, deadline: nil, targets: [], isSettled: true), inSession: "live-late", on: client)
        roster.asked(again, on: client)
        #expect(!chat.questions.all.contains { $0.question.id == "op-again" })
    }

    @Test func whatARowAskedForIsKeptWhateverOrderSnapshotsComeInAndOverAReconnect() throws {
        let questions = ChatQuestions()
        let first = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let second = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        // The opening's snapshot (seq 2, narrowed) is put up before the request it follows (seq 1).
        questions.ask(BotQuestion(id: "op-r", sessionID: "live-1", route: .connection, kind: .connection(installCard("op-r", seq: 2, fields: ["B"]))), on: first)
        questions.ask(BotQuestion(id: "op-r", sessionID: "live-1", route: .connection, kind: .connection(installCard("op-r", seq: 1, fields: ["A", "B"]))), on: first)
        #expect(Set(shownFields(questions)["fs"]?.map(\.name) ?? []) == ["A", "B"])
        // Lost with its connection and handed back narrowed on the next: still both.
        questions.lost(on: first)
        questions.ask(BotQuestion(id: "op-r", sessionID: "live-1", route: .connection, kind: .connection(installCard("op-r", seq: 3, fields: ["B"]))), on: second)
        #expect(Set(shownFields(questions)["fs"]?.map(\.name) ?? []) == ["A", "B"])
    }

    @Test func aSnapshotCardNotKnownToBeTheEndedTurnsIsCheckedWithTheGateway() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        roster.turnEnded(inSession: "live-main", on: client)
        // A card the app never heard of, in a snapshot taken before the end: the gateway has no
        // such card open, so it does not stay.
        let (unknown, _) = connectionQuestion("op-unknown", session: "live-main")
        roster.chatOpened(LiveChat(sessionID: "live-main", waiting: [unknown]), of: bot, on: client)
        try await until("the card to be found over") { chat.questions.cards.isEmpty }
        guard case .settled(let ending)? = chat.questions.all.first?.state else { Issue.record("not settled"); return }
        #expect(ending.text == "Answered elsewhere")
    }

    @Test func fieldsHeardBeforeAChatIsClaimedAreAskedForWhenItIs() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        // Two updates heard for a chat not yet claimed, the newer asking for less.
        roster.connectionChanged(installCard("op-u", seq: 1, fields: ["A", "B"]), inSession: "live-u", on: client)
        roster.connectionChanged(installCard("op-u", seq: 2, fields: ["B"]), inSession: "live-u", on: client)
        let snapshot = BotQuestion(id: "op-u", sessionID: "live-u", route: .connection, kind: .connection(installCard("op-u", seq: 2, fields: ["B"])))
        roster.chatOpened(LiveChat(sessionID: "live-u", waiting: [snapshot]), of: bot, on: client)
        #expect(Set(shownFields(chat.questions)["fs"]?.map(\.name) ?? []) == ["A", "B"])
    }

    @Test func aNewCardKeepsWhatItAskedForHoweverManyCameBefore() throws {
        let questions = ChatQuestions()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        for n in 1...25 {
            let id = "op-\(n)"
            questions.ask(BotQuestion(id: id, sessionID: "live-1", route: .connection, kind: .connection(installCard(id, seq: 1, fields: ["A", "B"]))), on: client)
            questions.connectionChanged(installCard(id, seq: 2, fields: ["B"]), inSession: "live-1", on: client)
            #expect(Set(questions.fields(of: questions.all.last?.question.id ?? "")["fs"]?.map(\.name) ?? []) == ["A", "B"], "card \(n)")
            questions.connectionChanged(ConnectionRequest(opID: id, seq: 3, deadline: nil, targets: [], isSettled: true), inSession: "live-1", on: client)
        }
    }

    @Test func fieldsHeardBeforeAChatIsClaimedOutlastAReconnect() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        roster.connectionChanged(installCard("op-d", seq: 1, fields: ["A", "B"]), inSession: "live-d", on: client)
        roster.connectionChanged(installCard("op-d", seq: 2, fields: ["B"]), inSession: "live-d", on: client)
        // The connection drops before the chat is claimed, and a new one is made.
        var drop = URLRequest(url: URL(string: "http://\(pretend.address)/api/drop")!)
        drop.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: drop)
        var next = client
        let deadline = Date.now.addingTimeInterval(15)
        while next === client {
            try #require(Date.now < deadline, "No new connection")
            try await Task.sleep(for: .milliseconds(100))
            next = (try? await roster.liveClient()) ?? client
        }
        // Opened again under a new live id, as Hermes gives after a reconnect.
        let snapshot = BotQuestion(id: "op-d", sessionID: "live-d2", route: .connection, kind: .connection(installCard("op-d", seq: 2, fields: ["B"])))
        roster.chatOpened(LiveChat(sessionID: "live-d2", waiting: [snapshot]), of: bot, on: next)
        #expect(Set(shownFields(chat.questions)["fs"]?.map(\.name) ?? []) == ["A", "B"])
    }

    @Test func aCardWaitingForItsChatKeepsItsFieldsHoweverManyCardsWereDone() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        // Fifty cards asked and settled in other chats.
        for n in 1...50 {
            roster.connectionChanged(installCard("op-old\(n)", seq: 1, fields: ["A"]), inSession: "live-old\(n)", on: client)
            roster.connectionChanged(ConnectionRequest(opID: "op-old\(n)", seq: 2, deadline: nil, targets: [], isSettled: true), inSession: "live-old\(n)", on: client)
        }
        // A new card asked in a chat not yet claimed, then more after it.
        roster.asked(BotQuestion(id: "op-new", sessionID: "live-new", route: .connection, kind: .connection(installCard("op-new", seq: 1, fields: ["A", "B"]))), on: client)
        for n in 1...3 { roster.connectionChanged(installCard("op-more\(n)", seq: 1, fields: ["A"]), inSession: "live-more\(n)", on: client) }
        roster.connectionChanged(installCard("op-new", seq: 2, fields: ["B"]), inSession: "live-new", on: client)
        let snapshot = BotQuestion(id: "op-new", sessionID: "live-new", route: .connection, kind: .connection(installCard("op-new", seq: 2, fields: ["B"])))
        roster.chatOpened(LiveChat(sessionID: "live-new", waiting: [snapshot]), of: bot, on: client)
        #expect(Set(shownFields(chat.questions)["fs"]?.map(\.name) ?? []) == ["A", "B"])
    }

    @Test func aWaitingCardKeepsItsFieldsOverAReconnectHoweverManyCardsCameAfter() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        roster.asked(BotQuestion(id: "op-x", sessionID: "live-x", route: .connection, kind: .connection(installCard("op-x", seq: 1, fields: ["A", "B"]))), on: client)
        roster.connectionChanged(installCard("op-x", seq: 2, fields: ["B"]), inSession: "live-x", on: client)
        // The connection drops before the chat is claimed, and a new one is made.
        var drop = URLRequest(url: URL(string: "http://\(pretend.address)/api/drop")!)
        drop.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: drop)
        var next = client
        let deadline = Date.now.addingTimeInterval(15)
        while next === client {
            try #require(Date.now < deadline, "No new connection")
            try await Task.sleep(for: .milliseconds(100))
            next = (try? await roster.liveClient()) ?? client
        }
        // Then fifty cards asked and settled elsewhere.
        for n in 1...50 {
            roster.connectionChanged(installCard("op-old\(n)", seq: 1, fields: ["A"]), inSession: "live-old\(n)", on: next)
            roster.connectionChanged(ConnectionRequest(opID: "op-old\(n)", seq: 2, deadline: nil, targets: [], isSettled: true), inSession: "live-old\(n)", on: next)
        }
        let snapshot = BotQuestion(id: "op-x", sessionID: "live-x2", route: .connection, kind: .connection(installCard("op-x", seq: 2, fields: ["B"])))
        roster.chatOpened(LiveChat(sessionID: "live-x2", waiting: [snapshot]), of: bot, on: next)
        #expect(Set(shownFields(chat.questions)["fs"]?.map(\.name) ?? []) == ["A", "B"])
    }

    @Test func plainValuesTypedIntoAWaitingCardOutlastItsViewAndGoWhenItIsOver() throws {
        let questions = ChatQuestions()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let card = ConnectionRequest(opID: "op-t", seq: 1, deadline: nil, targets: [
            ConnectionTarget(name: "fs", kind: .mcp, action: .install, state: .pending, fields: [
                ConnectionTarget.Field(name: "ROOT", isRequired: true, isSecret: false, defaultValue: "/d"),
            ], launch: ConnectionTarget.Launch(isRemote: false, target: "npx fs")),
        ])
        let question = BotQuestion(id: "op-t", sessionID: "live-1", route: .connection, kind: .connection(card))
        questions.ask(question, on: client)
        // Typed while the card shows; the card's view goes (another bot is picked) and comes back.
        questions.setDraft("/home/me/notes", of: "op-t", row: "fs", field: "ROOT")
        #expect(questions.draft(of: "op-t", row: "fs", field: "ROOT") == "/home/me/notes")
        // Lost with the connection and put up again: still there.
        questions.lost(on: client)
        let next = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        questions.ask(question, on: next)
        #expect(questions.draft(of: "op-t", row: "fs", field: "ROOT") == "/home/me/notes")
        // Over: let go.
        questions.connectionChanged(ConnectionRequest(opID: "op-t", seq: 2, deadline: nil, targets: [], settledBy: "continue", isSettled: true), inSession: "live-1", on: next)
        #expect(questions.draft(of: "op-t", row: "fs", field: "ROOT") == nil)
        // A card that is not waiting takes no draft.
        questions.setDraft("x", of: "op-t", row: "fs", field: "ROOT")
        #expect(questions.draft(of: "op-t", row: "fs", field: "ROOT") == nil)
    }

    /// Drops every connection to the pretend gateway and waits for the roster's next one.
    private func dropAndReconnect(_ pretend: Pretend, _ roster: RosterModel, from client: GatewayClient) async throws -> GatewayClient {
        var drop = URLRequest(url: URL(string: "http://\(pretend.address)/api/drop")!)
        drop.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: drop)
        var next = client
        let deadline = Date.now.addingTimeInterval(15)
        while next === client {
            try #require(Date.now < deadline, "No new connection")
            try await Task.sleep(for: .milliseconds(100))
            next = (try? await roster.liveClient()) ?? client
        }
        return next
    }

    private func plainCard(_ id: String, seq: Int = 1) -> ConnectionRequest {
        ConnectionRequest(opID: id, seq: seq, deadline: nil, targets: [
            ConnectionTarget(name: "fs", kind: .mcp, action: .install, state: .pending, fields: [
                ConnectionTarget.Field(name: "ROOT", isRequired: true, isSecret: false),
                ConnectionTarget.Field(name: "KEY", isRequired: true, isSecret: true),
            ], launch: ConnectionTarget.Launch(isRemote: false, target: "npx fs")),
        ])
    }

    /// The fields kept for the card shown first in a chat.
    private func shownFields(_ questions: ChatQuestions) -> [String: [ConnectionTarget.Field]] {
        questions.fields(of: questions.cards.first?.question.id ?? "")
    }

    @Test func aCardThatSettlesWhileDisconnectedLeavesNothingKept() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        let card = BotQuestion(id: "op-s", sessionID: "live-s", route: .connection, kind: .connection(plainCard("op-s")))
        roster.chatOpened(LiveChat(sessionID: "live-s", waiting: [card]), of: bot, on: client)
        chat.questions.setDraft("/home/me", of: "op-s", row: "fs", field: "ROOT")
        let next = try await dropAndReconnect(pretend, roster, from: client)
        // The chat is opened again under a new live id, and the card's updates come on it.
        let again = BotQuestion(id: "op-s", sessionID: "live-s2", route: .connection, kind: .connection(plainCard("op-s", seq: 2)))
        roster.chatOpened(LiveChat(sessionID: "live-s2", waiting: [again]), of: bot, on: next)
        #expect(chat.questions.draft(of: "op-s", row: "fs", field: "ROOT") == "/home/me")
        // Settled on the gateway, heard on the new connection and live id: nothing is kept for it.
        roster.connectionChanged(ConnectionRequest(opID: "op-s", seq: 3, deadline: nil, targets: [], isSettled: true), inSession: "live-s2", on: next)
        #expect(chat.questions.draft(of: "op-s", row: "fs", field: "ROOT") == nil)
        #expect(!roster.connectionMemory.entries.keys.contains { $0.op == "op-s" })
    }

    @Test func aDeletedBotsWaitingCardsGoWithItAndNoOneElses() async throws {
        let pretend = try await Pretend()
        let (roster, main, mainChat) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let gardenChat = roster.chat(for: garden)
        await gardenChat.load(garden, from: roster)
        var now: TimeInterval = 0
        roster.connectionMemory.clock = { now }
        let client = try await roster.liveClient()
        // A card waiting in each chat, with a plain field typed into.
        roster.chatOpened(LiveChat(sessionID: "live-g", waiting: [BotQuestion(id: "op-g", sessionID: "live-g", route: .connection, kind: .connection(plainCard("op-g")))]), of: garden, on: client)
        roster.chatOpened(LiveChat(sessionID: "live-m", waiting: [BotQuestion(id: "op-m", sessionID: "live-m", route: .connection, kind: .connection(plainCard("op-m")))]), of: main, on: client)
        gardenChat.questions.setDraft("/home/garden", of: "op-g", row: "fs", field: "ROOT")
        mainChat.questions.setDraft("/home/main", of: "op-m", row: "fs", field: "ROOT")
        #expect(await roster.delete(garden) == nil)
        now += ConnectionMemory.retention + 60
        roster.connectionMemory.prune()
        #expect(!roster.connectionMemory.entries.keys.contains { $0.owner == "garden" })
        // The main bot's card is still shown as waiting, so it is kept whatever the clock says.
        #expect(mainChat.questions.draft(of: "op-m", row: "fs", field: "ROOT") == "/home/main")
    }

    @Test func aStaleEmptyOpeningLosesNothingOfAWaitingCard() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        let card = BotQuestion(id: "op-e", sessionID: "live-e", route: .connection, kind: .connection(installCard("op-e", seq: 1, fields: ["A", "B"])))
        roster.chatOpened(LiveChat(sessionID: "live-e", waiting: [card]), of: bot, on: client)
        chat.questions.setDraft("typed", of: "op-e", row: "fs", field: "A")
        // An older opening that held no card comes in after the chat was claimed.
        roster.chatOpened(LiveChat(sessionID: "live-e", waiting: []), of: bot, on: client)
        #expect(chat.questions.draft(of: "op-e", row: "fs", field: "A") == "typed")
        // The next update asks only for what is missing; every field is still asked for.
        roster.connectionChanged(installCard("op-e", seq: 2, fields: ["B"]), inSession: "live-e", on: client)
        #expect(Set(chat.questions.fields(of: "op-e")["fs"]?.map(\.name) ?? []) == ["A", "B"])
    }

    @Test func aTurnEndingAfterAReconnectLosesNothingUntilTheCardSettles() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        let card = BotQuestion(id: "op-t", sessionID: "live-t", route: .connection, kind: .connection(installCard("op-t", seq: 1, fields: ["A", "B"])))
        roster.chatOpened(LiveChat(sessionID: "live-t", waiting: [card]), of: bot, on: client)
        chat.questions.setDraft("typed", of: "op-t", row: "fs", field: "A")
        let next = try await dropAndReconnect(pretend, roster, from: client)
        // The turn ends before the chat is opened again: the card stops being shown, its memory stays.
        roster.turnEnded(inSession: "live-t", on: next)
        #expect(chat.questions.draft(of: "op-t", row: "fs", field: "A") == "typed")
        // Opened again under a new live id, then settled there.
        let again = BotQuestion(id: "op-t", sessionID: "live-t2", route: .connection, kind: .connection(installCard("op-t", seq: 2, fields: ["B"])))
        roster.chatOpened(LiveChat(sessionID: "live-t2", waiting: [again]), of: bot, on: next)
        #expect(Set(chat.questions.fields(of: "op-t")["fs"]?.map(\.name) ?? []) == ["A", "B"])
        roster.connectionChanged(ConnectionRequest(opID: "op-t", seq: 3, deadline: nil, targets: [], isSettled: true), inSession: "live-t2", on: next)
        #expect(chat.questions.draft(of: "op-t", row: "fs", field: "A") == nil)
    }

    @Test func manyWaitingCardsKeepEveryField() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let client = try await roster.liveClient()
        for n in 1...60 {
            roster.asked(BotQuestion(id: "op-\(n)", sessionID: "live-\(n)", route: .connection, kind: .connection(installCard("op-\(n)", seq: 1, fields: ["A", "B"]))), on: client)
            roster.connectionChanged(installCard("op-\(n)", seq: 2, fields: ["B"]), inSession: "live-\(n)", on: client)
        }
        let next = try await dropAndReconnect(pretend, roster, from: client)
        let snapshot = BotQuestion(id: "op-1", sessionID: "live-1b", route: .connection, kind: .connection(installCard("op-1", seq: 2, fields: ["B"])))
        roster.chatOpened(LiveChat(sessionID: "live-1b", waiting: [snapshot]), of: bot, on: next)
        #expect(Set(chat.questions.fields(of: "op-1")["fs"]?.map(\.name) ?? []) == ["A", "B"])
        for n in 1...60 {
            let kept = roster.connectionMemory.entries.first { $0.key.op == "op-\(n)" }?.value.fields["fs"]
            #expect(Set(kept?.map(\.name) ?? []) == ["A", "B"], "op-\(n)")
        }
    }

    @Test func aCardInOneBotsChatNeverReadsAnothersWithTheSameId() throws {
        let memory = ConnectionMemory()
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let garden = ChatQuestions(), trips = ChatQuestions()
        garden.memory = memory; garden.owner = "garden"
        trips.memory = memory; trips.owner = "trips"
        garden.ask(BotQuestion(id: "op-x", sessionID: "live-1", route: .connection, kind: .connection(installCard("op-x", seq: 1, fields: ["A", "B"]))), on: client)
        trips.ask(BotQuestion(id: "op-x", sessionID: "live-2", route: .connection, kind: .connection(installCard("op-x", seq: 1, fields: ["C"]))), on: client)
        garden.setDraft("garden's", of: "op-x", row: "fs", field: "A")
        #expect(trips.draft(of: "op-x", row: "fs", field: "A") == nil)
        #expect(trips.fields(of: "op-x")["fs"]?.map(\.name) == ["C"])
        // Settled in one bot's chat: the other's stays.
        trips.connectionChanged(ConnectionRequest(opID: "op-x", seq: 2, deadline: nil, targets: [], isSettled: true), inSession: "live-2", on: client)
        #expect(garden.draft(of: "op-x", row: "fs", field: "A") == "garden's")
    }

    @Test func aCardThatHasEndedIsNotBroughtBackByAnOlderFrame() {
        let memory = ConnectionMemory()
        let key = ConnectionMemory.Key(owner: "garden", op: "op-f")
        memory.heard(installCard("op-f", seq: 1, fields: ["A"]), as: key, inSession: "live-1")
        // Ended for good (answered settled, closed elsewhere, or a settled update).
        memory.finish(key)
        memory.heard(installCard("op-f", seq: 1, fields: ["A"]), as: key, inSession: "live-1")
        #expect(memory.entries[key] == nil)
        memory.setDraft("x", of: key, row: "fs", field: "A")
        #expect(memory.entries[key] == nil)
    }

    @Test func aCardShownAsWaitingIsKeptWhateverTheGatewaysClockSays() {
        let memory = ConnectionMemory()
        var now: TimeInterval = 1_000
        memory.clock = { now }
        let key = ConnectionMemory.Key(owner: "garden", op: "op-c")
        // A deadline already past by this Mac's clock (the gateway's runs behind).
        let card = ConnectionRequest(opID: "op-c", seq: 1, deadline: Date.now.addingTimeInterval(-120), targets: installCard("op-c", seq: 1, fields: ["A"]).targets)
        memory.heard(card, as: key, inSession: "live-1")
        memory.setShown(["op-c"], owner: "garden")
        now += 3 * 3600
        memory.setDraft("typed", of: key, row: "fs", field: "A")
        #expect(memory.draft(of: key, row: "fs", field: "A") == "typed")
        // No longer shown: it lasts thirty minutes of this Mac's clock, then goes.
        memory.setShown([], owner: "garden")
        now += 29 * 60
        #expect(memory.draft(of: key, row: "fs", field: "A") == "typed")
        now += 2 * 60
        #expect(memory.draft(of: key, row: "fs", field: "A") == nil)
        memory.prune()
        #expect(memory.entries.isEmpty)
    }

    @Test func overTheLimitTheCardsNeverShownNorTypedIntoGoFirst() {
        let memory = ConnectionMemory()
        var now: TimeInterval = 0
        memory.clock = { now }
        let typed = ConnectionMemory.Key(owner: "garden", op: "op-typed")
        let shown = ConnectionMemory.Key(owner: "garden", op: "op-shown")
        // The oldest two are the one typed into and the one on screen.
        memory.heard(installCard("op-typed", seq: 1, fields: ["A"]), as: typed, inSession: nil)
        memory.setDraft("x", of: typed, row: "fs", field: "A")
        memory.heard(installCard("op-shown", seq: 1, fields: ["A"]), as: shown, inSession: nil)
        memory.setShown(["op-shown"], owner: "garden")
        for n in 1...(ConnectionMemory.most + 5) {
            now += 1
            memory.heard(installCard("op-\(n)", seq: 1, fields: ["A"]), as: .init(owner: "garden", op: "op-\(n)"), inSession: nil)
        }
        #expect(memory.entries.count == ConnectionMemory.most)
        #expect(memory.entries[typed] != nil && memory.entries[shown] != nil)
    }

    @Test func theCountIsOfRowsSettledNotOnlyConnected() {
        let rows = [
            ConnectionTarget(name: "connected", kind: .connector, action: .connect, state: .connected),
            ConnectionTarget(name: "skipped", kind: .mcp, action: .install, state: .skipped),
            ConnectionTarget(name: "installing", kind: .mcp, action: .install, state: .initiated),
            ConnectionTarget(name: "expired", kind: .connector, action: .connect, state: .expired),
        ]
        #expect(ConnectionCard.progress(of: rows) == "2 of 4 done")
    }

    @Test func anExpiredRowsOwnDetailIsSaidOnce() {
        let expired = ConnectionTarget(name: "notion", kind: .connector, action: .connect, state: .expired,
                                       detail: "The sign-in link ran out.")
        #expect(ConnectionCard.shownDetail(of: expired) == "The sign-in link ran out.")
        #expect(!ConnectionCard.showsSubtitle(for: expired))
        let noDetail = ConnectionTarget(name: "notion", kind: .connector, action: .connect, state: .expired)
        #expect(ConnectionCard.showsSubtitle(for: noDetail))
        let useful = ConnectionTarget(name: "notion", kind: .connector, action: .connect, state: .expired,
                                      detail: "Use your work account when you sign in again.")
        #expect(ConnectionCard.shownDetail(of: useful) == "Use your work account when you sign in again.")
        #expect(!ConnectionCard.showsSubtitle(for: useful))
    }

    @Test func aFailedAuthorizationIsTriedAgainWithAFreshLink() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        send("ask me connect authorizefail", chat, bot, roster)
        try await until("the authorization to fail") { row("calendar.work", chat)?.state == .failed }
        let failed = try #require(row("calendar.work", chat))
        // Hermes runs a failed MCP row again when it is approved (`_RETRY`); only a hosted app
        // is minted afresh through `connectors.connect`, which refuses a name with a dot.
        #expect(failed.move == .retry && !failed.retriesByReissue && failed.canBeApproved)
        #expect(ConnectionTarget(name: "notion", kind: .connector, action: .authorize, state: .failed).retriesByReissue)
        let asked = try #require(card(chat)?.asked)
        #expect(chat.questions.respond(asked.instance, with: ConnectionAnswer(moves: ["calendar.work": .approve(values: [:])]), for: bot))
        try await until("a fresh link") { row("calendar.work", chat)?.state == .initiated }
        #expect(row("calendar.work", chat)?.connectURL?.absoluteString.hasSuffix("attempt=2") == true)
        let heard = try await answers(pretend)
        #expect(heard.contains { $0["method"] as? String == "connection.respond" && ($0["moves"] as? [String: String]) == ["calendar.work": "approved"] })
        #expect(!heard.contains { $0["method"] as? String == "connectors.connect" })
        chat.questions.respond(asked.instance, with: ConnectionAnswer(isContinue: true), for: bot)
        try await until("the card to settle") { chat.questions.cards.isEmpty }
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

    @Test func aRefusedReissueSaysWhyAndA4004TargetRefusalKeepsTheCardOpen() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)

        // While a hosted link stays `initiated` (no 2 s failure race), a reissue is refused as LINK_STILL_VALID.
        send("ask me connect", chat, bot, roster)
        try await until("the first card") { card(chat) != nil }
        let openAsked = try #require(card(chat)?.asked)
        #expect(chat.questions.retry(openAsked.instance, row: "notion", for: bot))
        try await until("the link-valid refusal") { chat.questions.cards.first?.problem != nil }
        #expect(chat.questions.cards.first?.problem == "Couldn't try that again. That sign-in link is still active.")
        chat.questions.respond(openAsked.instance, with: ConnectionAnswer(isContinue: true), for: bot)
        try await until("the first card to settle") { chat.questions.cards.isEmpty }
        try await until("the first turn to end", within: 20) { !chat.isWorking }

        send("ask me connect reissuefail", chat, bot, roster)
        try await until("the second card") { card(chat) != nil }
        let asked = try #require(card(chat)?.asked)
        try await until("the sign-in to fail") { row("notion", chat)?.state == .failed }

        // A 5034 CONNECTOR_REQUEST_FAILED refusal uses plain wording rather than "doesn't understand".
        #expect(chat.questions.retry(asked.instance, row: "notion", for: bot))
        try await until("the reissue refusal") { chat.questions.cards.first?.problem != nil }
        #expect(chat.questions.cards.first?.problem == "Couldn't try that again. The connector request failed.")

        // A 4004 UNKNOWN_TARGET keeps the card open and names the problem.
        #expect(chat.questions.retry(asked.instance, row: "missing", for: bot))
        try await until("the target refusal") { chat.questions.cards.first?.problem != nil }
        #expect(chat.questions.cards.first?.problem == "Couldn't try that again. That item isn't on this card.")
        #expect(card(chat) != nil)

        chat.questions.respond(asked.instance, with: ConnectionAnswer(isContinue: true), for: bot)
        try await until("the card to settle") { chat.questions.cards.isEmpty }

        // Check every Hermes refusal reason maps cleanly.
        #expect(ChatQuestions.connectionProblem("Couldn't try that again.", for: GatewayClient.ConnectionRefusal(code: 4002, reason: "REISSUE_REFUSED", message: "The operation has settled.")) == "Couldn't try that again. This card has already finished.")
        #expect(ChatQuestions.connectionProblem("Couldn't try that again.", for: GatewayClient.ConnectionRefusal(code: 4002, reason: "REISSUE_REFUSED", message: "This target cannot be run again.")) == "Couldn't try that again. Hermes won't run this item again.")
        #expect(ChatQuestions.connectionProblem("Couldn't try that again.", for: GatewayClient.ConnectionRefusal(code: 4032, reason: "NEEDS_NOUS_AUTH", message: "Sign in to use connectors.")) == "Couldn't try that again. Connectors need you to sign in to your account again.")
        #expect(ChatQuestions.connectionProblem("Couldn't try that again.", for: GatewayClient.ConnectionRefusal(code: 4031, reason: "CONNECTORS_UNAVAILABLE", message: "Connectors are not available in this session.")) == "Couldn't try that again. Connectors aren't available in this chat.")
        #expect(ChatQuestions.connectionProblem("Couldn't try that again.", for: GatewayClient.ConnectionRefusal(code: 4030, reason: "ORG_ACCESS_DENIED", message: "raw")) == "Couldn't try that again. This account cannot manage connectors for this organization.")
        #expect(ChatQuestions.connectionProblem("Couldn't try that again.", for: GatewayClient.ConnectionRefusal(code: 5033, reason: "UNSUPPORTED_RUNTIME", message: "raw")) == "Couldn't try that again. Connectors can only be set up on the computer the bot runs on.")
        #expect(ChatQuestions.connectionProblem("Couldn't try that again.", for: GatewayClient.ConnectionRefusal(code: 4001, reason: "NOT_OWNER", message: "session ownership changed")) == "Couldn't try that again. This card comes from a chat that isn't open any more.")
        #expect(ChatQuestions.connectionProblem("Couldn't try that again.", for: GatewayClient.ConnectionRefusal(code: 4001, reason: "not_found", message: "not_found")) == "Couldn't try that again. This chat is no longer open on the gateway.")
        #expect(ChatQuestions.connectionProblem("Couldn't send that.", for: GatewayClient.ConnectionRefusal(code: 4001, reason: "invalid_params", message: "invalid_params")) == "Couldn't send that. The gateway refused that.")
    }
}
