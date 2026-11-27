import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// A long chat shows its latest page and reads older ones in when asked, and a reply
/// arriving fast is shown a few dozen times a second, against the pretend gateway's "long"
/// mode (the main bot's chat holds 500 messages).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LongChatTests {
    /// The person's messages shown, oldest first: in the pretend long chat, every other row.
    private func asked(_ chat: ChatModel) -> [Int] {
        chat.items.compactMap { if case .user(let id, _) = $0 { id } else { nil } }
    }

    @Test func aLongChatOpensOnItsLatestPageAndReadsOlderOnesAbove() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "long")
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let main = try #require(roster.bots.first { $0.name == "default" })
        let chat = roster.chat(for: main)
        await chat.load(main, from: roster)
        // The latest 50 of 500 rows, half of them the person's, ending with the newest.
        #expect(asked(chat).count == ChatModel.pageSize / 2)
        #expect(asked(chat).last == 499)
        #expect(chat.hasOlder && chat.canLoadOlder)

        let firstShown = try #require(asked(chat).first)
        await chat.loadOlder(main, from: roster)
        #expect(chat.window == 2 * ChatModel.pageSize)
        #expect(asked(chat).count == ChatModel.pageSize)
        // Above what was shown, which is all still there.
        #expect(asked(chat).contains(firstShown))
        #expect(try #require(asked(chat).first) < firstShown)
        #expect(asked(chat).last == 499)
        #expect(!chat.isLoadingOlder)

        // Opened again, it is back to its latest page.
        chat.showLatest()
        await chat.load(main, from: roster)
        #expect(asked(chat).count == ChatModel.pageSize / 2)
        #expect(asked(chat).first == firstShown)
    }

    /// Older replies read in above are not new: the pages and files they name are not let
    /// go and read again, as they are for a reply the bot has just written.
    @Test func olderRowsReadInAreNotNewReplies() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "long")
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let main = try #require(roster.bots.first { $0.name == "default" })
        let chat = roster.chat(for: main)
        await chat.load(main, from: roster)
        // The second and third pages hold a reply with the pretend chart page.
        await chat.loadOlder(main, from: roster)
        await chat.loadOlder(main, from: roster)
        #expect(chat.olderShown == 2)
        #expect(chat.items.contains { if case .bot(_, let text) = $0 { text.contains("::preview") } else { false } })
        #expect(chat.rereads.isEmpty)
    }

    /// A read of the chat asked for while a page of older rows is being read (as when the
    /// chat moves on on another device) waits for it, and does not take the page away.
    @Test func aReadAskedForMeanwhileWaitsForTheOlderPage() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "long")
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let main = try #require(roster.bots.first { $0.name == "default" })
        let chat = roster.chat(for: main)
        await chat.load(main, from: roster)
        async let older = chat.loadOlder(main, from: roster)
        await Task.yield()
        #expect(chat.isLoadingOlder)
        await chat.load(main, from: roster)
        #expect(await older)
        #expect(chat.window == 2 * ChatModel.pageSize)
        #expect(asked(chat).count == ChatModel.pageSize)
        #expect(chat.olderShown == 1)
        // Nothing is left waiting: a read asked for now is made at once.
        #expect(!chat.isLoadingOlder)
        let before = chat.shows
        await chat.load(main, from: roster)
        #expect(chat.shows == before + 1)
    }

    @Test func aShortChatHasNothingOlderToRead() async throws {
        let pretend = try await SendingTests.Pretend(whenBusy: "long")
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let trips = try #require(roster.bots.first { $0.name == "trips" })
        let chat = roster.chat(for: trips)
        await chat.load(trips, from: roster)
        #expect(!chat.hasOlder && !chat.canLoadOlder)
        await chat.loadOlder(trips, from: roster)
        #expect(chat.window == ChatModel.pageSize)
    }

    /// Only more words at the end of what the bot is saying may wait for the next showing;
    /// anything else is shown at once.
    @Test func onlyMoreWordsWaitToBeShown() {
        var before = LiveTurn()
        before.apply(.started)
        before.apply(.text("Hello"))
        var more = before
        more.apply(.text(" there"))
        #expect(ChatModel.onlyWordsAdded(from: before, to: more))
        #expect(!ChatModel.onlyWordsAdded(from: more, to: more))

        var tool = more
        tool.apply(.tool("notes"))
        #expect(!ChatModel.onlyWordsAdded(from: more, to: tool))
        var done = more
        done.apply(.finished(reply: nil, outcome: .complete))
        #expect(!ChatModel.onlyWordsAdded(from: more, to: done))
        var after = tool
        after.apply(.text("Done."))
        #expect(!ChatModel.onlyWordsAdded(from: tool, to: after))
    }
}
