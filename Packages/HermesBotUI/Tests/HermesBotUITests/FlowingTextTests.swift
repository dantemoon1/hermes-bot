#if os(macOS)
import AppKit
import Testing
@testable import HermesBotUI

@MainActor
struct FlowingTextTests {
    /// A long reply is as tall in the bubble as it was measured to be, however little of it
    /// is in sight. Laid out only as far as could be seen, its words ended well short of
    /// the bubble's end and moved as the chat was scrolled.
    @Test func aReplyTallerThanTheWindowIsLaidOutWhole() throws {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacingBefore = 10
        let sentence = "The Moon raises tides in the oceans and in the solid Earth, and friction drags the bulges ahead of it. "
        let words = (0..<40).map { String(repeating: sentence, count: 3 + $0 % 4) + ($0 % 3 == 0 ? "\u{2028}carried on" : "") }.joined(separator: "\n")
        let text = NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: style])
        let measured = FlowingText.Measure().size(of: text, within: 560)
        #expect(measured.height > 3000)

        let view = FlowingText.makeView(text)
        // Asking for the older means below would turn a view to it, so this is asked first.
        #expect(view.textLayoutManager == nil)
        view.frame = NSRect(origin: .zero, size: measured)
        // Only its first 400 points in sight, as in a window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.documentView = view
        window.contentView = scroll
        let layout = try #require(view.layoutManager), container = try #require(view.textContainer)
        #expect(ceil(layout.usedRect(for: container).height) == measured.height)
    }

    /// A reply arriving word by word, or changing in any other way, ends up exactly as the
    /// new text, whether only its end was replaced or the whole of it.
    @Test func replacingTheEndGivesTheNewTextExactly() {
        func text(_ words: String, colour: NSColor = .textColor) -> NSAttributedString {
            NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: colour])
        }
        let first = text("One paragraph.\nAnother that goes")
        let cases = [
            text("One paragraph.\nAnother that goes on and on.\nA third."),   // words added
            text("One paragraph.\nAnother"),                                  // taken back
            text("One paragraph, changed.\nAnother that goes"),               // the first paragraph
            text("One paragraph.\nAnother that goes", colour: .red),           // the same words, another look
            text(""),
        ]
        for new in cases {
            let storage = NSTextStorage(attributedString: first)
            FlowingText.replace(storage, was: first, with: new)
            #expect(storage.isEqual(to: new))
        }
    }

    /// The newest words are painted grey over the text, and painted again when the text
    /// changes, even over the same range: new text holds none of what was painted.
    @Test func theNewestWordsAreGreyAfterEveryChange() throws {
        func text(_ words: String) -> NSAttributedString {
            NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        }
        func isGrey(_ view: NSTextView, at index: Int) -> Bool {
            view.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) != nil
        }
        let measure = FlowingText.Measure()
        let first = text("Su")
        let view = FlowingText.makeView(first)
        measure.shown = first
        FlowingText.update(view, to: first, grey: NSRange(location: 0, length: 2), keeping: measure)
        #expect(isGrey(view, at: 0))
        // The whole of a new text is new: the same kind of range, painted again.
        let second = text("Summary")
        FlowingText.update(view, to: second, grey: NSRange(location: 0, length: 7), keeping: measure)
        #expect(isGrey(view, at: 0) && isGrey(view, at: 6))
        // More words: only they are grey.
        let third = text("Summary.\nMore words")
        FlowingText.update(view, to: third, grey: NSRange(location: 9, length: 10), keeping: measure)
        #expect(!isGrey(view, at: 0) && isGrey(view, at: 12))
        // Turned to full colour.
        FlowingText.update(view, to: third, grey: nil, keeping: measure)
        #expect(!isGrey(view, at: 12))
    }

    /// Measuring a text that grows gives what measuring it afresh gives.
    @Test func aGrowingTextIsMeasuredAsAFreshOne() {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 10
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .paragraphStyle: style]
        let measure = FlowingText.Measure()
        var words = "The first paragraph of a reply."
        for step in 0..<30 {
            words += step % 5 == 4 ? "\nA new paragraph begins" : " and more words arrive"
            let text = NSAttributedString(string: words, attributes: attributes)
            #expect(measure.size(of: text, within: 300) == FlowingText.Measure().size(of: text, within: 300))
            #expect(measure.size(of: text, within: 560) == FlowingText.Measure().size(of: text, within: 560))
        }
    }
}
#endif
