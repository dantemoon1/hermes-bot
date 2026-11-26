import HermesBotUI
import SwiftUI

/// The menu above the message box while a slash command is being typed, in the look of the
/// reference's @-mention menu: a floating card of rows, grouped, the chosen one lit.
struct SlashMenu: View {
    let commands: [SlashCommand]
    let lit: SlashCommand?
    /// Counts asks to bring the lit row into sight: from the keys, not the pointer, under
    /// which a row half in sight would jump.
    let scrollAsks: Int
    let choose: (SlashCommand) -> Void
    let light: (SlashCommand) -> Void
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 400
    private static let rowHeight: CGFloat = 46
    private static let headingHeight: CGFloat = 26

    var body: some View {
        let theme = Theme(scheme)
        let groups = SlashCommand.Group.allCases.compactMap { group -> (SlashCommand.Group, [SlashCommand])? in
            let rows = commands.filter { $0.group == group }
            return rows.isEmpty ? nil : (group, rows)
        }
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { group, rows in
                        Text(group.rawValue)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.leading, 10)
                            .padding(.bottom, 4)
                            .frame(height: Self.headingHeight, alignment: .bottomLeading)
                        ForEach(rows) { row($0, isLit: $0 == lit, theme) }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: scrollAsks) { if let lit { scroller.scrollTo(lit.id) } }
        }
        .frame(width: Self.width, height: Self.height(for: commands))
        .background(theme.control, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.hairline))
        .compositingGroup()
        .shadow(color: theme.floatShadow, radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }

    /// As tall as its rows, up to a height that leaves the chat in sight; then it scrolls,
    /// cut through the middle of a row so that it plainly goes on.
    static func height(for commands: [SlashCommand]) -> CGFloat {
        let groups = Set(commands.map(\.group)).count
        return min(CGFloat(commands.count) * rowHeight + CGFloat(groups) * headingHeight + 12, 358)
    }

    private func row(_ command: SlashCommand, isLit: Bool, _ theme: Theme) -> some View {
        Button { choose(command) } label: {
            HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("/\(command.name)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(theme.text)
                    if !command.hint.isEmpty {
                        Text(command.hint)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(command.about)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // As the approved mock-up has it: Tab takes the lit one.
            if isLit {
                Text("Tab")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
            .background(theme.chosen.opacity(isLit ? 1 : 0), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        // The caret stays in the message box, so typing and the arrow keys go on working.
        .focusable(false)
        // The pointer lights a row as the arrow keys do, so only one is ever lit.
        .onHover { if $0 { light(command) } }
        .id(command.id)
        .accessibilityLabel("/\(command.name), \(command.about)")
        .accessibilityAddTraits(isLit ? .isSelected : [])
    }
}

/// What a slash command left in the chat: a centred grey line for a change, a quiet card
/// for something to read, and a card with a dashed edge for an answer on the side, so it
/// is never taken for part of the chat. Here in this window only.
struct NoteView: View {
    let note: ChatNote
    let bot: String
    let dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        switch note.kind {
        case .line:
            Text(note.text ?? "\(note.asked)…")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        case .readout:
            card(theme, dashed: false, title: note.asked, subtitle: bot) {
                Text(note.text ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .aside(let question):
            card(theme, dashed: true, title: "/btw", subtitle: "Side answer") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(question)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    theme.hairline.frame(height: 1)
                    Text(note.text.map(Self.inline) ?? AttributedString("Thinking…"))
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(note.text == nil ? theme.secondaryText : theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Not part of the chat")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private func card(_ theme: Theme, dashed: Bool, title: String, subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(title.split(separator: " ").first.map(String.init) ?? title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.text)
                Text(" · \(subtitle)")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 8)
                WhenHovered { isHovered in
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                            .frame(width: 22, height: 22)
                            .background(theme.hover.opacity(isHovered ? 1 : 0), in: Circle())
                            .contentShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
            // As far from the right edge as the left: the close button alone sits nearer.
            content()
                .padding(.trailing, 6)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(dashed ? Color.clear : theme.codeBlock, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dashed ? theme.secondaryText.opacity(0.45) : theme.hairline, style: StrokeStyle(lineWidth: 1, dash: dashed ? [4, 3] : []))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
