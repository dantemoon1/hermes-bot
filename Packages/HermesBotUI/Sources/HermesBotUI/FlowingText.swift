#if os(macOS)
import AppKit
import SwiftUI

/// Several paragraphs, headings and list items shown as one piece of text, so that a drag
/// selects across all of them. SwiftUI's own text can only be selected one `Text` at a
/// time, which stops a selection at every paragraph.
public struct FlowingText: NSViewRepresentable {
    private let text: NSAttributedString

    public init(_ text: NSAttributedString) {
        self.text = text
    }

    public func makeNSView(context: Context) -> NSTextView {
        Self.makeView(text)
    }

    static func makeView(_ text: NSAttributedString) -> NSTextView {
        // Laid out whole, by the same means as `Measure` below. The newer means a text
        // view uses unless told lays out only what is in sight and guesses at the rest,
        // so in a reply taller than the window the words moved up and down inside the
        // bubble as it was scrolled, leaving a gap under them.
        let view = Unscrolled(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.isRichText = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A link keeps the colour it was given and gets the pointing hand.
        view.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        view.textStorage?.setAttributedString(text)
        return view
    }

    public func updateNSView(_ view: NSTextView, context: Context) {
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        // Words arriving at the end leave a selection made earlier where it was.
        let chosen = view.selectedRange()
        storage.setAttributedString(text)
        if chosen.length > 0, NSMaxRange(chosen) <= text.length { view.setSelectedRange(chosen) }
    }

    /// As wide as its longest line when that fits what is offered, and as tall as its
    /// lines then need.
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let offered = proposal.width.map { $0.isFinite ? $0 : 10_000 } ?? 10_000
        return context.coordinator.size(of: text, within: max(offered, 1))
    }

    public func makeCoordinator() -> Measure { Measure() }

    /// Lays the text out as the view will, to say how much room it takes. The last answer
    /// is kept: SwiftUI asks the same question many times over.
    @MainActor
    public final class Measure {
        private var last: (text: NSAttributedString, width: CGFloat, size: CGSize)?

        func size(of text: NSAttributedString, within width: CGFloat) -> CGSize {
            if let last, last.width == width, last.text.isEqual(to: text) { return last.size }
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let size = CGSize(width: min(ceil(used.maxX), width), height: ceil(used.height))
            last = (text, width, size)
            return size
        }
    }

    /// A text view that leaves scrolling to the chat it sits in.
    private final class Unscrolled: NSTextView {
        override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
#endif
