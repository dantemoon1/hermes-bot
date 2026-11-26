import HermesKit
import SwiftUI

/// A slash command offered in the message box. The list is ours, chosen and worded for a
/// bot's one chat; a command is offered only where the gateway lists it too.
struct SlashCommand: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case model = "Model and effort"
        case conversation = "This conversation"
        case information = "Information"
        case teaching = "Teaching"
        case approvals = "Approvals"
    }

    let name: String
    /// What may follow the name, as the menu shows it.
    let hint: String
    let about: String
    let group: Group
    /// Return in the menu puts the name in the box to type after, rather than running it.
    var waitsForWords = false
    /// Means nothing without words after it, so run bare it is only put in the box.
    var needsWords = false

    var id: String { name }

    /// What it prints is shown in a card, being something to read rather than a change:
    /// the Information group, the skill changes waiting, and the approval mode asked for bare.
    func isReadout(_ words: String) -> Bool {
        group == .information || name == "skills" || (name == "approvals" && words.isEmpty)
    }

    /// Every command the menu can offer, in its order. Nothing here is about other chats or
    /// sessions (`/new`, `/resume`, `/branch`): a bot has one chat.
    static let all: [SlashCommand] = [
        .init(name: "model", hint: "[name]", about: "Switch this bot's model", group: .model),
        .init(name: "reasoning", hint: "[off | low | medium | high | xhigh]", about: "Set how hard it thinks", group: .model, waitsForWords: true),
        .init(name: "fast", hint: "[on | off]", about: "Toggle faster replies", group: .model),
        .init(name: "personality", hint: "[name]", about: "View or change its tone", group: .model, waitsForWords: true),
        .init(name: "retry", hint: "", about: "Ask for the last answer again", group: .conversation),
        .init(name: "undo", hint: "[count]", about: "Take back the last exchange", group: .conversation),
        .init(name: "compress", hint: "", about: "Summarise earlier chat to free up context", group: .conversation),
        .init(name: "btw", hint: "<question>", about: "Ask a side question that stays out of the chat", group: .conversation, waitsForWords: true, needsWords: true),
        .init(name: "stop", hint: "", about: "Stop the current reply", group: .conversation),
        .init(name: "status", hint: "", about: "Show the model, approvals and session", group: .information),
        .init(name: "context", hint: "", about: "Show how much of the context window is used", group: .information),
        .init(name: "usage", hint: "", about: "Show tokens used and rate limits", group: .information),
        .init(name: "insights", hint: "[days]", about: "Show a summary of recent activity", group: .information),
        .init(name: "goal", hint: "[goal]", about: "Set or check a goal it works on across turns", group: .teaching, waitsForWords: true),
        .init(name: "learn", hint: "<what to learn from>", about: "Make a skill from something you describe", group: .teaching, waitsForWords: true, needsWords: true),
        .init(name: "refine", hint: "[focus]", about: "Save lessons from this chat to memory and skills", group: .teaching, waitsForWords: true),
        .init(name: "skills", hint: "[pending | approve | reject | diff]", about: "Review skill changes waiting for you", group: .teaching),
        .init(name: "plan", hint: "[task]", about: "Write a plan without carrying it out", group: .teaching, waitsForWords: true),
        .init(name: "approvals", hint: "[manual | smart | off]", about: "Show or change when it asks first", group: .approvals),
        .init(name: "yolo", hint: "[on | off]", about: "Stop asking before risky actions, in this chat", group: .approvals, waitsForWords: true),
    ]

    /// Listed by a gateway whose session authority handles chats, and refused there through
    /// `slash.exec` (Hermes's `gateway/session_commands.py`), so not offered.
    static let refusedBySessionAuthority: Set<String> = ["undo", "retry", "compress"]

    /// The commands the menu shows for what is typed: while the box holds a slash and the
    /// start of a name, the commands offered whose names begin with it. Nil when the menu
    /// is not wanted: no slash at the start, words after the name, a second slash (a path),
    /// or nothing that begins so.
    static func matching(_ typed: String, offered: Set<String>) -> [SlashCommand]? {
        guard typed.hasPrefix("/") else { return nil }
        let start = typed.dropFirst().lowercased()
        guard !start.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        let found = all.filter { offered.contains($0.name) && $0.name.hasPrefix(start) }
        return found.isEmpty ? nil : found
    }

    /// The command what was typed runs, with the words after its name, when it is one the
    /// gateway offers. Anything else is a message, as before there were commands.
    static func parse(_ typed: String, offered: Set<String>) -> (command: SlashCommand, words: String)? {
        // The slash first, as the menu wants it: "  /compress" is words.
        guard typed.hasPrefix("/") else { return nil }
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // The name ends where Hermes would end it. Straight after the slash, only the hidden
        // joiner this app writes there (`unbroken`) is passed over, so a command copied from
        // a note runs; "/ undo" is words, as the menu takes it.
        let rest = typed.dropFirst().drop { $0 == "\u{2060}" }
        let raw = rest.prefix { !isSeparator($0) }
        let name = raw.lowercased()
        guard !name.isEmpty, offered.contains(name), let command = all.first(where: { $0.name == name }) else { return nil }
        let words = rest.dropFirst(raw.count).drop(while: isSeparator)
        return (command, String(words).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What Hermes might take for a space: whitespace, and control characters (Python's
    /// `split` takes some of those for spaces too, and the rest are no part of a word).
    static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// The words after a name, split wherever Hermes might split them and lower-cased: for
    /// the commands whose words are checked here and sent on only in a form written out by
    /// this app.
    static func tokens(_ words: String) -> [String] {
        words.split(whereSeparator: isSeparator).map { $0.lowercased() }
    }

    /// A model of the providers on offer, by its name as typed: on the bot's own provider
    /// first, then on the first that has it. Capitals make no difference.
    static func model(named name: String, in options: ModelOptions, preferring provider: String?) -> ModelChoice? {
        let found = options.providers.compactMap { offer in
            offer.models.first { $0.caseInsensitiveCompare(name) == .orderedSame }.map { ModelChoice(provider: offer.slug, model: $0) }
        }
        return found.first { $0.provider == provider } ?? found.first
    }

    /// How hard to think, as typed: Hermes's own words, and "off" and "extra high" as the
    /// Reasoning menu says them.
    static func reasoning(_ word: String) -> ReasoningLevel? {
        switch word.lowercased() {
        case "off": .off
        case "extra high", "extra-high": .xhigh
        default: ReasoningLevel(word: word)
        }
    }

    /// What a command printed, without the terminal's colour codes or blank lines around
    /// it. The first line keeps its indent, as the rest do: readouts line up by spaces.
    static func plain(_ text: String) -> String {
        let lines = text.replacing(/\u{1B}\[[0-9;?]*[ -\/]*[@-~]/, with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/\s+$/, with: "") }
        let start = lines.firstIndex { !$0.isEmpty } ?? lines.endIndex
        let end = lines.lastIndex { !$0.isEmpty }.map { $0 + 1 } ?? start
        return lines[start..<max(start, end)].joined(separator: "\n")
    }

    /// A command written so that it never breaks across lines after its slash.
    static func unbroken(_ line: String) -> String {
        line.replacingOccurrences(of: "/", with: "/\u{2060}")
    }
}

/// Something a slash command left in the chat, here in this window only.
struct ChatNote: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A centred grey line, for a command that changed something.
        case line
        /// A quiet card with what a command printed.
        case readout
        /// An answer on the side (`/btw`), apart from the chat.
        case aside(question: String)
    }

    let id: Int
    var kind: Kind
    /// The command as it was run.
    let asked: String
    /// Shown after this item of the chat. Nil: before everything, the chat having been
    /// empty when it ran. An item no longer shown: at the end.
    var after: TranscriptItem.ID?
    /// How it went. Nil while it is still running.
    var text: String?
}

