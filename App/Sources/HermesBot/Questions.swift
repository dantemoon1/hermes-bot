import HermesKit
import Foundation

/// The questions a bot has put in its chat while answering: those still waiting on the
/// person, and a line for each one that is over.
///
/// What the person types into one (a secret, a password) is never kept here: it goes from
/// the card straight into the answer, and only whether it was given is noted.
@MainActor
@Observable
final class ChatQuestions {
    struct Asked: Identifiable, Equatable {
        /// What was asked, as the gateway last said it (a connection card changes as its rows do).
        var question: BotQuestion
        /// The connection it came on: it is answered on that one or not at all.
        let client: GatewayClient
        /// When it reached the app. The gateway's deadline counts from here.
        let asked: Date
        /// Where its line goes among the messages once it is over: when it was asked, and
        /// never before the newest row then shown, whose time is the gateway's clock.
        let placed: Date
        /// This showing of it. The gateway's id can come back for a new showing (after a
        /// connection is lost), and an answer given to an old one must not settle the new.
        let instance: UUID
        /// When it was first on screen.
        var shown: Date?
        var state: State
        /// Why the last try at answering did not go.
        var problem: String?
        /// The gateway said the question was over while our answer was on its way, and why.
        var endedMeanwhile: String??
        /// When our answer to a request went: a response frame is not acknowledged, so a
        /// deadline the gateway says passed just after can still be what happened.
        var answeredAt: Date?
        /// A move on a connection card is on its way.
        var isMoving = false
        /// Rows of a connection card whose sign-in the person opened from it: only those are
        /// said to be waiting on the browser (a link is minted before anyone clicks).
        var opened: Set<String> = []
        /// The line was said from what the app last saw, not from the gateway's own word on how
        /// the card ended; that word, when it comes, takes its place.
        var isProvisional = false

        var id: UUID { instance }
        var isOpen: Bool { if case .settled = state { false } else { true } }



        static func == (a: Asked, b: Asked) -> Bool {
            a.instance == b.instance && a.question == b.question && a.client === b.client && a.shown == b.shown
                && a.state == b.state && a.problem == b.problem && a.endedMeanwhile == b.endedMeanwhile && a.answeredAt == b.answeredAt
                && a.isMoving == b.isMoving && a.opened == b.opened && a.isProvisional == b.isProvisional
        }
    }

    enum State: Equatable {
        /// Waiting on the person.
        case open
        /// The answer is on its way.
        case answering
        case settled(Ending)
    }

    /// What the line left in the chat says.
    struct Ending: Equatable {
        enum Mark: Equatable { case allowed, denied, timedOut, none }
        let mark: Mark
        let text: String
        /// What it was about, shown as written (a command, a folder, a site).
        var detail: String?
        /// Words of the person's that went with it: why they said no.
        var quote: String?
        /// The connection was lost before it was answered: if the gateway still has it, it
        /// is put again when the chat is opened afresh.
        var wasLost = false
    }

    private(set) var all: [Asked] = [] {
        // The memory keeps a card shown as waiting for as long as it is.
        didSet {
            memory.setShown(Set(all.filter { $0.isOpen && { if case .connection = $0.question.kind { true } else { false } }($0) }.map(\.question.id)), owner: owner)
            onChange?()
        }
    }
    /// Called whenever questions are added, answered, or settled, so the roster can update cues.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The bot whose chat these questions are in (its profile), which owns its cards' memory.
    var owner = ""
    private func key(_ opID: String) -> ConnectionMemory.Key { .init(owner: owner, op: opID) }
    /// What is kept for each connection card on this gateway while it may still be answered:
    /// the fields it asked for and what was typed into the plain ones. One for the gateway,
    /// shared by every chat (the roster hands it over); a chat alone has one of its own.
    var memory = ConnectionMemory()

