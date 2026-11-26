import HermesBotUI
import HermesKit
import SwiftUI
import Testing
@testable import HermesBot

/// Going between bots by the keyboard, finding words in a chat, and the chat's text size.
@MainActor
struct ShortcutTests {
    private let order = ["default", "garden", "cafe", "tools"]

    @Test func aPlaceInTheRosterIsABotCountingTheMainBotFirst() {
        #expect(BotOrder.bot(at: 1, in: order) == "default")
        #expect(BotOrder.bot(at: 4, in: order) == "tools")
        #expect(BotOrder.bot(at: 5, in: order) == nil)
        #expect(BotOrder.bot(at: 0, in: order) == nil)
    }

    @Test func previousAndNextStopAtTheEnds() {
        #expect(BotOrder.step(1, from: "default", in: order) == "garden")
        #expect(BotOrder.step(-1, from: "garden", in: order) == "default")
        #expect(BotOrder.step(-1, from: "default", in: order) == nil)
        #expect(BotOrder.step(1, from: "tools", in: order) == nil)
        // With none showing, or one that has gone, the first.
        #expect(BotOrder.step(1, from: nil, in: order) == "default")
        #expect(BotOrder.step(1, from: "gone", in: order) == "default")
        #expect(BotOrder.step(1, from: nil, in: []) == nil)
    }

    @Test func viewUnreadGoesToTheNextUnreadGoingRound() {
        #expect(BotOrder.nextUnread(after: "cafe", in: order, unread: ["garden", "tools"]) == "tools")
        #expect(BotOrder.nextUnread(after: "tools", in: order, unread: ["garden", "tools"]) == "garden")
        // The one showing is not gone to again.
        #expect(BotOrder.nextUnread(after: "garden", in: order, unread: ["garden"]) == nil)
        #expect(BotOrder.nextUnread(after: nil, in: order, unread: ["cafe"]) == "cafe")
        #expect(BotOrder.nextUnread(after: nil, in: [], unread: ["cafe"]) == nil)
    }

    @Test func backAndForwardGoThroughTheBotsViewed() {
        var history = BotHistory()
        let all: Set = ["a", "b", "c"]
        // a, then b, then c.
        history.left("a")
        history.left("b")
        #expect(history.goForward(from: "c", among: all) == nil)
        #expect(history.goBack(from: "c", among: all) == "b")
        #expect(history.goBack(from: "b", among: all) == "a")
        #expect(history.goBack(from: "a", among: all) == nil)
        #expect(history.goForward(from: "a", among: all) == "b")
        // Choosing another bot from here drops what was ahead.
        history.left("b")
        #expect(history.goForward(from: "a", among: all) == nil)
        #expect(history.goBack(from: "a", among: all) == "b")
    }

    @Test func aBotNoLongerThereIsPassedOver() {
        var history = BotHistory()
        history.left("a")
        history.left("gone")
        #expect(history.goBack(from: "c", among: ["a", "c"]) == "a")
        #expect(history.goBack(from: "a", among: ["gone"]) == nil)
    }

    /// Find reads a stored message as its bubble shows it: what was attached for the bot
    /// is not looked through.
    @Test func findReadsASentMessageAsItsBubbleShowsIt() {
        let stored = "see this @file:attachments/notes.txt\n\n--- Attached Context ---\n\n📄 @file:attachments/notes.txt (3 tokens)\n```\nsecret words\n```\n@image:/tmp/a.png\n[screenshot]"
        let chat = ChatModel()
        let blocks = ChatView.shownBlocks(of: .user(id: 4, text: stored), in: chat) ?? []
        let words = blocks.map { String($0.text.characters) }.joined()
        #expect(!words.contains("secret"))
        #expect(!words.contains("@image"))
        #expect(ChatFind.matches(of: "secret", in: [("user-4", blocks)]).isEmpty)
        #expect(ChatView.shownBlocks(of: .date(.now), in: chat) == nil)
    }

    private func block(_ id: Int, _ kind: ReplyBlock.Kind, _ text: String) -> StyledBlock {
        StyledBlock(id: id, kind: kind, raw: text, text: AttributedString(text))
    }