/// A command that waits for the person to agree, asked in an alert.
struct CommandConfirm {
    let title: String
    let message: String
    /// The button that agrees.
    let action: String
    let run: @MainActor () -> Void
    var cancel: @MainActor () -> Void = {}
}

/// The commands are told apart from messages only by name: the gateway is never asked to
/// run anything it was not offered for.
extension ChatModel {
    /// Sends what is typed, or runs it when it is a command the gateway offers. Typed
    /// before the gateway's list has come, a command of ours waits for it.
    func submit(to bot: Bot, through roster: RosterModel) {
        let everything = Set(SlashCommand.all.map(\.name))
        if !roster.commandsKnown, phase == .loaded, let early = SlashCommand.parse(draft, offered: everything) {
            // A change to approvals is not left waiting, where something typed meanwhile could
            // go first: it stays in the box, said, for the person to send again.
            guard !["yolo", "approvals"].contains(early.command.name) else {
                Task { await roster.readCommands() }
                return finish(addNote(.line, asked: draft), "This gateway's commands are still being read. Send it again in a moment.")
            }
            let typed = draft
            let visit = leaves
            Task {
                await roster.readCommands()
                // Typed over meanwhile, the chat left, or the gateway: what is in the box now
                // is the person's.
                guard draft == typed, leaves == visit, !isAbandoned else { return }
                // Not known after all: what was meant as a command is not sent as a message.
                guard roster.commandsKnown else {
                    return finish(addNote(.line, asked: typed), "Couldn't find out which commands this gateway offers. Try again in a moment.")
                }
                submitNow(to: bot, through: roster)
            }
            return
        }
        submitNow(to: bot, through: roster)
    }

