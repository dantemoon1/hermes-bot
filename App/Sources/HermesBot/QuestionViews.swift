import HermesBotUI
import HermesKit
import SwiftUI

/// A question a bot is waiting on, as a card in its chat as wide as a reply.
///
/// What the card says first is the app's own: a title from what kind of question it is, and
/// what it is about exactly as the gateway gave it (a command, a folder, a site, the name of
/// a setting). The bot's own words come after, marked as the bot's, so a bot cannot dress a
/// request up as something else. Nothing on a card takes the keyboard when it arrives, so
/// what is being typed in the message box never lands in it, and Return there never answers.
struct QuestionCard: View {
    let asked: ChatQuestions.Asked
    let bot: Bot
    let look: AvatarLook
    let gatewayName: String
    let chat: ChatModel
    /// This card answers the shortcuts for allowing and denying: it is the first approval
    /// still open in the chat that is showing.
    let takesShortcuts: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        Group {
            switch asked.question.kind {
            case .approval(let approval):
                ApprovalCard(asked: asked, approval: approval, bot: bot, takesShortcuts: takesShortcuts) { chat.questions.answer(asked.instance, with: $0, for: bot) }
            case .clarify:
                // Asked in the panel over the message box, not here.
                EmptyView()
            case .secret(let name, let prompt):
                SecretCard(asked: asked, name: name, prompt: prompt, bot: bot, look: look, gatewayName: gatewayName) { chat.questions.answer(asked.instance, with: $0, for: bot) }
            case .sudo(let command):
                SudoCard(asked: asked, command: command, bot: bot, look: look, gatewayName: gatewayName) { chat.questions.answer(asked.instance, with: $0, for: bot) }
            case .connection(let connection):
                ConnectionCard(asked: asked, connection: connection, bot: bot, look: look, gatewayName: gatewayName,
                               mayAct: { chat.questions.mayAct(asked.instance) },
                               retry: { chat.questions.retry(asked.instance, row: $0, for: bot) },
                               opened: { chat.questions.opened(asked.instance, row: $0) },
                               askedFields: chat.questions.fields(of: connection.opID),
                               draft: { chat.questions.draft(of: connection.opID, row: $0, field: $1) },
                               setDraft: { chat.questions.setDraft($2, of: connection.opID, row: $0, field: $1) },
                               clearDrafts: { chat.questions.clearDrafts(of: connection.opID, row: $0) }) { chat.questions.respond(asked.instance, with: $0, for: bot) }
            }
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .onAppear { chat.questions.shown(asked.instance) }
        .background(theme.bubble, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(theme.hairline))
        .frame(maxWidth: .infinity, alignment: .leading)
        // Being answered: nothing more can be pressed until the gateway has it or refuses it.
        .disabled(asked.state != .open)
        .opacity(asked.state == .answering ? 0.6 : 1)
    }
}

/// The parts every card is made of.
enum CardParts {
    static func header(_ symbol: String, _ title: String, waits: Duration?, since: Date, until deadline: Date? = nil, _ theme: Theme) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
            Spacer(minLength: 8)
            if let deadline {
                Countdown(until: deadline)
            } else if let waits {
                Countdown(until: since.addingTimeInterval(Double(waits.components.seconds)))
            }
        }
    }

    /// What the question is about, as given: in a well, in the font of code, selectable.
    static func well(_ theme: Theme, @ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.codeBlock, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.hairline))
    }

    /// What a question is about, shown so that it reads as it will act: characters that
    /// would turn or hide text are written out as themselves, never acted on. A long one
    /// scrolls in its well, so the card's own title and buttons stay in sight.
    static func code(_ text: String, _ theme: Theme, weight: Font.Weight = .regular, oneLine: Bool = false) -> some View {
        ScrollView(.vertical) {
            Text(verbatim: ShownText.visible(text, oneLine: oneLine))
                .font(.system(size: 12.5, weight: weight, design: .monospaced))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A small label at the end of a well.
    static func tag(_ text: String, _ theme: Theme) -> some View {
        Text(verbatim: text)
            .lineLimit(1)
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .overlay(Capsule().strokeBorder(theme.hairline))
            .fixedSize()
    }

    /// The bot's own words, said to be the bot's.
    static func botSays(_ bot: Bot, _ words: String, _ theme: Theme) -> some View {
        // A few lines at most: a bot's words cannot push what the card is about out of sight.
        (Text(verbatim: "\(bot.title) says: ").fontWeight(.medium) + Text(verbatim: "“\(ShownText.visible(words, oneLine: false, prose: true))”"))
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(5)
            .truncationMode(.tail)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func note(_ symbol: String, _ text: String, _ theme: Theme) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            // The gateway's risk line can carry what a command did: shown as written, briefly.
            Text(verbatim: ShownText.visible(text, oneLine: false, prose: true))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.secondaryText)
    }
}

