import HermesBotUI
import HermesKit
import AppKit
import SwiftUI
import os

/// A page's message was not sent: the page, or its line, was no longer in sight.
struct PageOutOfSight: Error {}
/// A message held back because a change to approvals was asked for while it waited its
/// turn: it would have gone under the approvals being left.
struct ApprovalsWereChanging: Error {}

/// Writes of approval modes under way that every chat holds its messages for.
@Observable
final class ApprovalsHold {
    var count = 0
}

/// One bot's chat: what is stored, and the message being answered right now.
@MainActor
@Observable
final class ChatModel {
    enum Phase: Equatable {
        case loading
        case loaded
        /// Something went wrong that trying again might fix.
        case failed(String)
        /// This gateway can't show chats at all. Trying again would not help.
        case unavailable(String)
    }

    private(set) var phase = Phase.loading
    /// The stored chat, as last read.
    private(set) var stored: [TranscriptItem] = []
    /// What the bot has asked in this chat and is waiting on, and lines for what is over.
    let questions = ChatQuestions()
    /// When each row shown was said, where known: places the line a question leaves.
    @ObservationIgnored private var storedDates: [TranscriptItem.ID: Date] = [:]
    @ObservationIgnored private var liveDates: [TranscriptItem.ID: Date] = [:]
    /// Each bubble's text with its formatting worked out once, not on every redraw.
    private(set) var styled: [TranscriptItem.ID: [StyledBlock]] = [:]
    /// What is typed and not yet sent. Kept here so it survives selecting another bot.
    var draft = ""
    /// The person's last message and the bot's last answer to it, as stored: the only turn
    /// Retry and Undo act on.
    struct LatestTurn: Equatable {
        /// The person's message, by stored row.
        let asked: Int
        /// Its words, without what went with it.
        let words: String
        /// Files or pictures went with it. Retry is not offered: it would send the words alone.
        let hadAttachments: Bool
        /// The bot's last reply after it, if it said anything.
        let answer: Int?
        /// Nothing of the person's came before it in the chat as read.
        let isFirst: Bool

        var rewind: Rewind { Rewind(rowID: asked, emptiesChat: isFirst) }
    }
    private(set) var latest: LatestTurn?
    /// Reactions on stored rows, by row.
    private(set) var reactions: [Int: [Reaction]] = [:]
    /// The emoji offered for reacting.
    static let quickReactions = ["👍", "❤️", "😂", "😮", "🙏", "👀"]
    /// This gateway keeps no reactions, so none are offered.
    private(set) var cannotReact = false
    /// This gateway cannot take messages back, so Retry and Undo are not offered.
    private(set) var cannotRewind = false
    /// Words of a message to give back if the gateway turns out to have taken it back without
    /// asking it again: a Retry or Undo whose outcome was not heard. Settled by the next read
    /// of the chat that comes back, by the row, never by matching words alone.
    private var wordsIfGone: (row: Int, words: String)?
    /// The person's message being asked again, by stored row: it and what follows are not
    /// shown from the stored chat meanwhile. The stored chat itself is left as it was read, so
    /// a retry that does not go shows it again.
    private var askingAgain: Int?
    /// Reactions on their way to the gateway, by row: one after another, the last in line.
    @ObservationIgnored private var reacting: [Int: Task<Void, Never>] = [:]
    /// How many reactions for each row have not been answered. A read of the chat meanwhile
    /// leaves the row as the person last set it.
    @ObservationIgnored private var reactionsUnanswered: [Int: Int] = [:]
    /// Each row's reactions as the gateway last said they were, to go back to when a change
    /// does not go.
    @ObservationIgnored private var confirmedReactions: [Int: [Reaction]] = [:]
    /// Goes up whenever a reaction is set or answered. A read of the chat that began before a
    /// row's last change leaves that row alone, since it may predate the change.
    @ObservationIgnored private var reactionClock = 0
    @ObservationIgnored private var reactionChanged: [Int: Int] = [:]
    /// The notice showing is about a reaction.
    @ObservationIgnored private var reactionProblem = false
    /// Counts asks to put the caret in the composer.
    private(set) var focusAsks = 0

    /// Puts the caret back in the composer, as after a panel over the chat has closed.
    func focus() { focusAsks += 1 }
    /// Counts asks to find words in this chat (⌘F).
    private(set) var findAsks = 0

    /// Opens the field for finding words in the chat, or puts the caret back in it.
    func find() { findAsks += 1 }