    private func submitNow(to bot: Bot, through roster: RosterModel) {
        guard phase == .loaded, let (command, words) = SlashCommand.parse(draft, offered: roster.offeredCommands) else {
            send(to: bot, through: roster)
            return
        }
        run(command, words, for: bot, through: roster)
    }

    func run(_ command: SlashCommand, _ words: String, for bot: Bot, through roster: RosterModel) {
        let line = words.isEmpty ? "/\(command.name)" : "/\(command.name) \(words)"
        if command.needsWords, words.isEmpty {
            draft = line + " "
            focus()
            return
        }
        let typed = draft
        let visit = leaves
        let tokens = SlashCommand.tokens(words)
        switch command.name {
        case "model" where words.isEmpty:
            draft = ""
            if roster.cannotPickModel {
                finish(addNote(.line, asked: line), "This gateway doesn't let this app change a bot's model.")
            } else {
                roster.showDetails(pickingModel: true)
            }
        case "reasoning" where words.isEmpty:
            draft = ""
            if roster.cannotSetReasoning {
                finish(addNote(.line, asked: line), "This gateway doesn't let this app change how hard a bot thinks.")
            } else {
                roster.showDetails(pickingModel: false)
            }
        case "model": chooseModel(named: words, line, visit: visit, for: bot, through: roster)
        case "reasoning": think(words, line, for: bot, through: roster)
        case "stop":
            draft = ""
            if canStop { stop(bot) } else { finish(addNote(.line, asked: line), "\(bot.title) isn't working on anything.") }
        case "btw": askAside(words, line, for: bot, through: roster)
        // The approval commands go on only in a form written out here, so that what the person
        // agreed to, or was not asked about, is exactly what Hermes reads.
        case "yolo" where tokens == ["off"]:
            draft = ""
            skipApprovals(false, "/yolo off", for: bot, through: roster)
        case "yolo" where (tokens.isEmpty || tokens == ["on"]) && !roster.yoloKeptToOneChat:
            // An older Hermes could take the chat for no chat at all and skip approvals in every
            // one. What was read with the list may only have been a failed look at the version,
            // so it is asked again before the gateway is said to be old; the box keeps the
            // command meanwhile.
            Task {
                let kept = await roster.keepsYoloToOneChat()
                // Typed over meanwhile, the chat left, or the gateway: what is in the box now is the person's.
                guard draft == typed, leaves == visit, !isAbandoned else { return }
                if kept { return run(command, words, for: bot, through: roster) }
                draft = ""
                finish(addNote(.line, asked: line), "This gateway's Hermes is older than 0.21.6, where \(SlashCommand.unbroken("/yolo")) could turn approvals off for every chat it runs. Update Hermes to use it here.")
            }
        case "yolo" where tokens.isEmpty || tokens == ["on"]:
            // Never on a bare Return: the box keeps the command until the person agrees.
            ask(visit, CommandConfirm(
                title: "Turn off approvals for \(bot.title)?",
                message: Self.yoloWarning(bot.title),
                action: "Turn Off Approvals"
            ) { [weak self] in
                guard let self, !isAbandoned else { return }
                if messageDraft == typed { messageDraft = "" }
                skipApprovals(true, "/yolo", for: bot, through: roster)
            })
        case "yolo":
            draft = ""
            finish(addNote(.line, asked: line), "\(SlashCommand.unbroken("/yolo")) takes on or off.")
        case "approvals" where tokens == ["off"]:
            ask(visit, CommandConfirm(
                title: "Turn off approvals for \(bot.title)?",
                message: "\(bot.title) will run commands and make changes without asking you first. This is saved on \(bot.title) and lasts until approvals are turned back on.",
                action: "Turn Off Approvals"
            ) { [weak self] in
                guard let self, !isAbandoned else { return }
                if messageDraft == typed { messageDraft = "" }
                execute(command, "/approvals off", words: "off", for: bot, through: roster)
            })
        case "approvals" where tokens.count <= 1 && Set(["manual", "smart"]).isSuperset(of: tokens):
            draft = ""
            execute(command, (["/approvals"] + tokens).joined(separator: " "), words: tokens.first ?? "", for: bot, through: roster)
        case "approvals":
            draft = ""
            finish(addNote(.line, asked: line), "\(SlashCommand.unbroken("/approvals")) takes manual, smart or off.")
        // Only what Hermes's own app lets `/skills` do: review changes waiting. The rest of
        // it (search, install) belongs to the terminal.
        case "skills" where tokens.isEmpty || ["pending", "approve", "reject", "diff"].contains(tokens[0]):
            draft = ""
            // The subcommand as Hermes names it; what follows (a skill or a change) as typed.
            let given = words.split(whereSeparator: SlashCommand.isSeparator).map(String.init)
            execute(command, (["/skills", tokens.first ?? "pending"] + given.dropFirst()).joined(separator: " "), words: words, for: bot, through: roster)
        case "skills":
            draft = ""
            finish(addNote(.line, asked: line), "Here \(SlashCommand.unbroken("/skills")) reviews skill changes: pending, approve, reject or diff.")
        default:
            draft = ""
            execute(command, line, words: words, for: bot, through: roster)
        }
    }

