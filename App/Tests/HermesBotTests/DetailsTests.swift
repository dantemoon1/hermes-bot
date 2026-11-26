import Foundation
import HermesBotUI
import HermesKit
import Testing
@testable import HermesBot

/// Renaming, changing a face, the description and soul, usage, routines and deleting, against the pretend gateway.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct DetailsTests {
    private func open(_ pretend: SendingTests.Pretend) async -> RosterModel {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        return roster
    }

    @Test func aNewNameAndFaceAreSavedTogetherAndSeenByTheNextLaunch() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        var garden = try #require(roster.bots.first { $0.name == "garden" })
        let face = roster.look(for: garden)

        #expect(await roster.update(garden, title: "  Allotment ") == nil)
        garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(garden.title == "Allotment")
        // Renaming leaves the face, and changing the face leaves the name.
        #expect(roster.look(for: garden) == face)
        #expect(await roster.update(garden, look: AvatarLook(shape: .star, color: .teal)) == nil)
        garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(garden.title == "Allotment")
        #expect(roster.look(for: garden) == AvatarLook(shape: .star, color: .teal))
        // Hermes's own notes on the bot are still there.
        #expect(garden.uiMeta["hermes-bots"]?["title"]?.stringValue == "Garden")

        let again = await open(pretend)
        let same = try #require(again.bots.first { $0.name == "garden" })
        #expect(same.title == "Allotment")
        #expect(again.look(for: same) == AvatarLook(shape: .star, color: .teal))
        #expect(await roster.update(garden, title: "   ") == "A bot needs a name.")
    }

    @Test func changesMadeAtOnceFromAnOldCopyOfTheBotAllLast() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        // The same copy of the bot for each, as a pane holds while its saves are on the way.
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        // Asked one after another without waiting, as a person's edits are: tasks begun
        // in this order, on the main actor, start in it.
        let named = Task { await roster.update(garden, title: "Allotment") }
        let faced = Task { await roster.update(garden, look: AvatarLook(shape: .star, color: .teal)) }
        let renamed = Task { await roster.update(garden, title: "Plot") }
        #expect(await named.value == nil)
        #expect(await faced.value == nil)
        #expect(await renamed.value == nil)

        let again = await open(pretend)
        let same = try #require(again.bots.first { $0.name == "garden" })
        #expect(same.title == "Plot")
        #expect(again.look(for: same) == AvatarLook(shape: .star, color: .teal))
    }

    @Test func aNewFaceAloneDoesNotFixTheNameInPlace() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await roster.update(garden, look: AvatarLook(shape: .star, color: .teal)) == nil)
        let now = try #require(roster.bots.first { $0.name == "garden" })
        // The name still comes from Hermes's own notes, and follows them if they change.
        #expect(now.uiMeta["hermes-bot"]?["title"] == nil)
        #expect(now.title == garden.title)
    }

    @Test func aSuggestionLeavesWordsBeingTypedAlone() async throws {
        let chat = ChatModel()
        chat.suggest("What's a routine?")
        #expect(chat.draft == "What's a routine?")
        chat.draft = "half a thought"
        chat.suggest("What's a routine?")
        #expect(chat.draft == "half a thought")
        #expect(chat.focusAsks == 2)
    }

    private func status(_ pretend: SendingTests.Pretend, _ key: String) async throws -> [String] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://\(pretend.address)/api/status")!)
        let status = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return status[key] as? [String] ?? []
    }

    private func refreshes(_ pretend: SendingTests.Pretend) async throws -> [String] {
        try await status(pretend, "refreshes")
    }

    private func answered(_ chat: ChatModel) async throws {
        let deadline = Date.now.addingTimeInterval(20)
        while chat.isWorking {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aMessageSentAsANewSoulIsSavedWaitsForTheChatToTakeItUp() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "slow-refresh")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let chat = roster.chat(for: garden)
        await chat.load(garden, from: roster)
        // Saved and sent in the same moment, as when the pane closes and the person types.
        let save = roster.update(garden, soul: "Talk like a seed catalogue.")
        chat.draft = "quick what now"
        chat.send(to: garden, through: roster)
        try await answered(chat)
        #expect(await save.value.saved)
        #expect(try await status(pretend, "order") == ["refresh", "submit"])
    }

    @Test func aMessageWaitsForEverySoulSavedWhileItWaits() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "slow-refresh")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let chat = roster.chat(for: garden)
        await chat.load(garden, from: roster)
        let first = roster.update(garden, soul: "Talk like a seed catalogue.")
        chat.draft = "quick what now"
        chat.send(to: garden, through: roster)
        // Changed again while the message waits on the first.
        try await Task.sleep(for: .milliseconds(300))
        let second = roster.update(garden, soul: "Talk like a seed packet.")
        try await answered(chat)
        #expect(await first.value.saved)
        #expect(await second.value.saved)
        #expect(try await status(pretend, "order") == ["refresh", "refresh", "submit"])
    }

    @Test func aSoulSavedWhileABotsFirstMessageGoesReachesTheChatItStarted() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "slow-attach")
        let roster = await open(pretend)
        // A bot with no chat yet: its first message starts one, which the roster has not read.
        let books = try #require(roster.bots.first { $0.name == "books" })
        #expect(books.chat == nil)
        let chat = roster.chat(for: books)
        await chat.load(books, from: roster)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("soul-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)
        chat.attach([notes])
        let deadline = Date.now.addingTimeInterval(5)
        while chat.attachments.isEmpty {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        chat.draft = "quick have a look"
        chat.send(to: books, through: roster)
        // Saved while the file goes, after the chat has been started.
        try await Task.sleep(for: .milliseconds(400))
        let save = roster.update(books, soul: "Short answers.")
        try await answered(chat)
        #expect(await save.value == .init(saved: true, said: nil))
        #expect(try await refreshes(pretend) == ["books chat-books"])
        #expect(try await status(pretend, "order") == ["refresh", "submit"])
    }

    @Test func aSoulThatFailedToSaveIsKeptToOfferBackUntilTheBotGoes() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "unsaved")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await !roster.update(garden, soul: "Talk like a seed catalogue.").value.saved)
        #expect(roster.unsavedSouls[garden.id] == "Talk like a seed catalogue.")
        roster.discardUnsavedSoul(for: garden)
        #expect(roster.unsavedSouls[garden.id] == nil)
        #expect(await !roster.update(garden, soul: "Talk like a seed catalogue.").value.saved)
        // A bot made again under the same name is another bot, with nothing to offer back.
        #expect(await roster.delete(garden) == nil)
        #expect(roster.unsavedSouls[garden.id] == nil)
    }

    @Test func aDescriptionAndSoulAreReadAndSavedAndTheChatTakesTheSoulUp() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(garden.description == "Beds, sowing and watering")
        let read = try #require(await roster.personality(of: garden))
        #expect(read.soul.hasPrefix("You look after a small garden."))

        // Only what changed is sent, and the description shows at once.
        #expect(await roster.update(garden, description: "  Vegetables only ").value == .init(saved: true, said: nil))
        #expect(roster.bots.first { $0.name == "garden" }?.description == "Vegetables only")
        #expect(try await refreshes(pretend).isEmpty)
        // A new soul is taken up on the chat's next turn, not when its agent next starts.
        #expect(await roster.update(garden, soul: "Talk like a seed catalogue.").value == .init(saved: true, said: nil))
        #expect(try await refreshes(pretend) == ["garden chat-garden"])

        let again = await open(pretend)
        let same = try #require(again.bots.first { $0.name == "garden" })
        #expect(same.description == "Vegetables only")
        #expect(await again.personality(of: same) == BotPersonality(description: "Vegetables only", soul: "Talk like a seed catalogue."))
        // A bot with no chat yet begins its first with the new soul: nothing to renew.
        let books = try #require(again.bots.first { $0.name == "books" })
        #expect(await again.update(books, soul: "Short answers.").value == .init(saved: true, said: nil))
        #expect(try await refreshes(pretend) == ["garden chat-garden"])
    }

    @Test func aSoulTheGatewayAnsweredAsNotSavedIsNotTakenForSaved() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "unsaved")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let outcome = await roster.update(garden, description: "Vegetables only", soul: "Talk like a seed catalogue.").value
        #expect(!outcome.saved)
        #expect(outcome.said?.hasPrefix("Couldn't save that.") == true)
        #expect(roster.bots.first { $0.name == "garden" }?.description == "Beds, sowing and watering")
        #expect(try await refreshes(pretend).isEmpty)
        // Names and faces are still offered: this was one refusal, not a gateway that never keeps them.
        #expect(!roster.cannotEditBots)
    }

    @Test func aSoulSavedOnAGatewayThatCannotRenewAChatSaysWhenItTakesEffect() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-refresh")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        let outcome = await roster.update(garden, soul: "Talk like a seed catalogue.").value
        #expect(outcome.saved)
        #expect(outcome.said == "Saved, but the gateway couldn't refresh this chat, so the bot may keep its old personality for now.")
    }

    @Test func aGatewayThatCannotChangeBotsStillShowsWhoTheyAre() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-edits")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await roster.personality(of: garden) != nil)
        #expect(await roster.update(garden, soul: "Talk like a seed catalogue.").value == .init(saved: false, said: "This gateway doesn't let this app change bots."))
        #expect(roster.cannotEditBots)
    }

    @Test func usageIsKnownOnceTheChatIsOpenAndHasBeenAnswered() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        // Not open on the gateway yet, and opening it only to ask would start the bot.
        #expect(await roster.usage(of: main) == nil)
        let chat = roster.chat(for: main)
        await chat.load(main, from: roster)
        chat.draft = "quick hello"
        chat.send(to: main, through: roster)
        let deadline = Date.now.addingTimeInterval(20)
        while chat.isWorking {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        let usage = try #require(await roster.usage(of: main))
        #expect(usage.contextMax == 200_000)
        #expect(usage.contextUsed == 68_000)
        #expect(usage.contextFraction == 0.34)
        #expect((usage.tokens ?? 0) > 61_000)
        #expect(DetailsPanel.count(68_000) == 68_000.formatted(.number.notation(.compactName)))
    }

    @Test func usageIsReadByTheSessionAuthoritysOwnName() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "authority")
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        let chat = roster.chat(for: main)
        await chat.load(main, from: roster)
        chat.draft = "quick hello"
        chat.send(to: main, through: roster)
        try await answered(chat)
        let usage = try #require(await roster.usage(of: main))
        #expect(usage.contextUsed == 68_000)
        #expect(usage.contextMax == 200_000)
        #expect((usage.tokens ?? 0) > 61_000)
    }

    @Test func aGatewayThatCannotTellUsageLeavesItOut() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-usage")
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        let chat = roster.chat(for: main)
        await chat.load(main, from: roster)
        chat.draft = "quick hello"
        chat.send(to: main, through: roster)
        let deadline = Date.now.addingTimeInterval(20)
        while chat.isWorking {
            try #require(Date.now < deadline)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await roster.usage(of: main) == nil)
    }

    @Test func aBotsRoutinesAreListed() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        let routines = try #require(await roster.routines(of: main))
        #expect(routines.map(\.name) == ["Morning brief", "Inbox sweep", "Friday wrap-up"])
        #expect(routines.map(\.isEnabled) == [true, true, false])
        let books = try #require(roster.bots.first { $0.name == "books" })
        #expect(await roster.routines(of: books) == [])
    }

    @Test func deletingRemovesTheBotAndMovesOnToTheMainOne() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        roster.selectedID = garden.id
        let before = roster.bots.count

        // Asked twice at once, as a second click might: done once, with no complaint.
        async let twice = roster.delete(garden)
        #expect(await roster.delete(garden) == nil)
        #expect(await twice == nil)
        #expect(roster.bots.count == before - 1)
        #expect(!roster.bots.contains { $0.name == "garden" })
        #expect(roster.selected?.isDefault == true)
        // Gone for the next launch too.
        #expect(!(await open(pretend)).bots.contains { $0.name == "garden" })
    }

    @Test func aGatewayThatCannotChangeOrDeleteBotsStopsBeingAsked() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "no-edits")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(!roster.cannotEditBots)
        #expect(!roster.cannotDeleteBots)

        #expect(await roster.update(garden, title: "Allotment") == "This gateway doesn't keep names and faces from this app.")
        #expect(roster.cannotEditBots)
        #expect(roster.bots.first { $0.name == "garden" }?.title == garden.title)
        #expect(await roster.delete(garden) != nil)
        #expect(roster.cannotDeleteBots)
        #expect(roster.bots.contains { $0.name == "garden" })
    }

    @Test func aBotTheGatewayTookAwayIsGoneEvenIfClearingUpFailed() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "untidy-delete")
        let roster = await open(pretend)
        let garden = try #require(roster.bots.first { $0.name == "garden" })
        #expect(await roster.delete(garden) == nil)
        #expect(!roster.bots.contains { $0.name == "garden" })
    }

    @Test func aRefusedDeleteSaysWhyInALine() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        // Asked of the gateway directly, as nothing in the app would: the main bot stays.
        #expect(RosterModel.gist(of: "Profile: x\nPath: y\n\nError: Could not remove it.\n\ninstall out of sync") == "Could not remove it.")
        #expect(RosterModel.gist(of: "No such profile\n") == "No such profile")
        #expect(RosterModel.gist(of: "") == "")
        #expect(roster.bots.contains { $0.id == main.id })
    }

    @Test func theMainBotIsNeverDeleted() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = await open(pretend)
        let main = try #require(roster.mainBot)
        #expect(await roster.delete(main) == "The main bot can't be deleted.")
        #expect(roster.mainBot != nil)
        #expect((await open(pretend)).mainBot != nil)
    }
}