    /// Offers words to send, from a suggestion. Words already being typed are the person's
    /// and stay; either way the caret goes to the composer.
    func suggest(_ text: String) {
        if messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messageDraft = text }
        focusAsks += 1
    }
    /// Why the last message didn't go through or wasn't finished, until the next one is sent.
    private(set) var sendProblem: String?
    /// This gateway can't take messages, so there is nothing to type into.
    private(set) var cannotSend = false
    /// What the person has picked to go with the next message.
    private(set) var attachments: [PickedFile] = []
    /// What went with the message now on its way, shown under it until the stored chat,
    /// which knows what was attached, takes its place.
    private(set) var sentAttachments: [PickedFile] = []
    /// The row those belong to: the message on its way, and no other.
    var sentAttachmentsRow: Int { sentID }
    /// Files picked and still being read. The message waits for them.
    private(set) var filesBeingRead = 0
    /// Why something picked could not be attached.
    var attachProblem: String?
    /// This gateway has no way of taking attachments, so none are offered.
    private(set) var cannotAttach = false
    /// Not while the bot is answering: what is attached goes with a message of its own.
    var canAttach: Bool { !cannotAttach && !cannotSend && !isWorking && attachments.count + filesBeingRead < Self.mostAttachments }
    static let mostAttachments = 10

    /// Takes files the person picked, dropped or pasted. Read off the main thread; one
    /// that is too large or cannot be read is left out, and said.
    func attach(_ urls: [URL], expected: Int = 0) {
        // Places held for these while they were on their way are theirs to take now.
        filesBeingRead -= min(expected, filesBeingRead)
        guard !cannotAttach else { return }
        attachProblem = nil
        // Places are counted as taken while their files are still being read.
        let room = Self.mostAttachments - attachments.count - filesBeingRead
        if urls.count > room { attachProblem = "At most \(Self.mostAttachments) files go with one message." }
        let taking = Array(urls.prefix(max(room, 0)))
        guard !taking.isEmpty else { return }
        filesBeingRead += taking.count
        Task {
            for url in taking {
                let read = await Task.detached(operation: { PickedFile.read(url) }).value
                filesBeingRead -= 1
                // Found meanwhile that this gateway takes none.
                guard !cannotAttach else { continue }
                switch read {
                case .success(let file): attachments.append(file)
                case .failure(let problem): attachProblem = problem.text
                }
            }
        }
    }

    /// Holds places for files that have been dropped and are not here yet, so nothing is
    /// sent without them meanwhile. Returns how many were held, to hand to `attach`.
    func expect(_ count: Int) -> Int {
        let held = max(min(count, Self.mostAttachments - attachments.count - filesBeingRead), 0)
        filesBeingRead += held
        return held
    }

    /// Takes a picture that was pasted as a picture, with no file behind it. `data` is
    /// as the pasteboard held it; it is made into a PNG off the main thread.
    func attach(picture data: Data) {
        guard !cannotAttach, attachments.count + filesBeingRead < Self.mostAttachments else { return }
        attachProblem = nil
        filesBeingRead += 1
        Task {
            let made = await Task.detached(operation: { PickedFile.picture(data, named: "Pasted picture.png") }).value
            filesBeingRead -= 1
            guard !cannotAttach else { return }
            switch made {
            case .success(let file): attachments.append(file)
            case .failure(let problem): attachProblem = problem.text
            }
        }
    }

    func removeAttachment(_ id: PickedFile.ID) {
        attachments.removeAll { $0.id == id }
        attachProblem = nil
    }

    /// A stored message read for what went with it, once: the view asks every time it draws.
    @ObservationIgnored private var readParts: [String: SentParts] = [:]
    func parts(of stored: String) -> SentParts {
        if let read = readParts[stored] { return read }
        let read = SentParts(stored: stored)
        if readParts.count > 400 { readParts.removeAll() }
        readParts[stored] = read
        return read
    }

    /// What slash commands have left in this chat, oldest first. Kept in this window only,
    /// for as long as the app runs; never sent or stored.
    private(set) var notes: [ChatNote] = []
    private var notesMade = 0
    /// A command waiting for the person to agree to it.
    var confirming: CommandConfirm?
    /// The chat being opened for a command, which any other command waits for.
    var commandOpen: Task<(GatewayClient, LiveChat), any Error>?

    /// Adds a note after what the chat now ends with, and brings it into sight.
    @discardableResult
    func addNote(_ kind: ChatNote.Kind, asked: String) -> Int {
        notesMade += 1
        notes.append(ChatNote(id: notesMade, kind: kind, asked: asked, after: items.last?.id))
        scrollCount += 1
        return notesMade
    }

    /// Says how a command went in its note. A readout of more than two lines is a card,
    /// whatever its command: a list read as one centred line is hard to follow.
    func finish(_ id: Int, _ text: String, asCard: Bool = false) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].text = text
        if asCard || text.split(whereSeparator: \.isNewline).count > 2, case .line = notes[index].kind {
            notes[index].kind = .readout
        }
        scrollCount += 1
    }

    func dismissNote(_ id: Int) { notes.removeAll { $0.id == id } }

    /// Counts the times the stored chat has been put on screen, to know whether a read took.
    private(set) var shows = 0
    /// Changes to approvals asked for and not yet answered. No message goes meanwhile.
    var approvalsChanging = 0
    /// The roster's hold while it writes approval modes from Settings or to a new bot, shared
    /// by every chat, those made meanwhile too.
    var approvalsHold: ApprovalsHold?
    /// Whether messages are held for a change to approvals, this chat's own or the roster's.
    var approvalsHeld: Bool { approvalsChanging > 0 || (approvalsHold?.count ?? 0) > 0 }
    /// Said of a message held back for one.
    static let heldForApprovals = "Not sent while approvals were changing. Send it again."
    /// The last change to approvals asked for: each waits for the one before, so they land
    /// in the order asked.
    var approvalQueue: Task<Void, Never>?

    /// Puts back what was to go with a message that did not go.
    private func giveBack(_ files: [PickedFile]) {
        sentAttachments = []
        // Not where they cannot be sent at all: left in the box they would only fail again.
        guard !cannotAttach else {
            attachments = []
            return
        }
        // Ahead of anything picked since, and no more than a message takes.
        attachments = Array((files + attachments).prefix(Self.mostAttachments))
    }
    /// Goes up with each message sent, for the view to follow it to the end of the chat.
    private(set) var sendCount = 0

    /// How far the message being sent has got.
    private enum Stage {
        /// Opening the chat on the gateway. Nothing has been sent.
        case opening
        /// The message is on its way; the gateway has not said it has it.
        case submitting
        case answering
        /// The answer is over and the stored chat is being read to replace what was shown live.
        case settling
    }

    /// What the loop following an answer is told.
    private enum LiveItem {
        case step(TurnEvent)
        /// The chat has been quiet for a while.
        case quiet
        /// Something changed in `send()`: look again.
        case poke
    }

    /// The loop in `deliver` is following an answer, so more can be added to it.
    private var isFollowing = false
    /// Wakes that loop. Nil when there is none.
    private var poke: (() -> Void)?
    /// Messages added mid-answer that the gateway has not answered for yet.
    private var addedInFlight = 0
    /// A turn ending is not the end of the answer; see `deliver`.
    private var followsOn = false
    /// Goes up with every step received and everything sent, to notice either happening
    /// while something else is awaited.
    private var activity = 0
    /// Goes up with each message sent, for the view to follow it to the end of the chat.
    private(set) var scrollCount = 0
    /// The last message added mid-answer on its way to the bot; each waits for the one before.
    private var adding: Task<Void, Never>?
    /// A message was queued by the gateway and the turn that answers it has not begun.
    private var owesATurn = false
    /// Turns seen to begin while the current answer has been followed.
    private var turnsBegun = 0
    /// Words given back to the composer in this exchange, as they now stand at its start.
    private var givenBack = ""
    /// What the person has sent in this exchange, to tell their unanswered message in the
    /// stored chat from someone else's.
    private var ours: [String] = []

    /// The message just sent and the answer arriving, until the stored chat has them. A
    /// hidden one, sent by a page, is not shown as the person's.
    private var sent: (text: String, date: Date, hidden: Bool)?
    /// Parts of the answer that are messages a page added to it, not shown as the person's.
    private var hiddenParts: Set<Int> = []
    /// The answer as the chat shows it. Words arriving faster than the screen can usefully
    /// follow are gathered and shown at most `streamInterval` apart; `turn` is always the
    /// latest, for everything but drawing.
    private var shownTurn: LiveTurn?
    @ObservationIgnored private var pendingTurn: LiveTurn?
    @ObservationIgnored private var pendingShow: Task<Void, Never>?
    @ObservationIgnored private var lastShown = ContinuousClock.now
    static let streamInterval = Duration.milliseconds(33)
    private var turn: LiveTurn? {
        // What is shown is read first, so a view reading this follows it even while newer
        // words wait to be shown.
        get { let shown = shownTurn; return pendingTurn ?? shown }
        set {
            pendingTurn = nil
            pendingShow?.cancel()
            pendingShow = nil
            shownTurn = newValue
        }
    }
    private var stage = Stage.opening
    private var sending: Task<Void, Never>?
    private var stopRequested = false
    private(set) var isAbandoned = false
    /// How many times in a row a waiting message is found still unanswered, three seconds
    /// apart, before it is given up on. Five minutes, unless a test wants less.
    var quietChecksAllowed = 100
    private var live: (chat: LiveChat, client: GatewayClient)?
    private var lastStoredDate: Date?
    /// Counts reads of the stored chat, so one that was overtaken, by a newer read or by a
    /// message being sent, leaves the chat alone.
    private var loadCount = 0

    /// Stand-in ids for the rows shown live, below zero so they can't meet a stored row's, and
    /// different for each send so rows kept from an earlier one don't share them.
    private var sentID: Int { -1000 * sendCount }
    /// A part's id is steady for the part's life, so its row and its cached formatting are too.
    private func partID(_ part: LiveTurn.Part) -> Int { sentID - part.id }

    /// A message of ours is with the bot, or on its way, and not finished with.
    var isWorking: Bool { sending != nil }

    /// The bot has the message and is not saying anything right now.
    var isWaitingForWords: Bool {
        // Waiting on the person, not working: the question says so itself.
        guard isWorking, stage != .settling, !questions.isWaiting else { return false }
        if case .said? = turn?.parts.last?.content, turn?.isWorking == true { return false }
        return true
    }

    /// What the bot is doing while nothing is being said, in a word or two. Nil until the
    /// gateway has taken the message: before that there is nothing known to say.
    var waitingStatus: String? {
        guard isWaitingForWords, stage == .answering else { return nil }
        // Asked to stop, and not yet stopped.
        if stopRequested { return "Stopping…" }
        // Waiting its turn behind another answer, or after one that has finished: the
        // bot is not thinking about this yet, or any more.
        if owesATurn || turn?.isWorking == false { return nil }
        switch turn?.parts.last?.content {
        // It has used a tool, or said something and gone back to work.
        case .used?, .said?: return "Working…"
        case .added?, nil: return "Thinking…"
        }
    }

    /// More can be sent while the bot answers: it goes to the bot at once.
    var canAddToTurn: Bool { isWorking && stage == .answering && !stopRequested && isFollowing }

    /// A message is opening the chat on the gateway, which nothing else may do meanwhile.
    var isOpeningChat: Bool { isWorking && stage == .opening }

    /// Everything the chat shows, oldest first.
    var items: [TranscriptItem] {
        guard let sent else { return stored }
        var items = stored
        if let askingAgain, let place = stored.firstIndex(where: { $0.id == TranscriptItem.user(id: askingAgain, text: "").id }) {
            // The message asked again stands where it stood, under the same time stamp.
            items = Array(stored[..<place])
        } else if lastStoredDate.map({ sent.date.timeIntervalSince($0) >= 3600 }) ?? true, !sent.hidden || shownTurn?.parts.contains(where: { !hiddenParts.contains($0.id) }) == true {
            // A page's message shows nothing of its own: the time goes over what the bot says.
            items.append(.date(sent.date))
        }
        if !sent.hidden { items.append(.user(id: sentID, text: sent.text)) }
        for part in shownTurn?.parts ?? [] {
            switch part.content {
            case .said(let text): items.append(.bot(id: partID(part), text: text))
            case .used(let tools): items.append(.activity(id: partID(part), tools: tools))
            case .added(let text): if !hiddenParts.contains(part.id) { items.append(.user(id: partID(part), text: text)) }
            }
        }
        return items
    }

    /// The time of the newest row on screen, where known.
    var newestShown: Date? {
        (Array(storedDates.values) + Array(liveDates.values)).max()
    }

    /// The message being written, wherever it is just now: in the box, or put aside while the
    /// box answers clarifying questions. Words given back or suggested go here, never into
    /// an answer.
    var messageDraft: String {
        get { putAside?.draft ?? draft }
        set { if putAside != nil { putAside?.draft = newValue } else { draft = newValue } }
    }

    /// Puts words in the message being written, ahead of anything typed there: never into
    /// an answer to clarifying questions.
    func putAhead(_ words: String) {
        guard !words.isEmpty else { return }
        messageDraft = messageDraft.isEmpty ? words : words + "\n" + messageDraft
    }

    /// What was in the message box when clarifying questions came, which then takes their
    /// typed answers; it is put back when they go. The question it was put aside for.
    @ObservationIgnored private var putAside: (draft: String, for: UUID)?

    /// Clarifying questions have come or gone: the message box becomes their answer, and
    /// what was being typed is kept aside until it is the message box again. Words typed as
    /// an answer and not sent go with the questions.
    func clarifyingChanged(to instance: UUID?) {
        if let instance {
            if putAside == nil {
                putAside = (draft, instance)
                draft = ""
            } else if putAside?.for != instance {
                // Another set after the first: what was typed for the first is not its answer.
                putAside?.for = instance
                draft = ""
            }
        } else if let kept = putAside {
            putAside = nil
            draft = kept.draft
        }
    }

    /// Where each question that is over sits among the rows: after the last row said before
    /// it was asked, by row id; under nil, above every row. Questions still open come
    /// after everything, and are not here.
    var settledQuestions: [TranscriptItem.ID?: [ChatQuestions.Asked]] {
        let over = questions.all.filter { !$0.isOpen }
        guard !over.isEmpty else { return [:] }
        let rows = items
        var dated: [(id: TranscriptItem.ID, date: Date)] = []
        for item in rows {
            let date: Date? = switch item {
            case .date(let date): date
            default: storedDates[item.id] ?? liveDates[item.id]
            }
            if let date { dated.append((item.id, date)) }
        }
        var places: [TranscriptItem.ID?: [ChatQuestions.Asked]] = [:]
        for asked in over {
            // A row with no time of its own goes by its place: only rows with one are counted.
            let after = dated.last { $0.date <= asked.placed }?.id
            places[after, default: []].append(asked)
        }
        return places
    }

    /// Shows the answer as it now stands, working out the formatting of what changed.
    /// The turning to full colour of the words that last arrived in each part of a reply,
    /// while it waits its moment.
    private var settling: [TranscriptItem.ID: Task<Void, Never>] = [:]

    private func publish(_ answer: LiveTurn) {
        // Only more words for what the bot is saying: gathered, and shown with the next lot,
        // so a fast reply is laid out a few dozen times a second, not once for every word.
        if let before = turn, Self.onlyWordsAdded(from: before, to: answer) {
            let wait = Self.streamInterval - (ContinuousClock.now - lastShown)
            if wait > .zero {
                pendingTurn = answer
                if pendingShow == nil {
                    pendingShow = Task { [weak self] in
                        try? await Task.sleep(for: wait)
                        guard !Task.isCancelled, let self, let pending = self.pendingTurn else { return }
                        self.display(pending)
                    }
                }
                return
            }
        }
        display(answer)
    }

    /// The answer differs from the one before only by more words at the end of the last
    /// thing the bot is saying.
    static func onlyWordsAdded(from before: LiveTurn, to after: LiveTurn) -> Bool {
        guard before.parts.count == after.parts.count, let was = before.parts.last, let now = after.parts.last,
              was.id == now.id, before.outcome == after.outcome, before.hasStarted == after.hasStarted,
              case .said(let old) = was.content, case .said(let new) = now.content,
              new.count > old.count, new.hasPrefix(old) else { return false }
        return before.parts.dropLast() == after.parts.dropLast()
    }

    private func display(_ answer: LiveTurn) {
        lastShown = .now
        let before = shownTurn
        turn = answer
        if let sent { liveDates[TranscriptItem.user(id: sentID, text: "").id] = liveDates[TranscriptItem.user(id: sentID, text: "").id] ?? sent.date }
        for part in answer.parts {
            let partKey: TranscriptItem.ID = switch part.content {
            case .said: TranscriptItem.bot(id: partID(part), text: "").id
            case .used: TranscriptItem.activity(id: partID(part), tools: []).id
            case .added: TranscriptItem.user(id: partID(part), text: "").id
            }
            if liveDates[partKey] == nil { liveDates[partKey] = .now }
            guard before?.parts.first(where: { $0.id == part.id }) != part else { continue }
            switch part.content {
            case .said(let text):
                let id = TranscriptItem.bot(id: partID(part), text: "").id
                // The words that have just arrived come in grey and turn to full colour a
                // moment later, as the reference's do.
                var fresh = text.count
                if case .said(let was)? = before?.parts.first(where: { $0.id == part.id })?.content, text.hasPrefix(was) {
                    fresh = text.count - was.count
                }
                styled[id] = Self.greying(last: fresh, of: Self.style(reply: text, reusing: styled[id] ?? []))
                // One wait per part of the reply: words after a tool was used are a part of
                // their own, and must not leave the part before them grey.
                settling[id]?.cancel()
                settling[id] = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(380))
                    guard !Task.isCancelled, let self else { return }
                    self.settling[id] = nil
                    guard self.styled[id]?.last?.isGreyed == true else { return }
                    self.styled[id] = Self.style(reply: text, reusing: self.styled[id] ?? [])
                }
            case .added(let text): styled[TranscriptItem.user(id: partID(part), text: "").id] = Self.style(text)
            case .used: break
            }
        }
    }

    /// How many of the chat's latest stored rows are read and shown: a page when the chat is
    /// opened, and a page more each time the person scrolls to the top of what is shown, so a
    /// long chat costs no more to draw than a short one until it is read back.
    static let pageSize = 50
    /// Hermes gives at most this many rows in one read.
    static let mostShown = 500
    private(set) var window = ChatModel.pageSize
    /// The chat goes back further than what is shown, and more can be read in.
    private(set) var hasOlder = false
    private(set) var isLoadingOlder = false

    /// Older rows can be read in just now. Not while an answer is shown live: reading the
    /// stored chat would put it in the answer's place.
    var canLoadOlder: Bool { hasOlder && !isLoadingOlder && !isWorking && phase == .loaded }

    /// Goes up each time a page of older rows has been shown, in the same moment as the rows:
    /// the view keeps its place by it as they are laid out.
    private(set) var olderShown = 0
    /// How many rows the chat was last shown for.
    @ObservationIgnored private var windowShown = ChatModel.pageSize

    /// Another read of the chat was asked for while a page of older rows was being read, for
    /// the bot as it then was: it is made once that read is done, so nothing overtakes it.
    @ObservationIgnored private var readAfterOlder: Bot?

    /// Reads a page more of the chat's history, above what is shown. True when it is shown.
    /// The window stays as it was if it is not (the read failed, or a message sent meanwhile
    /// set it aside).
    @discardableResult
    func loadOlder(_ bot: Bot, from roster: RosterModel) async -> Bool {
        guard canLoadOlder else { return false }
        isLoadingOlder = true
        let was = window, olderBefore = olderShown
        window = min(window + Self.pageSize, Self.mostShown)
        await read(bot, from: roster)
        let shown = olderShown != olderBefore
        if !shown, window > was { window = was }
        isLoadingOlder = false
        // What was asked for meanwhile (the chat moved on elsewhere), now, for the bot as it
        // was last asked for, with the window as it stands. Any read asked for from here goes
        // straight ahead.
        if let waiting = readAfterOlder {
            readAfterOlder = nil
            await read(waiting, from: roster)
        }
        return shown
    }

    /// The chat is being opened: it shows its latest page again, however far back it was read.
    func showLatest() {
        window = Self.pageSize
    }

    /// Reads the stored chat. The first time it shows a spinner; after that the chat stays
    /// on screen while it is read again. While a page of older rows is being read, this read
    /// is made after it.
    func load(_ bot: Bot, from roster: RosterModel) async {
        if isLoadingOlder {
            readAfterOlder = bot
            return
        }
        await read(bot, from: roster)
    }

    /// True when what was read is shown.
    @discardableResult
    private func read(_ bot: Bot, from roster: RosterModel) async -> Bool {
        // Mid-answer the stored chat is behind what is on screen; it is read when the answer ends.
        guard !isWorking, !isAbandoned else { return false }
        loadCount += 1
        let thisLoad = loadCount
        if phase != .loaded { phase = .loading }
        let clock = reactionClock
        let asked = window
        do {
            let messages = try await roster.messages(for: bot, limit: asked)
            guard thisLoad == loadCount, !Task.isCancelled, !isAbandoned else { return false }
            freshen(show(messages, asked: asked, readFrom: clock), of: bot, through: roster)
            // On screen as far as this copy of the bot knew: the roster may count it read.
            roster.didShow(bot)
            return true
        } catch {
            // A load that was cancelled or overtaken has nothing to report. Nor does a
            // failed re-read: the chat already on screen is better than an error.
            guard thisLoad == loadCount, !Task.isCancelled, !(error is CancellationError), phase != .loaded else { return false }
            let text = roster.text(for: error)
            if case GatewayError.unsupported = error { phase = .unavailable(text) } else { phase = .failed(text) }
            return false
        }
    }

    /// Shows the stored chat, and says which files the bot's replies new since it was last
    /// shown name (pages and files handed over): the bot may have written any of them again.
    @discardableResult
    private func show(_ read: [ChatMessage], asked: Int, readFrom clock: Int? = nil) -> (pages: Set<String>, files: Set<String>) {
        // Read for a larger window than there is now (the chat was opened again meanwhile):
        // only the window's worth is shown.
        let messages = read.count > window ? Array(read.suffix(window)) : read
        let asked = min(asked, window)
        // A read that came back full may have left older rows behind.
        hasOlder = messages.count >= asked && asked < Self.mostShown
        if asked > windowShown { olderShown += 1 }
        windowShown = asked
        // The stored chat is in full colour; nothing waits to turn.
        for wait in settling.values { wait.cancel() }
        settling = [:]
        let shownBefore = phase == .loaded ? Set(stored.compactMap { if case .bot(let id, _) = $0, id >= 0 { id } else { nil } }) : nil
        let dated = Transcript.dated(from: messages)
        // What each row said when last shown, so a row that has not changed keeps its
        // formatting rather than being read again: the chat is read again after every turn.
        let saidBefore = Dictionary(stored.compactMap { item -> (TranscriptItem.ID, String)? in
            switch item {
            case .bot(_, let text), .user(_, let text): (item.id, text)
            default: nil
            }
        }, uniquingKeysWith: { first, _ in first })
        let styledBefore = styled
        stored = dated.map(\.item)
        storedDates = Dictionary(dated.compactMap { row in row.date.map { (row.item.id, $0) } }, uniquingKeysWith: { first, _ in first })
        liveDates = [:]
        lastStoredDate = messages.last?.date
        var read = Dictionary(messages.compactMap { $0.reactions.isEmpty ? nil : ($0.id, $0.reactions) }, uniquingKeysWith: { first, _ in first })
        var confirmed = read
        // A row with a change on its way, or changed since this read began, stays as it is.
        let kept = Set(reactionsUnanswered.filter { $0.value > 0 }.keys)
            .union(reactionChanged.filter { change in clock.map { change.value > $0 } ?? false }.keys)
        for row in kept {
            // What this read found stands as the gateway's word until an answer comes.
            confirmed[row] = confirmedReactions[row] ?? read[row]
            read[row] = reactions[row]
        }
        reactions = read
        confirmedReactions = confirmed
        latest = Self.latestTurn(in: messages, shown: stored)
        askingAgain = nil
        // Only a read that holds the whole chat, or reaches back as far as the row, can say
        // whether it is gone; one that cannot leaves the question for a later read.
        if let (row, words) = wordsIfGone, messages.count < asked || messages.first.map({ $0.id <= row }) ?? true {
            wordsIfGone = nil
            // Gone, and not asked again since: a newer row of the person's with the same words.
            let askedAgain = messages.contains { $0.isPersons && $0.id > row && SentParts(stored: $0.text).words == words }
            if !messages.contains(where: { $0.id == row }), !askedAgain, !words.isEmpty {
                let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = typed.isEmpty ? words : words + "\n" + draft
            }
        }
        styled = Dictionary(stored.compactMap { item in
            switch item {
            case .bot(_, let text), .user(_, let text):
                if saidBefore[item.id] == text, let kept = styledBefore[item.id], kept.last?.isGreyed != true { return (item.id, kept) }
                if case .user(let id, _) = item { return (item.id, Self.style(id < 0 ? text : parts(of: text).words)) }
                return (item.id, Self.style(reply: text))
            default: return nil
            }
        }, uniquingKeysWith: { first, _ in first })
        linesRead = Self.pageLines(in: messages, styled: styled)
        let newestBefore = lastRow
        lastRow = messages.map(\.id).max() ?? lastRow
        // A page whose reply was shown only as it arrived now stands under its stored id:
        // what was sent from it is in the stored chat.
        let pages = Set(styled.flatMap { id, blocks in blocks.compactMap { block -> String? in
            if case .page = block.kind { Self.pageKey(id, block.id) } else { nil }
        } })
        linesSent = linesSent.filter { pages.contains($0.key) }
        showLines()
        sent = nil
        sentAttachments = []
        turn = nil
        phase = .loaded
        shows += 1
        // A note after something no longer shown (a message that was arriving, or one /undo
        // took out) now follows what the chat ends with. One made in an empty chat stays first.
        let shown = Set(stored.map(\.id))
        for index in notes.indices {
            if let after = notes[index].after, !shown.contains(after) { notes[index].after = stored.last?.id }
        }
        // On first showing, nothing is new: what is kept of a file is as fresh as the chat.
        guard let shownBefore else { return ([], []) }
        var named: (pages: Set<String>, files: Set<String>) = ([], [])
        for item in stored {
            // Older rows read in above are not new: only those after the newest seen before.
            guard case .bot(let id, _) = item, !shownBefore.contains(id), id > newestBefore else { continue }
            for block in styled[item.id] ?? [] {
                switch block.kind {
                case .page: named.pages.insert(block.raw)
                case .file: named.files.insert(block.raw)
                default: break
                }
            }
        }
        return named
    }

    /// A reply new to this chat names files the bot may have written again since they were
    /// fetched: what was kept of them is let go, and every page in the chat showing one is
    /// read again, with the files beside it, and drawn again if it changed. A picture or
    /// card already on screen keeps what it showed; the new reply's own is fetched afresh.
    private func freshen(_ named: (pages: Set<String>, files: Set<String>), of bot: Bot, through roster: RosterModel) {
        guard !named.pages.isEmpty || !named.files.isEmpty else { return }
        roster.forget(named.pages.union(named.files), of: bot)
        // A page showing a file named by either, `::preview` or `MEDIA:`, is read again.
        for path in named.pages.union(named.files) { rereads[path] = Self.nextReading() }
    }

    // MARK: Pages that send their bot a message

    /// The grey line under a page that sent its bot something: the words, exactly, and
    /// how the page is getting on with them.
    struct PageLine: Equatable {
        enum Status { case updating, updated }
        let words: String
        /// The file the page shows.
        let path: String
        var status: Status?
        /// The bot is done, and the page is to be read again before it says Updated.
        var awaitsRead = false
        /// Which send from here it is; 0 for one read from the stored chat.
        var send = 0
        /// Sent from here, and the gateway has not yet said whether it took it.
        var pending = false
        /// The stored row it was read from; 0 for one sent from here.
        var row = 0
    }

    /// The line under each page that has one, by the page's place in the chat (`pageKey`).
    private(set) var pageLines: [String: PageLine] = [:]
    /// What the stored chat says each page last sent.
    @ObservationIgnored private var linesRead: [String: PageLine] = [:]
    /// What each page sent from here while this chat has been open, oldest first, and how
    /// it went. The last is shown; one the gateway refuses is taken out, so the one before
    /// it shows again.
    @ObservationIgnored private var linesSent: [String: [PageLine]] = [:]
    @ObservationIgnored private var pageSends = 0
    /// The last stored row when a page first sent from here: a stored line from a row
    /// before it cannot be one of those sends.
    @ObservationIgnored private var sendingSince: Int?
    @ObservationIgnored private var lastRow = 0
    /// When a page's message last went to the gateway, from any chat.
    static var lastPageMessage: ContinuousClock.Instant?
    /// For a file, the reading the pages showing it are to fetch it at, as the bot may have
    /// written it again: a number from one clock for every file and chat, so a file kept for
    /// one page's reading can be told to be new enough, or not, for another's
    /// (`RosterModel.file`).
    private(set) var rereads: [String: Int] = [:]
    private static var readings = 0
    private static func nextReading() -> Int {
        readings += 1
        return readings
    }
    /// A page's message has not yet gone. Every page in the chat keeps its height meanwhile,
    /// so none can move a line out of sight between its last check and its going.
    private(set) var holdsPages = false

    /// A page's place in the chat: the message it stands in, and which block of it.
    static func pageKey(_ item: TranscriptItem.ID, _ block: Int) -> String { "\(item)#\(block)" }

    /// The line each page has from the stored chat. Hermes keeps nothing that says which
    /// page sent a hidden message, so one is taken to be from the nearest page above it,
    /// if it could have been sent by a page at all; any other is shown nowhere.
    static func pageLines(in messages: [ChatMessage], styled: [TranscriptItem.ID: [StyledBlock]]) -> [String: PageLine] {
        var lines: [String: PageLine] = [:]
        var lastPage: (key: String, path: String)?
        for message in messages {
            if message.role == "assistant" {
                let id = TranscriptItem.bot(id: message.id, text: "").id
                if let page = styled[id]?.last(where: { if case .page = $0.kind { true } else { false } }) {
                    lastPage = (pageKey(id, page.id), page.raw)
                }
            } else if message.role == "user", message.isHidden, let lastPage {
                let words = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only what a page could have sent: not one of Hermes's own notices to the bot.
                if PageFrame.Keeper.mayBeSent(words) {
                    lines[lastPage.key] = PageLine(words: words, path: lastPage.path, row: message.id)
                }
            }
        }
        return lines
    }

    /// What was sent from here goes before what was read, wherever the stored chat would
    /// put the same words.
    private func showLines() {
        let lines = Self.merged(read: linesRead, sent: linesSent.compactMapValues(\.last), since: sendingSince)
        if lines != pageLines { pageLines = lines }
        // Until it has gone: once it has, it was seen going, and the check is behind it.
        let holds = linesSent.values.contains { $0.contains(where: \.pending) }
        if holds != holdsPages { holdsPages = holds }
    }

    /// Each page's line: what it sent from here, else what the stored chat says. A stored
    /// line gives way to the same words sent from here only when it is from a row stored
    /// after the first of those sends (`since`), so could be one of them.
    static func merged(read: [String: PageLine], sent: [String: PageLine], since: Int?) -> [String: PageLine] {
        let words = Set(sent.values.map(\.words))
        var lines = read.filter { _, line in !(words.contains(line.words) && line.row > (since ?? .max)) }
        lines.merge(sent) { _, ours in ours }
        return lines
    }

    /// Changes every line sent from here that `where` picks.
    private func changeLines(where picked: (PageLine) -> Bool, in only: String? = nil, _ change: (inout PageLine) -> Void) {
        for key in linesSent.keys where only == nil || key == only {
            for index in linesSent[key, default: []].indices where picked(linesSent[key]![index]) {
                change(&linesSent[key]![index])
            }
        }
    }

    /// Sends the bot words a page asked to send. It goes as a typed message does, stored as
    /// one no one sees, and says whether the gateway took it. The page's line shows the
    /// words at once.
    ///
    /// `seen` says whether the page and its line are still in sight. It is asked again just
    /// before the message goes, which is a moment after the line is drawn, a second after
    /// any page's last message, and perhaps after the chat has been opened: a page that has
    /// gone, or moved its line out of sight, meanwhile sends nothing.
    func send(fromPage words: String, at key: String, showing path: String, to bot: Bot, through roster: RosterModel, seen: @escaping @MainActor () -> Bool) async -> Bool {
        guard !cannotSend, phase == .loaded, !isAbandoned else { return false }
        // One at a time from a page: while one has not gone, its line shows it, so no other
        // may go meanwhile under a line that shows something else.
        guard linesSent[key]?.contains(where: \.pending) != true else { return false }
        pageSends += 1
        let number = pageSends
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let went = send(words, hidden: true, to: bot, through: roster, seen: seen) { [weak self] took in
                if let self {
                    switch took {
                    case true?: self.changeLines(where: { $0.send == number }) { $0.pending = false }
                    // Not sent: its line goes, and the one before it shows again.
                    case false?: self.linesSent[key]?.removeAll { $0.send == number }
                    // No answer either way: the words stay, saying nothing of how it went.
                    case nil: self.changeLines(where: { $0.send == number }) { $0.status = nil; $0.pending = false }
                    }
                    self.prune(key)
                    self.showLines()
                }
                done.resume(returning: took == true)
            }
            if went {
                if sendingSince == nil { sendingSince = lastRow }
                linesSent[key, default: []].append(PageLine(words: words, path: path, status: .updating, send: number, pending: true))
                prune(key)
                showLines()
            } else {
                done.resume(returning: false)
            }
        }
    }

    /// Keeps a page's last send the gateway took, or may have, and those after it it has
    /// not answered for yet: what a refusal could give way to, and no more.
    private func prune(_ key: String) {
        guard let lines = linesSent[key], let last = lines.lastIndex(where: { !$0.pending }) else { return }
        linesSent[key] = Array(lines[last...])
    }

    /// Waits until a page's message may go: its line drawn and laid out, a second after any
    /// page's last message, and the page still in sight with its line. Says whether it may.
    private static func pageTurn(_ seen: @MainActor () -> Bool) async -> Bool {
        try? await Task.sleep(for: .milliseconds(300))
        while let last = lastPageMessage, ContinuousClock.now - last < .seconds(1), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1) - (ContinuousClock.now - last))
        }
        guard !Task.isCancelled, seen() else { return false }
        lastPageMessage = .now
        return true
    }

    /// An exchange is over. The pages that sent something in it are read again, and say
    /// Updated once they have been, unless it did not end well.
    private func pagesAnswered(well: Bool) {
        var paths = Set<String>()
        changeLines(where: { $0.status == .updating && !$0.awaitsRead }) { line in
            line.awaitsRead = well
            if !well { line.status = nil }
            paths.insert(line.path)
        }
        for path in paths { rereads[path] = Self.nextReading() }
        showLines()
    }

    /// The page at `key` has fetched its file again, or tried to and could not.
    func pageWasRead(at key: String, well: Bool = true) {
        changeLines(where: { $0.awaitsRead }, in: key) { line in
            line.awaitsRead = false
            line.status = well ? .updated : nil
        }
        showLines()
    }

    /// The person's last message in the stored chat and the bot's last answer after it. A row
    /// the gateway does not count as the person's (a hidden turn) is passed over, as the
    /// gateway's own undo passes over it, and anything after the message goes with it.
    static func latestTurn(in messages: [ChatMessage], shown: [TranscriptItem]) -> LatestTurn? {
        guard let index = messages.lastIndex(where: { $0.isPersons && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        let asked = messages[index]
        guard let place = shown.firstIndex(where: { $0.id == TranscriptItem.user(id: asked.id, text: "").id }) else { return nil }
        let answer = shown[place...].last(where: { if case .bot = $0 { true } else { false } })
        let parts = SentParts(stored: asked.text)
        var answerID: Int?
        if case .bot(let id, _)? = answer { answerID = id }
        // A picture the gateway could only put as a stand-in, with no place to show it from,
        // went with the message all the same.
        // Read as SentParts reads the placed ones: only a line at the very end. The gateway
        // writes the same line for one the person typed, so Undo keeps the words whole (a
        // stand-in left in the box can be deleted; typed words taken off would be lost).
        let last = parts.words.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespaces) ?? ""
        let standIn = ["[image]", "[screenshot]"].contains(last)
        return LatestTurn(
            asked: asked.id, words: parts.words, hadAttachments: !parts.files.isEmpty || !parts.images.isEmpty || standIn,
            answer: answerID, isFirst: !messages[..<index].contains(where: \.isPersons)
        )
    }

    /// Retry and Undo can be offered: the chat on screen is the stored one, and nothing is
    /// on its way. While the bot works, Stop is what acts on the turn.
    private var offersTurnActions: Bool {
        phase == .loaded && !isWorking && sent == nil && !cannotSend && !cannotRewind
    }

    /// Undo is offered on this row: the person's last message.
    func canUndo(_ id: Int) -> Bool { offersTurnActions && latest?.asked == id }

    /// Retry is offered on this row: the bot's last answer, to a message that was words alone.
    func canRetry(_ id: Int) -> Bool {
        guard offersTurnActions, let latest, latest.answer == id else { return false }
        return !latest.hadAttachments && !latest.words.isEmpty
    }

    /// A reaction can be set on this row: a stored one, while nothing is being sent.
    func canReact(_ id: Int) -> Bool { id >= 0 && phase == .loaded && !isWorking && !cannotSend && !cannotReact }

    /// The person's reaction on a row, if any.
    func myReaction(on id: Int) -> String? { reactions[id]?.first(where: \.isPersons)?.emoji }

    /// Sets the person's reaction on a stored row; the same one again takes it off. Shown at
    /// once, and sent after any still on its way for that row, so the gateway ends as shown.
    func react(_ emoji: String, to row: Int, of bot: Bot, through roster: RosterModel) {
        guard canReact(row) else { return }
        let before = reactions[row] ?? []
        let chosen: String? = before.first(where: \.isPersons)?.emoji == emoji ? nil : emoji
        reactions[row] = before.filter { !$0.isPersons } + (chosen.map { [Reaction(emoji: $0, author: "user")] } ?? [])
        // Only a reaction's own notice goes; one about a message stays.
        if reactionProblem { sendProblem = nil }
        reactionProblem = false
        reactionsUnanswered[row, default: 0] += 1
        reactionClock += 1
        reactionChanged[row] = reactionClock
        let earlier = reacting[row]
        let task = Task {
            await earlier?.value
            var now: [Reaction]?
            var problem: (any Error)?
            do {
                let client = try await roster.liveClient()
                guard !isAbandoned else { throw CancellationError() }
                let open = try await liveChat(of: bot, on: client, through: roster)
                now = try await client.react(chosen, toRow: row, in: open, profile: bot.name)
            } catch {
                problem = error
            }
            reactionsUnanswered[row, default: 1] -= 1
            guard !isAbandoned else { return }
            reactionClock += 1
            reactionChanged[row] = reactionClock
            if let now { confirmedReactions[row] = now }
            let last = reactionsUnanswered[row] == 0
            // With nothing more on its way, the row is as the gateway last said: this answer,
            // or after a failure the last one that came.
            if last { reactions[row] = confirmedReactions[row] ?? [] }
            guard let problem, !(problem is CancellationError) else { return }
            if case GatewayError.unsupported = problem {
                cannotReact = true
            } else {
                sendProblem = GatewayProblem.actionText("react", for: problem)
                reactionProblem = true
            }
        }
        reacting[row] = task
    }

    /// Takes the person's last message back out of the chat, with the answer to it, and puts
    /// its words in the composer unless something is already typed there.
    func undo(_ bot: Bot, through roster: RosterModel) {
        guard let latest, canUndo(latest.asked) else { return }
        // Nothing can be sent or read in meanwhile; there is nothing to stop.
        loadCount += 1
        sendProblem = nil
        stage = .settling
        sending = Task {
            do {
                let client = try await roster.liveClient()
                guard !isAbandoned else { throw CancellationError() }
                let open = try await liveChat(of: bot, on: client, through: roster)
                // The fence first, then the check: anything said after the check moves the
                // fence, and the gateway then refuses the cut.
                let fence = try await client.rewindFence(in: open, profile: bot.name)
                try await stillLatest(latest, of: bot, through: roster)
                // Without an answer it may still have been done: then the next read, which
                // finds the row gone, gives the words back.
                wordsIfGone = (latest.asked, latest.words)
                try await client.undo(latest.rewind, fence: fence, in: open, profile: bot.name)
                wordsIfGone = nil
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    draft = latest.words
                    focus()
                } else if !latest.words.isEmpty {
                    sendProblem = "Undone. Its words weren't put in the message box, as something is already typed there."
                }
                if latest.hadAttachments, sendProblem == nil { sendProblem = "Undone. What was attached to it wasn't put back." }
            } catch where !isAbandoned && !(error is CancellationError) {
                // A gateway without it: the feature goes, as any missing method's does.
                if case GatewayError.unsupported = error { cannotRewind = true } else {
                    sendProblem = GatewayProblem.actionText("undo", for: error)
                }
            } catch {}
            // The chat as the gateway now has it.
            settle(bot, through: roster, readStored: true)
        }
    }

    /// Drops the bot's last answer and asks the person's message again in its place.
    func retry(_ bot: Bot, through roster: RosterModel) {
        guard let latest, let answer = latest.answer, canRetry(answer) else { return }
        send(latest.words, hidden: false, to: bot, through: roster, rewinding: latest)
    }

    /// Fails unless the person's last message on the gateway is still the one shown: another
    /// device may have said something meanwhile, and the cut must not take that too.
    private func stillLatest(_ latest: LatestTurn, of bot: Bot, through roster: RosterModel) async throws {
        let now = roster.bots.first(where: { $0.id == bot.id }) ?? bot
        let messages = try await roster.messages(for: now)
        guard !isAbandoned else { throw CancellationError() }
        guard messages.last(where: \.isPersons)?.id == latest.asked else {
            throw GatewayError.rejected(code: 0, message: "Something new was said in the chat meanwhile.")
        }
    }

    /// Sends the draft to the bot and follows its answer. While the bot is answering, the
    /// draft goes to it as more for the same answer. `words`, when given, are sent in place
    /// of the draft, which is left alone, and nothing picked goes with them: a message a
    /// slash command hands back. False when nothing could be sent just now.
    @discardableResult
    func send(to bot: Bot, through roster: RosterModel, words: String? = nil) -> Bool {
        let fromBox = words == nil
        let text = (words ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        // Not while a picked file is still being read: it would be left for the next message.
        guard !text.isEmpty || (fromBox && !attachments.isEmpty), !fromBox || filesBeingRead == 0 else { return false }
        return send(text, hidden: false, given: !fromBox, to: bot, through: roster)
    }

    /// Sends `text`, from the composer or, `hidden`, from a page. A hidden one leaves the
    /// composer and what is attached alone, is not shown as the person's, does not move the
    /// chat, and tells `receipt` whether the gateway took it: nil when it is not known.
    /// Returns whether it was sent on its way. `given` words came from somewhere other
    /// than the box (a slash command): they leave the box and what is attached alone.
    /// `rewinding` is the turn it is asked again in place of (Retry).
    @discardableResult
    private func send(_ text: String, hidden: Bool, given: Bool = false, to bot: Bot, through roster: RosterModel, seen: (@MainActor () -> Bool)? = nil, receipt: ((Bool?) -> Void)? = nil, rewinding: LatestTurn? = nil) -> Bool {
        // Nothing goes while a change to approvals is on its way: it would run under the old ones.
        guard !cannotSend, phase == .loaded, !approvalsHeld else { return false }
        // Words alone can join an answer under way; what is attached waits for a message
        // of its own, and stays in the box until then.
        if canAddToTurn, !text.isEmpty, let live, var answer = turn {
            // Everything the loop following the answer goes by is set here, at once, so it
            // cannot decide the chat is done between this message going and its arriving.
            if !hidden, !given { draft = "" }
            sendProblem = nil
            let part = answer.add(text)
            if hidden { hiddenParts.insert(part) }
            publish(answer)
            addedInFlight += 1
            followsOn = true
            activity += 1
            if !hidden { scrollCount += 1 }
            ours.append(text)
            let thisSend = sendCount
            // One after another, in the order typed: sent side by side, two messages could
            // reach the bot the wrong way round.
            let earlier = adding
            adding = Task {
                await earlier?.value
                // A new soul being saved is had by the turn this may begin. Waited for
                // before anything is decided, so a Stop meanwhile keeps this from going.
                await roster.personalitySettled(for: bot)
                var problem: String?
                var arrived = false
                var took = false
                defer { receipt?(took ? true : arrived ? nil : false) }
                // A page's waits its turn, and goes only if the page is still in sight.
                let mayGo = if let seen { await Self.pageTurn(seen) } else { true }
                // Stopped, or the answer no longer followed, before its turn to go came: it is not sent.
                // Held back if approvals began changing while it waited its turn: it would go
                // under the approvals being left.
                if approvalsHeld { problem = Self.heldForApprovals }
                if mayGo, !approvalsHeld, thisSend == sendCount, stage == .answering, isFollowing, !stopRequested, !isAbandoned {
                    do {
                        let begunBefore = turnsBegun
                        let receipt = try await live.client.send(text, in: live.chat, profile: bot.name, hidden: hidden)
                        arrived = true
                        took = true
                        // Not taken into the running turn, it gets a turn of its own. That turn
                        // may already have been seen to begin, before this receipt got here.
                        if receipt != .joined, thisSend == sendCount, turnsBegun == begunBefore { owesATurn = true }
                        // Stop was pressed while it was on its way: it must not start the bot again.
                        if stopRequested { try? await live.client.stop(live.chat, profile: bot.name) }
                    } catch {
                        switch error {
                        // 4090 covers "it may be queued" as well as a refusal; the gateway's
                        // words say which, and only "nothing was sent" is definite.
                        case GatewayError.rejected(4090, let message)
                            where !message.localizedCaseInsensitiveContains("nothing was sent"):
                            arrived = true
                            problem = GatewayProblem.sendText(for: error, onThisMac: roster.isThisMac, signedIn: roster.isSignedIn)
                        case GatewayError.unsupported, GatewayError.notConnected, GatewayError.rejected:
                            problem = GatewayProblem.sendText(for: error, onThisMac: roster.isThisMac, signedIn: roster.isSignedIn)
                        default:
                            // No answer either way. It stays on screen; the stored chat will tell.
                            arrived = true
                            problem = "The last message may not have been sent. Check the chat before sending it again."
                        }
                    }
                }
                // Another message may have been sent since, as a fresh send.
                guard thisSend == sendCount else { return }
                addedInFlight -= 1
                activity += 1
                if !arrived {
                    // It did not reach the bot. Take it off the screen and give the words back.
                    if var answer = turn {
                        answer.takeBack(part)
                        publish(answer)
                    }
                    if let index = ours.lastIndex(of: text) { ours.remove(at: index) }
                    if !hidden { giveBackAdded(text) }
                }
                if let problem, !stopRequested { sendProblem = problem }
                poke?()
            }
            return true
        }
        // Nor while a command is opening the chat: two openings would leave two live chats.
        guard !isWorking, commandOpen == nil else { return false }
        // A read of the stored chat still on its way would wipe the message off the screen.
        loadCount += 1
        // An earlier exchange the stored chat never came to replace stays on screen: keep it
        // with the stored rows, so it is not lost when this message takes its place.
        if let sent {
            stored = items
            lastStoredDate = sent.date
        }
        sendCount += 1
        if !hidden { scrollCount += 1 }
        ours = [text]
        hiddenParts = []
        owesATurn = false
        givenBack = ""
        // What is typed is the person's own when a message is asked again.
        if !hidden, !given, rewinding == nil { draft = "" }
        sendProblem = nil
        stopRequested = false
        stage = .opening
        sent = (text, .now, hidden)
        turn = LiveTurn()
        styled[TranscriptItem.user(id: sentID, text: text).id] = Self.style(text)
        // What is attached goes with what the person sends, never with a page's message.
        let files = hidden || given || rewinding != nil ? [] : attachments
        if !hidden, rewinding == nil {
            if !given {
                attachments = []
                attachProblem = nil
            }
            sentAttachments = files
        }
        // Shown from here as a message on its way, in place of the one asked again.
        askingAgain = rewinding?.asked
        sending = Task { await deliver(text, hidden: hidden, with: files, to: bot, through: roster, seen: seen, receipt: receipt, rewinding: rewinding) }
        return true
    }

    private func deliver(_ text: String, hidden: Bool = false, with files: [PickedFile] = [], to bot: Bot, through roster: RosterModel, seen: (@MainActor () -> Bool)? = nil, receipt: ((Bool?) -> Void)? = nil, rewinding: LatestTurn? = nil) async {
        // Kept here as well as in `turn`, so nothing that clears the screen can leave this waiting.
        var answer = LiveTurn()
        var accepted = false
        // Whether the gateway took it, said once: as soon as it did, or when it is known it did not.
        var told = false
        func tell(_ took: Bool?) {
            guard !told else { return }
            told = true
            receipt?(took)
        }
        defer { tell(false) }
        // Words not sent go back to the composer, unless a page sent them.
        let unsent = hidden ? "" : text
        /// Takes back what was handed over for this message, while it has not gone.
        var staged: (() -> Void)?
        defer { if !accepted { staged?() } }
        do {
            let client = try await roster.liveClient()
            // Left for another gateway meanwhile: that connection is not this chat's to use.
            guard !isAbandoned else { throw CancellationError() }
            // A new soul being saved is had by this turn: the chat is told to take it up, or a
            // chat not started yet starts with it, before anything goes.
            await roster.personalitySettled(for: bot)
            try Task.checkCancellation()
            guard !isAbandoned else { throw CancellationError() }
            var open = try await liveChat(of: bot, on: client, through: roster)
            // The fence first, then the check: anything said after the check moves the fence.
            var fence: RewindFence?
            if let rewinding {
                fence = try await client.rewindFence(in: open, profile: bot.name)
                try await stillLatest(rewinding, of: bot, through: roster)
            }
            // Pictures from a message that did not go may still be waiting in this chat.
            // Nothing is sent into it until they are known to be gone.
            open = try await emptied(open, of: bot, on: client, through: roster)
            let steps = await client.turnEvents(in: open)
            try Task.checkCancellation()
            // What is attached is handed to the gateway first, and the message then names it.
            var message = text
            var pictures: [StagedPicture] = []
            if !files.isEmpty {
                // Whatever happens from here until the gateway has said it has the
                // message, the pictures handed over are taken back.
                let into = open
                staged = { [weak self] in self?.takeBack(in: into, on: client, for: bot, through: roster) }
                (message, pictures) = try await attach(files, to: text, in: open, on: client, for: bot, through: roster)
            }
            // A page's waits its turn, and goes only if the page is still in sight.
            if let seen {
                guard await Self.pageTurn(seen) else { throw PageOutOfSight() }
                try Task.checkCancellation()
            }
            // And any soul saved while the files went.
            await roster.personalitySettled(for: bot)
            try Task.checkCancellation()
            guard !isAbandoned else { throw CancellationError() }
            // A change to approvals asked for while this waited goes first: sent now, it
            // would run under the approvals being left. Nothing is awaited from here to the send.
            guard !approvalsHeld else { throw ApprovalsWereChanging() }
            stage = .submitting
            let receipt = try await client.send(message, in: open, profile: bot.name, pictures: pictures, hidden: hidden, rewinding: rewinding?.rewind, fence: fence)
            accepted = true
            tell(true)
            staged = nil
            // They went with it.
            roster.picturesWent(in: open)
            try Task.checkCancellation()
            stage = .answering
            // The bot was already working and took the message into that work.
            if receipt == .joined { answer.joinRunningTurn() }
            publish(answer)
            // Sent to a bot that was already working, or with more sent mid-answer, a turn
            // ending is not the end: the answer may come in a later turn, or in several. From
            // then on the chat is followed until it has gone quiet with nothing of the
            // person's left unanswered in the stored chat.
            followsOn = receipt != .started
            owesATurn = receipt == .queued
            turnsBegun = 0
            addedInFlight = 0
            activity = 0

            let (items, feed) = AsyncStream.makeStream(of: LiveItem.self)
            let pump = Task {
                for await step in steps {
                    activity += 1
                    feed.yield(.step(step))
                }
                // The events have run out. That counts as something happening, so a read of
                // the stored chat under way does not go on to settle as if all were well.
                activity += 1
                feed.finish()
            }
            poke = { feed.yield(.poke) }
            isFollowing = true
            var quiet: Task<Void, Never>?
            var quietChecks = 0
            var sawATurnEnd = false
            var gaveUp = false
            /// The loop ended by deciding the answer was over, not by the events running out.
            var finished = false
            /// Asks for a nudge if the chat stays quiet for a while.
            func nudge() {
                quiet?.cancel()
                quiet = Task {
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { feed.yield(.quiet) }
                }
            }
            // A message that had to wait may never be reached, and then nothing at all
            // arrives: start the clock now, not at the first turn's end.
            if followsOn { nudge() }
            defer {
                isFollowing = false
                poke = nil
                pump.cancel()
                quiet?.cancel()
            }
            listening: for await item in items {
                // `turn` is the one copy: a message added mid-answer changes it from send().
                answer = turn ?? answer
                switch item {
                case .poke:
                    // Something was sent or heard back about. Between turns, wait on for
                    // whatever turn that brings.
                    if !answer.isWorking { nudge() }
                case .quiet:
                    // A nudge that crossed with our turn beginning is stale.
                    guard !(answer.isWorking && answer.hasStarted) else { continue }
                    // Something sent mid-answer has not been heard back about yet.
                    guard addedInFlight == 0 else {
                        nudge()
                        continue
                    }
                    if sawATurnEnd {
                        // A turn ended and no further one began. If the stored chat still ends
                        // on something the person said, it has yet to be answered.
                        let seenBefore = activity
                        var stored: [ChatMessage]?
                        if !isAbandoned {
                            // The roster first: an answer can move the chat on to a new id.
                            // And it may have written again to a file it handed over before.
                            roster.answered(bot)
                            await roster.refreshBots()
                            // Checked again before the read, which goes to whatever gateway is current.
                            if !isAbandoned, let now = roster.bots.first(where: { $0.id == bot.id }) {
                                stored = try? await roster.messages(for: now)
                            }
                        }
                        // Something happened during that read: deal with it before deciding.
                        guard activity == seenBefore else {
                            nudge()
                            continue
                        }
                        // Done when nothing is owed and the chat was read and does not end
                        // on something of the person's. A read that failed settles nothing,
                        // and a queued message's row can sit above the answer before it.
                        if !owesATurn, let last = stored?.last, !(last.role == "user" && isOurs(last.text)) {
                            finished = true
                            break listening
                        }
                    }
                    // Still waiting for a turn. Not for ever: the gateway drops a waiting
                    // message without a word when someone stops the bot. Shorter would give
                    // up on a bot that is only deep in one long piece of work.
                    quietChecks += 1
                    guard quietChecks < quietChecksAllowed else {
                        gaveUp = true
                        finished = true
                        break listening
                    }
                    nudge()
                case .step(let step):
                    if step == .started {
                        // Whichever turn this is, a queued message of ours is not kept waiting
                        // on the strength of a flag: from here the stored chat says if it is.
                        turnsBegun += 1
                        owesATurn = false
                    }
                    if !answer.isWorking {
                        // A turn ended while something of ours may still have been waiting. A
                        // new turn beginning says it was, and that turn answers it.
                        switch step {
                        case .started:
                            quiet?.cancel()
                            quietChecks = 0
                            // After something added mid-answer it is the same answer carrying
                            // on. Otherwise what came before was someone else's: start again.
                            if answer.hasAdditions { answer.carryOn() } else { answer = LiveTurn() }
                        case .trouble(let reason), .finished(_, .failed(let reason)):
                            // Ours could not begin. With nothing else on its way, that is the end.
                            sendProblem = reason.isEmpty ? "The bot couldn't start on the message." : reason
                            if addedInFlight == 0 {
                                finished = true
                                break listening
                            }
                            continue
                        default:
                            continue
                        }
                    }
                    answer.apply(step)
                    publish(answer)
                    if followsOn, answer.isWorking, !answer.hasStarted {
                        // Another turn is still talking, so the chat is not quiet.
                        quietChecks = 0
                        nudge()
                    }
                    guard !answer.isWorking else { continue }
                    var over = !(followsOn || addedInFlight > 0) || stopRequested
                    // A turn that failed is not followed by another: say why now.
                    if case .failed = answer.outcome, addedInFlight == 0 { over = true }
                    guard !over else {
                        finished = true
                        break listening
                    }
                    sawATurnEnd = true
                    nudge()
                }
            }
            // Nothing can be added from here on: the loop that would follow it has gone.
            isFollowing = false
            answer = turn ?? answer
            if !finished {
                // The events ran out first: Stop gave up waiting, or the connection went,
                // perhaps between two turns with an answer still to come.
                guard stopRequested else { throw GatewayError.connectionLost("") }
                if answer.isWorking {
                    answer.endStopped()
                    publish(answer)
                }
            }
            if stopRequested {
                sendProblem = nil
            } else if gaveUp {
                sendProblem = "The bot hasn't started on this message. It may have been dropped; check before sending it again."
            } else if case .failed(let reason) = answer.outcome {
                sendProblem = reason.isEmpty ? "The bot couldn't finish its answer." : reason
            }
            settle(bot, through: roster, readStored: true)
        } catch {
            if let rewinding, stage == .opening || stage == .submitting {
                // A retry that did not go: the gateway's chat says what is left. The words are
                // given back only if the message was taken back and not asked again.
                if case GatewayError.unsupported = error { cannotRewind = true } else if error is ApprovalsWereChanging {
                    sendProblem = Self.heldForApprovals
                } else if !stopRequested {
                    sendProblem = GatewayProblem.actionText("retry", for: error)
                }
                let open = stage == .submitting && stopRequested ? live : nil
                live = nil
                sent = nil
                turn = nil
                // Shown as it was read until the read below says otherwise.
                askingAgain = nil
                // Once the request that cuts has gone, the cut may have been made with the
                // message not asked again (the session authority cuts first; a refusal can
                // come after it). The next read says. Before that, nothing was cut.
                if stage == .submitting { wordsIfGone = (rewinding.asked, text) }
                settle(bot, through: roster, readStored: true, stopping: open)
                return
            }
            switch stage {
            case .opening:
                // Never sent. Put the words back; say why, unless it was Stop.
                giveBack(unsent)
                giveBack(files)
                if case GatewayError.unsupported = error { cannotSend = true }
                // A page that went out of sight before its message could go: nothing to say.
                if error is ApprovalsWereChanging {
                    sendProblem = Self.heldForApprovals
                } else if !stopRequested, !(error is PageOutOfSight) {
                    // For a bot with no chat yet, what the gateway lacks is starting one.
                    if case GatewayError.unsupported = error, bot.chat == nil {
                        sendProblem = "This gateway can't start a new bot's chat."
                    } else {
                        sendProblem = GatewayProblem.sendText(for: error, onThisMac: roster.isThisMac, signedIn: roster.isSignedIn)
                    }
                }
                settle(bot, through: roster, readStored: false)
            case .submitting:
                // Refused outright, as opposed to no answer either way.
                let refused = switch error {
                case GatewayError.unsupported, GatewayError.notConnected, GatewayError.rejected: true
                default: false
                }
                if refused {
                    if case GatewayError.unsupported = error { cannotSend = true }
                    giveBack(unsent)
                    giveBack(files)
                    // The open chat may be what the gateway refused; open it afresh next time.
                    live = nil
                    sendProblem = GatewayProblem.sendText(for: error, onThisMac: roster.isThisMac, signedIn: roster.isSignedIn)
                    // 4090 covers both "nothing was sent" and "it may be queued"; the gateway's
                    // own words, shown above, say which, and the stored chat settles it.
                    var mayHaveIt = false
                    if case GatewayError.rejected(4090, _) = error { mayHaveIt = true }
                    if case GatewayError.rejected(_, let message) = error, message.localizedCaseInsensitiveContains("nothing was sent") { mayHaveIt = false }
                    tell(mayHaveIt ? nil : false)
                    settle(bot, through: roster, readStored: mayHaveIt)
                } else {
                    // Stopped, or no answer either way. The bot has it or may have it, so
                    // stop it if that was asked, and let the stored chat say what happened.
                    let open = live
                    if !accepted {
                        tell(nil)
                        giveBack(unsent)
                        giveBack(files)
                        live = nil
                        sendProblem = "The message may not have been sent. Check the chat before sending it again."
                    }
                    settle(bot, through: roster, readStored: true, stopping: stopRequested ? open : nil)
                }
            default:
                // Lost mid-answer. What arrived stays on screen until the chat is read again.
                live = nil
                sendProblem = "Lost the connection while the bot was answering. The rest will be here when the chat is opened again."
                settle(bot, through: roster, readStored: false)
            }
        }
    }

    /// Hands each file to the gateway and returns the message to send, with what was
    /// handed over: the words, and a reference for each file that is not a picture. Where
    /// the session authority handles chats, pictures are only held on the gateway, and are
    /// returned to be named on the message; nothing waits in the chat there.
    ///
    /// A picture handed over waits on the gateway for the next message in that chat, so
    /// one left there would go with whatever is sent next. So the file on its way is
    /// never cut short: it is let finish even if the send is stopped meanwhile, so that
    /// every picture the gateway has is known, and can be taken back. No more are begun.
    private func attach(_ files: [PickedFile], to text: String, in open: LiveChat, on client: GatewayClient, for bot: Bot, through roster: RosterModel) async throws -> (message: String, pictures: [StagedPicture]) {
        let profile = bot.name
        let held = await client.usesSessionAuthority
        // Written down before the first picture goes, and kept by the roster rather than
        // here: if this chat is left part way, whoever sends into it next still knows.
        if !held, files.contains(where: \.isPicture) { roster.picturesMayWait(in: open) }
        // Off the main thread: making a large file into text for sending takes a moment.
        // The one on its way is let finish, so that where the gateway put it is known;
        // no more are begun once the send is stopped or the chat left.
        let stopped = OSAllocatedUnfairLock(initialState: false)
        let staging = Task.detached { () -> (attached: [Attached], failure: (any Error)?) in
            var attached: [Attached] = []
            for file in files {
                if stopped.withLock({ $0 }) { return (attached, CancellationError()) }
                do {
                    // That route takes no BMP as a picture: it goes as a PNG.
                    let file = held ? try file.asHeldPicture() : file
                    if stopped.withLock({ $0 }) { return (attached, CancellationError()) }
                    // Noted before it goes, and kept until the gateway answers about it.
                    if !held, file.isPicture {
                        await roster.pictureGoes(in: open)
                        // Stopped while that was being noted: it does not go.
                        if stopped.withLock({ $0 }) {
                            await roster.pictureAnswered(in: open)
                            return (attached, CancellationError())
                        }
                    }
                    let one = file.isPicture
                        ? try await client.attachImage(file.data, named: file.name, in: open, profile: profile)
                        : try await client.attachFile(file.data, named: file.name, type: file.type, in: open, profile: profile)
                    if case .image(let path, _) = one {
                        await roster.pictureWaits(at: path, in: open)
                        await roster.pictureAnswered(in: open)
                    }
                    attached.append(one)
                } catch {
                    // With no answer either way, the gateway may queue it after any count it gives.
                    if !held, file.isPicture, Self.answered(error) { await roster.pictureAnswered(in: open) }
                    return (attached, error)
                }
            }
            return (attached, nil)
        }
        // Waited for whatever happens to this send: its own task is not the one cancelled.
        // The caller takes back what was handed over if this throws.
        // Whoever sends into this open chat next waits for it too, this screen or another.
        roster.afterPictureWork(in: open) { _ = await staging.value }
        let (attached, failure) = await withTaskCancellationHandler {
            await staging.value
        } onCancel: {
            stopped.withLock { $0 = true }
        }
        if let failure {
            // A gateway with no such method is not one that cannot be sent to.
            if case GatewayError.unsupported = failure {
                cannotAttach = true
                throw GatewayError.rejected(code: 0, message: "This gateway doesn't take attachments.")
            }
            throw failure
        }
        try Task.checkCancellation()
        let references = attached.compactMap { item -> String? in
            if case .file(let reference, _) = item { return reference }
            return nil
        }
        let pictures = attached.compactMap { item -> StagedPicture? in
            if case .staged(let picture) = item { return picture }
            return nil
        }
        var message = ([text] + references).filter { !$0.isEmpty }.joined(separator: " ")
        // Pictures and no words: Hermes's own stand-in for the words, which it takes out again.
        if message.isEmpty {
            message = attached.compactMap { item -> String? in
                switch item {
                case .image(_, let name): "[User attached image: \(name)]"
                case .staged(let picture): "[User attached image: \(picture.name)]"
                case .file: nil
                }
            }.joined(separator: "\n")
        }
        // What the stored chat will hold for it, to know it for our own.
        ours = [message]
        return (message, pictures)
    }

    /// Takes back pictures handed to the gateway for a message that did not go. In a task
    /// of its own, since the send it belonged to may be the very thing that was stopped;
    /// the next send into this chat waits for it, and checks what it left.
    private func takeBack(in open: LiveChat, on client: GatewayClient, for bot: Bot, through roster: RosterModel) {
        guard roster.picturesWaiting(in: open) != nil else { return }
        let profile = bot.name
        roster.afterPictureWork(in: open) { _ = await Self.takeBack(in: open, on: client, profile: profile, through: roster) }
    }

    /// Asks the gateway to take back each picture known to wait in `open`, and then how
    /// many are left. True when it says none: only then is the chat's note cleared. A
    /// picture the gateway took without our hearing so is not known by its place, so
    /// taking back the known ones is no proof on its own.
    private static func takeBack(in open: LiveChat, on client: GatewayClient, profile: String, through roster: RosterModel) async -> Bool {
        guard let paths = roster.picturesWaiting(in: open) else { return true }
        var left: Int?
        for path in paths + [GatewayClient.noPicture] {
            do {
                left = try await client.detachImage(at: path, in: open, profile: profile)
            } catch GatewayError.unsupported where paths.isEmpty {
                // A gateway that knows nothing of pictures, and took none: none wait.
                left = 0
            } catch {
                left = nil
            }
        }
        guard left == 0, !roster.picturesMayLandLate(in: open) else { return false }
        roster.picturesWent(in: open)
        return true
    }

    /// The gateway answered the request, so it has done whatever it was going to do with it.
    nonisolated private static func answered(_ error: any Error) -> Bool {
        switch error {
        case GatewayError.rejected, GatewayError.unsupported, GatewayError.unexpectedReply: true
        default: false
        }
    }

    /// The open chat with nothing waiting in it from a message that did not go. If the
    /// gateway cannot be got to say so, and the bot is not at work in it, the open chat
    /// is closed and opened afresh, which drops whatever waited. A chat the bot is at
    /// work in is never closed for this, nor one the gateway will not speak for: then
    /// nothing is sent.
    private func emptied(_ open: LiveChat, of bot: Bot, on client: GatewayClient, through roster: RosterModel) async throws -> LiveChat {
        await roster.pictureWorkEnded(in: open)
        guard roster.picturesWaiting(in: open) != nil else { return open }
        guard !isAbandoned else { throw CancellationError() }
        if await Self.takeBack(in: open, on: client, profile: bot.name, through: roster) { return open }
        let waiting = GatewayError.rejected(code: 0, message: "A picture from a message that didn't go may still be waiting on the gateway, and would go with this one. Try again when the bot has finished what it is doing.")
        guard let chat = bot.chat, await client.isAnswering(in: chat, profile: bot.name) == false else { throw waiting }
        do {
            try await client.close(open, profile: bot.name)
        } catch {
            throw waiting
        }
        roster.picturesWent(in: open)
        live = nil
        guard !isAbandoned else { throw CancellationError() }
        return try await liveChat(of: bot, on: client, through: roster)
    }

    /// One of our own messages, as the stored chat holds it: alone, or joined to others the
    /// gateway merged it with while they waited.
    private func isOurs(_ stored: String) -> Bool {
        // Without what the gateway adds after a message that had attachments.
        let stored = SentParts(stored: stored).asSent
        let pieces = stored.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ours.contains { stored.trimmingCharacters(in: .whitespacesAndNewlines) == $0 || pieces.contains($0) }
    }

    /// Puts the words of an added message that was not sent back in the composer: after any
    /// given back before it, so they read in the order sent, and ahead of anything typed since.
    private func giveBackAdded(_ text: String) {
        if !givenBack.isEmpty, messageDraft.hasPrefix(givenBack) {
            let typed = messageDraft.dropFirst(givenBack.count)
            givenBack += "\n" + text
            messageDraft = givenBack + typed
        } else {
            givenBack = text
            messageDraft = messageDraft.isEmpty ? text : text + "\n" + messageDraft
        }
    }

    /// Puts unsent words back in the composer, ahead of anything typed since.
    private func giveBack(_ text: String) {
        sent = nil
        sentAttachments = []
        turn = nil
        putAhead(text)
    }

    /// Ends a send. `isWorking` stays true until the stored chat has replaced what was shown
    /// live, so nothing can be sent into that gap and then wiped by the read.
    private func settle(
        _ bot: Bot, through roster: RosterModel, readStored: Bool,
        stopping open: (chat: LiveChat, client: GatewayClient)? = nil
    ) {
        stage = .settling
        // Words gathered and not yet shown are shown: what arrived stays on screen if the
        // chat is not read again.
        if let pending = pendingTurn { display(pending) }
        guard !isAbandoned else {
            sending = nil
            return
        }
        // A new task: this one may have been cancelled by Stop, and a cancelled task can
        // neither stop the bot nor read the chat.
        let adding = adding
        sending = Task {
            // A message added mid-answer may still be on its way. Nothing new is sent into
            // this chat until it has landed or been given up.
            await adding?.value
            if let open { try? await open.client.stop(open.chat, profile: bot.name) }
            // Before the stored chat takes the place of what was shown live: a page in a reply
            // shown only live is read again too.
            pagesAnswered(well: readStored && sendProblem == nil && !stopRequested)
            if readStored, !isAbandoned {
                // The roster first: an answer can move the chat on to a new id.
                await roster.refreshBots()
                // Checked again before the read, which goes to whatever gateway is current.
                // A bot whose first chat the roster does not yet show has no stored chat to
                // read: what is on screen stays, rather than being taken for an empty chat.
                var shown: Bot?
                let clock = reactionClock
                let asked = window
                if !isAbandoned, let now = roster.bots.first(where: { $0.id == bot.id }), now.chat != nil || bot.chat != nil,
                   let messages = try? await roster.messages(for: now, limit: asked), !isAbandoned {
                    freshen(show(messages, asked: asked, readFrom: clock), of: now, through: roster)
                    shown = now
                }
                sending = nil
                // The answer is on screen as stored, so the roster may count it read, and
                // need not read it in again.
                if let shown { roster.didShow(shown) }
            }
            sending = nil
        }
    }

    /// Stop can do something: a message is on its way to the bot or being answered.
    var canStop: Bool { isWorking && stage != .settling && !stopRequested }

    /// The gateway this chat belongs to is being left. Nothing begun here may go on to read
    /// from or write to whatever gateway comes next.
    func abandon() {
        isAbandoned = true
        sending?.cancel()
        commandOpen?.cancel()
        // Nothing asked about here may be agreed to for whatever gateway comes next.
        leave()
    }

    /// Counts the times this chat has been left, so a question prepared for it before is
    /// not asked when it is next shown.
    private(set) var leaves = 0

    /// The chat is no longer showing: what it was asking goes, as answered with Cancel.
    func leave() {
        leaves += 1
        let pending = confirming
        confirming = nil
        pending?.cancel()
    }

    /// Waits until no message of this chat's is being sent or answered.
    func settled() async {
        while let task = sending {
            await task.value
            // One that is over and still in place is not waited on again.
            if sending == task { return }
        }
    }

    /// Stops the message being sent or answered. On the gateway this stops whatever the bot
    /// is doing in this chat and drops anything waiting behind it.
    func stop(_ bot: Bot) {
        guard canStop else { return }
        stopRequested = true
        guard stage == .answering, let live else {
            // Not known to be with the bot yet: stop the sending itself.
            sending?.cancel()
            return
        }
        let answering = sending
        let thisSend = sendCount
        Task {
            do {
                try await live.client.stop(live.chat, profile: bot.name)
            } catch {
                // Not stopped, so keep following the answer, if it is still this one.
                if thisSend == sendCount, stage == .answering {
                    stopRequested = false
                    sendProblem = "Couldn't stop the bot."
                }
                return
            }
            // The gateway ends a running turn within moments. It says nothing about a message
            // that was still waiting its turn, so don't wait for long.
            try? await Task.sleep(for: .seconds(3))
            if thisSend == sendCount, stage == .answering, stopRequested { answering?.cancel() }
        }
    }

    /// How full the open chat is and what it has used. Nil when it is not open, or the
    /// gateway can't say.
    func usage(for bot: Bot) async -> ChatUsage? {
        guard let live else { return nil }
        return try? await live.client.usage(of: live.chat, profile: bot.name)
    }

    /// The open chat on this connection, opened on first use. A bot that has never had a
    /// chat gets one started.
    func liveChat(of bot: Bot, on client: GatewayClient, through roster: RosterModel) async throws -> LiveChat {
        if let live, live.client === client { return live.chat }
        let open: LiveChat
        var started = false
        if let chat = bot.chat {
            open = try await client.openChat(chat, profile: bot.name)
        } else {
            do {
                open = try await client.startChat(profile: bot.name)
                started = true
            } catch let refusal as GatewayError {
                guard case .rejected = refusal else { throw refusal }
                // Perhaps the bot has a chat after all, started somewhere else since the
                // roster was read: the gateway would not make a second. Find that one and
                // open it. If there is none, the refusal was about something else: say so.
                await roster.refreshBots()
                guard !isAbandoned else { throw CancellationError() }
                guard let chat = roster.bots.first(where: { $0.id == bot.id })?.chat else { throw refusal }
                open = try await client.openChat(chat, profile: bot.name)
            }
        }
        // Left for another gateway meanwhile: this one's roster is not to be told.
        guard !isAbandoned else { throw CancellationError() }
        // Known to the roster at once, before it is read again, so a soul saved from now on
        // asks this chat to take it up.
        if started { roster.started(open, for: bot) }
        // Pictures may wait in an open chat handed back from a run that was quit. Not in one
        // just started, nor where the session authority handles chats: this app queues none there.
        let held = await client.usesSessionAuthority
        // Asked again after that hop: the gateway may have been left meanwhile.
        guard !isAbandoned else { throw CancellationError() }
        if !started, !held { roster.opened(open) }
        live = (open, client)
        // Questions the bot was already waiting on there, and any that came before this.
        roster.chatOpened(open, of: bot, on: client)
        return open
    }

    /// The gateway has let go of this open chat: the next use opens it again. Not while a
    /// message is under way, whose own following of the chat decides.
    func letGo(of open: LiveChat) {
        if !isWorking, live?.chat == open { live = nil }
    }

    /// The open chat as the gateway holds it this very moment: asked again, unless a message
    /// is under way in it, which shows it open. An older Hermes (before September 2026) took
    /// an id it had let go of for no chat at all, and applied `/yolo` to every chat it runs.
    /// Taken up as any opening is: the next message uses it, and the roster is told, so the
    /// questions in its snapshot are put up and those asked in it later find this chat.
    func reopened(_ open: LiveChat, of bot: Bot, on client: GatewayClient, through roster: RosterModel) async throws -> LiveChat {
        guard !isWorking, let chat = bot.chat else { return open }
        let fresh = try await client.openChat(chat, profile: bot.name)
        let held = await client.usesSessionAuthority
        guard !isAbandoned else { throw CancellationError() }
        if live == nil || (live?.chat == open && live?.client === client) { live = (fresh, client) }
        // Opened again under another live id, pictures may wait in it as in any chat handed back.
        if fresh.sessionID != open.sessionID, !held { roster.opened(fresh) }
        roster.chatOpened(fresh, of: bot, on: client)
        return fresh
    }

    /// What the person sent: bold, italics, code and links inside a line, and otherwise as typed.
    private static func style(_ text: String) -> [StyledBlock] {
        [StyledBlock(id: 0, kind: .paragraph, raw: text, text: inline(text))]
    }

    /// What a bot said, with its headings, lists, quotes and code blocks laid out. Blocks
    /// that read the same as before are kept, so a reply still arriving costs only its end.
    private static func style(reply text: String, reusing before: [StyledBlock] = []) -> [StyledBlock] {
        ReplyFormat.blocks(of: text).map { block in
            // Not one still grey at its end: that is styled again, in full colour.
            if block.id < before.count, before[block.id].kind == block.kind, before[block.id].raw == block.text, !before[block.id].isGreyed {
                return before[block.id]
            }
            switch block.kind {
            // Code is shown exactly as written, marks and all.
            case .code: return StyledBlock(id: block.id, kind: .code, raw: block.text, text: AttributedString(block.text))
            // Where a file is, exactly as written.
            case .file, .page: return StyledBlock(id: block.id, kind: block.kind, raw: block.text, text: AttributedString(block.text))
            case .table:
                return StyledBlock(
                    id: block.id, kind: .table, raw: block.text, text: AttributedString(),
                    cells: ReplyFormat.rows(ofTable: block.text).map { $0.map(inline) }
                )
            default: return StyledBlock(id: block.id, kind: block.kind, raw: block.text, text: inline(block.text))
            }
        }
    }

    /// The blocks with the last few characters of the last one in grey: the words that
    /// have only just arrived. A table is left alone.
    private static func greying(last count: Int, of blocks: [StyledBlock]) -> [StyledBlock] {
        guard count > 0, var block = blocks.last, block.kind != .table, !block.text.characters.isEmpty else { return blocks }
        var text = block.text
        let start = text.characters.index(text.endIndex, offsetBy: -min(count, text.characters.count))
        text[start..<text.endIndex].foregroundColor = Color.gray
        block = StyledBlock(id: block.id, kind: block.kind, raw: block.raw, text: text, cells: block.cells, isGreyed: true)
        return blocks.dropLast() + [block]
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

extension GatewayProblem {
    /// Why Retry, Undo or a reaction did not happen. `verb` is what was being done.
    static func actionText(_ verb: String, for error: any Error) -> String {
        switch error {
        case GatewayError.unsupported: "This gateway can't \(verb)."
        // The session authority's refusals are words for programs.
        case GatewayError.rejected(_, "revision_conflict"), GatewayError.rejected(_, "stale_generation"):
            "Couldn't \(verb). Something new was said in the chat meanwhile."
        case GatewayError.rejected(_, "session_busy"): "Couldn't \(verb). The bot is busy in this chat."
        case GatewayError.rejected(_, "not_found"): "Couldn't \(verb). That message is no longer in the chat."
        case GatewayError.rejected(_, let message) where !message.isEmpty: "Couldn't \(verb). \(message)"
        default: "Couldn't \(verb). \(text(for: error))"
        }
    }

    static func sendText(for error: any Error, onThisMac: Bool = false, signedIn: Bool = false) -> String {
        switch error {
        case GatewayError.unauthorized where signedIn: "Couldn't send. \(signInEnded)"
        // On this Mac there is no token to have been refused.
        case GatewayError.unauthorized where onThisMac: "Couldn't send. \(thisMacRefused)"
        case GatewayError.unsupported: "This gateway doesn't offer sending messages."
        case GatewayError.rejected(_, let message) where !message.isEmpty: "The gateway didn't take the message: \(message)"
        case GatewayError.timedOut: "The bot took too long to wake up."
        default: "Couldn't send. \(text(for: error))"
        }
    }
}

/// Where the reaction picker is open: on which stored row, with the button it floats over
/// in the window's own coordinates.
struct ReactionPickerTarget {
    let row: Int
    var anchor: CGRect
}

struct ChatView: View {
    let bot: Bot
    let roster: RosterModel
    @Binding var reactionPicker: ReactionPickerTarget?
    /// Raised by Try Again. Part of the load's identity, so a retry is cancelled like any
    /// other load when another bot is selected.
    @State private var attempt = 0
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var composerHeight: CGFloat = 46
    /// The field for finding words in this chat is open, with what is typed in it and the
    /// find gone to. Belongs to this bot's chat: another bot's opens without it.
    @State private var isFinding = false
    @State private var findQuery = ""
    @State private var currentFind: ChatFind.Match?
    /// Counts goings to a find, each of which brings it into sight.
    @State private var findJumps = 0
    /// How near the top of what is shown the chat is scrolled, and whether it has been at its
    /// end since it opened.
    private enum Top { case far, near, fits }
    private struct Place: Equatable {
        let top: Top
        let atEnd: Bool
        let offset: CGFloat
        let height: CGFloat
    }
    /// Where the chat was last scrolled, and how far from its end to keep it while older rows
    /// are read in above. Not state: it changes with every step of a scroll, and nothing is
    /// drawn from it.
    private final class ScrollMemo {
        var last: Place?
        /// Older rows are on their way (`ChatModel.olderShown` as it was when asked for): when
        /// they come, what was in sight is kept in place.
        var pagingFrom: Int?
        var reads = 0
    }
    @State private var scrollMemo = ScrollMemo()
    @State private var top = Top.far
    /// The bot whose chat has been at its end since it was opened.
    @State private var landedIn: Bot.ID?
    /// How wide the bot's name floating over the chat is, so the find pill keeps clear of it.
    @Environment(\.pillWidth) private var pillWidth
    /// A panel is open over the window: cards behind it take no keys or clicks.
    @Environment(\.isCovered) private var isCovered
    /// How large the chat's words are, ⌘+ and ⌘− (kept on this Mac).
    @AppStorage(TextZoom.key) private var zoom = 1.0
    @Environment(\.colorScheme) private var scheme

    private static var scrollBarWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    private struct LoadKey: Hashable {
        let bot: Bot.ID
        let attempt: Int
    }

    var body: some View {
        let theme = Theme(scheme)
        let chat = roster.chat(for: bot)
        GeometryReader { pane in
            // Only once the chat is loaded: a scroll view that opens empty and fills in
            // afterwards does not land exactly on its end.
            if chat.phase == .loaded {
                let finds = isFinding ? findsIn(chat) : []
                let items = chat.items
                // Each command's note after what the chat ended with when it ran; at the end
                // when that is no longer shown.
                let shownIDs = Set(items.map(\.id))
                let placed = Dictionary(grouping: chat.notes.filter { $0.after.map(shownIDs.contains) ?? false }, by: { $0.after! })
                let gone = chat.notes.filter { $0.after.map { !shownIDs.contains($0) } ?? false }
                ScrollViewReader { scroller in
                ScrollView {
                    // Not lazy: what is shown is a page or a few of the chat's latest rows
                    // (`ChatModel.window`), and a lazy stack anchored to the bottom can come up blank.
                    VStack(spacing: 14) {
                        let lines = chat.settledQuestions
                        ForEach(lines[nil] ?? []) { QuestionLine(asked: $0) }
                        // Made while the chat was empty: before everything said since.
                        ForEach(chat.notes.filter { $0.after == nil }) { note(chat, $0) }
                        ForEach(items) { item in
                            MessageRow(item: item, look: look(of: item, in: chat), bot: bot, roster: roster, chat: chat, reactionPicker: $reactionPicker)
                                .equatable()
                                // Said outright, as for a part of a reply (`ReplyPart`).
                                .alignmentGuide(HorizontalAlignment.center) { $0.width / 2 }
                                .id(item.id)
                            ForEach(lines[item.id] ?? []) { QuestionLine(asked: $0) }
                            ForEach(placed[item.id] ?? []) { note(chat, $0) }
                        }
                        ForEach(gone) { note(chat, $0) }
                        let open = chat.questions.cards
                        let shortcutsGoTo = open.first { if case .approval = $0.question.kind { true } else { false } }?.id
                        ForEach(open) { asked in
                            // Behind a panel the card takes no shortcut and no click.
                            QuestionCard(asked: asked, bot: bot, look: roster.look(for: bot), gatewayName: roster.gatewayName ?? "the gateway",
                                         chat: chat, takesShortcuts: !isCovered && asked.id == shortcutsGoTo)
                                .disabled(isCovered)
                                .id("question-\(asked.id)")
                        }
                        if chat.isWaitingForWords {
                            WorkingMark(roster.look(for: bot), status: chat.waitingStatus)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 6)
                                .padding(.top, 4)
                        }
                        if let problem = chat.sendProblem {
                            notice(problem, theme)
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: Composer.width)
                    .padding(.horizontal, 24)
                    .padding(.top, 72)
                    // Room for the composer, which floats over the end of the chat.
                    .padding(.bottom, chat.cannotSend ? 28 : composerHeight + 46)
                    // At least as tall as the pane, so a short chat starts at the top while a
                    // long one opens on its newest message.
                    .frame(maxWidth: .infinity, minHeight: pane.size.height, alignment: .top)
                }
                // Anchored to the end for size changes too, so rows read in above leave what is
                // in sight where it was.
                .defaultScrollAnchor(.bottom)
                .scrollPosition($position)
                // Near the top of what is shown, however it got there (a wheel, the keys, the
                // scroll bar), once it has landed on its end (a scroll view that has just opened
                // can say it is at the top before it gets there), or when it all fits: a page
                // more of the chat's history is read in.
                .onScrollGeometryChange(for: Place.self) { geometry in
                    Place(
                        top: geometry.contentSize.height <= geometry.containerSize.height ? .fits : geometry.contentOffset.y < 600 ? .near : .far,
                        atEnd: geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 2,
                        offset: geometry.contentOffset.y, height: geometry.contentSize.height
                    )
                } action: { before, place in
                    scrollMemo.last = place
                    if place.atEnd, landedIn != bot.id { landedIn = bot.id }
                    // Rows read in above leave what was in sight where it was: as far from the
                    // end as it was the moment before they came (not when they were asked for,
                    // since the person may have scrolled meanwhile). Once, for those rows, and
                    // only once they have been shown: nothing else that grows before takes it.
                    if let from = scrollMemo.pagingFrom, chat.olderShown > from, place.height > before.height {
                        scrollMemo.pagingFrom = nil
                        position.scrollTo(y: max(0, place.height - (before.height - before.offset)))
                        // Where this pass says the chat is comes before that: not near the top.
                        return
                    }
                    // Not while older rows are on their way: the rows coming put the chat
                    // elsewhere, and saying now that it is near the top would read on at once.
                    if scrollMemo.pagingFrom == nil, top != place.top { top = place.top }
                }
                .onChange(of: chat.canLoadOlder && (top == .fits || top == .near && landedIn == bot.id), initial: true) { _, wants in
                    guard wants else { return }
                    // Away from the top until the chat says otherwise: the rows coming put it
                    // there, and what it last said is from before they came.
                    top = .far
                    scrollMemo.pagingFrom = chat.olderShown
                    scrollMemo.reads += 1
                    let read = scrollMemo.reads
                    Task {
                        let shown = await chat.loadOlder(bot, from: roster)
                        // What came is in place: where the chat now is says whether to read on
                        // (a page that added nothing in sight changes nothing the chat would say
                        // by itself). One that did not come is not asked for again until the
                        // chat is scrolled: the gateway may be away.
                        try? await Task.sleep(for: .milliseconds(400))
                        guard scrollMemo.reads == read else { return }
                        scrollMemo.pagingFrom = nil
                        if shown, let last = scrollMemo.last, top != last.top { top = last.top }
                    }
                }

                // Anything else that moves the chat comes before keeping its place.
                .onChange(of: chat.scrollCount) { scrollMemo.pagingFrom = nil }
                .onChange(of: findJumps) { scrollMemo.pagingFrom = nil }
                .onChange(of: chat.questions.open.map(\.id)) { scrollMemo.pagingFrom = nil }
                // Where nothing floats over the chat: below the fade under the bot's name and
                // above the message box. A page's line must be there for the page to send.
                // The field for finding, while it is open, can reach below the fade.
                .environment(\.chatClear, Self.clearTop(isFinding)...max(Self.clearTop(isFinding), pane.size.height - (chat.cannotSend ? 0 : composerHeight + 16)))
                // Sending shows the message, wherever the chat had been scrolled to.
                .onChange(of: chat.scrollCount) { position.scrollTo(edge: .bottom) }
                // A question the bot is waiting on is brought into sight when it comes.
                .onChange(of: chat.questions.open.map(\.id)) { before, now in
                    if now.contains(where: { !before.contains($0) }) { withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) } }
                }
                // A fresh scroll view per bot: each chat opens at its end, wherever the last was left.
                .id(bot.id)
                // What scrolls up under the bot's name fades out before it gets there.
                .overlay(alignment: .top) {
                    LinearGradient(
                        stops: [.init(color: theme.canvas, location: 0), .init(color: theme.canvas, location: 0.35), .init(color: theme.canvas.opacity(0), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: Self.fade)
                    .padding(.trailing, Self.scrollBarWidth)
                    .allowsHitTesting(false)
                }
                // Older rows being read in above: over the fade, just under the bot's name
                // (which floats 10 to 48 down), so it is seen wherever the chat is scrolled.
                .overlay(alignment: .top) {
                    if chat.isLoadingOlder {
                        ProgressView().controlSize(.small)
                            .padding(.top, 58)
                            .padding(.trailing, Self.scrollBarWidth)
                            .allowsHitTesting(false)
                    }
                }
                // The find gone to is brought into sight; one that has gone from the chat
                // gives way to the newest that is left.
                .onChange(of: finds) { _, finds in
                    if let currentFind, finds.contains(currentFind) { return }
                    currentFind = finds.last
                    findJumps += 1
                }
                // What is typed goes to the newest find, whatever was gone to before.
                .onChange(of: findQuery) {
                    currentFind = findsIn(chat).last
                    findJumps += 1
                }
                // Each step brings its find into sight, even the one already gone to, which
                // may have been scrolled away from.
                .onChange(of: findJumps) {
                    guard let find = currentFind else { return }
                    // To the part of the message the find is in, not the whole of it: a long
                    // reply centred in the pane can have its end under the composer.
                    let item = chat.items.first { $0.id == find.item }
                    let stretch = item.flatMap { Self.shownBlocks(of: $0, in: chat) }
                        .flatMap { Self.stretches(of: $0).first { $0.blocks.contains { $0.id == find.block } } }
                    withAnimation(.easeOut(duration: 0.2)) {
                        if let stretch {
                            scroller.scrollTo(Self.partID(find.item, stretch.id), anchor: .center)
                        } else {
                            scroller.scrollTo(find.item, anchor: .center)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isFinding {
                        FindBar(
                            query: $findQuery, count: finds.count,
                            place: currentFind.flatMap { finds.firstIndex(of: $0) },
                            asks: chat.findAsks,
                            step: {
                                currentFind = ChatFind.step($0, from: currentFind, in: finds)
                                findJumps += 1
                            },
                            close: closeFind
                        )
                        // Beside the bot's name where there is room, under it where not.
                        .padding(.top, (pane.size.width - pillWidth) / 2 >= FindBar.width + 16 + Self.scrollBarWidth + 8 ? 10 : 56)
                        .padding(.trailing, 16 + Self.scrollBarWidth)
                        .transition(.opacity)
                    }
                }
                }
            }
        }
        // Only over a chat that is showing: one still loading has nothing to find in yet.
        .onChange(of: chat.findAsks) { if chat.phase == .loaded { isFinding = true } }
        .overlay {
            switch chat.phase {
            case .loaded: EmptyView()
            case .loading: ProgressView().controlSize(.small)
            case .unavailable(let reason):
                notice(reason, theme)
            case .failed(let problem):
                VStack(spacing: 8) {
                    notice(problem, theme)
                    Button("Try Again") { attempt += 1 }
                        .controlSize(.small)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if chat.phase == .loaded, !chat.cannotSend {
                VStack(spacing: -ClarifyPanel.underlap) {
                    if let asked = chat.questions.clarifying, case .clarify(let clarify) = asked.question.kind {
                        ClarifyPanel(asked: asked, clarify: clarify, bot: bot, questions: chat.questions)
                            .frame(maxWidth: Composer.width)
                            .disabled(isCovered)
                            // A set of its own each time, so each is seen to appear.
                            .id(asked.instance)
                    }
                    Composer(bot: bot, chat: chat, roster: roster)
                }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { composerHeight = $0 }
                    .padding(.horizontal, 24)
                    // A scroll bar that is always showing narrows the chat; stay in line with it.
                    .padding(.trailing, Self.scrollBarWidth)
                    .padding(.bottom, 16)
                    .id(bot.id)
            }
        }
        // Files dropped anywhere on the chat go in the message box, to be sent with the
        // next message.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard chat.phase == .loaded, chat.canAttach else { return false }
            let dropped = Dropped()
            let group = DispatchGroup()
            // Their places are held from now: Send waits until they are in the box.
            let held = chat.expect(providers.count)
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { dropped.add(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { chat.attach(dropped.urls, expected: held) }
            return true
        }
        .coordinateSpace(name: Self.pane)
        .task(id: LoadKey(bot: bot.id, attempt: attempt)) {
            // Opened at its latest page, however far back it was read last time.
            chat.showLatest()
            await chat.load(bot, from: roster)
        }
        // While clarifying questions are open the message box is their answer; what was
        // being typed is put aside until they go.
        .onChange(of: chat.questions.clarifying?.instance, initial: true) { _, now in chat.clarifyingChanged(to: now) }
        // A slash command that waits for the person to agree. Cancel is what Return does.
        .alert(
            chat.confirming?.title ?? "",
            isPresented: Binding(get: { chat.confirming != nil }, set: { if !$0 { chat.confirming = nil } }),
            presenting: chat.confirming
        ) { asked in
            Button("Cancel", role: .cancel) { asked.cancel() }
                .keyboardShortcut(.defaultAction)
            Button(asked.action) { asked.run() }
        } message: { asked in
            Text(asked.message)
        }
        // Not left for later: what was asked belongs to this chat as it is now.
        .onDisappear { chat.leave() }
    }

    private func note(_ chat: ChatModel, _ note: ChatNote) -> some View {
        NoteView(note: note, bot: bot.title) { chat.dismissNote(note.id) }
            .id("note-\(note.id)")
    }

    /// Closes the field for finding, and the caret goes back to the composer.
    private func closeFind() {
        isFinding = false
        findQuery = ""
        currentFind = nil
        chat(for: bot).focus()
    }

    private func chat(for bot: Bot) -> ChatModel { roster.chat(for: bot) }

    /// A part of a message, by its first block, to scroll to.
    static func partID(_ item: TranscriptItem.ID, _ stretch: Int) -> String { "\(item)#\(stretch)" }

    /// Every find in what the chat has on screen, from the top down.
    private func findsIn(_ chat: ChatModel) -> [ChatFind.Match] {
        ChatFind.matches(of: findQuery, in: chat.items.compactMap { item in
            Self.shownBlocks(of: item, in: chat).map { (item.id, $0) }
        })
    }

    /// The blocks a message shows its words in, as its bubble lays them out. None for a
    /// date or a line about tools used, which are not looked through.
    static func shownBlocks(of item: TranscriptItem, in chat: ChatModel) -> [StyledBlock]? {
        let text: String
        switch item {
        case .bot(_, let said): text = said
        // As the bubble has it: a stored message without what was attached.
        case .user(let id, let sent): text = id < 0 ? sent : chat.parts(of: sent).words
        case .date, .activity: return nil
        }
        guard !text.isEmpty else { return nil }
        return chat.styled[item.id] ?? [StyledBlock(id: 0, kind: .paragraph, raw: text, text: AttributedString(text))]
    }

    /// What a row shows, read from the chat here so the row itself reads nothing of it.
    private func look(of item: TranscriptItem, in chat: ChatModel) -> RowLook {
        var look = RowLook(zoom: TextZoom.clamped(zoom))
        switch item {
        case .date, .activity:
            return look
        case .bot(let id, let text):
            look.reactions = chat.reactions[id] ?? []
            look.canReact = chat.canReact(id)
            look.canRetry = chat.canRetry(id)
            // A reply still arriving has an id below nothing; stored, it has its own. One
            // that arrived whole and could not then be read back stored can change no more
            // either: nothing is at work in the chat.
            look.isSettled = id >= 0 || !chat.isWorking
            look.blocks = shownMarked(item, text, in: chat)
        case .user(let id, let text):
            look.reactions = chat.reactions[id] ?? []
            look.canUndo = chat.canUndo(id)
            if id >= 0 { look.parts = chat.parts(of: text) }
            if id == chat.sentAttachmentsRow { look.onItsWay = chat.sentAttachments }
            look.blocks = shownMarked(item, id < 0 ? text : look.parts.words, in: chat)
        }
        return look
    }

    /// A message's blocks as its bubble shows them, with what is found marked.
    private func shownMarked(_ item: TranscriptItem, _ text: String, in chat: ChatModel) -> [StyledBlock] {
        let shown = chat.styled[item.id] ?? [StyledBlock(id: 0, kind: .paragraph, raw: text, text: AttributedString(text))]
        return isFinding ? ChatFind.marked(shown, in: item.id, query: findQuery, current: currentFind, theme: Theme(scheme)) : shown
    }

    /// The chat's own space, in which a page's line is measured against `chatClear`.
    static let pane = "chat pane"
    /// How tall the fade under the bot's name is.
    static let fade: CGFloat = 84
    /// Where the part of the chat nothing floats over begins: below the fade, or below the
    /// field for finding where it sits under the bot's name (56 down, 38 tall).
    static func clearTop(_ isFinding: Bool) -> CGFloat { isFinding ? max(fade, 56 + 38 + 4) : fade }

    private func notice(_ text: String, _ theme: Theme) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(theme.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
    }

    /// Blocks that follow one another and can be shown as one piece of text, or one block
    /// that stands by itself.
    struct Stretch: Identifiable {
        let blocks: [StyledBlock]
        let flows: Bool
        var id: Int { blocks[0].id }
    }

    static func flows(_ kind: ReplyBlock.Kind) -> Bool {
        switch kind {
        case .paragraph, .heading, .item: true
        case .code, .table, .quote, .rule, .file, .page: false
        }
    }

    static func stretches(of blocks: [StyledBlock]) -> [Stretch] {
        var found: [Stretch] = []
        for block in blocks {
            if flows(block.kind), let last = found.last, last.flows {
                found[found.count - 1] = Stretch(blocks: last.blocks + [block], flows: true)
            } else {
                found.append(Stretch(blocks: [block], flows: flows(block.kind)))
            }
        }
        return found
    }

    /// The blocks of one stretch as a single text: each a paragraph of it, set out as the
    /// separate blocks were.
    static func flowing(_ blocks: [StyledBlock], _ theme: Theme, zoom: CGFloat = 1) -> NSAttributedString {
        flowingText(blocks, theme, zoom: zoom).text
    }

    /// The same, with where the newest words are, which are painted grey over the text for
    /// a moment rather than set in it, so turning them to full colour lays nothing out again.
    static func flowingText(_ blocks: [StyledBlock], _ theme: Theme, zoom: CGFloat = 1) -> (text: NSAttributedString, grey: NSRange?) {
        var greyFrom: Int?
        let whole = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4 * zoom
            if index > 0 { style.paragraphSpacingBefore = gap(above: block.kind, below: blocks[index - 1].kind) * zoom }
            var size: CGFloat = 14 * zoom
            var weight = NSFont.Weight.regular
            let paragraph = NSMutableAttributedString()
            switch block.kind {
            case .heading(let level):
                size = (level == 1 ? 18 : level == 2 ? 16 : 14) * zoom
                weight = .semibold
            case .item(let marker, let depth):
                // The marker ends at one stop and the words begin at the next, and lines
                // that wrap begin under the words.
                let indent = CGFloat(depth) * 19 * zoom
                let markerFont = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                let width = max(12 * zoom, ceil((marker as NSString).size(withAttributes: [.font: markerFont]).width))
                style.tabStops = [NSTextTab(textAlignment: .right, location: indent + width), NSTextTab(textAlignment: .left, location: indent + width + 7 * zoom)]
                style.headIndent = indent + width + 7 * zoom
                paragraph.append(NSAttributedString(string: "\t\(marker)\t", attributes: [
                    .font: markerFont, .foregroundColor: NSColor(theme.secondaryText),
                ]))
            default:
                break
            }
            for run in block.text.runs {
                var font = NSFont.systemFont(ofSize: size, weight: weight)
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(theme.text)]
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight) }
                    if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                }
                if let link = run.link {
                    attributes[.link] = link
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                // The newest words, in grey for a moment: painted over, from here to the end.
                if run.foregroundColor != nil, greyFrom == nil { greyFrom = whole.length + paragraph.length }
                // A find in the chat.
                if let behind = run.backgroundColor { attributes[.backgroundColor] = NSColor(behind) }
                attributes[.font] = font
                // A line break inside a block stays inside its paragraph: as a new paragraph
                // it would begin at the edge, losing a list item's indent.
                let words = String(block.text[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
                paragraph.append(NSAttributedString(string: words, attributes: attributes))
            }
            if index < blocks.count - 1 { paragraph.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size)])) }
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            whole.append(paragraph)
        }
        return (whole, greyFrom.map { NSRange(location: $0, length: whole.length - $0) })
    }

    /// The room between two blocks of a reply: items of a list sit close, a heading stands off.
    static func gap(above kind: ReplyBlock.Kind, below previous: ReplyBlock.Kind) -> CGFloat {
        switch (previous, kind) {
        case (.item, .item): 5
        case (_, .heading): 16
        case (.heading, _): 6
        default: 10
        }
    }

}

/// What one row of the chat shows, worked out by the chat once per redraw. A row is drawn
/// again only when this changes.
struct RowLook: Equatable {
    /// The blocks its words are shown in, with any finds marked. Nil for a date or a line
    /// about tools used.
    var blocks: [StyledBlock]?
    var reactions: [Reaction] = []
    var canReact = false
    var canRetry = false
    var canUndo = false
    /// A reply that can change no more: stored, or arrived whole with nothing at work.
    var isSettled = true
    /// What went with the person's stored message, and what is on its way with theirs.
    var parts = SentParts(stored: "")
    var onItsWay: [PickedFile] = []
    var zoom: CGFloat = 1
}

/// One row of the chat. A view of its own, compared by what it shows, so that a redraw of
/// the chat (its pane resizing as the sidebar opens or closes, a word arriving in another
/// message, a find typed) leaves every row it does not change as it was, without building
/// or measuring its text again. It reads nothing of the chat as it draws: the chat hands
/// it everything, so a change elsewhere in the chat does not reach it.
struct MessageRow: View, Equatable {
    let item: TranscriptItem
    let look: RowLook
    let bot: Bot
    let roster: RosterModel
    let chat: ChatModel
    @Binding var reactionPicker: ReactionPickerTarget?
    @Environment(\.colorScheme) private var scheme

    nonisolated static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.item == b.item && a.look == b.look && a.bot == b.bot && a.roster === b.roster && a.chat === b.chat
    }

    var body: some View {
        let theme = Theme(scheme)
        switch item {
        case .date(let date):
            // More room above than below, so the time belongs to what follows it.
            Text(ChatDate.text(for: date))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .padding(.top, 14)
                .padding(.bottom, 6)
        case .activity(_, let tools):
            Text(ToolSummary.text(for: tools))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .padding(.top, 4)
                .padding(.bottom, -4)
        case .bot(let id, let text):
            WithActions(
                text: text, isLeading: true,
                canReact: look.canReact,
                turnAction: look.canRetry ? .retry { chat.retry(bot, through: roster) } : nil,
                hasReactions: !look.reactions.isEmpty,
                reactionPicker: $reactionPicker,
                reactionRow: id
            ) {
                // As wide as its words and no wider than 560, so the buttons sit beside it.
                NoWiderThan(width: 560) {
                    bubble(theme)
                        .background(theme.bubble, in: RoundedRectangle(cornerRadius: 15))
                        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(theme.bubbleEdge))
                        .reactions(look.reactions, isLeading: true, canChange: look.canReact) {
                            chat.react($0, to: id, of: bot, through: roster)
                        }
                }
            }
        case .user(let id, let text):
            // As the gateway stores it, a message holds more than was typed: what was
            // attached is shown as what it is, and the rest is for the bot.
            // Only a stored message is read for what went with it. One on its way is the
            // words as typed, whatever they say.
            let parts = look.parts
            let words = id < 0 ? text : parts.words
            // The one on its way shows what was picked; a stored one, what the gateway has.
            let onItsWay = look.onItsWay
            VStack(alignment: .trailing, spacing: 6) {
                if !onItsWay.isEmpty || !parts.images.isEmpty || !parts.files.isEmpty {
                    if words.isEmpty {
                        // A message that was only what went with it still takes Undo.
                        WithActions(
                            text: "", isLeading: false,
                            turnAction: look.canUndo ? .undo { chat.undo(bot, through: roster) } : nil,
                            hasReactions: !look.reactions.isEmpty,
                            reactionPicker: $reactionPicker
                        ) {
                            SentAttachments(picked: onItsWay, images: parts.images, files: parts.files, bot: bot, roster: roster)
                                .reactions(look.reactions, isLeading: false, canChange: false) { _ in }
                        }
                    } else {
                        SentAttachments(picked: onItsWay, images: parts.images, files: parts.files, bot: bot, roster: roster)
                    }
                }
                if !words.isEmpty {
                    WithActions(
                        text: words, isLeading: false,
                        turnAction: look.canUndo ? .undo { chat.undo(bot, through: roster) } : nil,
                        hasReactions: !look.reactions.isEmpty,
                        reactionPicker: $reactionPicker
                    ) {
                        NoWiderThan(width: 560) {
                            bubble(theme)
                                .background(theme.sentBubble, in: RoundedRectangle(cornerRadius: 18))
                                // The bot's reactions to it; the person reacts to the bot's.
                                .reactions(look.reactions, isLeading: false, canChange: false) { _ in }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func bubble(_ theme: Theme) -> some View {
        let blocks = look.blocks ?? []
        let zoom = look.zoom
        // Paragraphs, headings and list items that follow one another are one piece of
        // text, so a drag selects across them. Code, tables, quotes and rules stand apart.
        let stretches = ChatView.stretches(of: blocks)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(stretches.enumerated()), id: \.element.id) { index, stretch in
                ReplyPart(blocks: stretch.blocks, flows: stretch.flows, zoom: zoom, isSettled: look.isSettled,
                          itemID: item.id, bot: bot, roster: roster, chat: chat)
                    .equatable()
                // As tall as its words need at this width: with more than one block, a
                // long paragraph was otherwise cut to a line with an ellipsis.
                .fixedSize(horizontal: false, vertical: true)
                // For finding: what to bring into sight.
                .id(ChatView.partID(item.id, stretch.id))
                .padding(.top, index == 0 ? 0 : ChatView.gap(above: stretch.blocks[0].kind, below: stretches[index - 1].blocks.last!.kind) * zoom)
            }
        }
        .font(.system(size: 14 * zoom))
        .lineSpacing(4 * zoom)
        .foregroundStyle(theme.text)
        .textSelection(.enabled)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

}

/// One stretch of a message: paragraphs, headings and list items as one piece of text, or
/// a block that stands by itself. A view of its own, compared by what it shows, so that as
/// a reply arrives only the stretch that changed is built and laid out again.
struct ReplyPart: View, Equatable {
    let blocks: [StyledBlock]
    let flows: Bool
    let zoom: CGFloat
    let isSettled: Bool
    let itemID: TranscriptItem.ID
    let bot: Bot
    let roster: RosterModel
    let chat: ChatModel
    @Environment(\.colorScheme) private var scheme

    nonisolated static func == (a: ReplyPart, b: ReplyPart) -> Bool {
        a.flows == b.flows && a.zoom == b.zoom && a.isSettled == b.isSettled && a.itemID == b.itemID
            && a.blocks == b.blocks && a.bot == b.bot && a.roster === b.roster && a.chat === b.chat
    }

    var body: some View {
        let theme = Theme(scheme)
        Group {
            if flows {
                let flowing = ChatView.flowingText(blocks, theme, zoom: zoom)
                FlowingText(flowing.text, grey: flowing.grey)
            } else {
                block(blocks[0], theme, zoom: zoom)
            }
        }
        // Where its leading edge is, said outright, as it would be found: otherwise every
        // pass over the chat asks all the way down for it, which SwiftUI does not keep, and
        // measures a code block or table both as it fits and as it scrolls.
        .alignmentGuide(.leading) { _ in 0 }
    }

    /// A box for what can be wider than the bubble: as wide as what is in it when that
    /// fits, and scrolling sideways when it does not.
    private func wide(_ theme: Theme, fill: Color, edge: Color, @ViewBuilder content: () -> some View) -> some View {
        let content = content()
        return ViewThatFits(in: .horizontal) {
            content
            // What scrolls under the corners is cut to them.
            ScrollView(.horizontal) { content }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .background(fill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(edge))
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func block(_ block: StyledBlock, _ theme: Theme, zoom: CGFloat = 1) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text)
        case .heading(let level):
            Text(block.text)
                .font(.system(size: (level == 1 ? 18 : level == 2 ? 16 : 14) * zoom, weight: .semibold))
        case .item(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7 * zoom) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
                    .frame(minWidth: 12 * zoom, alignment: .trailing)
                Text(block.text)
            }
            .padding(.leading, CGFloat(depth) * 19 * zoom)
        case .code:
            wide(theme, fill: theme.codeBlock, edge: theme.bubbleEdge) {
                Text(block.text)
                    .font(.system(size: 12.5 * zoom, design: .monospaced))
                    .lineSpacing(3 * zoom)
                    .fixedSize()
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
            }
        case .table:
            wide(theme, fill: .clear, edge: theme.hairline) {
                Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 0) {
                    ForEach(Array(block.cells.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            // Across every column, however many there are.
                            theme.hairline.frame(height: 1)
                                .gridCellUnsizedAxes(.horizontal)
                                .gridCellColumns(max(row.count, 1))
                        }
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                NoWiderThan(width: 240) {
                                    Text(cell).fontWeight(index == 0 ? .semibold : .regular)
                                }
                                .gridColumnAlignment(.leading)
                                .padding(.vertical, 7)
                            }
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 2)
            }
        case .quote:
            Text(block.text)
                .foregroundStyle(theme.secondaryText)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(theme.secondaryText.opacity(0.45)).frame(width: 2)
                }
        case .rule:
            theme.hairline.frame(height: 1).padding(.vertical, 4)
        case .file:
            // A view of its own for each file: what one fetched is never shown for another
            // whose name took its place.
            HandedFile(path: block.raw, bot: bot, roster: roster, isSettled: isSettled)
                // Its card is the same size however large the words are.
                .lineSpacing(4)
                .id(block.raw)
        case .page:
            InlinePage(path: block.raw, bot: bot, roster: roster, chat: chat, key: ChatModel.pageKey(itemID, block.id), isSettled: isSettled)
                .lineSpacing(4)
                .id(block.raw)
        }
    }
}

