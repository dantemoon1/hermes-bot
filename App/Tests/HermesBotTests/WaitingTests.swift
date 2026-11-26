import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// A bot waiting on the person is visible from the sidebar, from outside the app while in the
/// background, and even in a chat not yet opened this run (issues #53 and #49).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct WaitingTests {
    typealias Pretend = SendingTests.Pretend

    init() { ChatQuestions.arrivalGuard = 0 }

    /// Records every outside-the-app alert call without touching the real Dock or Notification Center.
    @MainActor
    final class AlertSpy {
        var posted: [WaitingAlerts.Notice] = []
        var removed: [[String]] = []
        var bounces = 0
        var cancelled: [Int] = []
        private var nextBounce = 0
        lazy var alerts = WaitingAlerts(
            post: { [weak self] in self?.posted.append($0) },
            remove: { [weak self] in self?.removed.append($0) },
            bounce: { [weak self] in
                guard let self else { return 0 }
                self.bounces += 1
                self.nextBounce += 1
                return self.nextBounce
            },
            cancelBounce: { [weak self] in self?.cancelled.append($0) }
        )

        var removedIDs: Set<String> { Set(removed.flatMap { $0 }) }
    }

    private func open(_ pretend: Pretend, alerts: WaitingAlerts = .silent()) async throws -> (RosterModel, Bot, ChatModel) {
        let roster = RosterModel(gateway: (pretend.address, "demo"), alerts: alerts)
        await roster.load()
        let main = try #require(roster.mainBot)
        let chat = roster.chat(for: main)
        await chat.load(main, from: roster)
        #expect(chat.phase == .loaded)
        return (roster, main, chat)
    }

    private func triggerRoutine(_ pretend: Pretend, bot: String, kind: String, push: Bool = false, short: Bool = false, replace: Bool = false, fresh: Bool = false) async throws {
        var url = "http://\(pretend.address)/api/ask?bot=\(bot)&kind=\(kind)"
        if push { url += "&push=1" }
        if short { url += "&short=1" }
        if replace { url += "&replace=1" }
        if fresh { url += "&fresh=1" }
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    private func answers(_ pretend: Pretend) async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "http://\(pretend.address)/api/status")!)
        request.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let status = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return status?["answers"] as? [[String: Any]] ?? []
    }

    private func until(_ what: String, within seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !condition() {
            try #require(Date.now < deadline, "Waited \(seconds) s for \(what)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Sidebar cues

    @Test func aWaitingQuestionInAnotherBotsChatShowsTheDotAndPreviewAndClearsWhenAnswered() async throws {
        let pretend = try await Pretend()
        let (roster, main, mainChat) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let gardenChat = roster.chat(for: garden)
        await gardenChat.load(garden, from: roster)

        // Start an approval in Garden, then switch back to the main bot before it settles.
        roster.selectedID = garden.id
        gardenChat.draft = "ask me approve quick"
        gardenChat.send(to: garden, through: roster)
        try await until("Garden's approval card") { !gardenChat.questions.open.isEmpty }
        // Looked at in front: preview says what it waits on, no dot while looking right at it.
        #expect(roster.rowPreview(for: garden) == "Waiting for approval")
        #expect(!roster.showsDot(for: garden))

        // Switch away to Main: Garden now carries the blue dot and appears in View Unread.
        roster.selectedID = main.id
        #expect(roster.showsDot(for: garden))
        #expect(roster.needsAttention.contains(garden.id))
        #expect(roster.rowPreview(for: garden) == "Waiting for approval")
        // Waiting does not hijack unread state (Mark as Read stays for unread messages).
        #expect(!roster.unread.contains(garden.id))

        // Answer it: preview and dot clear once it settles.
        let asked = try #require(gardenChat.questions.open.first)
        gardenChat.questions.answer(asked.instance, with: .approval(.once), for: garden)
        try await until("Garden's card to settle") { !gardenChat.questions.isWaiting }
        #expect(!roster.isWaiting(garden))
        #expect(roster.waitingText(for: garden) == nil)
        #expect(roster.rowPreview(for: garden) != "Waiting for approval")
        _ = mainChat
    }

    @Test func theMainBotTileShowsTheBlueDotAndPreviewWhenWaitingWhileAnotherBotIsSelected() async throws {
        let pretend = try await Pretend()
        let (roster, main, mainChat) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })

        mainChat.draft = "ask me clarify quick"
        mainChat.send(to: main, through: roster)
        try await until("main bot's clarify") { mainChat.questions.clarifying != nil }

        // Turn to Garden: main bot tile now carries the blue dot and its hover preview says why.
        roster.selectedID = garden.id
        #expect(roster.showsDot(for: main))
        #expect(roster.needsAttention.contains(main.id))
        #expect(roster.rowPreview(for: main) == "Waiting for your answer")

        let asked = try #require(mainChat.questions.clarifying)
        mainChat.questions.answer(asked.instance, with: .skipped, for: main)
        try await until("clarify settled") { !mainChat.questions.isWaiting }
        #expect(!roster.isWaiting(main))
        #expect(roster.waitingText(for: main) == nil)
    }

    // MARK: Chats not opened this run (and #49)

    @Test func aRoutineApprovalInAnUnopenedChatIsDiscoveredAndNeverDeclined() async throws {
        let pretend = try await Pretend()
        let spy = AlertSpy()
        let (roster, _, _) = try await open(pretend, alerts: spy.alerts)
        roster.unclaimedWait = .milliseconds(300)
        // Garden has never been opened this run; a routine asks for approval there.
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        try await triggerRoutine(pretend, bot: "garden", kind: "approve")

        try await until("Garden's approval discovered in background") { roster.isWaiting(garden) }
        #expect(roster.showsDot(for: garden))
        #expect(roster.rowPreview(for: garden) == "Waiting for approval")
        // Wait well past unclaimedWait to prove it was claimed rather than turned away.
        try await Task.sleep(for: .milliseconds(600))
        #expect(roster.isWaiting(garden))
        #expect(spy.posted.isEmpty) // app is in foreground

        let asked = try #require(roster.chat(for: garden).questions.open.first)
        roster.chat(for: garden).questions.answer(asked.instance, with: .approval(.once), for: garden)
        try await until("approval settled") { !roster.isWaiting(garden) }
        let heard = try await answers(pretend)
        #expect(heard.contains { ($0["result"] as? [String: Any])?["choice"] as? String == "once" })
    }

    @Test func aRoutineApprovalInAnUnopenedChatIsDiscoveredOnTheSessionAuthorityToo() async throws {
        let pretend = try await Pretend(whenBusy: "authority")
        let (roster, _, _) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        try await triggerRoutine(pretend, bot: "garden", kind: "approve")

        try await until("Garden's approval discovered on authority") { roster.isWaiting(garden) }
        #expect(roster.showsDot(for: garden))
        #expect(roster.rowPreview(for: garden) == "Waiting for approval")

        let asked = try #require(roster.chat(for: garden).questions.open.first)
        roster.chat(for: garden).questions.answer(asked.instance, with: .approval(.deny), for: garden)
        try await until("approval settled") { !roster.isWaiting(garden) }
    }

    @Test func anUnclaimedConnectionCardOpensItsBotsChatInsteadOfBeingDropped() async throws {
        // Covers #49: a connection card pushed for a chat not yet opened is claimed by opening
        // that bot's chat in the background and shown in the sidebar rather than dropped at 10 s.
        let pretend = try await Pretend()
        let (roster, _, _) = try await open(pretend)
        roster.unclaimedWait = .milliseconds(300)
        let garden = try #require(roster.bots.first { $0.name == "garden" })

        try await triggerRoutine(pretend, bot: "garden", kind: "connect", push: true)
        try await until("Garden's connection card claimed") { roster.isWaiting(garden) }
        #expect(roster.rowPreview(for: garden) == "Waiting to connect")
        #expect(roster.showsDot(for: garden))
        // Still waiting past unclaimedWait.
        try await Task.sleep(for: .milliseconds(600))
        #expect(roster.isWaiting(garden))

        let asked = try #require(roster.chat(for: garden).questions.open.first)
        #expect(roster.chat(for: garden).questions.respond(asked.instance, with: ConnectionAnswer(isContinue: true), for: garden))
        try await until("connection card settled") { !roster.isWaiting(garden) }
        #expect(roster.waitingText(for: garden) == nil)
    }

    @Test func anUnclaimedApprovalFrameOpensItsBotsChatInsteadOfBeingDeclined() async throws {
        let pretend = try await Pretend()
        let (roster, _, _) = try await open(pretend)
        roster.unclaimedWait = .milliseconds(300)
        let garden = try #require(roster.bots.first { $0.name == "garden" })

        try await triggerRoutine(pretend, bot: "garden", kind: "approve", push: true)
        try await until("Garden's approval claimed") { roster.isWaiting(garden) }
        try await Task.sleep(for: .milliseconds(600))
        #expect(roster.isWaiting(garden))

        let asked = try #require(roster.chat(for: garden).questions.open.first)
        roster.chat(for: garden).questions.answer(asked.instance, with: .approval(.once), for: garden)
        try await until("approval settled") { !roster.isWaiting(garden) }
    }

    // MARK: Outside the app (background alerts) & clearing on every ending

    @Test func backgroundQuestionNotifiesAndBouncesAndClearsOnTimeoutAndWithdrawal() async throws {
        let pretend = try await Pretend()
        let spy = AlertSpy()
        let (roster, _, _) = try await open(pretend, alerts: spy.alerts)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        roster.isLookedAt = false

        // 1. Withdrawn ("stale" withdraws after 2 s).
        try await triggerRoutine(pretend, bot: "garden", kind: "stale")
        try await until("background alert posted") { spy.posted.count == 1 }
        #expect(spy.posted[0].botID == "garden")
        #expect(spy.posted[0].botTitle == garden.title)
        #expect(spy.posted[0].body == "Waiting for approval")
        #expect(spy.bounces == 1)
        #expect(roster.showsDot(for: garden))

        try await until("withdrawn alert cleared", within: 10) {
            !roster.isWaiting(garden) && spy.removedIDs.contains(spy.posted[0].id) && spy.cancelled.contains(1)
        }

        // 2. Timed out ("short" times out after 4 s).
        try await triggerRoutine(pretend, bot: "garden", kind: "approve", short: true)
        try await until("second background alert posted") { spy.posted.count == 2 }
        #expect(spy.bounces == 2)
        try await until("timed-out alert cleared", within: 10) {
            !roster.isWaiting(garden) && spy.removedIDs.contains(spy.posted[1].id) && spy.cancelled.contains(2)
        }
    }

    @Test func backgroundAlertClearsWhenAnsweredElsewhereAndClickingNotificationSelectsBot() async throws {
        let pretend = try await Pretend()
        let spy = AlertSpy()
        let (first, _, _) = try await open(pretend, alerts: spy.alerts)
        let (second, _, _) = try await open(pretend)
        let garden = try #require(first.bots.first { $0.name == "garden" })
        let gardenOnSecond = try #require(second.bots.first { $0.name == "garden" })
        first.isLookedAt = false

        try await triggerRoutine(pretend, bot: "garden", kind: "secret")
        try await until("alert in first app and card in second") {
            spy.posted.count == 1 && second.isWaiting(gardenOnSecond)
        }
        #expect(spy.posted[0].body == "Waiting for a secret")

        // Answered on the second device: first app's cue, notification, and bounce all clear.
        let asked = try #require(second.chat(for: gardenOnSecond).questions.open.first)
        second.chat(for: gardenOnSecond).questions.answer(asked.instance, with: .value("pretend-secret-123"), for: gardenOnSecond)
        try await until("first app clears cue after remote answer", within: 15) {
            !first.isWaiting(garden) && spy.removedIDs.contains(spy.posted[0].id) && spy.cancelled.contains(1)
        }

        // Next question: clicking the notification selects Garden and clears its notice.
        try await triggerRoutine(pretend, bot: "garden", kind: "sudo")
        try await until("sudo alert posted") { spy.posted.count == 2 }
        #expect(spy.posted[1].body == "Waiting for a password")
        let opensBefore = first.notificationOpens
        spy.alerts.selectBot("garden")
        #expect(first.selectedID == "garden")
        #expect(first.notificationOpens == opensBefore + 1)
        #expect(spy.removedIDs.contains(spy.posted[1].id))

        // Clean up the waiting sudo turn.
        let sudo = try #require(first.chat(for: garden).questions.open.first)
        first.chat(for: garden).questions.answer(sudo.instance, with: .skipped, for: garden)
        try await until("sudo settled") { !first.isWaiting(garden) }
    }

    @Test func foregroundQuestionDoesNotAlertWhenSwitchingAwayAndComingForwardStopsBounce() async throws {
        let pretend = try await Pretend()
        let spy = AlertSpy()
        let (roster, main, mainChat) = try await open(pretend, alerts: spy.alerts)
        // Question arrives while the app is in front: no notification or bounce.
        mainChat.draft = "ask me approve quick"
        mainChat.send(to: main, through: roster)
        try await until("main card") { !mainChat.questions.open.isEmpty }
        #expect(spy.posted.isEmpty)
        #expect(spy.bounces == 0)

        // Switching to another app does not ping for a question already seen in front, though
        // the sidebar dot shows while behind another app.
        roster.isLookedAt = false
        #expect(roster.showsDot(for: main))
        #expect(spy.posted.isEmpty)
        #expect(spy.bounces == 0)

        // A second bot asks while in the background: now it notifies and bounces.
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        try await triggerRoutine(pretend, bot: "garden", kind: "approve")
        try await until("garden alert posted") { spy.posted.count == 1 }
        #expect(spy.bounces == 1)

        // Bringing the window forward stops the bounce; Garden's notice clears when turned to.
        roster.isLookedAt = true
        #expect(spy.cancelled == [1])
        #expect(!spy.removedIDs.contains(spy.posted[0].id))
        roster.selectedID = garden.id
        #expect(spy.removedIDs.contains(spy.posted[0].id))

        // Clean up both waiting questions.
        if let q = mainChat.questions.open.first { mainChat.questions.answer(q.instance, with: .approval(.deny), for: main) }
        if let q = roster.chat(for: garden).questions.open.first { roster.chat(for: garden).questions.answer(q.instance, with: .approval(.deny), for: garden) }
        try await until("both settled") { !roster.isWaiting(main) && !roster.isWaiting(garden) }
    }

    @Test func aReplacedOrReleasedSessionStillDiscoversWaitingQuestionsOnSessionAuthority() async throws {
        let pretend = try await Pretend(whenBusy: "authority")
        let (roster, main, _) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        // Open Garden's original chat on this client so `liveSessions` holds an entry for it.
        let client = try await roster.liveClient()
        let original = try await client.openChat(try #require(garden.chat), profile: garden.name)
        roster.chatOpened(original, of: garden, on: client)
        roster.selectedID = main.id

        // 1. Canonical session replaced (compaction): new live id while old one is still in liveSessions.
        try await triggerRoutine(pretend, bot: "garden", kind: "approve", replace: true)
        try await until("Garden's approval discovered on replaced session") { roster.isWaiting(garden) }
        #expect(roster.showsDot(for: garden))
        let first = try #require(roster.chat(for: garden).questions.open.first)
        roster.chat(for: garden).questions.answer(first.instance, with: .approval(.once), for: garden)
        try await until("first approval settled") { !roster.isWaiting(garden) }

        // 2. Gateway releases open sessions without dropping the socket (/api/let-go).
        var letGo = URLRequest(url: URL(string: "http://\(pretend.address)/api/let-go")!)
        letGo.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: letGo)
        try await triggerRoutine(pretend, bot: "garden", kind: "approve")
        try await until("Garden's approval discovered after /api/let-go") { roster.isWaiting(garden) }
        let second = try #require(roster.chat(for: garden).questions.open.first)
        roster.chat(for: garden).questions.answer(second.instance, with: .approval(.deny), for: garden)
        try await until("second approval settled") { !roster.isWaiting(garden) }
    }

    @Test func settlingABackgroundAlertCancelsBounceEvenWhileAForegroundQuestionRemainsOpen() async throws {
        let pretend = try await Pretend()
        let spy = AlertSpy()
        let (roster, main, mainChat) = try await open(pretend, alerts: spy.alerts)
        // Question A arrives in the foreground (never notified or bounced).
        mainChat.draft = "ask me approve quick"
        mainChat.send(to: main, through: roster)
        try await until("main card") { !mainChat.questions.open.isEmpty }
        #expect(spy.bounces == 0)

        // Move to background; Question B arrives and withdraws after 2 s while Question A stays open.
        roster.isLookedAt = false
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        try await triggerRoutine(pretend, bot: "garden", kind: "stale")
        try await until("background alert posted") { spy.posted.count == 1 }
        #expect(spy.bounces == 1)

        try await until("bounce cancelled when background alert settles", within: 10) {
            !roster.isWaiting(garden) && spy.removedIDs.contains(spy.posted[0].id) && spy.cancelled.contains(1)
        }
        // Main's foreground question is still open the whole time.
        #expect(roster.isWaiting(main))

        if let q = mainChat.questions.open.first { mainChat.questions.answer(q.instance, with: .approval(.deny), for: main) }
        try await until("main settled") { !roster.isWaiting(main) }
    }

    @Test func anUnclaimedQuestionForABrandNewChatOnSessionAuthorityRefreshesAndClaims() async throws {
        let pretend = try await Pretend(whenBusy: "authority")
        let (roster, _, _) = try await open(pretend)
        roster.unclaimedWait = .milliseconds(500)
        // Reading List (`books`) has no canonical chat at launch (`chat == nil`).
        let books = try #require(roster.bots.first { $0.name == "books" })
        #expect(books.chat == nil)

        try await triggerRoutine(pretend, bot: "books", kind: "approve", push: true)
        try await until("Books's brand-new chat claimed on authority") { roster.isWaiting(books) }
        #expect(roster.showsDot(for: books))
        #expect(roster.rowPreview(for: books) == "Waiting for approval")

        let asked = try #require(roster.chat(for: books).questions.open.first)
        roster.chat(for: books).questions.answer(asked.instance, with: .approval(.once), for: books)
        try await until("books settled") { !roster.isWaiting(books) }
    }

    @Test func twoBrandNewChatsAskingOneAfterTheOtherAreBothClaimedOnSessionAuthority() async throws {
        let pretend = try await Pretend(whenBusy: "authority")
        let (roster, _, _) = try await open(pretend)
        roster.unclaimedWait = .milliseconds(800)
        let books = try #require(roster.bots.first { $0.name == "books" })
        let garden = try #require(roster.bots.first { $0.name == "garden" })

        // The second arrives while the first one's roster refresh and look are still under way;
        // it must get a refresh of its own rather than being covered by the first's.
        try await triggerRoutine(pretend, bot: "books", kind: "approve", push: true)
        try await triggerRoutine(pretend, bot: "garden", kind: "approve", push: true, fresh: true)
        try await until("both brand-new chats claimed") { roster.isWaiting(books) && roster.isWaiting(garden) }

        for bot in [books, garden] {
            let asked = try #require(roster.chat(for: bot).questions.open.first)
            roster.chat(for: bot).questions.answer(asked.instance, with: .approval(.deny), for: bot)
        }
        try await until("both settled") { !roster.isWaiting(books) && !roster.isWaiting(garden) }
    }

    private func staleResume(_ pretend: Pretend, chat: String, keep: Bool = false, failRecheck: Bool = false) async throws {
        var request = URLRequest(url: URL(string: "http://\(pretend.address)/api/stale-resume?chat=\(chat)\(keep ? "&keep=1" : "")\(failRecheck ? "&failrecheck=1" : "")")!)
        request.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try await URLSession.shared.data(for: request)
    }

    private func resumes(_ pretend: Pretend, of chat: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://\(pretend.address)/api/status")!)
        request.setValue("demo", forHTTPHeaderField: "X-Hermes-Session-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let status = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (status?["resumes"] as? [String: Int])?[chat] ?? 0
    }

    @Test func anApprovalAnsweredElsewhereBeforeALateOpeningIsNotPutUp() async throws {
        let pretend = try await Pretend()
        let (roster, _, _) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        try await staleResume(pretend, chat: "chat-garden")

        // Garden's turn ends before the snapshot of its opening comes, and that snapshot still
        // holds an approval answered elsewhere: a second look finds it gone, so it never shows.
        let chat = roster.chat(for: garden)
        await chat.load(garden, from: roster)
        let client = try await roster.liveClient()
        let before = try await resumes(pretend, of: "chat-garden")
        _ = try await chat.liveChat(of: garden, on: client, through: roster)
        var looked = before
        for _ in 0..<100 where looked < before + 2 {
            try await Task.sleep(for: .milliseconds(50))
            looked = try await resumes(pretend, of: "chat-garden")
        }
        #expect(looked >= before + 2, "the chat was looked at again")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!chat.questions.open.contains { $0.question.id == "srq-stale" })
        #expect(!roster.isWaiting(garden))
    }

    @Test func aQuestionTheSecondLookStillHoldsIsPutUp() async throws {
        let pretend = try await Pretend()
        let (roster, _, _) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        try await staleResume(pretend, chat: "chat-garden", keep: true)

        // The same late opening, but the approval is still asked: it shows once looked at again.
        let chat = roster.chat(for: garden)
        await chat.load(garden, from: roster)
        let client = try await roster.liveClient()
        _ = try await chat.liveChat(of: garden, on: client, through: roster)
        try await until("the approval still asked is shown") { chat.questions.open.contains { $0.question.id == "srq-stale" } }
        #expect(roster.isWaiting(garden))
    }

    @Test func aTurnEndingWhileTheSecondLookIsUnderWayLetsGoOfWhatWasHeld() async throws {
        let pretend = try await Pretend()
        let (roster, _, _) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        // The approval is still asked when the late opening comes, then another turn of the
        // chat ends while it is being looked at again, and both looks fail. The end made the
        // request obsolete, so falling back must not put it up.
        try await staleResume(pretend, chat: "chat-garden", keep: true, failRecheck: true)
        let chat = roster.chat(for: garden)
        await chat.load(garden, from: roster)
        let client = try await roster.liveClient()
        let before = try await resumes(pretend, of: "chat-garden")
        _ = try await chat.liveChat(of: garden, on: client, through: roster)
        var looked = before
        for _ in 0..<100 where looked < before + 3 {
            try await Task.sleep(for: .milliseconds(50))
            looked = try await resumes(pretend, of: "chat-garden")
        }
        #expect(looked >= before + 3, "both looks again were made")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!chat.questions.open.contains { $0.question.id == "srq-stale" })
        #expect(!roster.isWaiting(garden))
    }

    @Test func aRequestHeardBeforeItsChatWasClaimedIsOverWhenTheTurnEnds() async throws {
        let pretend = try await Pretend()
        let (roster, _, _) = try await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let client = try await roster.liveClient()
        roster.unclaimedWait = .seconds(30)

        // A request heard live for Garden's chat before this app claimed it, then that turn's
        // end: on the older route another app may have answered it unseen, so opening the chat
        // must not put it up.
        let early = BotQuestion(id: "srq-early", sessionID: "live-chat-garden", route: .request(.string("srq-early")),
                                kind: .approval(Approval(subject: .command("echo early"), choices: [.once, .deny])))
        roster.asked(early, on: client)
        roster.turnEnded(inSession: "live-chat-garden", on: client)
        let chat = roster.chat(for: garden)
        await chat.load(garden, from: roster)
        _ = try await chat.liveChat(of: garden, on: client, through: roster)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!chat.questions.open.contains { $0.question.id == "srq-early" })
        #expect(!roster.isWaiting(garden))
    }

    @Test func clickingNotificationReopensWindowAndAppliesSelectionAfterLoad() async throws {
        let pretend = try await Pretend()
        let spy = AlertSpy()
        let roster = RosterModel(gateway: (pretend.address, "demo"), alerts: spy.alerts)
        var reopened = 0
        roster.reopenMainWindow = { reopened += 1 }

        // Clicked before load() populates bots: remembered and applied once the roster loads.
        spy.alerts.selectBot("garden")
        #expect(reopened == 1)
        #expect(roster.selectedID == nil)

        await roster.load()
        #expect(roster.selectedID == "garden")
        #expect(roster.notificationOpens == 1)

        // Clicking again while loaded selects immediately and calls reopenMainWindow.
        spy.alerts.selectBot("trips")
        #expect(reopened == 2)
        #expect(roster.selectedID == "trips")
        #expect(roster.notificationOpens == 2)

        // A pre-load click for a bot that no longer exists is consumed on load, not kept forever.
        let staleSpy = AlertSpy()
        let second = RosterModel(gateway: (pretend.address, "demo"), alerts: staleSpy.alerts)
        staleSpy.alerts.selectBot("no-such-bot")
        await second.load()
        #expect(second.selectedID == second.mainBot?.id)
        #expect(second.notificationOpens == 0)
    }
}
