import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// Sending, against the pretend gateway in `Tools/fake-gateway.py`, which these tests start.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SendingTests {
    /// A pretend gateway on its own port, stopped when the test lets go of it.
    final class Pretend {
        let process = Process()
        let address: String
        let port: Int

        /// `whenBusy` is what a message to a bot that is answering does: "interrupt" turns
        /// the answer to it, as Hermes does unless set otherwise, and "queue" makes it wait.
        /// `extra` is a further word for a mode that takes one, such as the port that
        /// "redirects" sends its askers on to.
        init(port: Int = Int.random(in: 20000..<40000), whenBusy: String = "interrupt", extra: String? = nil) async throws {
            address = "127.0.0.1:\(port)"
            self.port = port
            let script = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tools/fake-gateway.py")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", script.path, String(port), whenBusy] + (extra.map { [$0] } ?? [])
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Up when it answers.
            let status = URL(string: "http://\(address)/api/status")!
            for _ in 0..<100 {
                if (try? await URLSession.shared.data(from: status)) != nil { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CocoaError(.fileNoSuchFile)
        }

        deinit { process.terminate() }
    }

    private func open(_ pretend: Pretend) async throws -> (RosterModel, Bot, ChatModel) {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let bot = try #require(roster.mainBot)
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        #expect(chat.phase == .loaded)
        return (roster, bot, chat)
    }

    private func settled(_ chat: ChatModel, within seconds: Double = 20) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while chat.isWorking {
            try #require(Date.now < deadline, "The chat was still working after \(seconds) seconds")
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

    @Test func aMessageIsAnsweredAndBothSidesEndUpInTheStoredChat() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let before = chat.items.count

        chat.draft = "  quick hello  "
        chat.send(to: bot, through: roster)
        #expect(chat.draft.isEmpty)
        #expect(chat.isWorking)
        #expect(texts(chat).last == "quick hello")
        #expect(roster.isWorking(bot))
        try await settled(chat)

        #expect(chat.sendProblem == nil)
        #expect(chat.items.count > before)
        #expect(texts(chat).suffix(2).first == "quick hello")
        #expect(texts(chat).last?.contains("everything arrived") == true)
        // Stored ids, not the stand-ins shown while it was live.
        #expect(!chat.items.contains { $0.id.contains("--") })
        #expect(roster.mainBot?.chat?.preview.hasPrefix("You said") == true)
    }

    /// A read of the stored chat that began before a send must not wipe the message off the
    /// screen or leave the chat working for ever.
    @Test func aReadAlreadyUnderWayDoesNotWipeAMessageBeingSent() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)

        async let read: Void = chat.load(bot, from: roster)
        await Task.yield()
        chat.draft = "quick one"
        chat.send(to: bot, through: roster)
        await read
        #expect(chat.isWorking)
        #expect(texts(chat).contains("quick one"))
        try await settled(chat)
        #expect(texts(chat).suffix(2).first == "quick one")
    }

    /// The moment one answer ends, the next message can be typed and sent; neither is lost.
    @Test func twoMessagesInARowBothArrive() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)

        chat.draft = "quick first"
        chat.send(to: bot, through: roster)
        // Not yet with the bot, so there is no answer to add to: the words stay in the composer.
        chat.draft = "quick second"
        chat.send(to: bot, through: roster)
        #expect(chat.draft == "quick second")
        chat.draft = ""
        try await settled(chat)
        chat.draft = "quick second"
        chat.send(to: bot, through: roster)
        try await settled(chat)

        let said = texts(chat)
        #expect(said.filter { $0 == "quick first" }.count == 1)
        #expect(said.filter { $0 == "quick second" }.count == 1)
        #expect(chat.sendProblem == nil)
    }

    @Test func stopEndsALongAnswerAndKeepsWhatWasSaid() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)

        chat.draft = "quick but slow"
        chat.send(to: bot, through: roster)
        let deadline = Date.now.addingTimeInterval(10)
        while chat.isWaitingForWords {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        chat.stop(bot)
        try await settled(chat, within: 8)

        #expect(chat.sendProblem == nil)
        let last = try #require(texts(chat).last)
        #expect(last.hasPrefix("Still"))
        #expect(last.count < 300)
    }

    private func hasWords(_ chat: ChatModel, within seconds: Double = 10) async throws {
        let deadline = Date.now.addingTimeInterval(seconds)
        while chat.isWaitingForWords {
            try #require(Date.now < deadline, "No words from the bot after \(seconds) seconds")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func interrupts(_ pretend: Pretend) async throws -> Int {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://\(pretend.address)/api/status")!)
        let status = try JSONDecoder().decode(JSONValue.self, from: data)
        return try #require(status["interrupts"]?.numberValue.map { Int($0) })
    }

    @Test func stoppingOneBotLeavesAnotherAnswering() async throws {
        let pretend = try await Pretend()
        let (roster, main, chat) = try await open(pretend)
        let garden = try #require(roster.otherBots.first { $0.chat != nil })
        let other = roster.chat(for: garden)
        await other.load(garden, from: roster)

        chat.draft = "quick but slow main"
        other.draft = "quick but slow garden"
        chat.send(to: main, through: roster)
        other.send(to: garden, through: roster)
        try await hasWords(chat)
        try await hasWords(other)
        other.stop(garden)
        try await settled(other, within: 8)

        #expect(try await interrupts(pretend) == 1)
        #expect(texts(other).last?.hasPrefix("Still") == true)
        // The other bot is still going, well past where the first was cut off.
        #expect(chat.isWorking)
        try await Task.sleep(for: .seconds(1))
        #expect(chat.isWorking)
        chat.stop(main)
        try await settled(chat, within: 8)
    }

    /// Stop pressed while the gateway is slow to say it has the message: the bot may have
    /// it, so the bot is told to stop, and the words are back in the composer.
    @Test func stopWhileTheMessageIsOnItsWayStopsTheBot() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)

        chat.draft = "quick late slow"
        chat.send(to: bot, through: roster)
        try await Task.sleep(for: .milliseconds(300))
        #expect(chat.canStop)
        chat.stop(bot)
        #expect(!chat.canStop)
        try await settled(chat, within: 8)

        #expect(try await interrupts(pretend) == 1)
        #expect(chat.draft == "quick late slow")
        #expect(chat.sendProblem != nil)
        // The bot did take it, and the stored chat says so.
        #expect(texts(chat).contains("quick late slow"))
        // And it stopped: a second later nothing more has been said.
        try await Task.sleep(for: .milliseconds(1500))
        await chat.load(bot, from: roster)
        #expect(texts(chat).last == "quick late slow")
    }

    /// On a gateway set to queue: sent while the bot is answering someone else, the message
    /// waits, the other answer is not cut off, and ours is the answer the chat ends on.
    @Test func onAQueueingGatewayAMessageToABusyBotWaitsAndGetsItsOwnAnswer() async throws {
        let pretend = try await Pretend(whenBusy: "queue")
        let (roster, bot, chat) = try await open(pretend)
        let someoneElse = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await someoneElse.connect()
        let theirs = try await someoneElse.openChat(try #require(bot.chat), profile: bot.name)

        // Theirs is taken first but slow to begin, so its answer begins and ends while ours
        // is being listened for: the answer shown has to move on from theirs to ours.
        async let sent = someoneElse.send("quick late theirs", in: theirs, profile: bot.name)
        try await Task.sleep(for: .milliseconds(200))
        chat.draft = "quick mine"
        chat.send(to: bot, through: roster)
        _ = try await sent
        try await settled(chat)

        #expect(try await interrupts(pretend) == 0)
        #expect(chat.sendProblem == nil)
        let said = texts(chat)
        #expect(said.contains { $0.contains("“quick late theirs”") && $0.contains("everything arrived") })
        #expect(said.last?.contains("“quick mine”") == true)
        #expect(said.last?.contains("everything arrived") == true)
        await someoneElse.disconnect()
    }

    /// More sent while the bot is answering goes to it at once, and the answer turns to it.
    @Test func moreSentMidAnswerGoesToTheBotAtOnce() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)

        chat.draft = "quick but slow, book the 9am"
        chat.send(to: bot, through: roster)
        try await hasWords(chat)
        #expect(chat.canAddToTurn)
        chat.draft = "quick, make it 10"
        chat.send(to: bot, through: roster)
        #expect(chat.draft.isEmpty)
        // Give the loop a moment to take it in: it is on screen before the bot has answered it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(texts(chat).last == "quick, make it 10")
        #expect(chat.isWorking)
        // While the fresh answer arrives, what the bot had said before is there once, above
        // the added message, and not again below it.
        let deadline = Date.now.addingTimeInterval(10)
        while !(texts(chat).last?.hasPrefix("You said") ?? false) {
            try #require(Date.now < deadline, "The fresh answer never began")
            try await Task.sleep(for: .milliseconds(20))
        }
        let live = texts(chat)
        #expect(live.filter { $0.hasPrefix("Still") }.count == 1)
        #expect(live.suffix(3).first?.hasPrefix("Still") == true)
        #expect(live.suffix(2).first == "quick, make it 10")
        try await settled(chat)

        #expect(try await interrupts(pretend) == 0)
        #expect(chat.sendProblem == nil)
        let said = texts(chat)
        #expect(said.filter { $0 == "quick but slow, book the 9am" }.count == 1)
        #expect(said.filter { $0 == "quick, make it 10" }.count == 1)
        // The first answer stopped where it was, and a fresh one answered the new message.
        #expect(said.last?.contains("“quick, make it 10”") == true)
        #expect(said.last?.contains("everything arrived") == true)
        #expect(said.contains { $0.hasPrefix("Still") })
    }

    /// Two more messages sent in quick succession mid-answer: each is shown once, in the
    /// order sent, and the chat is followed until the last has its answer.
    @Test(arguments: ["interrupt", "queue"])
    func twoMoreSentMidAnswerAreBothAnswered(whenBusy: String) async throws {
        let pretend = try await Pretend(whenBusy: whenBusy)
        let (roster, bot, chat) = try await open(pretend)

        chat.draft = "quick but slow, book the 9am"
        chat.send(to: bot, through: roster)
        try await hasWords(chat)
        chat.draft = "quick, make it 10"
        chat.send(to: bot, through: roster)
        chat.draft = "quick, and add coffee"
        chat.send(to: bot, through: roster)
        #expect(chat.draft.isEmpty)
        #expect(Array(texts(chat).suffix(2)) == ["quick, make it 10", "quick, and add coffee"])
        try await settled(chat, within: 40)

        #expect(chat.sendProblem == nil)
        let said = texts(chat)
        #expect(said.filter { $0 == "quick, make it 10" }.count == 1)
        #expect(said.filter { $0 == "quick, and add coffee" }.count == 1)
        #expect(said.contains { $0.contains("“quick, and add coffee”") && $0.contains("everything arrived") })
        // They reached the bot in the order sent, so the chat ends on the answer to the last.
        #expect(said.last?.contains("“quick, and add coffee”") == true)
        #expect(said.last?.contains("everything arrived") == true)
    }

    /// Stop pressed straight after adding a message: the bot stops, and the added message
    /// does not set it going again.
    @Test func stopRightAfterAddingAMessageStopsTheBot() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)

        chat.draft = "quick but slow"
        chat.send(to: bot, through: roster)
        try await hasWords(chat)
        chat.draft = "quick, something else"
        chat.send(to: bot, through: roster)
        chat.stop(bot)
        try await settled(chat, within: 10)
        #expect(chat.sendProblem == nil)

        // The bot is free again: a fresh message is answered itself, not the stopped one.
        chat.draft = "quick fresh"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(texts(chat).last?.contains("“quick fresh”") == true)
    }

    /// The bot is answering someone else. By default our message turns that answer to ours
    /// straight away, and the app follows it without having seen it begin.
    @Test func aMessageToABotBusyElsewhereJoinsThatAnswer() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let someoneElse = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await someoneElse.connect()
        let theirs = try await someoneElse.openChat(try #require(bot.chat), profile: bot.name)

        try await someoneElse.send("quick but slow theirs", in: theirs, profile: bot.name)
        try await Task.sleep(for: .milliseconds(600))
        chat.draft = "quick mine"
        chat.send(to: bot, through: roster)
        try await settled(chat)

        #expect(chat.sendProblem == nil)
        #expect(texts(chat).last?.contains("“quick mine”") == true)
        #expect(texts(chat).last?.contains("everything arrived") == true)
        await someoneElse.disconnect()
    }

    /// On a queueing gateway, sent while someone else's answer is already streaming, so its
    /// beginning was never seen: once ours is answered the chat settles, without waiting on.
    @Test func aMessageQueuedBehindAnAnswerAlreadyStreamingSettlesOnceAnswered() async throws {
        let pretend = try await Pretend(whenBusy: "queue")
        let (roster, bot, chat) = try await open(pretend)
        let someoneElse = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await someoneElse.connect()
        let theirs = try await someoneElse.openChat(try #require(bot.chat), profile: bot.name)

        try await someoneElse.send("quick theirs, at some length so it is still going", in: theirs, profile: bot.name)
        try await Task.sleep(for: .milliseconds(400))
        chat.draft = "quick mine"
        chat.quietChecksAllowed = 3
        chat.send(to: bot, through: roster)
        try await settled(chat, within: 20)

        #expect(chat.sendProblem == nil)
        #expect(texts(chat).last?.contains("“quick mine”") == true)
        await someoneElse.disconnect()
    }

    /// Someone else stops the bot while our message waits behind their turn. The gateway
    /// drops ours without a word; the chat must not sit there working for ever.
    @Test func aWaitingMessageDroppedBySomeoneElsesStopIsGivenUpOn() async throws {
        let pretend = try await Pretend(whenBusy: "queue")
        let (roster, bot, chat) = try await open(pretend)
        let someoneElse = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await someoneElse.connect()
        let theirs = try await someoneElse.openChat(try #require(bot.chat), profile: bot.name)

        // Theirs is under way before ours is listening, so ours never sees it begin.
        try await someoneElse.send("quick but slow theirs", in: theirs, profile: bot.name)
        try await Task.sleep(for: .milliseconds(600))
        chat.draft = "quick mine"
        chat.quietChecksAllowed = 2
        chat.send(to: bot, through: roster)
        try await Task.sleep(for: .milliseconds(600))
        try await someoneElse.stop(theirs, profile: bot.name)
        try await settled(chat, within: 15)

        #expect(chat.sendProblem?.contains("dropped") == true)
        #expect(texts(chat).contains("quick mine"))
        #expect(!texts(chat).contains { $0.contains("“quick mine”") })
        await someoneElse.disconnect()
    }

    @Test func aGatewayThatIsGoneGivesTheWordsBack() async throws {
        let pretend = try await Pretend()
        let (roster, bot, chat) = try await open(pretend)
        pretend.process.terminate()
        pretend.process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(200))

        chat.draft = "quick hello"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.draft == "quick hello")
        #expect(chat.sendProblem != nil)
        #expect(!texts(chat).contains("quick hello"))
    }

    /// The gateway restarts. The first send finds the connection gone; the next one gets
    /// through on a fresh connection, without the app being restarted.
    @Test func sendingWorksAgainOnceTheGatewayIsBack() async throws {
        let port = Int.random(in: 40000..<50000)
        var pretend: Pretend? = try await Pretend(port: port)
        let (roster, bot, chat) = try await open(try #require(pretend))
        pretend?.process.terminate()
        pretend?.process.waitUntilExit()
        pretend = try await Pretend(port: port)

        chat.draft = "quick hello again"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        if chat.sendProblem != nil {
            // The first try may be the one that finds out the old connection is gone.
            #expect(chat.draft == "quick hello again")
            chat.send(to: bot, through: roster)
            try await settled(chat)
        }
        #expect(chat.sendProblem == nil)
        #expect(texts(chat).last?.contains("“quick hello again”") == true)
        _ = pretend
    }
}
