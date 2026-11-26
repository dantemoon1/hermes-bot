import HermesBotUI
import HermesKit
import SwiftUI

/// Finding words in the chat showing: only what has been read in and is on screen. The
/// gateway has no way to search a chat, so nothing older than that is looked through.
enum ChatFind {
    /// One place the words were found: in which message, which block of it, which cell
    /// of a table if it is one, and which of the finds in that text.
    struct Match: Equatable, Hashable {
        let item: TranscriptItem.ID
        let block: Int
        var cell: Int?
        let index: Int
    }

    /// The words as typed, less space at either end. Nothing to find when that is empty.
    static func needle(_ query: String) -> String? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? nil : needle
    }

    /// Where the words are in a text, in order and not overlapping. Capitals and accents
    /// make no difference.
    static func ranges(of query: String, in text: AttributedString) -> [Range<AttributedString.Index>] {
        guard let needle = needle(query) else { return [] }
        var found: [Range<AttributedString.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let range = text[from...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            guard !range.isEmpty else { break }
            found.append(range)
            from = range.upperBound
        }
        return found
    }

    /// Every find in the chat, from the top down: message by message, block by block,
    /// cell by cell. Pictures, files, pages and rules have no words to find.
    static func matches(of query: String, in messages: [(id: TranscriptItem.ID, blocks: [StyledBlock])]) -> [Match] {
        guard needle(query) != nil else { return [] }
        var found: [Match] = []
        for message in messages {
            for block in message.blocks {
                switch block.kind {
                case .paragraph, .heading, .item, .code, .quote:
                    found += ranges(of: query, in: block.text).indices.map { Match(item: message.id, block: block.id, index: $0) }
                case .table:
                    for (cell, text) in block.cells.joined().enumerated() {
                        found += ranges(of: query, in: text).indices.map { Match(item: message.id, block: block.id, cell: cell, index: $0) }
                    }
                case .rule, .file, .page:
                    break
                }
            }
        }
        return found
    }

    /// The finds in a text marked: each with a quiet grey behind it, and the one gone to
    /// with the colour of a selection.
    static func marked(_ text: AttributedString, query: String, current: Int?, theme: Theme) -> AttributedString {
        var text = text
        for (index, range) in ranges(of: query, in: text).enumerated() {
            text[range].backgroundColor = index == current ? theme.findCurrent : theme.findMatch
        }
        return text
    }

    /// A message's blocks with the finds in them marked. The same blocks when nothing is
    /// being looked for.
    static func marked(_ blocks: [StyledBlock], in item: TranscriptItem.ID, query: String, current: Match?, theme: Theme) -> [StyledBlock] {
        guard needle(query) != nil else { return blocks }
        return blocks.map { block in
            var block = block
            let here = current.flatMap { $0.item == item && $0.block == block.id ? $0 : nil }
            switch block.kind {
            case .table:
                var at = 0
                block.cells = block.cells.map { row in
                    row.map { cell in
                        defer { at += 1 }
                        return marked(cell, query: query, current: here?.cell == at ? here?.index : nil, theme: theme)
                    }
                }
            case .rule, .file, .page:
                break
            default:
                block.text = marked(block.text, query: query, current: here?.cell == nil ? here?.index : nil, theme: theme)
            }
            return block
        }
    }

    /// The find a step on from the one gone to, going round at the ends. The first, with
    /// none gone to yet.
    static func step(_ by: Int, from current: Match?, in all: [Match]) -> Match? {
        guard !all.isEmpty else { return nil }
        guard let current, let at = all.firstIndex(of: current) else { return by < 0 ? all.last : all.first }
        return all[(at + by + all.count) % all.count]
    }
}

/// The field for finding words in the chat: a small pill floating over the chat's top
/// corner, as the bot's name floats over its middle.
struct FindBar: View {
    static let width: CGFloat = 280

    @Binding var query: String
    let count: Int
    /// Which of the finds is gone to, counting from the top. Nil with none.
    let place: Int?
    /// Asks to find, so ⌘F with the field open puts the caret back in it.
    let asks: Int
    /// A step through the finds: up the chat (-1) or down it (1).
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isCovered) private var isCovered

    var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            TextField("Find in Chat", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .focused($isFocused)
                // Return goes up the chat, to older finds, as the chat is read from its end;
                // Shift-Return comes back down.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers == .shift { step(1) } else if press.modifiers.isEmpty { step(-1) } else { return .ignored }
                    return .handled
                }
                .onExitCommand(perform: close)
                .accessibilityLabel("Find in chat")
            if ChatFind.needle(query) != nil {
                // Only what is on screen is looked through, and that is what is counted.
                Text(count == 0 ? "None" : "\((place ?? 0) + 1) of \(count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize()
                    .help("Looks through the messages on screen")
                button("chevron.up", "Previous", theme) { step(-1) }
                    .disabled(count == 0)
                button("chevron.down", "Next", theme) { step(1) }
                    .disabled(count == 0)
            }
            button("xmark", "Close", theme, action: close)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(width: Self.width, height: 38)
        .background(theme.control, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.hairline))
        .shadow(color: theme.floatShadow, radius: 6, y: 2)
        // Under a panel it takes no keys, as the composer takes none.
        .disabled(isCovered)
        .onAppear { isFocused = true }
        .onChange(of: asks) { isFocused = true }
    }

    private func button(_ symbol: String, _ label: String, _ theme: Theme, action: @escaping () -> Void) -> some View {
        WhenHovered { isHovered in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(theme.hover.opacity(isHovered ? 1 : 0), in: Circle())
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        // The caret stays in the field.
        .focusable(false)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// How large the chat's words are shown: ⌘+, ⌘− and ⌘0. Kept on this Mac only.
enum TextZoom {
    static let key = "chatTextZoom"
    static let steps: [Double] = [0.85, 1, 1.15, 1.3, 1.5, 1.75]

    /// One of the steps, whatever was kept.
    static func clamped(_ zoom: Double) -> CGFloat {
        CGFloat(steps.min { abs($0 - zoom) < abs($1 - zoom) } ?? 1)
    }

    /// The next step larger (1) or smaller (-1), staying at the ends.
    static func step(_ by: Int, from zoom: Double) -> Double {
        let at = steps.firstIndex(of: Double(clamped(zoom))) ?? 1
        return steps[min(max(at + by, 0), steps.count - 1)]
    }
}