    /// Asks the person to agree, unless something else is being asked already: one alert at
    /// a time, and the one showing is never replaced.
    /// Not once the chat has been left since the command was typed (`visit`): coming back
    /// to it must not bring up a question prepared meanwhile.
    @discardableResult
    private func ask(_ visit: Int, _ confirm: CommandConfirm) -> Bool {
        guard confirming == nil, leaves == visit, !isAbandoned else { return false }
        confirming = confirm
        return true
    }

    /// The chat open on the gateway, for a command to run in: as it is open for sending, or
    /// opened now, with the connection it is open on. Not while a message is opening it, and
    /// one command's opening is waited for by the next, so there are never two live chats.
    /// Never for a gateway other than this chat's: one left meanwhile ends it here.
    private func opened(_ bot: Bot, through roster: RosterModel) async throws -> (GatewayClient, LiveChat) {
        guard !isAbandoned else { throw CancellationError() }
        let opening: Task<(GatewayClient, LiveChat), any Error>
        if let joined = commandOpen {
            opening = joined
        } else {
            guard !isOpeningChat else { throw StillOpening() }
            opening = Task { () -> (GatewayClient, LiveChat) in
                let client = try await roster.liveClient()
                guard !self.isAbandoned else { throw CancellationError() }
                let current = roster.bots.first { $0.id == bot.id } ?? bot
                return (client, try await self.liveChat(of: current, on: client, through: roster))
            }
            commandOpen = opening
        }
        defer { if commandOpen == opening { commandOpen = nil } }
        let open = try await opening.value
        // For every caller, the one who opened it and any who waited on it.
        guard !isAbandoned else { throw CancellationError() }
        return open
    }