    /// How far the person has got through a set of clarifying questions, which are answered
    /// one at a time in the panel over the message box.
    struct Progress: Equatable {
        /// The question showing.
        var place = 0
        /// Choices picked, by question, by their place among its choices.
        var picked: [String: Set<Int>] = [:]
        /// Each question answered so far, nil where it was passed over.
        var answers: [String: ClarifyAnswer?] = [:]
    }

    private(set) var progress: [UUID: Progress] = [:]
    /// The locking of answers on the gateway, one after another, for each set.
    @ObservationIgnored private var locks: [UUID: Task<Void, Never>] = [:]

    /// Keys pressed in the moment a question arrives were meant for something else: nothing
    /// is done to a question for this long after it appears.
    static var arrivalGuard: TimeInterval = 0.4

    /// The clarifying questions the panel over the message box is for: the oldest set still open.
    var clarifying: Asked? {
        all.first { if case .clarify = $0.question.kind { $0.isOpen } else { false } }
    }

    /// Questions shown as cards in the chat: everything open but clarifying questions.
    var cards: [Asked] {
        all.filter { if case .clarify = $0.question.kind { false } else { $0.isOpen } }
    }
    /// Lines kept for questions that are over, at most.
    static let kept = 40

    var open: [Asked] { all.filter(\.isOpen) }
    var isWaiting: Bool { all.contains(where: \.isOpen) }
    /// Questions put whose connection went before they were answered.
    var lost: [Asked] { all.filter { if case .settled(let ending) = $0.state { ending.wasLost } else { false } } }

    /// A question has come. One already here is kept as it is, unless it had only been lost
    /// with a connection: then it is shown afresh, on the connection that has it now, as a
    /// new showing of its own. `notBefore` is the time of the newest row then on screen.
    func ask(_ question: BotQuestion, on client: GatewayClient, notBefore: Date? = nil) {
        if let index = all.firstIndex(where: { $0.question.id == question.id }) {
            let was = all[index]
            let wasLost = if case .settled(let ending) = was.state { ending.wasLost } else { false }
            if case .connection(let card) = question.kind { memory.heard(card, as: key(card.opID), inSession: question.sessionID) }
            if !wasLost, was.client === client, case .connection(let update) = question.kind {
                // The same card again (a chat's snapshot): it may say more than the one shown.
                connectionChanged(update, inSession: question.sessionID, on: client)
                return
            }
            guard wasLost || (was.isOpen && was.client !== client) else { return }
            forgetWork(of: was.instance)
            all.remove(at: index)
        }
        let now = Date.now
        if case .connection(let card) = question.kind { memory.heard(card, as: key(card.opID), inSession: question.sessionID) }
        all.append(Asked(question: question, client: client, asked: now, placed: max(now, notBefore ?? now), instance: UUID(), state: .open))
        trim()
    }

    /// The panel or card has been put on screen.
    func shown(_ instance: UUID) {
        guard let index = all.firstIndex(where: { $0.instance == instance }), all[index].shown == nil else { return }
        all[index].shown = .now
    }

    /// Past the moment it arrived: a key already on its way then was meant for something else.
    /// Never before it has been on screen, so a question waiting behind another is not
    /// answered by a key meant for the one before it.
    private func isSettledIn(_ asked: Asked) -> Bool {
        guard Self.arrivalGuard > 0 else { return true }
        guard let shown = asked.shown else { return false }
        return Date.now.timeIntervalSince(max(shown, asked.asked)) >= Self.arrivalGuard
    }

    func progress(of asked: Asked) -> Progress {
        if let kept = progress[asked.instance] { return kept }
        // Answers the gateway already holds, from before a reconnect, are taken as given.
        var start = Progress()
        guard case .clarify(let clarify) = asked.question.kind else { return start }
        for question in clarify.questions {
            guard let locked = clarify.locked[question.id] else { continue }
            guard let text = locked else {
                start.answers[question.id] = .some(nil)
                continue
            }
            if question.multiSelect, let list = try? JSONDecoder().decode([String].self, from: Data(text.utf8)) {
                start.answers[question.id] = .some(.several(list))
                start.picked[question.id] = Set(list.compactMap { item in question.choices.firstIndex { Clarify.bare($0) == item } })
            } else {
                start.answers[question.id] = .some(.one(text))
                if let place = question.choices.firstIndex(where: { Clarify.bare($0) == text }) { start.picked[question.id] = [place] }
            }
        }
        start.place = clarify.questions.firstIndex { start.answers[$0.id] == nil } ?? 0
        return start
    }