/// Lets what is in it be as narrow as it likes and no wider than `width`, wrapping there,
/// and says truly how tall that makes it. (A frame with a maximum width does not, when
/// nothing outside limits the width: it answers with the height of one long line.)
private struct NoWiderThan: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? width, width), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// A message with small buttons beside it, shown while the pointer is on the message's row,
/// as the reference shows its message actions. Copy takes the whole message as written
/// (selecting with the pointer takes one block of a reply at a time). On a bot's reply, Add
/// reaction; on the latest turn, Retry or Undo.
private struct WithActions<Bubble: View>: View {
    /// Retry on the bot's last answer, or Undo on the person's last message.
    enum TurnAction {
        case retry(() -> Void)
        case undo(() -> Void)
    }

    let text: String
    /// The bubble sits at the leading edge, as a bot's does, with the buttons after it.
    let isLeading: Bool
    /// This row can take the person's reaction.
    var canReact = false
    var turnAction: TurnAction? = nil
    /// Reaction pills hang under the bubble, and the buttons line up with the bubble, not them.
    var hasReactions = false
    @Binding var reactionPicker: ReactionPickerTarget?
    /// The stored row a reaction would go on. Nil for the person's own messages.
    var reactionRow: Int? = nil
    @ViewBuilder let bubble: Bubble
    @State private var isHovered = false
    @State private var copied = 0
    @State private var showsCopied = false
    /// Where Add reaction is in the window, so the floating capsule can follow it.
    @State private var reactAt = CGRect.zero
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPicking: Bool {
        guard let reactionRow else { return false }
        return reactionPicker?.row == reactionRow
    }