/// A pill on a card. The one that does what was asked is filled; the others are quiet.
struct CardButton: View {
    enum Style { case primary, plain, quiet }
    let title: String
    var style = Style.plain
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, style: Style = .plain, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        let theme = Theme(scheme)
        WhenHovered { isHovered in
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12.5, weight: style == .primary ? .medium : .regular))
                    .foregroundStyle(foreground(theme))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(background(theme, isHovered), in: Capsule())
                    .overlay(Capsule().strokeBorder(style == .primary && isEnabled ? .clear : theme.hairline))
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func foreground(_ theme: Theme) -> Color {
        switch style {
        case .primary: isEnabled ? theme.canvas : theme.secondaryText
        case .plain: theme.text
        case .quiet: theme.secondaryText
        }
    }

    private func background(_ theme: Theme, _ isHovered: Bool) -> Color {
        switch style {
        case .primary: isEnabled ? theme.text.opacity(isHovered ? 0.85 : 1) : theme.raised
        case .plain: isHovered ? theme.raisedHover : theme.raised
        case .quiet: isHovered ? theme.hover : .clear
        }
    }
}

/// How long until the gateway stops waiting, in seconds or minutes and seconds.
struct Countdown: View {
    let until: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = until.timeIntervalSince(context.date).rounded(.up)
            // Bounded before it is made a whole number: a time far off must not trap.
            let left = seconds.isFinite ? Int(min(max(seconds, 0), 359_999)) : 0
            Text(left >= 60 ? "\(left / 60)m \(left % 60)s" : "\(left)s")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme(scheme).secondaryText)
        }
    }
}


/// Leave to run a command, or to reach a folder or a site.
private struct ApprovalCard: View {
    let asked: ChatQuestions.Asked
    let approval: Approval
    let bot: Bot
    let takesShortcuts: Bool
    let answer: (QuestionAnswer) -> Void
    @State private var isGivingReason = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 10) {
            CardParts.header(symbol, title, waits: asked.question.waits, since: asked.asked, theme)
            CardParts.well(theme) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CardParts.code(subject, theme, oneLine: isOneLine)
                    Spacer(minLength: 6)
                    switch approval.subject {
                    case .folder(_, let canWrite?): CardParts.tag(canWrite ? "Read & write" : "Read only", theme)
                    case .site(_, let label?):
                        Text(verbatim: ShownText.visible(label, oneLine: true))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    default: EmptyView()
                    }
                }
            }
            if let risk = approval.risk {
                CardParts.note("exclamationmark.triangle", risk, theme)
            }
            if let description = approval.description, description != subject {
                CardParts.botSays(bot, description, theme)
            }
            if let problem = asked.problem {
                CardParts.note("exclamationmark.circle", problem, theme)
            }
            if isGivingReason {
                HStack(spacing: 8) {
                    TextField("Why not (optional)", text: $reason)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($reasonFocused)
                        .onSubmit { deny() }
                        .onExitCommand { isGivingReason = false }
                    CardButton("Back", style: .quiet) { isGivingReason = false }
                    CardButton("Deny", style: .primary) { deny() }
                }
                .padding(.leading, 11)
                .padding(.trailing, 4)
                .frame(height: 36)
                .background(theme.composer, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.hairline))
            } else {
                HStack(spacing: 6) {
                    // First in the row, so Tab into the card lands on Deny before anything that allows.
                    CardButton("Deny") { deny() }
                        .keyboardShortcut(takesShortcuts ? KeyboardShortcut("d", modifiers: [.command, .shift]) : nil)
                        .help(takesShortcuts ? "Deny (⇧⌘D)" : "Deny")
                    if approval.takesReason {
                        CardButton("Reason…", style: .quiet) {
                            isGivingReason = true
                            reasonFocused = true
                        }
                        .help("Deny, saying why")
                    }
                    Spacer(minLength: 8)
                    // Never a shortcut: allowing for good is only ever a deliberate click.
                    if approval.choices.contains(.always) {
                        CardButton("Always", style: .quiet) { choose(.always) }
                            .help(alwaysHelp)
                    }
                    if approval.choices.contains(.session) {
                        CardButton("Session") { choose(.session) }
                            .help("Allow until this chat's session on the gateway ends")
                    }
                    if approval.choices.contains(.once) {
                        CardButton("Allow once", style: .primary) { choose(.once) }
                            .keyboardShortcut(takesShortcuts ? KeyboardShortcut("a", modifiers: [.command, .shift]) : nil)
                            .help(takesShortcuts ? "Allow once (⇧⌘A)" : "Allow once")
                    }
                }
            }
        }
    }

    /// A folder or a site is one line, whatever it holds.
    private var isOneLine: Bool { if case .command = approval.subject { false } else { true } }

    private var symbol: String {
        switch approval.subject {
        case .command: "apple.terminal"
        case .folder: "folder"
        case .site: "globe"
        }
    }

    /// Said by the app, from what kind of request it is, never by the bot.
    private var title: String {
        switch approval.subject {
        case .command: "Run a command"
        case .folder(_, let canWrite): canWrite == true ? "Read and write folder" : canWrite == false ? "Read folder" : "Use folder"
        case .site: "Connect to site"
        }
    }

    private var subject: String {
        switch approval.subject {
        case .command(let command): command.isEmpty ? "(no command given)" : command
        case .folder(let path, _): path
        case .site(let host, _): host
        }
    }

    private var alwaysHelp: String {
        switch approval.subject {
        case .command: "Allow commands like this from now on, without asking"
        case .folder: "Allow this folder from now on, without asking"
        case .site: "Allow this site from now on, without asking"
        }
    }


    private func choose(_ choice: ApprovalChoice) {
        // Nothing is done in the moment the card arrives (`ChatQuestions.answer`).
        guard approval.choices.contains(choice) else { return }
        answer(.approval(choice))
    }

    private func deny() {
        let why = approval.takesReason ? reason.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        answer(.approval(.deny, reason: why.isEmpty ? nil : why))
    }
}

