import HermesBotUI
import HermesKit
import SwiftUI

struct RosterView: View {
    let roster: RosterModel
    let openSettings: () -> Void
    let newBot: () -> Void
    let search: () -> Void
    let rename: (Bot) -> Void
    let delete: (Bot) -> Void
    /// Shown as a rail of faces only (⌘B).
    var isCompact = false
    var toggleCompact: () -> Void = {}
    /// Says what change from a row's menu did not stay, and why.
    var report: (_ what: String, _ why: String) -> Void = { _, _ in }
    @Environment(\.colorScheme) private var scheme

    /// How wide the roster is, open and as a rail. The rail's width is the reference's.
    static let width: CGFloat = 264
    static let compactWidth: CGFloat = 88

    var body: some View {
        if isCompact { rail(Theme(scheme)) } else { full(Theme(scheme)) }
    }

    /// A bot's menu, as the reference's: Pin, Mark as Unread, Rename Bot, Delete. The main
    /// bot is already at the top and can't be deleted, so it has neither.
    @ViewBuilder
    private func menu(for bot: Bot) -> some View {
        if !roster.cannotEditBots {
            if !bot.isDefault {
                let pinned = roster.isPinned(bot)
                Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                    act(pinned ? "Couldn't unpin \(bot.title)" : "Couldn't pin \(bot.title)") { await roster.pin(bot, !pinned) }
                }
            }
            if roster.unread.contains(bot.id) {
                Button("Mark as Read", systemImage: "circlebadge") { act("Couldn't mark \(bot.title) as read") { await roster.markAsRead(bot) } }
            } else {
                Button("Mark as Unread", systemImage: "circlebadge.fill") { act("Couldn't mark \(bot.title) as unread") { await roster.markAsUnread(bot) } }
            }
            Divider()
            Button("Rename Bot", systemImage: "pencil") { rename(bot) }
        }
        if !bot.isDefault, !roster.cannotDeleteBots {
            if !roster.cannotEditBots { Divider() }
            Button("Delete", systemImage: "trash", role: .destructive) { delete(bot) }
        }
    }

    private func act(_ what: String, _ change: @escaping () async -> String?) {
        Task {
            guard let problem = await change() else { return }
            // The title already says what did not stay.
            report(what, problem.hasPrefix("Couldn't save that. ") ? String(problem.dropFirst("Couldn't save that. ".count)) : problem)
        }
    }

    private func mainTile(_ main: Bot) -> some View {
        MainBotTile(
            bot: main, look: roster.look(for: main), preview: roster.rowPreview(for: main),
            waiting: roster.waitingText(for: main),
            isUnread: roster.showsDot(for: main), isWorking: roster.isWorking(main),
            isSelected: roster.selectedID == main.id, isCompact: isCompact
        ) {
            roster.selectedID = main.id
        }
        .contextMenu { menu(for: main) }
    }

    /// The roster as faces only, in a narrow rail: the main bot, a line, the others, and
    /// the window's few buttons at the foot.
    private func rail(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            // Room for the window's buttons.
            Color.clear.frame(height: 46)
            if let main = roster.mainBot {
                mainTile(main)
                theme.hairline.frame(width: 40, height: 1)
                    .padding(.vertical, 12)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(roster.otherBots) { bot in
                        RailFace(
                            bot: bot, look: roster.look(for: bot), waiting: roster.waitingText(for: bot),
                            isUnread: roster.showsDot(for: bot), isWorking: roster.isWorking(bot), isSelected: roster.selectedID == bot.id
                        ) {
                            roster.selectedID = bot.id
                        }
                        .contextMenu { menu(for: bot) }
                        .opacity(roster.deleting.contains(bot.id) ? 0.4 : 1)
                        .disabled(roster.deleting.contains(bot.id))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if case .loading = roster.phase, roster.bots.isEmpty {
                ProgressView().controlSize(.small).padding(.bottom, 20)
            }
            VStack(spacing: 6) {
                RailButton(symbol: "sidebar.left", label: "Expand Sidebar", action: toggleCompact)
                RailButton(symbol: "magnifyingglass", label: "Search", action: search)
                if !roster.cannotMakeBots {
                    RailButton(symbol: "plus", label: "New Bot", action: newBot)
                        .disabled(roster.phase != .loaded)
                }
                Button(action: openSettings) { GatewayBadge() }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .help(roster.gatewayName.map { "Settings, \($0)" } ?? "Settings")
                    .accessibilityLabel(roster.gatewayName.map { "Settings, gateway \($0)" } ?? "Settings")
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private func full(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer()
                RoundButton(symbol: "magnifyingglass", label: "Search", action: search)
                // Not offered at all on a gateway found unable to make bots.
                if !roster.cannotMakeBots {
                    RoundButton(symbol: "plus", label: "New Bot", action: newBot)
                        .disabled(roster.phase != .loaded)
                }
            }
            .padding(.trailing, 16)
            .frame(height: 60)

            if let main = roster.mainBot {
                mainTile(main)
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(roster.otherBots) { bot in
                        BotRow(
                            bot: bot, look: roster.look(for: bot), preview: roster.rowPreview(for: bot),
                            waiting: roster.waitingText(for: bot),
                            isUnread: roster.showsDot(for: bot), isWorking: roster.isWorking(bot), isSelected: roster.selectedID == bot.id
                        ) {
                            roster.selectedID = bot.id
                        }
                        .contextMenu { menu(for: bot) }
                        // Going: no longer something to pick or ask twice about.
                        .opacity(roster.deleting.contains(bot.id) ? 0.4 : 1)
                        .disabled(roster.deleting.contains(bot.id))
                    }
                }
                .padding(.horizontal, 8)
            }

            switch roster.phase {
            case .loaded, .needsSetup:
                EmptyView()
            case .loading:
                if roster.bots.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 20)
                }
            case .failed(let problem):
                VStack(spacing: 8) {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await roster.load() } }
                        .controlSize(.small)
                }
                .padding(16)
            }

            // Where the bots live, and the way into settings.
            WhenHovered { isHovered in
                Button(action: openSettings) {
                    HStack(spacing: 10) {
                        GatewayBadge()
                        Text(roster.gatewayName ?? "Settings")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 46)
                    // Lit under the pointer as the rows above it are.
                    .background(theme.surface.opacity(isHovered ? 0.55 : 0), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 8)
                    .frame(height: 58)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(roster.gatewayName.map { "Settings, gateway \($0)" } ?? "Settings")
            .help("Settings")
        }
    }
}

