import HermesBotUI
import HermesKit
import SwiftUI

/// What the search palette can find and do.
enum PaletteItem: Equatable, Identifiable {
    case bot(Bot.ID)
    case newBot
    case rename
    case details
    case settings

    var id: String {
        switch self {
        case .bot(let id): "bot-\(id)"
        case .newBot: "new-bot"
        case .rename: "rename"
        case .details: "details"
        case .settings: "settings"
        }
    }
}

enum Palette {
    /// A bot as the palette knows it: what it is called, the last thing said in its chat,
    /// and anything else it answers to without showing it, such as its name on the gateway.
    struct Entry: Equatable {
        let id: Bot.ID
        let title: String
        let preview: String
        var also = ""
    }

    /// What the window is able to do just now, which decides the actions on offer.
    struct Offer: Equatable {
        var canMakeBots = true
        /// A bot is showing, so there is one to rename and to see the details of.
        var hasBot = true
        var canRename = true
        var showsDetails = false
    }

    /// The bots and the actions that answer to what was typed, bots first. Nothing typed
    /// gives everything. Capitals and accents make no difference.
    static func items(for query: String, bots: [Entry], offer: Offer = Offer()) -> (bots: [PaletteItem], actions: [PaletteItem]) {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        func answers(_ text: String) -> Bool {
            words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        // A bot whose name answers comes before one found by anything else about it.
        let named = bots.filter { answers($0.title) }
        let otherwise = bots.filter { !answers($0.title) && !words.isEmpty && answers("\($0.title) \($0.also) \($0.preview)") }
        var actions: [PaletteItem] = []
        if offer.canMakeBots { actions.append(.newBot) }
        if offer.hasBot, offer.canRename { actions.append(.rename) }
        if offer.hasBot { actions.append(.details) }
        actions.append(.settings)
        return ((named + otherwise).map { .bot($0.id) }, actions.filter { answers(title(of: $0, offer: offer)) })
    }

    static func title(of action: PaletteItem, offer: Offer = Offer()) -> String {
        switch action {
        case .newBot: "New Bot"
        case .rename: "Rename Bot"
        case .details: offer.showsDetails ? "Hide Bot Details" : "Bot Details"
        case .settings: "Settings"
        case .bot: ""
        }
    }

    /// The item to light and to do on Return: the one chosen if it is still on offer,
    /// otherwise the first. Chosen by what it is and not by its place, so the list changing
    /// under an open palette never moves the choice to something else.
    static func chosen(_ id: PaletteItem.ID?, in all: [PaletteItem]) -> PaletteItem? {
        all.first { $0.id == id } ?? all.first
    }

    /// The item a step up or down from the one lit, going round at the ends.
    static func step(_ by: Int, from id: PaletteItem.ID?, in all: [PaletteItem]) -> PaletteItem? {
        guard let lit = chosen(id, in: all), let at = all.firstIndex(of: lit) else { return nil }
        return all[(at + by + all.count) % all.count]
    }
}

/// The search palette: bots by name or by the last thing said, and the app's few actions.
struct SearchView: View {
    let roster: RosterModel
    let showsDetails: Bool
    /// Closes the palette and does what was chosen, if anything was. The one way out.
    let finish: (PaletteItem?) -> Void
    @State private var query = ""
    @State private var chosenID: PaletteItem.ID?
    @FocusState private var isSearching: Bool
    @Environment(\.colorScheme) private var scheme

    private var offer: Palette.Offer {
        Palette.Offer(
            canMakeBots: !roster.cannotMakeBots && roster.phase == .loaded,
            hasBot: roster.selected != nil,
            canRename: !roster.cannotEditBots,
            showsDetails: showsDetails
        )
    }

    private var found: (bots: [PaletteItem], actions: [PaletteItem]) {
        Palette.items(
            for: query,
            // One being deleted is no longer something to go to.
            bots: roster.bots.filter { !roster.deleting.contains($0.id) }.map {
                Palette.Entry(
                    id: $0.id, title: $0.title, preview: roster.rowPreview(for: $0),
                    also: "\($0.name) \($0.description) \(roster.previews[$0.id] ?? "")"
                )
            },
            offer: offer
        )
    }