    /// Goes to another question of the set.
    func go(to place: Int, in instance: UUID) {
        guard let asked = all.first(where: { $0.instance == instance }), asked.state == .open, isSettledIn(asked),
              case .clarify(let clarify) = asked.question.kind, clarify.questions.indices.contains(place) else { return }
        var now = progress(of: asked)
        now.place = place
        progress[instance] = now
    }

    /// Picks or unpicks a choice of the question showing. One that takes a single answer
    /// keeps only the last picked. False, and nothing done, when there is no such choice. In
    /// the moment the set arrives a choice is not picked, though the key is still taken.
    @discardableResult
    func toggle(_ choice: Int, in instance: UUID) -> Bool {
        guard let asked = all.first(where: { $0.instance == instance }), asked.state == .open,
              case .clarify(let clarify) = asked.question.kind else { return false }
        var now = progress(of: asked)
        let question = clarify.questions[min(now.place, clarify.questions.count - 1)]
        guard question.choices.indices.contains(choice) else { return false }
        guard isSettledIn(asked) else { return true }
        var set = now.picked[question.id, default: []]
        if question.multiSelect {
            if set.contains(choice) { set.remove(choice) } else { set.insert(choice) }
        } else {
            set = set.contains(choice) ? [] : [choice]
        }
        now.picked[question.id] = set
        progress[instance] = now
        return true
    }

    /// The question showing in the panel can be answered with these words, or with what is
    /// picked when they are blank.
    func canAnswerShowing(with words: String) -> Bool {
        guard let asked = clarifying, asked.state == .open, case .clarify(let clarify) = asked.question.kind else { return false }
        let now = progress(of: asked)
        let question = clarify.questions[min(now.place, clarify.questions.count - 1)]
        return !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !now.picked[question.id, default: []].isEmpty
    }

    /// Answers the question showing with the words typed, or with what is picked when nothing
    /// is typed, and moves on to the next one not yet answered; the whole set goes to the
    /// gateway once the last is. Each answer but the last is locked on the gateway as it is
    /// given, one after another and before the set, so it stands if the gateway stops
    /// waiting first. Returns false, and changes nothing, when there is nothing to answer
    /// with, or in the moment the panel arrives.
    @discardableResult
    func answerShowing(with words: String, for bot: Bot) -> Bool {
        guard let asked = clarifying, asked.state == .open, isSettledIn(asked),
              case .clarify(let clarify) = asked.question.kind else { return false }
        var now = progress(of: asked)
        let question = clarify.questions[min(now.place, clarify.questions.count - 1)]
        let typed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        let picks = now.picked[question.id, default: []].sorted().map { Clarify.bare(question.choices[$0]) }
        let answer: ClarifyAnswer
        if question.multiSelect {
            let all = picks + (typed.isEmpty ? [] : [typed])
            guard !all.isEmpty else { return false }
            answer = .several(all)
        } else if !typed.isEmpty {
            answer = .one(typed)
        } else if let pick = picks.first {
            answer = .one(pick)
        } else {
            return false
        }
        now.answers[question.id] = .some(answer)
        progress[asked.instance] = now
        if let next = clarify.questions.indices.first(where: { now.answers[clarify.questions[$0].id] == nil }) {
            progress[asked.instance]?.place = next
            let client = asked.client, before = locks[asked.instance]
            locks[asked.instance] = Task {
                await before?.value
                _ = try? await client.lock(answer, for: question.id, of: asked.question, profile: bot.name)
            }
        } else {
            send(asked.instance, .clarify(now.answers), for: bot)
        }
        return true
    }