    private struct StillOpening: Error {}
    private struct OldHermes: Error {}

    /// Does `work` in the open chat. A chat the gateway has let go of meanwhile (an idle one
    /// it closed, "session not found") is let go of here too and opened again, once: without
    /// that every command would go on naming it and failing.
    private func inChat<T>(_ bot: Bot, through roster: RosterModel, _ work: (GatewayClient, LiveChat) async throws -> T) async throws -> T {
        let (client, open) = try await opened(bot, through: roster)
        do {
            return try await work(client, open)
        } catch GatewayError.rejected(code: 4001, _) where !isWorking {
            letGo(of: open)
            let (client, open) = try await opened(bot, through: roster)
            return try await work(client, open)
        }
    }

    /// Runs a command in the chat with Hermes's own `slash.exec`, and shows what came of it.
    /// Runs a change to approvals after any asked for before it, and holds every message
    /// from now until it has been answered.
    /// What the alert before `/yolo` says. `/yolo off` only ends this chat's skipping of
    /// approvals: a bot whose own mode is off still does not ask.
    static func yoloWarning(_ title: String) -> String {
        "\(title) will run commands and make changes without asking you first, in this chat. \(SlashCommand.unbroken("/yolo off")) ends that for this chat, and then \(title)'s own approval mode applies again."
    }

    private func changeApprovals(_ work: @escaping @MainActor () async -> Void) {
        approvalsChanging += 1
        let earlier = approvalQueue
        approvalQueue = Task {
            await earlier?.value
            await work()
            approvalsChanging -= 1
        }
    }

    private func execute(_ command: SlashCommand, _ line: String, words: String, for bot: Bot, through roster: RosterModel) {
        let note = addNote(.line, asked: line)
        // A change to approvals holds every message until the gateway has answered for it,
        // and goes after any change before it.
        if command.name == "approvals", !words.isEmpty {
            roster.approvalsChangedInChat()
            changeApprovals { [weak self] in
                defer { roster.approvalsChangedInChat() }
                await self?.perform(command, line, words: words, note: note, for: bot, through: roster)
            }
        } else {
            Task { await perform(command, line, words: words, note: note, for: bot, through: roster) }
        }
    }