/// A field for something that must not be seen or kept. What is typed lives only in the
/// field until it is sent or skipped, and is emptied then and whenever the card goes.
private struct SecretField: View {
    let placeholder: String
    @Binding var value: String
    /// A key pasted from somewhere can be looked at before it goes; a password cannot.
    let canReveal: Bool
    let submit: () -> Void
    @State private var isRevealed = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $value)
                } else {
                    SecureField(placeholder, text: $value)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: isRevealed ? .monospaced : .default))
            .textContentType(nil)
            .autocorrectionDisabled()
            .focused($isFocused)
            // Return with nothing typed does nothing; Skip is said by pressing Skip.
            .onSubmit { if !value.isEmpty { submit() } }
            if canReveal {
                Button {
                    isRevealed.toggle()
                    isFocused = true
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isRevealed ? "Hide" : "Show")
                .accessibilityLabel(isRevealed ? "Hide value" : "Show value")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(theme.composer, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.hairline))
        // Hidden again whenever the field is left or the app is not in front.
        .onChange(of: isFocused) { if !isFocused { isRevealed = false } }
        .onChange(of: activeState) { if activeState != .key { isRevealed = false } }
        .onDisappear { value = "" }
    }
}

/// A value for one of the bot's settings, such as a key for a service.
private struct SecretCard: View {
    let asked: ChatQuestions.Asked
    let name: String
    let prompt: String
    let bot: Bot
    let look: AvatarLook
    let gatewayName: String
    let answer: (QuestionAnswer) -> Bool
    @State private var value = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 10) {
            CardParts.header("lock", "Secret value", waits: asked.question.waits, since: asked.asked, theme)
            CardParts.well(theme) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        CardParts.code(name.isEmpty ? "(no name given)" : name, theme, weight: .semibold, oneLine: true)
                        Spacer(minLength: 6)
                        CardParts.tag("Secret", theme)
                    }
                    RequestedBy(bot: bot, look: look, place: "Saved on", gatewayName: gatewayName)
                }
            }
            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                CardParts.botSays(bot, prompt, theme)
            }
            SecretField(placeholder: name.isEmpty ? "Value" : "Paste value for \(ShownText.visible(name, oneLine: true))", value: $value, canReveal: true, submit: send)
            CardParts.note("shield", "Goes only to \(gatewayName). Not kept in this app or this chat.", theme)
            if let problem = asked.problem {
                CardParts.note("exclamationmark.circle", problem, theme)
            }
            HStack {
                CardButton("Skip", style: .quiet) { skip() }
                Spacer()
                CardButton("Submit", style: .primary, action: send)
                    .disabled(value.isEmpty)
            }
        }
    }

    private func send() {
        guard !value.isEmpty else { return }
        // Emptied once taken; a press in the moment the card arrived is not taken, and the
        // words typed stay.
        if answer(.value(value)) { value = "" }
    }

    private func skip() {
        if answer(.value("")) { value = "" }
    }
}

/// The person's password on the gateway's machine, for a command the bot runs with sudo.
private struct SudoCard: View {
    let asked: ChatQuestions.Asked
    let command: String
    let bot: Bot
    let look: AvatarLook
    let gatewayName: String
    let answer: (QuestionAnswer) -> Bool
    @State private var value = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 10) {
            CardParts.header("key", "Admin password for \(gatewayName)", waits: asked.question.waits, since: asked.asked, theme)
            CardParts.well(theme) {
                VStack(alignment: .leading, spacing: 5) {
                    CardParts.code(command.isEmpty ? "(no command given)" : command, theme)
                    RequestedBy(bot: bot, look: look, place: "Runs on", gatewayName: gatewayName)
                }
            }
            SecretField(placeholder: "Password", value: $value, canReveal: false, submit: send)
            CardParts.note("shield", "Goes to \(gatewayName) for this command. Not kept in this app or this chat.", theme)
            if let problem = asked.problem {
                CardParts.note("exclamationmark.circle", problem, theme)
            }
            HStack {
                CardButton("Skip", style: .quiet) { skip() }
                Spacer()
                CardButton("Submit", style: .primary, action: send)
                    .disabled(value.isEmpty)
            }
        }
    }

    private func send() {
        guard !value.isEmpty else { return }
        // Emptied once taken; a press in the moment the card arrived is not taken, and the
        // words typed stay.
        if answer(.value(value)) { value = "" }
    }

    private func skip() {
        if answer(.value("")) { value = "" }
    }
}