    /// The gateway says a question is over (answered elsewhere, timed out, withdrawn). Only
    /// for the question it names, in the chat and on the connection it names. One whose
    /// answer is on its way is left for that answer to settle.
    func ended(_ id: String, inSession sessionID: String?, on client: GatewayClient, reason: String?) {
        guard let index = all.firstIndex(where: {
            $0.question.id == id && $0.client === client && (sessionID?.isEmpty != false || $0.question.sessionID == sessionID)
        }) else { return }
        switch all[index].state {
        case .open:
            all[index].state = .settled(Self.ending(endedBy: reason, all[index].question))
            forgetWork(of: all[index].instance)
        case .answering:
            all[index].endedMeanwhile = .some(reason)
        case .settled:
            // A request's answer is a frame the gateway does not acknowledge: a deadline or a
            // stop it reports just after means ours came too late.
            // Any end but "resolved" (which can be ours being taken) says ours did not count.
            guard let reason, reason != "resolved", case .request = all[index].question.route,
                  let went = all[index].answeredAt, Date.now.timeIntervalSince(went) < 10 else { return }
            all[index].state = .settled(Self.ending(endedBy: reason, all[index].question))
            all[index].answeredAt = nil
        }
    }

    /// The bot's turn in a chat has ended. On the older route the gateway drops a request
    /// someone else answered without telling the other apps, so one still open here for that
    /// chat can no longer be answered: it is over, by whom not known. The session authority
    /// says when each of its prompts is settled, so those are left to it. A connection card
    /// holds its turn until it settles (`run.py`), so one still open when the turn ends had
    /// its settling update missed: it is over too, until that update says how.
    func turnEnded(inSession sessionID: String, on client: GatewayClient) {
        for index in all.indices where all[index].isOpen && all[index].client === client && all[index].question.sessionID == sessionID {
            switch all[index].question.route {
            case .request:
                guard all[index].state == .open else { continue }
                all[index].state = .settled(Self.ending(endedBy: nil, all[index].question))
            case .connection:
                all[index].state = .settled(Self.ending(endedBy: nil, all[index].question))
                all[index].isProvisional = true
            case .prompt:
                continue
            }
            forgetWork(of: all[index].instance)
        }
    }

    /// The gateway says what has changed on a connection card: its rows as they now stand,
    /// and, once it is over, how. Only for the card it names, in the chat and on the
    /// connection it names, and only a newer snapshot than the one shown (`updated(by:)`),
    /// keeping what only the request carried. A line said provisionally gives way to the
    /// gateway's own word on how the card ended.
    func connectionChanged(_ update: ConnectionRequest, inSession sessionID: String?, on client: GatewayClient) {
        guard let index = all.firstIndex(where: {
            $0.question.id == update.opID && $0.client === client && (sessionID?.isEmpty != false || $0.question.sessionID == sessionID)
        }), case .connection(let shown) = all[index].question.kind else { return }
        // What a row asked for counts even from a snapshot older than the one shown.
        memory.heard(update, as: key(update.opID), inSession: sessionID)
        let provisional = all[index].isProvisional
        guard all[index].isOpen || (provisional && update.isSettled), let now = shown.updated(by: update) else { return }
        let asked = all[index].question
        all[index].question = BotQuestion(id: asked.id, sessionID: asked.sessionID, route: .connection, kind: .connection(now), waits: asked.waits)
        // A row tried again, here or elsewhere, has a fresh link, which it has not opened.
        for target in now.targets {
            let before = shown.targets.first { $0.name == target.name }
            if target.state != .initiated || before?.connectURL != target.connectURL { all[index].opened.remove(target.name) }
        }
        if now.isSettled {
            all[index].state = .settled(Self.ending(for: now))
            all[index].isProvisional = false
            forgetWork(of: all[index].instance)
        }
    }

    /// The gateway no longer has this connection card open (asked after its turn ended).
    func connectionGone(_ opID: String, on client: GatewayClient) {
        guard let index = all.firstIndex(where: { $0.question.id == opID && $0.client === client && $0.isOpen }) else { return }
        connectionClosedElsewhere(all[index].instance)
    }