    var body: some View {
        let theme = Theme(scheme)
        let found = found
        let all = found.bots + found.actions
        let chosen = Palette.chosen(chosenID, in: all)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.secondaryText)
                TextField("Search Bots, Settings…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .foregroundStyle(theme.text)
                    .focused($isSearching)
                    .onSubmit { if let chosen { finish(chosen) } }
                    .onKeyPress(.downArrow) { move(1, in: all) }
                    .onKeyPress(.upArrow) { move(-1, in: all) }
                    .accessibilityLabel("Search")
            }
            .padding(.horizontal, 20)
            .frame(height: 58)

            if all.isEmpty {
                Text("Nothing found")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollViewReader { scroller in
                    // As tall as what was found when that fits the window, scrolling when not.
                    ViewThatFits(in: .vertical) {
                        results(found, chosen, theme)
                        ScrollView { results(found, chosen, theme) }
                    }
                    .frame(maxHeight: 480)
                    .onChange(of: chosen) {
                        if let chosen { scroller.scrollTo(chosen.id) }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(theme.control, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.hairline))
        // One shadow, under the palette as a whole, not one under every row inside it.
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        // Near the top of the window, where the reference puts it, not the middle.
        .padding(.top, 120)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        // Escape closes it wherever the caret is, as it does the other panels.
        .background {
            Button("Close") { finish(nil) }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // What is lit is held by name from the start, not only once a key or the pointer has
        // chosen: otherwise a bot arriving above it would take the light, and Return with it.
        .onAppear { chosenID = all.first?.id }
        .onChange(of: query) {
            let found = self.found
            chosenID = (found.bots + found.actions).first?.id
        }
        .onChange(of: all.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == chosenID }) { chosenID = ids.first }
        }
        .task {
            // After the panel is on screen; sooner and the field does not take the caret.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            isSearching = true
        }
    }

    private func move(_ step: Int, in all: [PaletteItem]) -> KeyPress.Result {
        chosenID = Palette.step(step, from: chosenID, in: all)?.id
        return .handled
    }

    private func results(_ found: (bots: [PaletteItem], actions: [PaletteItem]), _ chosen: PaletteItem?, _ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !found.bots.isEmpty {
                heading("Bots", theme)
                ForEach(found.bots) { row($0, isChosen: $0 == chosen, theme) }
            }
            if !found.actions.isEmpty {
                heading("Actions", theme)
                    .padding(.top, found.bots.isEmpty ? 0 : 10)
                ForEach(found.actions) { row($0, isChosen: $0 == chosen, theme) }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func heading(_ title: String, _ theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .padding(.leading, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func row(_ item: PaletteItem, isChosen: Bool, _ theme: Theme) -> some View {
        Button { finish(item) } label: {
            HStack(spacing: 12) {
                switch item {
                case .bot(let id):
                    if let bot = roster.bots.first(where: { $0.id == id }) {
                        BotAvatar(roster.look(for: bot), size: 28, isWorking: roster.isWorking(bot))
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bot.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.text)
                            let preview = roster.rowPreview(for: bot)
                            if !preview.isEmpty {
                                Text(preview)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        .lineLimit(1)
                    }
                default:
                    Image(systemName: symbol(of: item))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 30, height: 30)
                        // An edge and no fill, so it shows on the card and on the lit row alike.
                        .overlay(Circle().strokeBorder(theme.hairline))
                    Text(Palette.title(of: item, offer: offer))
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                }
                Spacer(minLength: 8)
                if case .bot(let id) = item, let bot = roster.bots.first(where: { $0.id == id }), roster.showsDot(for: bot) {
                    Circle().fill(theme.unread).frame(width: 8, height: 8)
                        .padding(.trailing, 4)
                        .accessibilityLabel(roster.isWaiting(bot) ? "Waiting for you" : "Unread")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(theme.chosen.opacity(isChosen ? 1 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // The caret stays in the field, so typing and the arrow keys always work.
        .focusable(false)
        // The pointer chooses as the arrow keys do, so there is only ever one lit row.
        .onHover { if $0 { chosenID = item.id } }
        .id(item.id)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func symbol(of item: PaletteItem) -> String {
        switch item {
        case .newBot: "plus"
        case .rename: "pencil"
        case .details: "sidebar.right"
        case .settings: "gearshape"
        case .bot: ""
        }
    }
}
