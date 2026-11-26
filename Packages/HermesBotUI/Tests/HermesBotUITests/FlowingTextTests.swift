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
}
#endif