private struct MainBotTile: View {
    let bot: Bot
    let look: AvatarLook
    /// The last thing said, for the card shown beside the tile under the pointer.
    let preview: String
    /// What the bot is waiting on the person for, if anything.
    var waiting: String?
    let isUnread: Bool
    let isWorking: Bool
    let isSelected: Bool
    /// In the rail: a smaller tile with no name under the face.
    var isCompact = false
    let select: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = Theme(scheme)
        let side: CGFloat = isCompact ? 56 : 94
        Button(action: select) {
            VStack(spacing: 6) {
                BotAvatar(look, size: isCompact ? 40 : 56, isWorking: isWorking)
                    // In the rail, at the foot of the face as on the other faces there.
                    .overlay(alignment: isCompact ? .bottomTrailing : .topTrailing) {
                        if isUnread {
                            // On the edge of the face, where a badge sits.
                            Circle().fill(theme.unread).frame(width: 10, height: 10)
                                .offset(x: isCompact ? 1 : -3, y: isCompact ? 1 : 3)
                                .accessibilityLabel(waiting == nil ? "Unread" : "Waiting for you")
                        }
                    }
                if !isCompact {
                    Text(bot.title)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                }
            }
            .frame(width: side, height: side)
            // Under the pointer it lights a little, as the reference does; the chosen one stays lit.
            .background {
                RoundedRectangle(cornerRadius: 15)
                    .fill(theme.surface.opacity(isSelected ? 1 : isHovered ? 0.55 : 0))
                    // Only the light fades; the face keeps its own timing.
                    .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        // In the rail its name is not written under it.
        .accessibilityLabel(waiting.map { "\(bot.title), \($0)" } ?? bot.title)
        .onHover { isHovered = $0 }
        // A bot looks at the pointer only while the pointer is on that bot.
        .avatarsFollowPointer()
        // Under the pointer, a card beside the tile with the bot's face, name and the last
        // thing said, as the reference shows. It takes no clicks and covers nothing for long.
        .overlay(alignment: .leading) {
            if isHovered {
                HoverCard(bot: bot, look: look, preview: preview)
                    .fixedSize()
                    .offset(x: side + 10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
    }
}

/// The main bot's face, name and the last thing it said, beside its tile.
private struct HoverCard: View {
    let bot: Bot
    let look: AvatarLook
    let preview: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                BotAvatar(look, size: 16)
                Text(bot.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            }
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 220, alignment: .leading)
        .background(theme.control, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.hairline))
        .shadow(color: theme.floatShadow, radius: 6, y: 2)
        .accessibilityHidden(true)
    }
}

/// A bot in the rail: its face alone, its name on a tooltip.
private struct RailFace: View {
    let bot: Bot
    let look: AvatarLook
    var waiting: String?
    let isUnread: Bool
    let isWorking: Bool
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        let tip = waiting.map { "\(bot.title) — \($0)" } ?? bot.title
        Button(action: select) {
            BotAvatar(look, size: 36, isWorking: isWorking)
                .overlay(alignment: .bottomTrailing) {
                    if isUnread {
                        // On the edge of the face, as in the reference's rail.
                        Circle().fill(theme.unread).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(theme.sidebar, lineWidth: 1.5))
                            .offset(x: 1, y: 1)
                            .accessibilityLabel(waiting == nil ? "Unread" : "Waiting for you")
                    }
                }
                .frame(width: 56, height: 56)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(theme.surface.opacity(isSelected ? 1 : isHovered ? 0.55 : 0))
                        .animation(.easeOut(duration: 0.15), value: isHovered)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .avatarsFollowPointer()
        .help(tip)
        .accessibilityLabel(waiting.map { "\(bot.title), \($0)" } ?? bot.title)
    }
}