    private func perform(_ command: SlashCommand, _ line: String, words: String, note: Int, for bot: Bot, through roster: RosterModel) async {
            do {
                // As long as Hermes's own client gives a compression: it answers once the summary is written.
                let outcome = try await inChat(bot, through: roster) { client, open in
                    try await client.runCommand(line, in: open, profile: bot.name, wait: command.name == "compress" ? .seconds(660) : .seconds(120))
                }
                guard !isAbandoned else { return }
                switch outcome {
                case .said(let text, let warning):
                    let said = [SlashCommand.plain(text), warning.map(SlashCommand.plain) ?? ""].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    finish(note, said.isEmpty ? "Done." : said, asCard: !said.isEmpty && command.isReadout(words))
                    // A change may have changed the chat too, as /compress does. Not the approval
                    // mode, whose hold on sending must not wait for an answer under way to end.
                    if !command.isReadout(words), command.name != "approvals" { await reload(bot, through: roster) }
                case .send(let message, let notice):
                    if let notice { finish(note, SlashCommand.plain(notice)) } else { dismissNote(note) }
                    // What /retry took out goes from the screen before it is asked again; if the
                    // chat could not be read, it is not asked, and the words wait in the box.
                    let shown = await reload(bot, through: roster)
                    guard !isAbandoned else { return }
                    guard shown else {
                        putAhead(message)
                        return finish(addNote(.line, asked: line), "Couldn't read the chat again, so this wasn't sent. Send it once the chat is up to date.")
                    }
                    // Sent as the person's next message, or left in the box when that can't be now.
                    if !send(to: bot, through: roster, words: message) {
                        putAhead(message)
                        // Held for a change to approvals is said as that, not as the bot being busy.
                        finish(addNote(.line, asked: line), approvalsHeld ? Self.heldForApprovals : "\(bot.title) is busy. Send this when it has finished.")
                    }
                case .prefill(let message, let notice):
                    // Said once the chat shows it: the words come back as what they replace goes.
                    await reload(bot, through: roster)
                    guard !isAbandoned else { return }
                    putAhead(message)
                    finish(note, notice.map(SlashCommand.plain) ?? "Done.")
                    focus()
                }
            } catch {
                finish(note, problem(error, line, bot, roster))
            }
    }

    /// Reads the stored chat again after a command that changed it: once any answer under
    /// way has settled (a read then would be given up), and after the roster, since a
    /// command can move the chat on to a new id or start it.
    /// True when it was read and put on screen.
    @discardableResult
    private func reload(_ bot: Bot, through roster: RosterModel) async -> Bool {
        await settled()
        guard !isAbandoned else { return false }
        let refreshed = await roster.refreshBots()
        guard !isAbandoned else { return false }
        let current = roster.bots.first { $0.id == bot.id } ?? bot
        let before = shows
        await load(current, from: roster)
        // Read from the gateway: a bot the roster knows no chat for has nothing to read, and
        // an empty chat put on screen for it is not the chat as stored.
        return refreshed && current.chat != nil && shows > before
    }

    private func askAside(_ question: String, _ line: String, for bot: Bot, through roster: RosterModel) {
        draft = ""
        let note = addNote(.aside(question: question), asked: line)
        Task {
            do {
                let answer = try await inChat(bot, through: roster) { client, open in
                    try await client.askAside(question, in: open, profile: bot.name)
                }
                finish(note, answer.isEmpty ? "No answer came back." : answer)
            } catch {
                finish(note, problem(error, line, bot, roster))
            }
        }
    }

    /// `/yolo`: says only what Hermes says changed, this chat's skipping of approvals. The
    /// bot's own approval mode (`/approvals`) is another thing, and may still be off.
    private func skipApprovals(_ skipped: Bool, _ line: String, for bot: Bot, through roster: RosterModel) {
        let note = addNote(.line, asked: line)
        changeApprovals { [weak self] in
            guard let self else { return }
            do {
                let off = try await inChat(bot, through: roster) { client, opened in
                    // Asked of the server the write goes to, now, not as it was when the list
                    // was read: it may have been put back to an older Hermes since.
                    if skipped, !GatewayClient.keepsYoloToOneChat(version: await client.hermesVersion()) { throw OldHermes() }
                    let open = try await reopened(opened, of: roster.bots.first { $0.id == bot.id } ?? bot, on: client, through: roster)
                    return try await client.setApprovalsSkipped(skipped, in: open, profile: bot.name)
                }
                finish(note, off
                    ? "Approvals are skipped in this chat: \(bot.title) won't ask before risky actions. Send \(SlashCommand.unbroken("/yolo off")) to stop."
                    : "Approvals are no longer skipped in this chat.")
            } catch {
                finish(note, problem(error, line, bot, roster))
            }
        }
    }

