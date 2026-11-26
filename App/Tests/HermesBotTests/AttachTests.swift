import AppKit
import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// Sending files and pictures with a message, against the pretend gateway.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AttachTests {
    private func open(_ pretend: SendingTests.Pretend, store: GatewayStore? = nil) async throws -> (RosterModel, Bot, ChatModel) {
        let roster = RosterModel(gateway: (pretend.address, "demo"), store: store)
        await roster.load()
        let bot = try #require(roster.mainBot)
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        return (roster, bot, chat)
    }

    private func settled(_ chat: ChatModel) async throws {
        // No deadline of its own: a busy Mac may take longer, while the suite's own
        // time limit still catches a turn that never ends.
        while chat.isWorking { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Files to pick, made in a folder of their own. Returns them with what removes them.
    private func files(_ named: [String: Data]) throws -> ([String: URL], () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [String: URL] = [:]
        for (name, data) in named {
            urls[name] = folder.appendingPathComponent(name)
            try data.write(to: urls[name]!)
        }
        return (urls, { try? FileManager.default.removeItem(at: folder) })
    }

    private func picked(_ chat: ChatModel, _ count: Int) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while chat.attachments.count < count, chat.attachProblem == nil {
            try #require(Date.now < deadline, "The files were not taken")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A picture's first bytes are enough for the pretend gateway, which only keeps them.
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private func lastSent(_ chat: ChatModel) -> SentParts? {
        chat.items.reversed().compactMap { item -> SentParts? in
            if case .user(_, let text) = item { return SentParts(stored: text) }
            return nil
        }.first
    }

    @Test func aPictureAndAFileGoWithTheMessageAndAreShownWithIt() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let (urls, remove) = try files(["sketch.png": png, "my notes.txt": Data("hello".utf8)])
        defer { remove() }

        chat.attach([urls["sketch.png"]!, urls["my notes.txt"]!])
        try await picked(chat, 2)
        #expect(chat.attachments.map(\.name) == ["sketch.png", "my notes.txt"])
        #expect(chat.attachments.map(\.isPicture) == [true, false])
        chat.draft = "quick look at these"
        chat.send(to: bot, through: roster)
        // Out of the box and with the message while it is on its way.
        #expect(chat.attachments.isEmpty)
        #expect(chat.sentAttachments.count == 2)
        #expect(lastSent(chat)?.words == "quick look at these")
        try await settled(chat)

        #expect(chat.sendProblem == nil)
        #expect(chat.sentAttachments.isEmpty)
        // The stored message is read back as its words and what went with it, and nothing
        // of what the gateway added for the bot is shown.
        let sent = try #require(chat.items.compactMap { item -> SentParts? in
            if case .user(_, let text) = item, text.contains("quick look") { return SentParts(stored: text) }
            return nil
        }.last)
        #expect(sent.words == "quick look at these")
        #expect(sent.files == ["my notes.txt"])
        #expect(sent.images.count == 1)
        // What was sent is there to be fetched, as any file on the gateway is.
        #expect(try await roster.file(at: sent.images[0], from: bot).data == png)
        #expect(roster.mainBot?.chat?.preview.contains("Attached Context") == false)
    }

    /// Where the session authority handles chats, the plus is offered, and pictures are held
    /// on the gateway and named on the message. That route takes no BMP, so one goes as a PNG.
    @Test func throughTheSessionAuthorityAPictureAndAFileGoWithTheMessage() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "authority")
        let (store, forget) = ownStore()
        defer { forget() }
        let (roster, bot, chat) = try await open(pretend, store: store)
        #expect(chat.canAttach)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bmp = try #require(bitmap.representation(using: .bmp, properties: [:]))
        let (urls, remove) = try files(["sketch.png": png, "old.bmp": bmp, "my notes.txt": Data("hello".utf8)])
        defer { remove() }
        chat.attach([urls["sketch.png"]!, urls["old.bmp"]!, urls["my notes.txt"]!])
        try await picked(chat, 3)
        chat.draft = "quick look at these"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil, "\(chat.sendProblem ?? "")")
        let sent = try #require(lastSent(chat))
        #expect(sent.words == "quick look at these")
        #expect(sent.files == ["my notes.txt"])
        try #require(sent.images.count == 2)
        #expect(try await roster.file(at: sent.images[0], from: bot).data == png)
        #expect(try await roster.file(at: sent.images[1], from: bot).data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        // A picture alone goes with Hermes's stand-in for the words, as on the older route.
        chat.attach(picture: png)
        try await picked(chat, 1)
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let alone = try #require(lastSent(chat))
        #expect(alone.words.isEmpty && alone.images.count == 1)

        // Nothing waits in the chat on that route, so a message that did not go leaves
        // nothing noted as on its way, which would have the next send close the chat.
        chat.attach(picture: png)
        try await picked(chat, 1)
        chat.draft = "refuse this message"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem != nil)
        #expect(store.picturesMayLandLate.isEmpty)
    }

    /// A BMP that cannot be made into a PNG is not sent as a BMP, which that route refuses:
    /// nothing goes, and why is said of the file picked.
    @Test func throughTheSessionAuthorityABMPThatCannotBeConvertedIsSaidSo() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "authority")
        let (roster, bot, chat) = try await open(pretend)
        let (urls, remove) = try files(["broken.bmp": Data("not a picture".utf8)])
        defer { remove() }
        chat.attach([urls["broken.bmp"]!])
        try await picked(chat, 1)
        chat.draft = "quick look"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem?.contains("broken.bmp couldn't be read.") == true, "\(chat.sendProblem ?? "")")
        #expect(chat.draft == "quick look")
    }

    @Test func aPictureAloneCanBeSent() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.attach(picture: png)
        // Not sent while what was picked is still being read: it would be left behind.
        chat.send(to: bot, through: roster)
        try await picked(chat, 1)
        #expect(!chat.isWorking || chat.sentAttachments.count == 1)
        if !chat.isWorking { chat.send(to: bot, through: roster) }
        #expect(chat.isWorking)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(lastSent(chat))
        #expect(sent.words.isEmpty)
        #expect(sent.images.count == 1)
    }

    /// Several pictures with one message are all there when it is read back, and not
    /// offered at all while the bot is answering.
    @Test func severalPicturesGoWithOneMessage() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.attach(picture: png)
        chat.attach(picture: png)
        try await picked(chat, 2)
        chat.draft = "late slow compare these"
        chat.send(to: bot, through: roster)
        #expect(!chat.canAttach)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(chat.items.compactMap { item -> SentParts? in
            if case .user(_, let text) = item, text.contains("compare these") { return SentParts(stored: text) }
            return nil
        }.last)
        #expect(sent.words == "late slow compare these")
        #expect(sent.images.count == 2)
        #expect(chat.canAttach)
    }

    /// One the gateway will not take: nothing is sent, the words and the files come back
    /// to the box, and a picture already handed over does not go with a later message.
    @Test func whenAFileIsRefusedNothingGoesAndEverythingComesBack() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let (urls, remove) = try files(["a.png": png, "please refuse.txt": Data("x".utf8)])
        defer { remove() }
        let before = chat.items.count

        chat.attach([urls["a.png"]!, urls["please refuse.txt"]!])
        try await picked(chat, 2)
        chat.draft = "quick these two"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem?.contains("could not store the file") == true)
        #expect(chat.draft == "quick these two")
        #expect(chat.attachments.map(\.name) == ["a.png", "please refuse.txt"])
        #expect(chat.sentAttachments.isEmpty)
        #expect(chat.items.count == before)
        // Sent again without them, the picture taken back does not ride along.
        chat.removeAttachment(chat.attachments[0].id)
        chat.removeAttachment(chat.attachments[0].id)
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        #expect(lastSent(chat)?.images.isEmpty == true)
    }

    /// The gateway took the picture and then would not take the message. The picture is
    /// taken back, so it does not go with whatever is sent next.
    @Test func aPictureDoesNotRideAlongWithALaterMessage() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        chat.attach(picture: png)
        try await picked(chat, 1)
        chat.draft = "refuse this message"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem != nil)
        #expect(chat.attachments.count == 1)
        // The same when the send is stopped as the files are going.
        chat.draft = "late slow one, stopped at once"
        chat.send(to: bot, through: roster)
        chat.stop(bot)
        try await settled(chat)
        while !chat.attachments.isEmpty { chat.removeAttachment(chat.attachments[0].id) }
        chat.draft = "quick, words only"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(lastSent(chat))
        #expect(sent.words == "quick, words only")
        #expect(sent.images.isEmpty)
    }

    /// The gateway is slow to take pictures back, and the next message is sent at once.
    /// It waits for them to be gone rather than going with them.
    @Test func theNextMessageWaitsForPicturesToBeTakenBack() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "slow-detach")
        let (roster, bot, chat) = try await open(pretend)
        chat.attach(picture: png)
        chat.attach(picture: png)
        try await picked(chat, 2)
        chat.draft = "refuse this message"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem != nil)
        while !chat.attachments.isEmpty { chat.removeAttachment(chat.attachments[0].id) }
        chat.draft = "words only, sent at once"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(lastSent(chat))
        #expect(sent.words == "words only, sent at once")
        #expect(sent.images.isEmpty)
    }

    /// The gateway took a picture and the app never heard so: where it is cannot be
    /// known, so it cannot be taken back by name. The next message still goes without it.
    @Test func aPictureTheAppNeverHeardWasTakenDoesNotRideAlong() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let (urls, remove) = try files(["lost.png": png])
        defer { remove() }
        chat.attach(Array(urls.values))
        try await picked(chat, 1)
        chat.draft = "with a picture"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem != nil)
        while !chat.attachments.isEmpty { chat.removeAttachment(chat.attachments[0].id) }
        chat.draft = "words only"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(lastSent(chat))
        #expect(sent.words == "words only")
        #expect(sent.images.isEmpty)
    }

    /// A run of the app that was quit left a picture waiting in the open chat, and the
    /// gateway hands that open chat back. The first message of this run goes without it.
    @Test func aPictureLeftByARunThatWasQuitDoesNotRideAlong() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        // The run before, which queued a picture and was gone before taking it back.
        let before = GatewayClient(endpoint: try #require(GatewayEndpoint(pretend.address)), token: "demo")
        await before.connect()
        let left = try await before.openChat(try #require(bot.chat), profile: bot.name)
        _ = try await before.attachImage(png, named: "left.png", in: left, profile: bot.name)
        await before.disconnect()
        chat.draft = "words only"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(lastSent(chat))
        #expect(sent.words == "words only")
        #expect(sent.images.isEmpty)
    }

    /// A store of a test's own: what is noted on disk about pictures on their way is not
    /// left for other tests, whose pretend gateways hand out the same open chats.
    private func ownStore() -> (GatewayStore, () -> Void) {
        let suite = "AttachTests.\(UUID().uuidString)"
        return (GatewayStore(suite: suite, service: suite), { UserDefaults().removePersistentDomain(forName: suite) })
    }

    /// Sends a picture whose connection goes before the gateway answers, as when the
    /// gateway is left; the pretend gateway queues it only just after the next count.
    private func sendLate(_ chat: ChatModel, to bot: Bot, through roster: RosterModel) async throws {
        let (urls, remove) = try files(["late.png": png])
        defer { remove() }
        chat.attach(Array(urls.values))
        try await picked(chat, 1)
        chat.draft = "with a picture"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem != nil)
        while !chat.attachments.isEmpty { chat.removeAttachment(chat.attachments[0].id) }
    }

    /// The connection went while a picture was on its way, and the gateway queued it only
    /// after the app, connected again, had been told none were waiting. The next message
    /// still goes without it.
    @Test func aPictureQueuedAfterTheCountDoesNotRideAlong() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, forget) = ownStore()
        defer { forget() }
        let (roster, bot, chat) = try await open(pretend, store: store)
        try await sendLate(chat, to: bot, through: roster)
        chat.draft = "words only"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(lastSent(chat))
        #expect(sent.words == "words only")
        #expect(sent.images.isEmpty)
    }

    /// The same, with the app quit while the gateway was still at work on the picture: the
    /// next run is told none wait, and the picture is queued just after.
    @Test func aPictureStillOnItsWayAtAQuitDoesNotRideAlong() async throws {
        let pretend = try await SendingTests.Pretend()
        let (store, forget) = ownStore()
        defer { forget() }
        do {
            let (roster, bot, chat) = try await open(pretend, store: store)
            try await sendLate(chat, to: bot, through: roster)
        }
        // The next run, with only what was kept on disk.
        let (roster, bot, chat) = try await open(pretend, store: store)
        chat.draft = "words only"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(lastSent(chat))
        #expect(sent.words == "words only")
        #expect(sent.images.isEmpty)
        // Settled, so nothing is left noted.
        #expect(store.picturesMayLandLate.isEmpty)
    }

    /// A gateway that takes no attachments at all still takes words afterwards.
    @Test func wordsStillGoWhereTheGatewayTakesNoPictures() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-attachments")
        let (roster, bot, chat) = try await open(pretend)
        chat.attach(picture: png)
        try await picked(chat, 1)
        chat.draft = "with a picture"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem != nil)
        #expect(!chat.canAttach)
        chat.draft = "words only"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        #expect(lastSent(chat)?.words == "words only")
    }

    /// Files dropped are counted from the drop, before they arrive: nothing is sent
    /// without them meanwhile.
    @Test func sendWaitsForFilesThatWereDropped() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let (urls, remove) = try files(["a.txt": Data("x".utf8)])
        defer { remove() }
        let held = chat.expect(1)
        chat.draft = "with what I dropped"
        chat.send(to: bot, through: roster)
        #expect(!chat.isWorking)
        #expect(chat.draft == "with what I dropped")
        chat.attach(Array(urls.values), expected: held)
        try await picked(chat, 1)
        #expect(chat.filesBeingRead == 0)
        // A drop that brought nothing gives its places back.
        chat.attach([], expected: chat.expect(3))
        #expect(chat.filesBeingRead == 0)
    }

    /// At most ten, counting ones still being read, however they are picked.
    @Test func noMoreThanTenGoWithOneMessage() async throws {
        let pretend = try await SendingTests.Pretend()
        let (_, _, chat) = try await open(pretend)
        var named: [String: Data] = [:]
        for number in 1...14 { named["f\(number).txt"] = Data("x".utf8) }
        let (urls, remove) = try files(named)
        defer { remove() }
        chat.attach(Array(urls.values.prefix(7)))
        chat.attach(Array(urls.values.suffix(7)))
        try await picked(chat, 10)
        try await Task.sleep(for: .milliseconds(100))
        #expect(chat.attachments.count == 10)
        #expect(chat.filesBeingRead == 0)
        #expect(chat.attachProblem == "At most 10 files go with one message.")
    }

    /// A message on its way is shown as the words typed, whatever they say; and once
    /// stored, words that only read like an attachment are still words.
    @Test func whatIsTypedIsShownAsTyped() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat) = try await open(pretend)
        let typed = "quick: the heading --- Attached Context --- and sam@file.example"
        chat.draft = typed
        chat.send(to: bot, through: roster)
        // On its way: exactly as typed.
        let echoed = chat.items.compactMap { item -> String? in
            if case .user(let id, let text) = item, id < 0 { return text }
            return nil
        }
        #expect(echoed == [typed])
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        let sent = try #require(lastSent(chat))
        #expect(sent.words == typed)
        #expect(sent.files.isEmpty && sent.images.isEmpty)
    }

    @Test func aGatewayWithNoWayOfTakingAttachmentsStopsOfferingThemAndStillSends() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-attachments")
        let (roster, bot, chat) = try await open(pretend)
        chat.attach(picture: png)
        try await picked(chat, 1)
        chat.draft = "quick with a picture"
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem?.contains("doesn't take attachments") == true)
        #expect(chat.cannotAttach)
        #expect(!chat.cannotSend)
        #expect(chat.draft == "quick with a picture")
        // Nothing is left in the box that could only fail again, and the words still go.
        #expect(chat.attachments.isEmpty)
        #expect(!chat.canAttach)
        chat.send(to: bot, through: roster)
        try await settled(chat)
        #expect(chat.sendProblem == nil)
        #expect(lastSent(chat)?.words == "quick with a picture")
    }

    @Test func whatCannotBeAttachedIsLeftOutAndSaid() async throws {
        let pretend = try await SendingTests.Pretend()
        let (_, _, chat) = try await open(pretend)
        let (urls, remove) = try files(["ok.txt": Data("x".utf8)])
        defer { remove() }
        chat.attach([URL(fileURLWithPath: "/nonexistent/gone.txt"), urls["ok.txt"]!])
        try await picked(chat, 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(chat.attachments.map(\.name) == ["ok.txt"])
        #expect(chat.attachProblem == "gone.txt couldn't be read.")
        // A folder is not a file.
        if case .failure(let problem) = PickedFile.read(FileManager.default.temporaryDirectory) { #expect(problem.text.contains("couldn't be read")) } else { Issue.record("A folder was taken") }
        #expect(PickedFile.read(urls["ok.txt"]!).map(\.type) == .success("text/plain"))
    }
}

extension PickedFile.Problem: Equatable {
    public static func == (one: PickedFile.Problem, other: PickedFile.Problem) -> Bool { one.text == other.text }
}