/// App accounts to connect and MCP servers to install, one row each, as the connection card
/// mock-up drew it. What each row will run or contact, and where its sign-in opens, is shown
/// before anything is done; a sign-in opens in the browser only on a click, and only an https
/// address (or one on this Mac). A value a row asks for goes only into the move that sends it.
struct ConnectionCard: View {
    let asked: ChatQuestions.Asked
    let connection: ConnectionRequest
    let bot: Bot
    let look: AvatarLook
    let gatewayName: String
    let mayAct: () -> Bool
    let retry: (String) -> Bool
    let opened: (String) -> Void
    /// Every field each row has asked for while the card may be answered, kept by the
    /// gateway's `ConnectionMemory`.
    let askedFields: [String: [ConnectionTarget.Field]]
    /// What was typed into a row's plain field, kept by the chat while the card waits: it
    /// stays once sent (Hermes keeps none from an approval that still lacked a required
    /// value, so the next one sends it again), and over a switch of bot or a reconnect.
    let draft: (String, String) -> String?
    let setDraft: (String, String, String?) -> Void
    let clearDrafts: (String) -> Void
    let respond: (ConnectionAnswer) -> Bool
    /// What is typed into each row's secret fields, by row and field: only here, and emptied
    /// once sent or skipped, and when the card goes.
    @State private var secrets: [String: [String: String]] = [:]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        let theme = Theme(scheme)
        let targets = connection.targets
        let isDirectory = connection.suggested != nil && targets.isEmpty
        VStack(alignment: .leading, spacing: 10) {
            CardParts.header("link", title, waits: nil, since: asked.asked, until: connection.deadline, theme)
            RequestedBy(bot: bot, look: look, place: "On", gatewayName: gatewayName)
            if isDirectory {
                // The directory card: every app the gateway can connect. This app has no such list.
                CardParts.note("info.circle", "\(bot.title) wants to show the apps you can connect. Hermes Bot can't list them here yet; connect them in Hermes's own app, then press Continue.", theme)
                if let suggested = connection.suggested, !suggested.isEmpty {
                    CardParts.note("star", "Suggested: " + suggested.map { ShownText.visible($0, oneLine: true) }.joined(separator: ", "), theme)
                }
            }
            ForEach(targets) { target in
                row(target, theme)
            }
            if let problem = asked.problem {
                CardParts.note("exclamationmark.circle", problem, theme)
            }
            HStack(spacing: 8) {
                let open = targets.filter(isSkippable)
                if open.count > 1 {
                    CardButton("Skip all", style: .quiet) {
                        if respond(ConnectionAnswer(moves: Dictionary(open.map { ($0.name, .skip) }, uniquingKeysWith: { first, _ in first }))) {
                            secrets = [:]
                            for target in open { clearDrafts(target.name) }
                        }
                    }
                }
                Spacer()
                if !targets.isEmpty {
                    Text("\(targets.filter { $0.state == .connected }.count) of \(targets.count) ready")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
                // Quiet while rows are still open: it leaves them as they are.
                CardButton("Continue", style: isDirectory || connection.allResolved ? .primary : .plain) {
                    if respond(ConnectionAnswer(isContinue: true)) { secrets = [:] }
                }
                .help(isDirectory || connection.allResolved ? "Done here" : "Done here: the bot carries on with what is connected, and the rest is left")
            }
        }
        .disabled(asked.isMoving)
        .onDisappear { secrets = [:] }
    }

    private var title: String {
        let targets = connection.targets
        let kinds = Set(targets.map(\.kind))
        let one = targets.count == 1
        if targets.isEmpty || kinds == [.connector] { return one ? "Connect an app" : "Connect apps" }
        if kinds == [.mcp] { return one ? "Add an MCP server" : "Add MCP servers" }
        if kinds == [.plugin] { return one ? "Install a plugin" : "Install plugins" }
        if kinds == [.skill] { return one ? "Install a skill" : "Install skills" }
        if kinds.isSubset(of: [.plugin, .skill]) { return "Install plugins & skills" }
        if kinds.isSubset(of: [.connector, .mcp]) { return "Connect apps & servers" }
        return "Connect apps & add tools"
    }