    /// Makes the person's moves on a connection card: a row skipped, approved with its
    /// values, or Continue. The card stays until the gateway says it is over. Returns whether
    /// the moves went (not in the moment the card arrived, nor while another is on its way).
    @discardableResult
    func respond(_ instance: UUID, with answer: ConnectionAnswer, for bot: Bot) -> Bool {
        guard let index = all.firstIndex(where: { $0.instance == instance }), all[index].state == .open, !all[index].isMoving,
              isSettledIn(all[index]), case .connection(let connection) = all[index].question.kind else { return false }
        let asked = all[index]
        all[index].isMoving = true
        all[index].problem = nil
        Task {
            do {
                let settled = try await asked.client.respond(to: connection, inSession: asked.question.sessionID, with: answer, profile: bot.name)
                guard let now = all.firstIndex(where: { $0.instance == instance }) else { return }
                all[now].isMoving = false
                // Over, and the gateway's own word on how has not come: said from what is
                // shown for now, and replaced by that word when it comes.
                if settled { memory.finish(key(connection.opID)) }
                if settled, all[now].isOpen, case .connection(let latest) = all[now].question.kind {
                    all[now].state = .settled(Self.ending(for: latest, continued: answer.isContinue))
                    all[now].isProvisional = true
                    forgetWork(of: instance)
                }
            } catch is GatewayClient.ConnectionOver {
                connectionClosedElsewhere(instance)
            } catch {
                guard let now = all.firstIndex(where: { $0.instance == instance }) else { return }
                all[now].isMoving = false
                if all[now].isOpen { all[now].problem = Self.connectionProblem("Couldn't send that.", for: error) }
            }
        }
        return true
    }

    /// Asks the gateway to try a failed or expired row again (a hosted app's sign-in: Hermes
    /// mints a fresh link through `connectors.connect`). The new link is shown on the row and
    /// opened only when the person clicks it. Returns whether it went.
    @discardableResult
    func retry(_ instance: UUID, row name: String, for bot: Bot) -> Bool {
        guard let index = all.firstIndex(where: { $0.instance == instance }), all[index].state == .open, !all[index].isMoving,
              isSettledIn(all[index]), case .connection(let connection) = all[index].question.kind else { return false }
        let asked = all[index]
        all[index].isMoving = true
        all[index].problem = nil
        all[index].opened.remove(name)
        Task {
            do {
                let now = try await asked.client.retry(name, of: connection, inSession: asked.question.sessionID, profile: bot.name)
                guard let at = all.firstIndex(where: { $0.instance == instance }) else { return }
                all[at].isMoving = false
                if let now { connectionChanged(now, inSession: asked.question.sessionID, on: asked.client) }
            } catch is GatewayClient.ConnectionOver {
                connectionClosedElsewhere(instance)
            } catch {
                guard let at = all.firstIndex(where: { $0.instance == instance }) else { return }
                all[at].isMoving = false
                if all[at].isOpen { all[at].problem = Self.connectionProblem("Couldn't try that again.", for: error) }
            }
        }
        return true
    }

