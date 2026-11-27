#if os(macOS)
import AppKit
import SwiftUI

/// Several paragraphs, headings and list items shown as one piece of text, so that a drag
/// selects across all of them. SwiftUI's own text can only be selected one `Text` at a
/// time, which stops a selection at every paragraph.
public struct FlowingText: NSViewRepresentable {
    private let text: NSAttributedString
    private let grey: NSRange?

    /// `grey` is drawn in grey for a moment: the words that have only just arrived. It is
    /// drawn over the text as it stands, so turning it to full colour lays nothing out again.
    public init(_ text: NSAttributedString, grey: NSRange? = nil) {
        self.text = text
        self.grey = grey
    }

    public func makeNSView(context: Context) -> NSTextView {
        let view = Self.makeView(text)
        context.coordinator.shown = text
        Self.paint(grey, in: view, was: nil)
        context.coordinator.grey = grey
        return view
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
        Self.update(view, to: text, grey: grey, keeping: context.coordinator)
    }

    static func update(_ view: NSTextView, to text: NSAttributedString, grey: NSRange?, keeping coordinator: Measure) {
        var greyWas = coordinator.grey
        var changed = false
        // The same text again, as a redraw of the chat hands over, is not laid out again.
        if let storage = view.textStorage, !coordinator.isShowing(text) {
            // Words arriving at the end leave a selection made earlier where it was.
            let chosen = view.selectedRange()
            Self.replace(storage, was: coordinator.shown, with: text)
            if chosen.length > 0, NSMaxRange(chosen) <= text.length { view.setSelectedRange(chosen) }
            coordinator.shown = text
            // Whatever was painted over the old text comes off all of it, and the grey is
            // painted again even when it is the same range: new text holds none of it.
            greyWas = NSRange(location: 0, length: storage.length)
            changed = true
        }
        if changed || grey != greyWas { Self.paint(grey, in: view, was: greyWas) }
        coordinator.grey = grey
    }

    /// Makes `storage`, which holds `old`, hold `new`. When only the end has changed, as when
    /// words arrive, only the end is replaced, from the start of the paragraph where the two
    /// first differ, so only that much is laid out again.
    static func replace(_ storage: NSTextStorage, was old: NSAttributedString?, with new: NSAttributedString) {
        guard let old, storage.length == old.length, old.length > 0, new.length > 0 else {
            storage.setAttributedString(new)
            return
        }
        let before = old.string as NSString, after = new.string as NSString
        let same = (before.commonPrefix(with: new.string, options: .literal) as NSString).length
        // Paragraph styles belong to whole paragraphs: the one holding the first difference
        // is replaced whole.
        let from = min(before.paragraphRange(for: NSRange(location: min(same, before.length - 1), length: 0)).location,
                       after.paragraphRange(for: NSRange(location: min(same, after.length - 1), length: 0)).location)
        // What is kept must be exactly as it is in the new text, its look included.
        guard from > 0, old.attributedSubstring(from: NSRange(location: 0, length: from))
            .isEqual(to: new.attributedSubstring(from: NSRange(location: 0, length: from))) else {
            storage.setAttributedString(new)
            return
        }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: from, length: before.length - from),
                                  with: new.attributedSubstring(from: NSRange(location: from, length: after.length - from)))
        storage.endEditing()
    }

    /// Paints the newest words grey over the text, or takes the grey off, without laying
    /// anything out again.
    private static func paint(_ grey: NSRange?, in view: NSTextView, was: NSRange?) {
        guard let layout = view.layoutManager, let storage = view.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        if let was { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSIntersectionRange(was, whole)) }
        if let grey {
            let range = NSIntersectionRange(grey, whole)
            if range.length > 0 { layout.addTemporaryAttribute(.foregroundColor, value: NSColor.gray, forCharacterRange: range) }
        }
    }

    /// As wide as its longest line when that fits what is offered, and as tall as its
    /// lines then need.
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let offered = proposal.width.map { $0.isFinite ? $0 : 10_000 } ?? 10_000
        return context.coordinator.size(of: text, within: max(offered, 1))
    }

    public func makeCoordinator() -> Measure { Measure() }

    /// Lays the text out as the view will, to say how much room it takes. Each width's
    /// answer is kept until the text changes: SwiftUI asks the same questions many times
    /// over, at more than one width, on every pass over the chat.
    ///
    /// The text is kept, laid out at each width asked about, so that when it changes only
    /// what changed is laid out again: a reply arriving word by word is not laid out whole
    /// for every few words.
    @MainActor
    public final class Measure {
        /// The text the sizes are for, and the text the view shows.
        private var measured: NSAttributedString?
        private let storage = NSTextStorage()
        private struct Laid {
            let width: CGFloat
            let layout: NSLayoutManager
            let container: NSTextContainer
            var size: CGSize?
        }
        private var laid: [Laid] = []
        var shown: NSAttributedString?
        var grey: NSRange?

        public init() {}

        /// The view already shows this text: the very same, or one equal to it.
        func isShowing(_ text: NSAttributedString) -> Bool {
            guard let shown else { return false }
            if shown === text { return true }
            guard shown.length == text.length, shown.isEqual(to: text) else { return false }
            self.shown = text
            return true
        }

        func size(of text: NSAttributedString, within width: CGFloat) -> CGSize {
            if measured !== text {
                // An equal text, made afresh by a redraw, keeps what was measured.
                if let measured, measured.length == text.length, measured.isEqual(to: text) {} else {
                    FlowingText.replace(storage, was: measured, with: text)
                    for index in laid.indices { laid[index].size = nil }
                }
                measured = text
            }
            let index: Int
            if let found = laid.firstIndex(where: { $0.width == width }) {
                if let size = laid[found].size { return size }
                index = found
            } else {
                // A few widths are asked about; a window resized by hand asks about many.
                if laid.count >= 3 { storage.removeLayoutManager(laid.removeFirst().layout) }
                let layout = NSLayoutManager()
                let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                storage.addLayoutManager(layout)
                laid.append(Laid(width: width, layout: layout, container: container))
                index = laid.count - 1
            }
            let layout = laid[index].layout, container = laid[index].container
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let size = CGSize(width: min(ceil(used.maxX), width), height: ceil(used.height))
            laid[index].size = size
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