    /// A slug as a name: `google_drive` as "Google Drive". Hosted apps come with no name of
    /// their own (only catalog rows do), as in Hermes's own card.
    static func title(of slug: String) -> String {
        let words = slug.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map { $0.lowercased() == "mcp" ? "MCP" : $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? slug : words.joined(separator: " ")
    }

    /// Every value the row has asked for while the card has been open.
    private func fields(of target: ConnectionTarget) -> [ConnectionTarget.Field] {
        ConnectionTarget.merged(askedFields[target.name] ?? [], with: target.fields)
    }

    private func name(of target: ConnectionTarget) -> String {
        ShownText.visible(target.title ?? Self.title(of: target.name), oneLine: true)
    }

    /// The person can still skip it: anything not done one way or the other.
    private func isSkippable(_ target: ConnectionTarget) -> Bool {
        ![.connected, .skipped, .notConnected].contains(target.state)
    }

    @ViewBuilder
    private func row(_ target: ConnectionTarget, _ theme: Theme) -> some View {
        let isDone = target.state == .connected || target.state == .skipped
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol(target))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(theme.raised, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.hairline))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: name(of: target))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(target.state == .skipped ? theme.secondaryText : theme.text)
                            .lineLimit(1)
                        if !isDone { CardParts.tag(kindLabel(target), theme) }
                    }
                    if !isDone {
                        Text(verbatim: subtitle(target))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if target.state == .connected {
                    Label(doneLabel(target), systemImage: target.caveat == nil ? "checkmark" : "exclamationmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text)
                } else if target.state == .skipped {
                    Text("Skipped").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                } else if isSkippable(target) {
                    CardButton("Skip", style: .quiet) {
                        if respond(ConnectionAnswer(moves: [target.name: .skip])) {
                            secrets[target.name] = nil
                            clearDrafts(target.name)
                        }
                    }
                    actionButton(target)
                }
            }
            if !isDone {
                details(target, theme)
            } else if target.state == .connected, let caveat = target.caveat {
                CardParts.note("exclamationmark.triangle", "Done, but \(caveat).", theme)
            }
        }
        .padding(isDone ? 8 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeBlock, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.hairline))
        .opacity(target.state == .skipped ? 0.7 : 1)
    }

    /// Fields are asked for where approving (or trying again) sends them.
    private func asksForValues(_ target: ConnectionTarget) -> Bool {
        guard target.kind != .connector, !fields(of: target).isEmpty, target.canBeApproved else { return false }
        return target.move == .approve || target.move == .retry
    }

    @ViewBuilder
    private func details(_ target: ConnectionTarget, _ theme: Theme) -> some View {
        if let description = target.description {
            Text(verbatim: ShownText.visible(description, oneLine: false, prose: true))
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let launch = target.launch {
            // What it will run or contact, where, and with which variables, as the gateway gives it.
            VStack(alignment: .leading, spacing: 4) {
                Text(launch.isRemote ? "Contacts" : "Runs")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                CardParts.well(theme) {
                    VStack(alignment: .leading, spacing: 3) {
                        CardParts.code(launch.target, theme, oneLine: launch.isRemote)
                        if let cwd = launch.cwd {
                            Text(verbatim: "In " + ShownText.visible(cwd, oneLine: true))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .textSelection(.enabled)
                        }
                        if !launch.env.isEmpty {
                            // Every name, however many: they are part of what is approved.
                            Text(verbatim: "With " + launch.env.map { ShownText.visible($0, oneLine: true) }.joined(separator: ", "))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        } else if target.kind == .mcp, target.move == .approve || target.move == .retry, !target.canBeApproved {
            CardParts.note("exclamationmark.triangle", "Hermes didn't say what this server would run, so it can't be added from here.", theme)
        }
        if let source = target.source {
            sourceLines(target, source, theme)
        }
        if !target.tools.isEmpty {
            let shown = target.tools.prefix(3).map { String(ShownText.visible($0, oneLine: true).prefix(40)) }.joined(separator: ", ")
            let more = target.tools.count > 3 ? " +\(target.tools.count - 3) more" : ""
            CardParts.note("wrench.and.screwdriver", "Adds: \(shown)\(more)", theme)
                .help(target.tools.prefix(50).map { String(ShownText.visible($0, oneLine: true).prefix(80)) }.joined(separator: "\n"))
        }
        if let scan = target.scan {
            CardParts.note("exclamationmark.triangle", "Security scan: \(scan)", theme)
        }
        if case .open(let url) = target.move {
            CardParts.note("globe", "Opens in your browser: \(ShownText.visible(url.host ?? "", oneLine: true))", theme)
            if target.state == .initiated, asked.opened.contains(target.name) {
                CardParts.note("hourglass", "Waiting for you to finish in your browser…", theme)
            }
        } else if target.hasUnopenableLink, target.state == .pending || target.state == .initiated {
            CardParts.note("exclamationmark.triangle", "Hermes Bot won't open this sign-in link: it isn't a secure web address.", theme)
        }
        if let detail = target.detail, target.state != .connected {
            CardParts.note(target.state == .failed || target.state == .expired ? "exclamationmark.triangle" : "info.circle", detail, theme)
        }
        if asksForValues(target) {
            ForEach(fields(of: target)) { field in
                fieldRow(target, field, theme)
            }
        }
    }

    @ViewBuilder
    private func sourceLines(_ target: ConnectionTarget, _ source: ConnectionTarget.Source, _ theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let repo = source.repo {
                let commit = source.sha.map { " @ " + String(ShownText.visible($0, oneLine: true).prefix(12)) } ?? ""
                let folder = source.subdir.map { " · " + ShownText.visible($0, oneLine: true) } ?? ""
                Text(verbatim: ShownText.visible(repo, oneLine: true) + commit + folder)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if target.kind == .plugin, source.pinnedCommit == nil {
                    CardParts.note("exclamationmark.triangle", "Hermes didn't give the exact commit, so it can't be installed from here.", theme)
                }
            } else if target.kind == .skill {
                Text(verbatim: "From the skills hub: " + ShownText.visible(target.name, oneLine: true))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                CardParts.note("exclamationmark.triangle", "Hermes didn't say where this comes from, so it can't be installed from here.", theme)
            }
            // The bot by its name, not its id on the gateway.
            let into = source.targetProfile.map { "Installs into \($0 == bot.name ? bot.title : ShownText.visible($0, oneLine: true))" }
            let platforms = source.platforms.isEmpty ? nil : "For " + source.platforms.map(Self.platform).joined(separator: ", ")
            let line = [into, platforms].compactMap { $0 }.joined(separator: " · ")
            if !line.isEmpty {
                Text(verbatim: line)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
        }
    }

    /// A platform as people write it.
    static func platform(_ name: String) -> String {
        switch name.lowercased() {
        case "macos", "darwin": "macOS"
        case "linux": "Linux"
        case "windows", "win32": "Windows"
        default: ShownText.visible(name, oneLine: true)
        }
    }

    @ViewBuilder
    private func fieldRow(_ target: ConnectionTarget, _ field: ConnectionTarget.Field, _ theme: Theme) -> some View {
        let label = ShownText.visible(field.name, oneLine: true)
        let prompt = field.prompt.map { ShownText.visible($0, oneLine: true) }
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: label)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer()
                Text(field.isSecret ? (field.isRequired ? "Required · secret, not kept in this app or chat" : "Optional · secret, not kept in this app or chat")
                     : field.isRequired ? "Required" : "Optional")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            if field.isSecret {
                SecretField(placeholder: prompt ?? "Paste value for \(label)", value: binding(target, field), canReveal: true, submit: {})
            } else {
                TextField(prompt ?? label, text: binding(target, field))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(theme.composer, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.hairline))
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ target: ConnectionTarget) -> some View {
        switch target.move {
        case .none:
            // A link refused here is said so in the row; nothing is under way to show.
            if !target.hasUnopenableLink {
                Text(workingLabel(target))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme(scheme).secondaryText)
            }
        case .open(let url):
            CardButton(asked.opened.contains(target.name) ? "Open again ↗" : openLabel(target), style: .primary) {
                // A click, not in the moment the card came, and only an address checked as safe.
                guard mayAct() else { return }
                opened(target.name)
                openURL(url)
            }
            .help(url.absoluteString)
        case .approve:
            if target.canBeApproved {
                CardButton(approveLabel(target), style: .primary) { approve(target) }
                    .disabled(!isFilled(target))
            }
        case .retry:
            CardButton("Retry", style: .primary) {
                if target.retriesByReissue {
                    // A sign-in is minted afresh by the gateway; its link is opened only on a click.
                    _ = retry(target.name)
                } else {
                    approve(target)
                }
            }
            .disabled(!target.retriesByReissue && (!target.canBeApproved || !isFilled(target)))
        }
    }

    /// What has been typed into a field: a secret here, anything else as the chat keeps it.
    private func typed(_ target: ConnectionTarget, _ field: ConnectionTarget.Field) -> String? {
        field.isSecret ? secrets[target.name]?[field.name] : draft(target.name, field.name)
    }

    private func isFilled(_ target: ConnectionTarget) -> Bool {
        !fields(of: target).contains { $0.isRequired && !$0.isFilled(typed: typed(target, $0)) }
    }

    /// Approves a row (or runs it again) with every value it has asked for: the one rule for
    /// what is sent is the field's own (`Field.value(typed:)`), so a secret's default never
    /// goes. A plugin is pinned to the commit the card showed. Plain values stay in their
    /// fields for a later approval; secrets are emptied once sent.
    private func approve(_ target: ConnectionTarget) {
        var sent: [String: String] = [:]
        for field in fields(of: target) {
            let value = field.value(typed: typed(target, field))
            if !value.isEmpty { sent[field.name] = value }
        }
        if target.kind == .plugin, let commit = target.source?.pinnedCommit { sent["ref"] = commit }
        if respond(ConnectionAnswer(moves: [target.name: .approve(values: sent)])) { secrets[target.name] = nil }
    }

    private func approveLabel(_ target: ConnectionTarget) -> String {
        switch target.action {
        case .install: "Install"
        case .enable: "Enable"
        case .authorize: "Authorize"
        case .reconnect, .connect: "Connect"
        }
    }

    private func openLabel(_ target: ConnectionTarget) -> String {
        target.action == .install || target.action == .enable ? "Open in browser ↗" : "Open sign-in ↗"
    }

    /// What a row with nothing to do says: the gateway is at work on it.
    private func workingLabel(_ target: ConnectionTarget) -> String {
        if target.state == .pending { return "Getting the sign-in link…" }
        return switch target.action {
        case .install: "Installing…"
        case .enable: "Enabling…"
        case .authorize: "Authorizing…"
        case .connect, .reconnect: "Connecting…"
        }
    }

    private func binding(_ target: ConnectionTarget, _ field: ConnectionTarget.Field) -> Binding<String> {
        Binding {
            field.value(typed: typed(target, field))
        } set: { value in
            if field.isSecret { secrets[target.name, default: [:]][field.name] = value } else { setDraft(target.name, field.name, value) }
        }
    }

    private func symbol(_ target: ConnectionTarget) -> String {
        switch target.kind {
        case .connector: "app.badge"
        case .mcp: "server.rack"
        case .plugin: "puzzlepiece.extension"
        case .skill: "sparkles"
        }
    }

    private func kindLabel(_ target: ConnectionTarget) -> String {
        let kind = switch target.kind {
        case .connector: "Hosted app"
        case .mcp: "MCP server"
        case .plugin: "Plugin"
        case .skill: "Skill"
        }
        let tier: String? = switch target.tier {
        case .official: "Official"
        case .verified: "Verified"
        case .community: "Community"
        case nil: nil
        }
        return tier.map { "\($0) · \(kind)" } ?? kind
    }

    private func subtitle(_ target: ConnectionTarget) -> String {
        switch target.state {
        case .connected: return kindLabel(target)
        case .skipped: return "Skipped"
        case .expired: return "The sign-in ran out of time"
        case .notConnected: return "Not connected"
        case .failed: return "Didn't work"
        case .pending, .initiated:
            return switch target.action {
            case .connect: "Connect your account"
            case .reconnect: "Sign in again"
            case .authorize: "Authorize on \(gatewayName)"
            case .install: "Install on \(gatewayName)"
            case .enable: "Enable on \(gatewayName)"
            }
        }
    }

    private func doneLabel(_ target: ConnectionTarget) -> String {
        switch target.action {
        case .install: "Installed"
        case .enable: "Enabled"
        case .authorize: "Authorized"
        case .connect, .reconnect: "Connected"
        }
    }
}

/// "Requested by [face] Bot · Saved on Gateway"
private struct RequestedBy: View {
    let bot: Bot
    let look: AvatarLook
    let place: String
    let gatewayName: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: 5) {
            Text("Requested by").foregroundStyle(theme.secondaryText)
            BotAvatar(look, size: 13)
            Text(bot.title).foregroundStyle(theme.text)
            Text("·").foregroundStyle(theme.secondaryText)
            Text(place).foregroundStyle(theme.secondaryText)
            Text(gatewayName).foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
    }
}

/// The line a question leaves in the chat once it is over: what was decided and about what,
/// never anything typed into a secret.
struct QuestionLine: View {
    let asked: ChatQuestions.Asked
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        if case .settled(let ending) = asked.state {
            HStack(spacing: 5) {
                switch ending.mark {
                case .allowed: Image(systemName: "checkmark")
                case .denied: Image(systemName: "xmark")
                case .timedOut: Image(systemName: "clock")
                case .none: EmptyView()
                }
                Text(verbatim: ShownText.visible(ending.text, oneLine: true, prose: true))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = ending.detail {
                    Text("·")
                    Text(verbatim: ShownText.visible(detail, oneLine: true))
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let quote = ending.quote {
                    Text(verbatim: "— “\(ShownText.visible(quote, oneLine: true, prose: true))”")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .help(ending.detail.map { ShownText.visible($0, oneLine: true) } ?? "")
        }
    }
}

/// A bot's clarifying questions, one at a time, in a panel docked over the message box, as
/// a coding assistant asks its questions. A choice is picked by a
/// click or by its number while the message box is empty; words typed in the message box
/// are the answer instead. Return answers the question showing and moves on, and the
/// whole set goes once the last is answered.
struct ClarifyPanel: View {
    let asked: ChatQuestions.Asked
    let clarify: Clarify
    let bot: Bot
    let questions: ChatQuestions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        let progress = questions.progress(of: asked)
        let place = min(progress.place, clarify.questions.count - 1)
        let question = clarify.questions[place]
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(bot.title) asks")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                if let waits = asked.question.waits {
                    Countdown(until: asked.asked.addingTimeInterval(Double(waits.components.seconds)))
                }
                WhenHovered { isHovered in
                    Button { questions.answer(asked.instance, with: .skipped, for: bot) } label: {
                        Text("Cancel")
                            .font(.system(size: 12.5))
                            .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .help(clarify.questions.count > 1 ? "Answer none of these (Escape)" : "Don't answer (Escape)")
                if clarify.questions.count > 1 {
                    Menu {
                        ForEach(Array(clarify.questions.enumerated()), id: \.element.id) { index, each in
                            Button {
                                questions.go(to: index, in: asked.instance)
                            } label: {
                                let mark = progress.answers[each.id] != nil ? "✓ " : ""
                                Text(verbatim: "\(index + 1). \(mark)\(ShownText.visible(each.text, oneLine: true, prose: true))")
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(place + 1)/\(clarify.questions.count)")
                                .font(.system(size: 12.5).monospacedDigit())
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(theme.secondaryText)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("All the questions")
                    .accessibilityLabel("Question \(place + 1) of \(clarify.questions.count)")
                }
            }
            ScrollView(.vertical) {
                Text(verbatim: ShownText.visible(question.text, oneLine: false, prose: true))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            if !question.choices.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                            row(question, index, choice, isOn: progress.picked[question.id, default: []].contains(index), theme)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = asked.problem {
                CardParts.note("exclamationmark.circle", problem, theme)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        // The message box sits over the panel's lower edge.
        .padding(.bottom, 14 + ClarifyPanel.underlap)
        .background(theme.bubble, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20).strokeBorder(theme.hairline))
        .padding(.horizontal, 14)
        .disabled(asked.state != .open)
        .opacity(asked.state == .answering ? 0.6 : 1)
        .onAppear { questions.shown(asked.instance) }
    }

    /// How far the message box covers the panel's lower edge.
    static let underlap: CGFloat = 22

    private func row(_ question: Clarify.Question, _ index: Int, _ choice: String, isOn: Bool, _ theme: Theme) -> some View {
        // A choice's first line is its title; lines after it, where Hermes gives any, say more.
        let bare = Clarify.bare(choice)
        let lines = bare.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = ShownText.visible(String(lines.first ?? ""), oneLine: true, prose: true)
        let more = lines.count > 1 ? ShownText.visible(String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines), oneLine: false, prose: true) : ""
        return WhenHovered { isHovered in
            Button { questions.toggle(index, in: asked.instance) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: question.multiSelect ? (isOn ? "checkmark.square.fill" : "square") : (isOn ? "largecircle.fill.circle" : "circle"))
                        .font(.system(size: 13))
                        .foregroundStyle(isOn ? theme.text : theme.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.text)
                        if !more.isEmpty {
                            Text(more)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if choice.hasSuffix("(Recommended)") {
                        CardParts.tag("Recommended", theme)
                    }
                    if index < 9 {
                        Text("\(index + 1)")
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isOn ? theme.chosen : isHovered ? theme.hover : theme.composer, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.hairline))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Text a bot or the gateway gave, made safe to show: characters that turn the direction of
/// what follows, or hide, are written out as their code (⟨U+202E⟩) rather than acted on, so
/// a command or a name reads as it will act. Other control characters too; and where a thing
/// is one line (a folder, a site, a name), a line break is shown as ⏎. What is sent to the
/// gateway is never changed.
enum ShownText {
    /// `prose` is a person's or a bot's sentences, where the joiners and breaks that writing
    /// systems and emoji need are kept; anywhere else (a command, a path, a name) they are
    /// written out, since they hide.
    static func visible(_ text: String, oneLine: Bool, prose: Bool = false) -> String {
        var shown = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09:
                shown.unicodeScalars.append(scalar)
            case 0x0A where !oneLine:
                shown.unicodeScalars.append(scalar)
            case 0x2028...0x2029 where !oneLine:
                shown += "\n"
            case 0x0A, 0x0D, 0x2028, 0x2029:
                shown += "⏎"
            case 0x200B...0x200D where prose:
                // Joins the parts of an emoji, or letters in Persian and Indic scripts.
                shown.unicodeScalars.append(scalar)
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0x061C, 0xFEFF, 0x00AD:
                shown += String(format: "⟨U+%04X⟩", scalar.value)
            case 0x00...0x1F, 0x7F...0x9F:
                shown += String(format: "⟨U+%04X⟩", scalar.value)
            default:
                shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }
}