    /// Plain wording when a move or reissue on a connection card is refused or fails, using the
    /// structured `reason` from Hermes (`ConnectorErrorReason` / `AuthorityRefusal`) before
    /// falling back to the gateway's message or general transport wording.
    static func connectionProblem(_ lead: String, for error: any Error) -> String {
        if let refusal = error as? GatewayClient.ConnectionRefusal {
            let detail: String = switch refusal.reason {
            case "LINK_STILL_VALID": "That sign-in link is still active."
            case "REISSUE_REFUSED":
                // Both SETTLED and NOT_ALLOWED share reason `REISSUE_REFUSED` in Hermes (`connector_refusals.py`).
                refusal.message.localizedCaseInsensitiveContains("settled")
                    ? "This card has already finished."
                    : "Hermes won't run this item again."
            case "UNKNOWN_TARGET": "That item isn't on this card."
            case "CONNECTORS_UNAVAILABLE": "Connectors aren't available in this chat."
            case "NEEDS_NOUS_AUTH": "Connectors need you to sign in to your account again."
            case "ORG_ACCESS_DENIED": "This account cannot manage connectors for this organization."
            case "FORBIDDEN_SCOPE": "Connector access is not permitted for this account."
            case "CONNECTOR_REQUEST_FAILED":
                refusal.message == "Connector request failed. Try again explicitly." || refusal.message.isEmpty
                    ? "The connector request failed."
                    : refusal.message
            case "INVALID_ANSWER": "The gateway didn't accept that."
            case "UNSUPPORTED_RUNTIME": "Connectors can only be set up on the computer the bot runs on."
            case "not_found": "This chat is no longer open on the gateway."
            case "NOT_OWNER": "This card comes from a chat that isn't open any more."
            case "permission_denied", "profile_mismatch": "This account isn't allowed to change this chat."
            default:
                refusal.message.isEmpty || refusal.message == refusal.reason
                    ? "The gateway refused that."
                    : refusal.message
            }
            return "\(lead) \(detail)"
        }
        if case GatewayError.unsupported = error { return "This gateway doesn't offer that." }
        return "\(lead) \(GatewayProblem.text(for: error))"
    }

    /// The person opened a row's sign-in from the card.
    func opened(_ instance: UUID, row name: String) {
        guard let index = all.firstIndex(where: { $0.instance == instance }) else { return }
        all[index].opened.insert(name)
    }

    /// The gateway has no such card open any more: it settled, here or on another device,
    /// and its last word did not reach this app. Over, until that word says how.
    private func connectionClosedElsewhere(_ instance: UUID) {
        guard let index = all.firstIndex(where: { $0.instance == instance }) else { return }
        all[index].isMoving = false
        guard all[index].isOpen else { return }
        all[index].state = .settled(Ending(mark: .none, text: "Answered elsewhere"))
        all[index].isProvisional = true
        forgetWork(of: instance)
        // The gateway has it closed: nothing kept for it is needed.
        memory.finish(key(all[index].question.id))
    }

    /// Something on the card may be done now: past the moment it arrived.
    func mayAct(_ instance: UUID) -> Bool {
        all.first(where: { $0.instance == instance }).map { $0.state == .open && isSettledIn($0) } ?? false
    }

    /// The line a connection card leaves: each row as it ended. `continued` says the person
    /// pressed Continue, which leaves what was not finished as it was.
    static func ending(for connection: ConnectionRequest, continued: Bool = false) -> Ending {
        let timedOut = connection.settledBy == "deadline"
        if connection.targets.isEmpty {
            // The directory card, or a card with no rows this app could read.
            let text = timedOut ? "Timed out" : connection.settledBy == "interrupt" ? "Stopped" : connection.suggested != nil ? "Saw the apps to connect" : "Done"
            return Ending(mark: timedOut ? .timedOut : .none, text: text)
        }
        let stopped = continued || connection.settledBy == "continue"
        let rows = connection.targets.map { target -> String in
            let name = ShownText.visible(target.title ?? ConnectionCard.title(of: target.name), oneLine: true)
            switch target.state {
            case .connected:
                let done = switch target.action {
                case .install: "Installed \(name)"
                case .enable: "Enabled \(name)"
                case .authorize: "Authorized \(name)"
                case .reconnect: "Reconnected \(name)"
                case .connect: "Connected \(name)"
                }
                return target.caveat.map { "\(done), but \($0)" } ?? done
            case .skipped: return "Skipped \(name)"
            case .failed: return "\(name) didn't work"
            default: return stopped ? "Left \(name)" : "\(name) not finished"
            }
        }
        let text = (timedOut ? ["Timed out"] : connection.settledBy == "interrupt" ? ["Stopped"] : []) + rows
        let allConnected = connection.targets.allSatisfy { $0.state == .connected && $0.caveat == nil }
        return Ending(mark: timedOut ? .timedOut : allConnected ? .allowed : .none, text: text.joined(separator: " · "))
    }