    /// `/model <name>`, saved on the bot as the model picker saves it.
    private func chooseModel(named name: String, _ line: String, visit: Int, for bot: Bot, through roster: RosterModel) {
        draft = ""
        let note = addNote(.line, asked: line)
        Task {
            guard let options = await roster.modelOptions(for: bot), !isAbandoned else {
                return finish(note, roster.cannotPickModel
                    ? "This gateway doesn't let this app change a bot's model."
                    : "Couldn't read the models this gateway offers. Try again in a moment.")
            }
            let own = options.current?.provider ?? bot.provider.map { options.listed(ModelChoice(provider: $0, model: "")).provider }
            guard let choice = SlashCommand.model(named: name, in: options, preferring: own) else {
                return finish(note, "No model called “\(name)” on the providers this gateway is signed in to.")
            }
            await saveModel(choice, note, confirmed: false, visit: visit, for: bot, through: roster)
        }
    }

    private func saveModel(_ choice: ModelChoice, _ note: Int, confirmed: Bool, visit: Int, for bot: Bot, through roster: RosterModel) async {
        // Not for a gateway this chat no longer belongs to: the bot there may share the name.
        guard !isAbandoned else { return }
        switch await roster.setModel(choice, for: bot, confirmed: confirmed) {
        case .saved:
            finish(note, "Model set to \(choice.model). Saved on \(bot.title).")
        case .needsConfirming(let said):
            // As in the picker: nothing is saved until the person agrees, and Return is Cancel.
            let asked = ask(visit, CommandConfirm(
                title: "Switch \(bot.title) to \(choice.model)?",
                message: [said, "This is saved on \(bot.title)."].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                action: "Switch Model",
                run: { [weak self] in Task { await self?.saveModel(choice, note, confirmed: true, visit: visit, for: bot, through: roster) } },
                cancel: { [weak self] in self?.finish(note, "Not switched.") }))
            if !asked { finish(note, confirming == nil ? "Not switched." : "Not switched: answer the question already open first.") }
        case .failed(let trouble):
            finish(note, trouble)
        }
    }

    /// `/reasoning <level>`, saved on the bot as the Reasoning menu saves it.
    private func think(_ word: String, _ line: String, for bot: Bot, through roster: RosterModel) {
        draft = ""
        let note = addNote(.line, asked: line)
        guard let level = SlashCommand.reasoning(word) else {
            return finish(note, "Reasoning can be off, minimal, low, medium, high, xhigh, max or ultra.")
        }
        guard !roster.cannotSetReasoning else {
            return finish(note, "This gateway doesn't let this app change how hard a bot thinks.")
        }
        Task {
            guard !isAbandoned else { return }
            let trouble = await roster.setReasoning(level, for: bot)
            finish(note, trouble ?? "Reasoning set to \(level.title). Saved on \(bot.title).")
        }
    }

    /// What went wrong running a command, in words. Hermes's own words where it gave some.
    private func problem(_ error: any Error, _ line: String, _ bot: Bot, _ roster: RosterModel) -> String {
        let name = SlashCommand.unbroken(line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? line)
        switch error {
        case GatewayError.rejected(_, let message) where !message.isEmpty: return message
        case GatewayError.unsupported: return "This gateway doesn't run \(name) for this app."
        case GatewayError.timedOut: return "No answer about \(name) in time. It may still have been done."
        case is StillOpening: return "Try \(name) again in a moment, once \(bot.title) has woken up."
        case is OldHermes: return "This gateway's Hermes is older than 0.21.6, where \(name) could turn approvals off for every chat it runs. Update Hermes to use it here."
        default: return "Couldn't run \(name). \(roster.text(for: error))"
        }
    }
}