    var body: some View {
        let theme = Theme(scheme)
        HStack(alignment: .bottom, spacing: 6) {
            if !isLeading { Spacer(minLength: 0) }
            if !isLeading { buttons(theme) }
            bubble
            if isLeading { buttons(theme) }
            if isLeading { Spacer(minLength: 0) }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onChange(of: isHovered) { if !isHovered, !isPicking { reactAt = .zero } }
        // Reacting stopped being possible with the picker up: it goes, and does not come back
        // by itself.
        .onChange(of: canReact) { if !canReact, isPicking { reactionPicker = nil } }
        .onDisappear { if isPicking { reactionPicker = nil } }
        .task(id: copied) {
            guard copied > 0 else { return }
            showsCopied = true
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { showsCopied = false }
        }
    }

    /// From the bubble outward, as the sketches have them: a reply's Add reaction, then Retry,
    /// then Copy; Copy, then Undo, before the person's message.
    private func buttons(_ theme: Theme) -> some View {
        HStack(spacing: 2) {
            if !isLeading { turnButton(theme) }
            if !isLeading { copyButton(theme) }
            if isLeading { reactButton(theme) }
            if isLeading { turnButton(theme) }
            if isLeading { copyButton(theme) }
        }
        .padding(.bottom, hasReactions ? 19 : 0)
        // Kept while the picker it opened is up, or the picker would lose its place.
        .opacity(isHovered || showsCopied || isPicking ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder private func reactButton(_ theme: Theme) -> some View {
        if canReact, let reactionRow {
            let button = ActionButton(symbol: "smiley", label: "Add reaction", isLit: isPicking) {
                if isPicking {
                    reactionPicker = nil
                } else {
                    reactionPicker = ReactionPickerTarget(row: reactionRow, anchor: reactAt)
                }
            }
            if isHovered || isPicking {
                button
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(appWindowSpace))
                    } action: { frame in
                        reactAt = frame
                        // A keyboard-opened picker first learns where its button is; after that,
                        // scrolling or a change in layout closes it rather than leaving it behind.
                        if isPicking {
                            if reactionPicker?.anchor == .zero { reactionPicker?.anchor = frame }
                            else if reactionPicker?.anchor != frame { reactionPicker = nil }
                        }
                    }
            } else {
                button
            }
        }
    }

    @ViewBuilder private func turnButton(_ theme: Theme) -> some View {
        switch turnAction {
        case .retry(let retry)?: ActionButton(symbol: "arrow.clockwise", label: "Retry", size: 12.5, action: retry)
        case .undo(let undo)?: ActionButton(symbol: "arrow.uturn.backward", label: "Undo", size: 12.5, action: undo)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private func copyButton(_ theme: Theme) -> some View {
        if !text.isEmpty { copyButtonItself(theme) }
    }

    private func copyButtonItself(_ theme: Theme) -> some View {
        ActionButton(symbol: showsCopied ? "checkmark" : "square.on.square", label: showsCopied ? "Copied" : "Copy message") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied += 1
        }
    }
}

/// One of a message's small round buttons.
private struct ActionButton: View {

    let symbol: String
    let label: String
    var isLit = false
    var size: CGFloat = 11
    let action: () -> Void
    @State private var isOver = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        Button(action: action) {
            Group {
                // The system's smiley comes filled here whatever is asked; the reference's
                // icons are all outlines, so this one is drawn.
                if symbol == "smiley" { SmileyIcon() } else { Image(systemName: symbol).font(.system(size: size, weight: .medium)) }
            }
                .foregroundStyle(isOver || isLit ? theme.text : theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(theme.hover.opacity(isOver || isLit ? 1 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isOver = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

/// An outline smiley, the size and weight of the symbols beside it.
private struct SmileyIcon: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let unit = side / 13
            let face = CGRect(x: (size.width - side) / 2 + 0.75 * unit, y: (size.height - side) / 2 + 0.75 * unit, width: side - 1.5 * unit, height: side - 1.5 * unit)
            let shading = GraphicsContext.Shading.foreground
            context.stroke(Path(ellipseIn: face), with: shading, lineWidth: 1.3 * unit)
            for x in [face.midX - 2.2 * unit, face.midX + 2.2 * unit] {
                context.fill(Path(ellipseIn: CGRect(x: x - 0.8 * unit, y: face.midY - 2.4 * unit, width: 1.6 * unit, height: 1.6 * unit)), with: shading)
            }
            var mouth = Path()
            mouth.addArc(center: CGPoint(x: face.midX, y: face.midY + 0.4 * unit), radius: 3 * unit,
                         startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
            context.stroke(mouth, with: shading, style: StrokeStyle(lineWidth: 1.3 * unit, lineCap: .round))
        }
        .frame(width: 12, height: 12)
    }
}

/// An emoji to react with, in the picker.
private struct EmojiChoice: View {
    let emoji: String
    let isChosen: Bool
    let action: () -> Void
    @State private var isOver = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = Theme(scheme)
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .background(theme.hover.opacity(isOver || isChosen ? 1 : 0), in: Circle())
                .scaleEffect(isOver && !reduceMotion ? 1.14 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isOver)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isOver = $0 }
        .accessibilityLabel(isChosen ? "\(emoji), your reaction" : emoji)
    }
}

/// The reactions as a floating capsule, in the look of the bot's name pill.
struct ReactionCapsule: View {
    static let width: CGFloat = 200
    static let height: CGFloat = 38

    let row: Int
    let bot: Bot
    let roster: RosterModel
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        let chat = roster.chat(for: bot)
        HStack(spacing: 2) {
            ForEach(ChatModel.quickReactions, id: \.self) { emoji in
                EmojiChoice(emoji: emoji, isChosen: emoji == chat.myReaction(on: row)) {
                    close()
                    chat.react(emoji, to: row, of: bot, through: roster)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(width: Self.width, height: Self.height)
        .background(theme.control, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.hairline))
        .shadow(color: theme.floatShadow, radius: 6, y: 2)
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reactions")
    }
}

extension View {
    /// Reactions as small pills on the bubble's bottom edge, at its leading corner for a bot's
    /// reply and its trailing one for the person's message. One emoji from both sides is one
    /// pill with a count. The person's own is lit, and a click on it takes it off.
    @ViewBuilder
    func reactions(_ reactions: [Reaction], isLeading: Bool, canChange: Bool, change: @escaping (String) -> Void) -> some View {
        if reactions.isEmpty {
            self
        } else {
            self
                .overlay(alignment: isLeading ? .bottomLeading : .bottomTrailing) {
                    ReactionPills(reactions: reactions, canChange: canChange, change: change)
                        .padding(.horizontal, 10)
                        .offset(y: 20)
                }
                .padding(.bottom, 19)
        }
    }
}

private struct ReactionPills: View {
    let reactions: [Reaction]
    let canChange: Bool
    let change: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    /// One emoji's pill. The person's own is lit: a step darker than the bot's, with a firmer
    /// edge, in light as in dark.
    private func pill(_ emoji: String, count: Int, isMine: Bool, isOver: Bool, _ theme: Theme) -> some View {
        HStack(spacing: 4) {
            Text(emoji).font(.system(size: 13))
            if count > 1 {
                Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isOver ? theme.reactionHover : isMine ? theme.chosen : theme.control, in: Capsule())
        .overlay(Capsule().strokeBorder(isMine ? (isOver ? theme.reactionHoverEdge : theme.text.opacity(0.16)) : theme.hairline))
        // A ring of the page's own colour, so the pill sits clear of the bubble's edge.
        .background(Capsule().stroke(theme.canvas, lineWidth: 3))
    }

    var body: some View {
        let theme = Theme(scheme)
        // In the order first given, one pill to each emoji.
        let emoji = reactions.map(\.emoji).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        HStack(spacing: 4) {
            ForEach(emoji, id: \.self) { one in
                let from = reactions.filter { $0.emoji == one }
                let isMine = from.contains(where: \.isPersons)
                let who = isMine ? (from.count > 1 ? "You and the bot" : "You") : "The bot"
                if isMine, canChange {
                    WhenHovered { isOver in
                        Button { change(one) } label: { pill(one, count: from.count, isMine: true, isOver: isOver, theme) }
                            .buttonStyle(.plain)
                    }
                    .help(from.count > 1 ? "You and the bot. Click to remove yours." : "Your reaction. Click to remove it.")
                    .accessibilityLabel("\(one), \(who). Remove your reaction")
                } else {
                    pill(one, count: from.count, isMine: isMine, isOver: false, theme)
                        .help(isMine ? (from.count > 1 ? "You and the bot" : "Your reaction") : "The bot's reaction")
                        .accessibilityLabel("\(one), \(who)")
                }
            }
        }
    }
}

/// One block of a message, with the formatting inside its lines worked out.
struct StyledBlock: Identifiable, Equatable {
    let id: Int
    let kind: ReplyBlock.Kind
    /// As it was written, to tell whether it has changed.
    let raw: String
    var text: AttributedString
    /// A table's cells, row by row, headings first. Empty for every other kind.
    var cells: [[AttributedString]] = []
    /// Its last words are in grey, having only just arrived.
    var isGreyed = false
}

/// Where a message is typed. It floats over the end of the chat.
private struct Composer: View {
    /// The chat column and the composer share one width.
    static let width: CGFloat = 960

    let bot: Bot
    @Bindable var chat: ChatModel
    let roster: RosterModel
    @FocusState private var isFocused: Bool
    /// The caret was in the box when the questions' answer went.
    @State private var caretWasHere = false
    @State private var pasteWatch: Any?
    @State private var pasteGate = PasteGate()
    /// The command lit in the slash menu, by name, and asks to bring it into sight.
    @State private var litCommand: String?
    @State private var menuScrollAsks = 0
    /// What the box held when Escape closed the slash menu: it stays closed until that changes.
    @State private var menuClosedAt: String?
    /// Where the pointer was when the menu opened. Until it moves, it lights nothing: a menu
    /// opening under a resting pointer must not choose what Return then runs.
    @State private var pointerAtOpen: CGPoint?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isCovered) private var isCovered

    /// The set of clarifying questions the message box answers while it is open, and
    /// while its answer is on its way (the box then takes nothing).
    private var clarifying: ChatQuestions.Asked? { chat.questions.clarifying }

    /// The questions' answer has gone and the box waits for the gateway.
    private var clarifyAnswering: Bool { clarifying.map { $0.state != .open } ?? false }

    /// What the empty box says: what it is for while clarifying questions are open.
    private var placeholder: String {
        guard let asked = clarifying, case .clarify(let clarify) = asked.question.kind else { return "Message \(bot.title)" }
        let question = clarify.questions[min(chat.questions.progress(of: asked).place, clarify.questions.count - 1)]
        if question.choices.isEmpty { return "Type your answer" }
        if question.multiSelect { return "Add your own answer, or leave this blank to use the selected options" }
        return "Type your own answer, or leave this blank to use the selected option"
    }

    /// Answers the question showing in the panel over the box with what is typed, or with
    /// what is picked when nothing is.
    private func answerClarifying() {
        if chat.questions.answerShowing(with: chat.draft, for: bot) { chat.draft = "" }
    }

    /// The commands the slash menu shows for what is typed, or nil when it is not open.
    private var menu: [SlashCommand]? {
        // Not while the box answers the bot's questions: what is typed there is the answer.
        guard !isCovered, chat.draft != menuClosedAt, chat.confirming == nil, clarifying == nil else { return nil }
        return SlashCommand.matching(chat.draft, offered: roster.offeredCommands)
    }

    /// The lit command: the one named while it is still listed, otherwise the first.
    private func lit(in menu: [SlashCommand]) -> SlashCommand? {
        menu.first { $0.name == litCommand } ?? menu.first
    }

    /// Return or a click: a command that wants words after it is put in the box to type
    /// them; any other runs at once.
    private func choose(_ command: SlashCommand) {
        litCommand = nil
        if command.waitsForWords {
            chat.draft = "/\(command.name) "
        } else {
            chat.draft = "/\(command.name)"
            chat.submit(to: bot, through: roster)
        }
        isFocused = true
    }

    private func moveInMenu(_ step: Int, _ menu: [SlashCommand]) {
        guard let lit = lit(in: menu), let at = menu.firstIndex(of: lit) else { return }
        litCommand = menu[(at + step + menu.count) % menu.count].name
        menuScrollAsks += 1
    }

    private var canSend: Bool {
        let hasWords = !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Words can join an answer under way; what is attached needs a message of its own.
        guard chat.filesBeingRead == 0 else { return false }
        // Not while a command is opening the chat: a fresh message would wait on it.
        guard !chat.approvalsHeld else { return false }
        return chat.isWorking ? chat.canAddToTurn && hasWords : chat.commandOpen == nil && (hasWords || !chat.attachments.isEmpty)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "Choose files to send to \(bot.title)"
        if panel.runModal() == .OK { chat.attach(panel.urls) }
    }

    /// What is on the pasteboard, if it is files or a picture and not words: a picture
    /// copied from a page or a screenshot, or files copied in the Finder.
    /// The key that pastes: whichever one types "v" as the keyboard is set. Where it is
    /// set to letters that are not these, the key in V's place, as the system has it.
    private static func isV(_ event: NSEvent) -> Bool {
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if typed == "v" { return true }
        return event.keyCode == 9 && !typed.isEmpty && !typed.unicodeScalars.allSatisfy(\.isASCII)
    }

    private func pasteAttachments() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            chat.attach(urls)
            return true
        }
        // Words copied with a picture of them, as from a document, are pasted as words.
        guard board.string(forType: .string) == nil else { return false }
        // Handed on as it is: making a PNG of it is done off the main thread.
        if let picture = board.data(forType: .png) ?? board.data(forType: .tiff) {
            chat.attach(picture: picture)
            return true
        }
        return false
    }

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 0) {
        if !chat.attachments.isEmpty || chat.attachProblem != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !chat.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(chat.attachments) { file in
                                PickedChip(file: file) { chat.removeAttachment(file.id) }
                            }
                        }
                    }
                }
                if let problem = chat.attachProblem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 6)
        }
        HStack(alignment: .bottom, spacing: 8) {
            if !chat.cannotAttach {
                WhenHovered { isHovered in
                    Button(action: pick) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                            .frame(width: 30, height: 30)
                            // A fill that shows on the box in both appearances.
                            .background(theme.hover.opacity(isHovered ? 1 : 0), in: Circle())
                            .background(theme.hover, in: Circle())
                            .contentShape(Circle())
                            // Not on offer while the bot is answering, and seen not to be.
                            .opacity(chat.canAttach ? 1 : 0.4)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!chat.canAttach || isCovered)
                .help("Attach files")
                .accessibilityLabel("Attach files")
                .padding(.bottom, 8)
            }
            TextField(placeholder, text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                // Under a panel the field takes no keys, however focus might reach it.
                .disabled(isCovered || clarifyAnswering)
                .font(.system(size: 14))
                .foregroundStyle(theme.text)
                .lineLimit(1...8)
                .focused($isFocused)
                .padding(.vertical, 14)
                // Return sends; Shift-Return and Option-Return start a new line. With the slash
                // menu open, Return chooses from it.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers == .shift {
                        // A new line where the caret is, as Option-Return gives.
                        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    } else if press.modifiers.isEmpty {
                        // With clarifying questions open, what is typed answers them.
                        if clarifying != nil {
                            if !clarifyAnswering { answerClarifying() }
                        } else if let menu, let lit = lit(in: menu) {
                            choose(lit)
                        } else {
                            chat.submit(to: bot, through: roster)
                        }
                    } else {
                        return .ignored
                    }
                    return .handled
                }
                // Escape puts the clarifying questions aside unanswered, as Cancel does.
                .onKeyPress(.escape, phases: .down) { _ in
                    guard let asked = clarifying else { return .ignored }
                    if asked.state == .open { chat.questions.answer(asked.instance, with: .skipped, for: bot) }
                    return .handled
                }
                // A choice of the question showing is picked by its number, while nothing is
                // typed: with words in the box, a number is a number.
                .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                    guard let asked = clarifying, chat.draft.isEmpty, press.modifiers.isEmpty,
                          let digit = Int(press.characters), digit >= 1 else { return .ignored }
                    // A number that picks nothing is typed as a number.
                    return chat.questions.toggle(digit - 1, in: asked.instance) ? .handled : .ignored
                }
                // The slash menu's keys, only while it is open: otherwise they are the box's.
                .onKeyPress(.downArrow) {
                    guard let menu else { return .ignored }
                    moveInMenu(1, menu)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard let menu else { return .ignored }
                    moveInMenu(-1, menu)
                    return .handled
                }
                .onKeyPress(.tab) {
                    // Tab puts the name in the box, to type after.
                    guard let menu, let lit = lit(in: menu) else { return .ignored }
                    litCommand = nil
                    chat.draft = "/\(lit.name) "
                    return .handled
                }
                .onKeyPress(.escape) {
                    // Closes the menu and leaves what was typed.
                    guard menu != nil else { return .ignored }
                    menuClosedAt = chat.draft
                    return .handled
                }
            // With words typed the button sends them, even mid-answer; otherwise it stops the bot.
            if clarifyAnswering, chat.canStop {
                // The answer is on its way: the bot can still be stopped.
                button("stop.fill", "Stop", size: 10, theme) { chat.stop(bot) }
            } else if clarifying != nil {
                button("arrow.up", "Answer", size: 14, theme) { answerClarifying() }
                    // Nothing to answer with yet: seen not to do anything, and does nothing.
                    .opacity(chat.questions.canAnswerShowing(with: chat.draft) ? 1 : 0.35)
                    .disabled(!chat.questions.canAnswerShowing(with: chat.draft) || isCovered)
            } else if canSend {
                // With the slash menu open it does what Return does: chooses.
                button("arrow.up", "Send message", size: 14, theme) {
                    if let menu, let lit = lit(in: menu) { choose(lit) } else { chat.submit(to: bot, through: roster) }
                }
            } else if chat.canStop {
                button("stop.fill", "Stop", size: 10, theme) { chat.stop(bot) }
            }
        }
        }
        .padding(.leading, chat.cannotAttach ? 18 : 8)
        .padding(.trailing, 8)
        .frame(minHeight: 46)
        .background(theme.composer, in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(theme.hairline))
        .shadow(color: theme.floatShadow, radius: 6, y: 2)
        .frame(maxWidth: Self.width)
        // The slash menu floats above the box, from its leading edge.
        .overlay(alignment: .topLeading) {
            if let menu {
                SlashMenu(commands: menu, lit: lit(in: menu), scrollAsks: menuScrollAsks, choose: choose) { command in
                    // Only once the pointer has really moved since the menu opened.
                    guard NSEvent.mouseLocation != pointerAtOpen else { return }
                    pointerAtOpen = nil
                    litCommand = command.name
                }
                    .offset(y: -SlashMenu.height(for: menu) - 8)
            }
        }
        // Typing goes back to the first command that answers, as in search.
        .onChange(of: chat.draft) {
            litCommand = nil
            // Escape kept the menu closed for that text only, not whenever it comes again.
            if chat.draft != menuClosedAt { menuClosedAt = nil }
            menuScrollAsks += 1
        }
        .onChange(of: menu != nil) { _, open in pointerAtOpen = open ? NSEvent.mouseLocation : nil }
        .task { await roster.readCommands() }
        .onAppear { isFocused = true }
        .onChange(of: chat.focusAsks) { isFocused = true }
        // The box took nothing while the questions' answer went: the caret comes back after,
        // if it was here when the answer went and has not been taken somewhere else since.
        .onChange(of: clarifyAnswering) { _, now in
            if now {
                caretWasHere = isFocused
            } else if caretWasHere, !isCovered, !(NSApp.keyWindow?.firstResponder is NSTextView) {
                isFocused = true
            }
        }
        // Paste, when what was copied is files or a picture: taken as attachments. Words
        // are left to the field as ever.
        // What the watcher goes by is kept where it can read it afresh each time: what
        // it was given when it was set up would be as things stood then.
        .onChange(of: isFocused, initial: true) { pasteGate.hasCaret = isFocused }
        .onChange(of: isCovered, initial: true) { pasteGate.isCovered = isCovered }
        .onAppear {
            if let pasteWatch { NSEvent.removeMonitor(pasteWatch) }
            let gate = pasteGate
            pasteWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Only a paste into this message box: Command and V and nothing else (Caps
                // Lock aside, and whatever letters the keyboard is set to), in the main
                // window and no sheet or panel, with the caret in a text field, and this
                // chat's box the one that has it.
                let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard gate.hasCaret, !gate.isCovered, held == .command,
                      Self.isV(event), chat.canAttach,
                      let window = event.window, window.isKeyWindow, window.canBecomeMain, window.attachedSheet == nil,
                      window.firstResponder is NSTextView
                else { return event }
                return pasteAttachments() ? nil : event
            }
        }
        .onDisappear {
            if let pasteWatch { NSEvent.removeMonitor(pasteWatch) }
            pasteWatch = nil
        }
    }

    private func button(_ symbol: String, _ label: String, size: CGFloat, _ theme: Theme, action: @escaping () -> Void) -> some View {
        WhenHovered { isHovered in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(theme.canvas)
                    .frame(width: 30, height: 30)
                    .background(theme.text.opacity(isHovered ? 0.82 : 1), in: Circle())
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
        .padding(.bottom, 8)
    }
}

extension EnvironmentValues {
    /// A panel is open over the window, so what is behind it takes no input.
    @Entry var isCovered = false
    /// How wide the bot's name is where it floats over the chat.
    @Entry var pillWidth: CGFloat = 160
    /// The part of the chat nothing floats over, top to bottom in `ChatView.pane`. Nil
    /// outside a chat, where a page sends nothing.
    @Entry var chatClear: ClosedRange<CGFloat>? = nil
}

/// Collects what was dropped, as each file's address arrives from wherever it came.
private final class Dropped: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [URL] = []
    var urls: [URL] { lock.withLock { found } }
    func add(_ url: URL) { lock.withLock { found.append(url) } }
}

/// What the paste watcher goes by, read afresh at each key press.
@MainActor
private final class PasteGate {
    var hasCaret = false
    var isCovered = false
}