    /// The connection these questions came on has gone. They can no longer be answered there.
    func lost(on client: GatewayClient) {
        for index in all.indices where all[index].isOpen && all[index].client === client {
            all[index].state = .settled(Ending(mark: .none, text: "Lost the connection", detail: Self.detail(of: all[index].question), wasLost: true))
            forgetWork(of: all[index].instance)
        }
    }

    /// The gateway is being left: what it asked goes with it.
    func forget() {
        for lock in locks.values { lock.cancel() }
        locks = [:]
        progress = [:]
        memory.clear()
        all = []
    }

    /// Sends the person's answer, unless it comes in the moment the question arrived. The
    /// question is shown as answered once the gateway has it. Returns whether it was taken.
    @discardableResult
    func answer(_ instance: UUID, with answer: QuestionAnswer, for bot: Bot) -> Bool {
        guard let asked = all.first(where: { $0.instance == instance }), asked.state == .open, isSettledIn(asked) else { return false }
        send(instance, answer, for: bot)
        return true
    }

    private func send(_ instance: UUID, _ answer: QuestionAnswer, for bot: Bot) {
        guard let index = all.firstIndex(where: { $0.instance == instance }) else { return }
        let asked = all[index]
        all[index].state = .answering
        all[index].problem = nil
        let acknowledged: Bool = if case .prompt = asked.question.route { true } else { false }
        let ending = Self.ending(for: asked.question, answer, taken: acknowledged)
        let locking = locks.removeValue(forKey: instance)
        Task {
            // A set's earlier answers are locked first, so the set does not overtake them.
            await locking?.value
            // Ended meanwhile, by the gateway or by losing the connection: the answer is not sent.
            guard let still = all.firstIndex(where: { $0.instance == instance }), all[still].state == .answering else { return }
            if let reason = all[still].endedMeanwhile {
                all[still].state = .settled(Self.ending(endedBy: reason, asked.question))
                progress[instance] = nil
                return
            }
            do {
                let counted = try await asked.client.answer(asked.question, with: answer, profile: bot.name)
                guard let now = all.firstIndex(where: { $0.instance == instance }), all[now].state == .answering else { return }
                all[now].answeredAt = .now
                if case .some(let reason)? = all[now].endedMeanwhile, reason != "resolved" {
                    // Timed out, stopped or withdrawn as ours went: an answer cannot do that, so
                    // it was not ours.
                    all[now].state = .settled(Self.ending(endedBy: reason, asked.question))
                } else {
                    all[now].state = .settled(counted ? ending : Ending(mark: .none, text: "Answered elsewhere", detail: ending.detail))
                }
            } catch {
                guard let now = all.firstIndex(where: { $0.instance == instance }), all[now].state == .answering else { return }
                if let reason = all[now].endedMeanwhile {
                    // Over anyway; whether ours was what ended it is not known.
                    all[now].state = .settled(Self.ending(endedBy: reason, asked.question))
                } else {
                    all[now].state = .open
                    all[now].problem = "Couldn't send the answer. \(GatewayProblem.text(for: error))"
                    return
                }
            }
            progress[instance] = nil
        }
    }

    private func forgetWork(of instance: UUID) {
        locks.removeValue(forKey: instance)?.cancel()
        progress[instance] = nil
    }

    /// Every field each row of a connection card has asked for while it may be answered.
    func fields(of opID: String) -> [String: [ConnectionTarget.Field]] {
        memory.fields(of: key(opID))
    }

    /// What was typed into a plain field of a connection card, if anything.
    func draft(of opID: String, row: String, field: String) -> String? {
        memory.draft(of: key(opID), row: row, field: field)
    }

    /// Notes what is typed into a plain field of a connection card still waiting.
    func setDraft(_ value: String?, of opID: String, row: String, field: String) {
        memory.setDraft(value, of: key(opID), row: row, field: field)
    }

