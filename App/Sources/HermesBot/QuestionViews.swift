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
    static func header(_ symbol: String, _ title: String, waits: Duration?, since: Date, _ theme: Theme) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 14)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
            Spacer(minLength: 8)
            if let waits {
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
        Text(text)
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
                    .overlay(Capsule().strokeBorder(style == .primary ? .clear : theme.hairline))
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
            let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
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