/// One of the rail's buttons at its foot: a glyph alone, lit under the pointer.
private struct RailButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        WhenHovered { isHovered in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(theme.hover.opacity(isHovered ? 1 : 0), in: Circle())
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct BotRow: View {
    let bot: Bot
    let look: AvatarLook
    /// The last thing said, without the marks that lay a reply out: "## Plan" reads "Plan".
    let preview: String
    /// What the bot is waiting on the person for, if anything.
    var waiting: String?
    let isUnread: Bool
    let isWorking: Bool
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        Button(action: select) {
            HStack(spacing: 12) {
                BotAvatar(look, size: 34, isWorking: isWorking)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bot.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.text)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if isUnread {
                    Circle().fill(theme.unread).frame(width: 8, height: 8)
                        .padding(.trailing, 4)
                        .accessibilityLabel(waiting == nil ? "Unread" : "Waiting for you")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 58)
            // Under the pointer it lights a little, as the reference does; the chosen one stays lit.
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.surface.opacity(isSelected ? 1 : isHovered ? 0.55 : 0))
                    // Only the light fades; the face keeps its own timing.
                    .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .avatarsFollowPointer()
    }
}

struct RoundButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        WhenHovered { isHovered in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.text)
                    .frame(width: 34, height: 34)
                    .background(isHovered ? theme.controlHover : theme.control, in: Circle())
                    .overlay(Circle().strokeBorder(theme.hairline))
                    .shadow(color: theme.floatShadow, radius: 6, y: 2)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