    /// Lets go of what was typed into one row of a connection card (it was skipped).
    func clearDrafts(of opID: String, row: String) {
        memory.clearDrafts(of: key(opID), row: row)
    }

    private func trim() {
        var settled = all.filter { !$0.isOpen }
        guard settled.count > Self.kept else { return }
        settled.removeFirst(settled.count - Self.kept)
        let keep = Set(settled.map(\.instance))
        for gone in all where !gone.isOpen && !keep.contains(gone.instance) { forgetWork(of: gone.instance) }
        all.removeAll { !$0.isOpen && !keep.contains($0.instance) }
    }

    /// The line left when the gateway ends a question, by why.
    static func ending(endedBy reason: String?, _ question: BotQuestion) -> Ending {
        let detail = detail(of: question)
        return switch reason {
        case "timeout": Ending(mark: .timedOut, text: "Timed out", detail: detail)
        case "resolved": Ending(mark: .none, text: "Answered elsewhere", detail: detail)
        default: Ending(mark: .none, text: "No longer asked", detail: detail)
        }
    }

    /// What a question was about, as the line after it shows it.
    static func detail(of question: BotQuestion) -> String? {
        switch question.kind {
        case .approval(let approval):
            switch approval.subject {
            case .command(let command): command.isEmpty ? nil : command
            case .folder(let path, _): path
            case .site(let host, _): host
            }
        case .secret(let name, _): name.isEmpty ? nil : name
        case .sudo, .clarify, .connection: nil
        }
    }

    /// The line left once the person has answered. A secret or password is only said to
    /// have been given or not. Where the gateway does not say it took the answer (`taken`
    /// false: the older route's answer is a frame it does not acknowledge, and drops if
    /// someone else answered first), leave is said as what the person chose, not as done.
    static func ending(for question: BotQuestion, _ answer: QuestionAnswer, taken: Bool = true) -> Ending {
        let detail = detail(of: question)
        switch (question.kind, answer) {
        case (.approval, .approval(let choice, let reason)):
            switch choice {
            case .once: return Ending(mark: .allowed, text: taken ? "Allowed once" : "You chose Allow once", detail: detail)
            case .session: return Ending(mark: .allowed, text: taken ? "Allowed for this session" : "You chose Allow for this session", detail: detail)
            case .always: return Ending(mark: .allowed, text: taken ? "Always allowed" : "You chose Always allow", detail: detail)
            case .deny:
                let text = taken ? "Denied" : "You chose Deny"
                let why = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let why, !why.isEmpty, case .approval(let approval) = question.kind, approval.takesReason {
                    return Ending(mark: .denied, text: text, detail: detail, quote: why)
                }
                return Ending(mark: .denied, text: text, detail: detail)
            }
        case (.approval, _):
            return Ending(mark: .denied, text: taken ? "Denied" : "You chose Deny", detail: detail)
        case (.clarify(let clarify), .clarify(let answers)):
            let said = clarify.questions.compactMap { question -> String? in
                switch answers[question.id] {
                case .some(.some(.one(let text))): return text
                case .some(.some(.several(let picks))): return picks.joined(separator: ", ")
                default: return nil
                }
            }
            return said.isEmpty ? Ending(mark: .none, text: "Skipped") : Ending(mark: .none, text: "Answered · " + said.joined(separator: " · "))
        case (.clarify, _):
            return Ending(mark: .none, text: "Skipped")
        case (.secret, .value(let value)):
            return Ending(mark: .none, text: value.isEmpty ? "Skipped" : "Provided", detail: detail)
        case (.sudo, .value(let value)):
            return Ending(mark: .none, text: value.isEmpty ? "Skipped the password" : "Password provided")
        case (.secret, _):
            return Ending(mark: .none, text: "Skipped", detail: detail)
        case (.sudo, _):
            return Ending(mark: .none, text: "Skipped the password")
        case (.connection(let connection), _):
            return ending(for: connection)
        }
    }
}