    @Test func findLooksThroughEveryBlockWithWordsInOrder() {
        var table = block(2, .table, "")
        table.cells = [[AttributedString("Café"), AttributedString("x")], [AttributedString("cafe au lait"), AttributedString("CAFE")]]
        let messages: [(id: TranscriptItem.ID, blocks: [StyledBlock])] = [
            ("user-1", [block(0, .paragraph, "Where's the café?")]),
            ("bot-2", [block(0, .heading(2), "Cafés"), block(1, .code, "cafe --open"), table, block(3, .file, "/tmp/cafe.png"), block(4, .quote, "cafe, cafe")]),
        ]
        let found = ChatFind.matches(of: " CAFE ", in: messages)
        typealias M = ChatFind.Match
        let expected: [M] = [
            M(item: "user-1", block: 0, index: 0),
            M(item: "bot-2", block: 0, index: 0),
            M(item: "bot-2", block: 1, index: 0),
            M(item: "bot-2", block: 2, cell: 0, index: 0),
            M(item: "bot-2", block: 2, cell: 2, index: 0),
            M(item: "bot-2", block: 2, cell: 3, index: 0),
            M(item: "bot-2", block: 4, index: 0),
            M(item: "bot-2", block: 4, index: 1),
        ]
        #expect(found == expected)
        #expect(ChatFind.matches(of: "   ", in: messages).isEmpty)
        #expect(ChatFind.matches(of: "tea", in: messages).isEmpty)
    }

    @Test func findsDoNotOverlapAndAreMarkedTheOneGoneToApart() {
        let theme = Theme(.dark)
        #expect(ChatFind.ranges(of: "aa", in: AttributedString("aaaaa")).count == 2)
        let marked = ChatFind.marked(AttributedString("one two one"), query: "one", current: 1, theme: theme)
        let behind = marked.runs.map(\.backgroundColor)
        #expect(behind == [theme.findMatch, nil, theme.findCurrent])
        // Carried into the text a reply's paragraphs are shown in.
        let flowing = ChatView.flowing([StyledBlock(id: 0, kind: .paragraph, raw: "", text: marked)], theme)
        #expect(flowing.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
        #expect(flowing.attribute(.backgroundColor, at: 4, effectiveRange: nil) == nil)
    }

    @Test func returnStepsThroughTheFindsGoingRound() {
        let all = [ChatFind.Match(item: "a", block: 0, index: 0), .init(item: "b", block: 0, index: 0), .init(item: "b", block: 0, index: 1)]
        #expect(ChatFind.step(-1, from: all[1], in: all) == all[0])
        #expect(ChatFind.step(-1, from: all[0], in: all) == all[2])
        #expect(ChatFind.step(1, from: all[2], in: all) == all[0])
        #expect(ChatFind.step(-1, from: nil, in: all) == all[2])
        #expect(ChatFind.step(1, from: nil, in: []) == nil)
    }

    @Test func zoomGoesByStepsAndStopsAtTheEnds() {
        #expect(TextZoom.step(1, from: 1) == 1.15)
        #expect(TextZoom.step(-1, from: 1) == 0.85)
        #expect(TextZoom.step(-1, from: 0.85) == 0.85)
        #expect(TextZoom.step(1, from: 1.75) == 1.75)
        // Whatever was kept, one of the steps.
        #expect(TextZoom.clamped(9) == 1.75)
        #expect(TextZoom.step(1, from: 1.2) == 1.3)
        // The text of a reply is set at the size asked for.
        let text = ChatView.flowing([block(0, .paragraph, "Hi")], Theme(.light), zoom: 1.5)
        #expect((text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 21)
    }

    @Test func theShortcutsListedAreTheOnesTheAppHas() {
        let titles = (ShortcutList.left + ShortcutList.right).flatMap(\.shortcuts).map(\.title)
        // Nothing the reference has and this app does not: voice, skills, connected apps.
        for absent in ["Dictate", "Skills", "Connect apps", "Switch Bots", "Add selection to chat"] {
            #expect(!titles.contains(absent))
        }
        #expect(titles.contains("Find in chat"))
    }
}
