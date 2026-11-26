import HermesBotUI
import SwiftUI

/// Every keyboard shortcut the app has, grouped, in two columns: ⌘/ and Help → Keyboard
/// Shortcuts, as in the reference. Only shortcuts that do something here are listed.
enum ShortcutList {
    struct Shortcut: Identifiable {
        let title: String
        /// A word after the title, quieter: how to do something nearby.
        var hint: String?
        /// One or more ways to do it, each a run of keys.
        let keys: [[String]]
        /// What goes between the ways: "or" for two ways to do one thing, "/" for a pair of
        /// opposites.
        var joiner = "/"
        var id: String { title }
    }

    struct Group: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    static let left = [
        Group(title: "Essentials", shortcuts: [
            Shortcut(title: "Search", keys: [["⌘", "K"], ["⇧", "⌘", "F"]], joiner: "or"),
            Shortcut(title: "New Bot", keys: [["⌘", "N"]]),
            Shortcut(title: "Send", hint: "⇧↵ for new line", keys: [["↵"]]),
            Shortcut(title: "Go to Bot", keys: [["⌘", "1–9"]]),
            Shortcut(title: "Compact sidebar", keys: [["⌘", "B"]]),
            Shortcut(title: "Settings", keys: [["⌘", ","]]),
            Shortcut(title: "Keyboard shortcuts", keys: [["⌘", "/"]]),
        ]),
        Group(title: "Chat", shortcuts: [
            Shortcut(title: "Focus chat", keys: [["⌘", "I"]]),
            Shortcut(title: "Find in chat", keys: [["⌘", "F"]]),
            Shortcut(title: "Allow once", keys: [["⇧", "⌘", "A"]]),
            Shortcut(title: "Deny", keys: [["⇧", "⌘", "D"]]),
        ]),
    ]

    static let right = [
        Group(title: "Navigation", shortcuts: [
            Shortcut(title: "Previous / next Bot", keys: [["⌥", "↑"], ["⌥", "↓"]]),
            Shortcut(title: "Back / forward", keys: [["⌘", "["], ["⌘", "]"]]),
        ]),
        Group(title: "Panels", shortcuts: [
            Shortcut(title: "Details", keys: [["⇧", "⌘", "I"]]),
        ]),
        Group(title: "Window", shortcuts: [
            Shortcut(title: "Zoom", keys: [["⌘", "+"], ["⌘", "−"], ["⌘", "0"]]),
            Shortcut(title: "Full screen", keys: [["⌃", "⌘", "F"]]),
        ]),
    ]
}

struct ShortcutsView: View {
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.text)
                Spacer()
                WhenHovered { isHovered in
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(theme.hover.opacity(isHovered ? 1 : 0), in: Circle())
                            .contentShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(.bottom, 10)

            HStack(alignment: .top, spacing: 40) {
                column(ShortcutList.left, theme)
                column(ShortcutList.right, theme)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: 760)
        .background(theme.control, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.hairline))
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        .padding(24)
    }

    private func column(_ groups: [ShortcutList.Group], _ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.bottom, 4)
                    ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                        if index > 0 { theme.hairline.frame(height: 1) }
                        row(shortcut, theme)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ shortcut: ShortcutList.Shortcut, _ theme: Theme) -> some View {
        HStack(spacing: 8) {
            Text(shortcut.title)
                .font(.system(size: 14))
                .foregroundStyle(theme.text)
            if let hint = shortcut.hint {
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { index, keys in
                    if index > 0 {
                        Text(shortcut.joiner)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 2)
                    }
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .frame(minWidth: 20, minHeight: 20)
                            .padding(.horizontal, key.count > 1 ? 4 : 0)
                            .background(theme.hover, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
        .frame(height: 34)
    }
}
