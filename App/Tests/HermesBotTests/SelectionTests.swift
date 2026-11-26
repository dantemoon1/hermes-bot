import AppKit
import HermesBotUI
import SwiftUI
import Testing
@testable import HermesBot

/// A reply's paragraphs, headings and list items are one piece of text, so that a drag
/// selects across them.
@MainActor
struct SelectionTests {
    private func block(_ id: Int, _ kind: ReplyBlock.Kind, _ text: String) -> StyledBlock {
        StyledBlock(id: id, kind: kind, raw: text, text: AttributedString(text))
    }

    @Test func whatFollowsOnIsOnePieceAndWhatStandsApartIsItsOwn() {
        let blocks = [
            block(0, .heading(2), "Plan"), block(1, .paragraph, "First."), block(2, .item(marker: "1.", depth: 0), "One"),
            block(3, .code, "ls"), block(4, .paragraph, "After."), block(5, .quote, "Said"), block(6, .rule, ""),
            block(7, .item(marker: "•", depth: 1), "Last"),
        ]
        let stretches = ChatView.stretches(of: blocks)
        #expect(stretches.map { $0.blocks.map(\.id) } == [[0, 1, 2], [3], [4], [5], [6], [7]])
        #expect(stretches.map(\.flows) == [true, false, true, false, false, true])
        // Named by its first block, so the view for it is kept as words arrive at its end.
        #expect(stretches.map(\.id) == [0, 3, 4, 5, 6, 7])
        #expect(ChatView.stretches(of: []).isEmpty)
    }

    @Test func onePieceHoldsEveryBlocksWordsInOrderWithItsMarkers() {
        var bold = AttributedString("castle")
        bold.inlinePresentationIntent = .stronglyEmphasized
        let blocks = [
            block(0, .heading(1), "Lisbon"),
            StyledBlock(id: 1, kind: .paragraph, raw: "", text: AttributedString("Go to the ") + bold + AttributedString(".")),
            block(2, .item(marker: "2.", depth: 1), "Walk up"),
        ]
        let text = ChatView.flowing(blocks, Theme(.dark))
        #expect(text.string == "Lisbon\nGo to the castle.\n\t2.\tWalk up")
        // The heading is larger and heavier; the word marked strong is bold; the item hangs.
        let heading = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(heading?.pointSize == 18)
        let strong = text.attribute(.font, at: (text.string as NSString).range(of: "castle").location, effectiveRange: nil) as? NSFont
        #expect(strong?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let item = text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil) as? NSParagraphStyle
        #expect((item?.headIndent ?? 0) > 19)
        #expect(item?.paragraphSpacingBefore == 10)
    }

    /// A list item that runs on to a second line of its own keeps its indent there: the
    /// break stays inside the item's paragraph and does not begin a new one at the edge.
    @Test func aLineBreakInsideAnItemDoesNotBeginANewParagraph() {
        let text = ChatView.flowing([block(0, .item(marker: "•", depth: 1), "First line\ncontinuation"), block(1, .paragraph, "After")], Theme(.dark))
        #expect(text.string == "\t•\tFirst line\u{2028}continuation\nAfter")
        // One paragraph for the item, by the count of paragraph breaks.
        #expect(text.string.components(separatedBy: "\n").count == 2)
        let at = (text.string as NSString).range(of: "continuation").location
        let style = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) > 19)
    }
}
