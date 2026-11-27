import AppKit
import HermesBotUI
import HermesKit
import SwiftUI

@main
struct HermesBotApp: App {
    @State private var roster = RosterModel(alerts: .live())
    @State private var panel: Panel?
    @State private var showsDetails = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    /// The roster as a rail of faces (⌘B), kept on this Mac.
    @AppStorage("compactSidebar") private var isCompact = false
    @AppStorage(TextZoom.key) private var zoom = 1.0
    private let updates = Updates.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        // `--write-icon <folder>` draws the app's icon and leaves, for the script that
        // makes the app bundle. No window is opened.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--write-icon"), arguments.indices.contains(flag + 1) {
            exit(AppIconWriter.write(to: URL(fileURLWithPath: arguments[flag + 1])) ? 0 : 1)
        }
        // Needed while the app runs unbundled from `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        // One window: the roster and its connection belong to it.
        Window("Hermes Bot", id: "main") {
            Group {
                if CommandLine.arguments.contains("--avatars") {
                    AvatarGallery()
                } else {
                    MainWindow(roster: roster, panel: $panel, showsDetails: $showsDetails, isCompact: $isCompact)
                        .task {
                            roster.reopenMainWindow = {
                                if !roster.isMakingBot { panel = nil }
                                if !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
                                    openWindow(id: "main")
                                }
                            }
                            // A window opened again (from the Dock or a notification) finds the
                            // roster already loaded and watched: reading it again would start a
                            // new load and drop what the watch hears meanwhile.
                            if roster.phase != .loaded { await roster.load() }
                        }
                }
            }
            // For screenshots in both appearances without changing the system setting.
            .preferredColorScheme(
                CommandLine.arguments.contains("--light") ? .light
                    : CommandLine.arguments.contains("--dark") ? .dark : appearance.scheme
            )
        }
        .commands {
            CommandGroup(after: .appInfo) {
                // Only in a copy of the app that can install updates; see Updates.
                if updates.isOn {
                    Button("Check for Updates…") { updates.check() }
                        .disabled(!updates.canCheck)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { panel = .settings }
                    .keyboardShortcut(",")
                    .disabled(roster.phase == .needsSetup || roster.isMakingBot)
            }
            CommandGroup(after: .textEditing) {
                // Again to close it, as in the reference.
                Button("Search…") { panel = panel == .search ? nil : .search }
                    .keyboardShortcut("k")
                    .disabled(roster.phase == .needsSetup || roster.isMakingBot)
                Button("Find in Chat") { if let bot = roster.selected { roster.chat(for: bot).find() } }
                    .keyboardShortcut("f")
                    .disabled(!hasChat)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Bot") { panel = .newBot }
                    .keyboardShortcut("n")
                    .disabled(roster.phase != .loaded || roster.cannotMakeBots || roster.isMakingBot)
            }
            CommandGroup(after: .sidebar) {
                Button(isCompact ? "Expand Sidebar" : "Compact Sidebar") { isCompact.toggle() }
                    .keyboardShortcut("b")
                    // Not while a roster that could not be read is held open.
                    .disabled(!canMove || rosterFailed)
                Button(showsDetails ? "Hide Details" : "Show Details") { showsDetails.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(roster.phase == .needsSetup || roster.selected == nil || panel != nil)
                // Goes to the next bot with something unread or waiting on the person, in the roster's order.
                Button("View Unread") {
                    if let id = BotOrder.nextUnread(after: roster.selectedID, in: roster.order, unread: roster.needsAttention) { roster.selectedID = id }
                }
                .disabled(!canMove || BotOrder.nextUnread(after: roster.selectedID, in: roster.order, unread: roster.needsAttention) == nil)
                Divider()
                Button("Actual Size") { zoom = 1 }
                    .keyboardShortcut("0")
                    .disabled(!canMove || TextZoom.clamped(zoom) == 1)
                Button("Zoom In") { zoom = TextZoom.step(1, from: zoom) }
                    .keyboardShortcut("+")
                    .disabled(!canMove || TextZoom.clamped(zoom) == TextZoom.steps.last.map { CGFloat($0) })
                Button("Zoom Out") { zoom = TextZoom.step(-1, from: zoom) }
                    .keyboardShortcut("-")
                    .disabled(!canMove || TextZoom.clamped(zoom) == TextZoom.steps.first.map { CGFloat($0) })
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { panel = panel == .shortcuts ? nil : .shortcuts }
                    .keyboardShortcut("/")
                    .disabled(roster.phase == .needsSetup || roster.isMakingBot)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
    }

    /// The roster is up and nothing is open over it, so the keyboard can move between bots.
    private var canMove: Bool { roster.phase != .needsSetup && panel == nil }
    private var rosterFailed: Bool {
        if case .failed = roster.phase { return true }
        return false
    }
    /// A chat is showing, read in, with nothing over it.
    private var hasChat: Bool { canMove && roster.selected.map { roster.chat(for: $0).phase == .loaded } == true }
}

/// The window's own coordinate space, in which the reaction capsule is placed.
let appWindowSpace = "main window"

struct MainWindow: View {
    let roster: RosterModel
    @Binding var panel: Panel?
    /// The pane beside the chat with the selected bot's details.
    @Binding var showsDetails: Bool
    /// The roster as a rail of faces.
    @Binding var isCompact: Bool
    /// Asks to rename a bot, and how many the pane has answered; see `DetailsPanel`.
    @State private var renameAsks = 0
    @State private var renamesAnswered = 0
    /// The same for opening the model picker, asked by `/model` in the message box.
    @State private var modelAsksAnswered = 0
    /// Counts openings of the search palette, so each is a fresh one.
    @State private var searchOpens = 0
    /// A bot the person has asked to delete, until they confirm or think better of it.
    @State private var deleting: Bot?
    @State private var deleteProblem: String?
    /// What pin or mark from a row's menu did not stay, and why.
    @State private var menuProblem: (what: String, why: String)?
    /// The reaction picker open in the chat, if one is.
    @State private var reactionPicker: ReactionPickerTarget?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        if roster.phase == .needsSetup {
            SetupView(roster: roster)
                .ignoresSafeArea()
                // Settings belongs to a gateway; it must not reappear over the next one.
                .onAppear {
                    panel = nil
                    showsDetails = false
                }
        } else {
            main(theme)
                // Behind the panel nothing takes clicks. Not `disabled`, which would also
                // grey the bots' faces.
                .allowsHitTesting(panel == nil)
                .environment(\.isCovered, panel != nil)
                .accessibilityHidden(panel != nil)
                .coordinateSpace(name: appWindowSpace)
                .onKeyPress(.escape, phases: .down) { _ in
                    guard reactionPicker != nil else { return .ignored }
                    reactionPicker = nil
                    return .handled
                }
                .overlay {
                    if let target = reactionPicker, let bot = roster.selected {
                        reactionOverlay(target, bot: bot)
                            .ignoresSafeArea()
                    }
                }
                .overlay {
                    if let panel {
                        ZStack {
                            Color.black.opacity(scheme == .dark ? 0.5 : 0.2)
                                .onTapGesture { if !roster.isMakingBot { self.panel = nil } }
                            switch panel {
                            case .settings: SettingsView(roster: roster) { self.panel = nil }
                            case .shortcuts: ShortcutsView { self.panel = nil }
                            // Closes itself only: by the time a bot is made, another panel may be up.
                            case .newBot: NewBotView(roster: roster) { if self.panel == .newBot { self.panel = nil } }
                            case .search:
                                SearchView(roster: roster, showsDetails: showsDetails) { item in
                                    guard self.panel == .search else { return }
                                    self.panel = nil
                                    switch item {
                                    case .bot(let id): roster.selectedID = id
                                    case .newBot: self.panel = .newBot
                                    case .settings: self.panel = .settings
                                    case .details: showsDetails.toggle()
                                    case .rename:
                                        renameAsks += 1
                                        showsDetails = true
                                    case nil: break
                                    }
                                }
                                // Afresh each time it opens, even if the last one is still fading out.
                                .id(searchOpens)
                            }
                        }
                        .ignoresSafeArea()
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: panel)
                .onChange(of: panel) { _, now in
                    if now != nil { reactionPicker = nil }
                    switch now {
                    case .search:
                        searchOpens += 1
                        // The composer would keep the caret, and the keys, behind the panel.
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    case .settings, .shortcuts:
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    case .newBot:
                        break
                    case nil:
                        // However the panel closed, back to typing in the chat that is showing.
                        if let bot = roster.selected { roster.chat(for: bot).focus() }
                    }
                }
                // A chat is read when it is showing and the app is in front, not behind another.
                // A window closed or in the Dock is not being looked at either.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in look() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in look() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in look() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in look() }
                .onAppear { look() }
                .onDisappear { roster.isLookedAt = false }
                // The reference's other way to search, and its ways between bots, kept off
                // the menus as the reference keeps them. Not there at all under a panel, so
                // its fields have the keys (⌥↑ moves the caret there).
                .background { if panel == nil { keys } }
        }
    }

    /// Shortcuts with no menu item: they are listed in Keyboard Shortcuts (⌘/).
    private var keys: some View {
        ZStack {
            Button("Search") { panel = .search }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            ForEach(1..<10) { place in
                Button("Go to Bot \(place)") {
                    if let id = BotOrder.bot(at: place, in: roster.order) { roster.selectedID = id }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(place)")))
            }
            Button("Previous Bot") {
                if let id = BotOrder.step(-1, from: roster.selectedID, in: roster.order) { roster.selectedID = id }
            }
            .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Next Bot") {
                if let id = BotOrder.step(1, from: roster.selectedID, in: roster.order) { roster.selectedID = id }
            }
            .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Back") { roster.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { roster.goForward() }
                .keyboardShortcut("]")
            Button("Focus Chat") { if let bot = roster.selected { roster.chat(for: bot).focus() } }
                .keyboardShortcut("i")
            // ⌘= as well as ⌘+, which on most keyboards needs Shift.
            Button("Zoom In") { zoom = TextZoom.step(1, from: zoom) }
                .keyboardShortcut("=")
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @AppStorage(TextZoom.key) private var zoom = 1.0
    /// How wide the bot's name over the chat is, for the find pill beside it.
    @State private var pillWidth: CGFloat = 160

    /// The roster as a rail, unless it could not be read: what went wrong, and Try Again,
    /// need the open roster's room.
    private var showsRail: Bool {
        if case .failed = roster.phase { return false }
        return isCompact
    }

    /// Whether the chat on screen can be seen: the app in front, with a window of its own
    /// showing. Asked a moment later, once the system has finished what it was announcing.
    private func look() {
        Task { @MainActor in
            roster.isLookedAt = NSApp.isActive && NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }
        }
    }

    /// A click anywhere outside the capsule closes it, as a popover's would.
    private func reactionOverlay(_ target: ReactionPickerTarget, bot: Bot) -> some View {
        ZStack {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { reactionPicker = nil }
            GeometryReader { space in
                let width = ReactionCapsule.width
                let height = ReactionCapsule.height
                let leading = (showsRail ? RosterView.compactWidth : RosterView.width) + 1
                let trailing = showsDetails ? DetailsPanel.width + 1 : 0
                let minX = leading + 8 + width / 2
                let maxX = max(minX, space.size.width - trailing - 8 - width / 2)
                let x = min(max(target.anchor.minX - 4 + width / 2, minX), maxX)
                let aboveTop = target.anchor.minY - 8 - height
                let belowTop = target.anchor.maxY + 8
                // The bot's name pill owns the top 56 points; the composer owns the bottom.
                let minTop: CGFloat = 56
                let maxTop = max(minTop, space.size.height - 70 - height)
                let useAbove = aboveTop >= minTop || belowTop > maxTop
                let top = min(max(useAbove ? aboveTop : belowTop, minTop), maxTop)
                ReactionCapsule(row: target.row, bot: bot, roster: roster) {
                    reactionPicker = nil
                }
                .background {
                    // Escape closes it wherever the caret is, as a popover's would.
                    Button("Close") { reactionPicker = nil }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
                .position(x: x, y: top + height / 2)
            }
        }
    }

    private func main(_ theme: Theme) -> some View {
        HStack(spacing: 0) {
            RosterView(
                roster: roster, openSettings: { panel = .settings }, newBot: { panel = .newBot }, search: { panel = .search },
                rename: { bot in
                    roster.selectedID = bot.id
                    renameAsks += 1
                    showsDetails = true
                },
                delete: { deleting = $0 },
                isCompact: showsRail,
                toggleCompact: { isCompact.toggle() },
                report: { menuProblem = (what: $0, why: $1) }
            )
                .frame(width: showsRail ? RosterView.compactWidth : RosterView.width)
                .background(theme.sidebar)
                // Over the chat, so the card beside the main bot's tile is not hidden by it.
                .zIndex(1)
            theme.hairline.frame(width: 1)
            ZStack(alignment: .top) {
                theme.canvas
                if let bot = roster.selected {
                    ChatView(bot: bot, roster: roster, reactionPicker: $reactionPicker)
                        // A fresh view per bot: scroll position and retries belong to one chat.
                        .id(bot.id)
                        .environment(\.pillWidth, pillWidth)
                    // Watched from outside the button: inside its label the pointer is not told of.
                    WhenHovered { isHovered in
                        Button {
                            showsDetails.toggle()
                        } label: {
                            BotPill(bot: bot, look: roster.look(for: bot), isHovered: isHovered)
                        }
                        // For the find pill, which keeps clear of it.
                        .onGeometryChange(for: CGFloat.self, of: \.size.width) { pillWidth = $0 }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(bot.title), details")
                    .help("Details")
                    .padding(.top, 10)
                }
            }
            if showsDetails, let bot = roster.selected {
                theme.hairline.frame(width: 1)
                DetailsPanel(
                    bot: bot, roster: roster, renameAsks: renameAsks, renamesAnswered: $renamesAnswered,
                    modelAsks: roster.modelPickAsks, modelAsksAnswered: $modelAsksAnswered
                ) { showsDetails = false }
                    // A fresh pane per bot, so a name half typed is saved to the bot it was for.
                    .id(bot.id)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeOut(duration: 0.25), value: showsDetails)
        .animation(.easeOut(duration: 0.2), value: showsRail)
        // `/model` and `/reasoning` in the message box, with nothing after them.
        .onChange(of: roster.detailsAsks) { showsDetails = true }
        // Clicking a system notification closes any panel over the chat so the question shows,
        // unless a bot is mid-creation (whose dialog holds its retry state).
        .onChange(of: roster.notificationOpens) { if !roster.isMakingBot { panel = nil } }
        .ignoresSafeArea()
        .confirmationDialog(
            "Delete \(deleting?.title ?? "this bot")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { bot in
            Button("Delete", role: .destructive) {
                Task { deleteProblem = await roster.delete(bot) }
            }
        } message: { _ in
            Text("The bot, its chat, its memory and its routines are removed from the gateway. This can't be undone.")
        }
        .alert(roster.cannotDeleteBots ? "This gateway can't delete bots" : "Couldn't delete the bot", isPresented: Binding(get: { deleteProblem != nil }, set: { if !$0 { deleteProblem = nil } })) {
            Button("OK") { deleteProblem = nil }
        } message: {
            Text(deleteProblem ?? "")
        }
        .alert(menuProblem?.what ?? "", isPresented: Binding(get: { menuProblem != nil }, set: { if !$0 { menuProblem = nil } })) {
            Button("OK") { menuProblem = nil }
        } message: {
            Text(menuProblem?.why ?? "")
        }
    }
}

/// The bot's avatar and name, floating over the top of its chat.
struct BotPill: View {
    let bot: Bot
    let look: AvatarLook
    /// Under the pointer it lightens and opens out to show where it leads, as the
    /// reference's does.
    var isHovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        Group {
            HStack(spacing: 8) {
                BotAvatar(look, size: 22)
                Text(bot.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                if isHovered {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(height: 38)
            .background(isHovered ? theme.controlHover : theme.control, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.hairline))
            .shadow(color: theme.floatShadow, radius: 6, y: 2)
        }
    }
}

/// What can be open over the window.
enum Panel: Equatable {
    case settings
    case newBot
    case search
    case shortcuts
}
