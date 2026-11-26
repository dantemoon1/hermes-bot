import HermesKit
import Foundation

/// What the app keeps for each connection card on one gateway while the card may still be
/// answered: every field its rows have asked for, and what was typed into the plain ones.
///
/// Hermes keeps no value from an approval that still lacked a required one and then asks
/// only for what is missing (`_start_install`), so the app keeps the whole list itself. The
/// rule, kept in this one place:
///
/// - a card's memory is kept by the bot whose chat it is in and its operation id (a card heard
///   before its chat is claimed is kept by that chat until it is: `adopt`);
/// - it is let go at a definitive end (a settled snapshot, `connection.respond` answering
///   settled, the gateway saying the card is closed), which leaves a short note so an older
///   frame of the card cannot bring it back;
/// - otherwise it lasts while the card is shown as waiting, and for 30 minutes of this Mac's own
///   clock after it was last heard of or shown, so a gateway whose clock differs cannot cut it
///   short; a snapshot that leaves a card out only stops it being shown;
/// - a deleted bot's cards go with it (`forget(owner:)`);
/// - at most 200 cards, the first let go being those never shown nor typed into, then those
///   not on screen, the longest quiet first;
/// - secrets are never kept here.
@MainActor
@Observable
final class ConnectionMemory {
    /// Whose card it is: the bot whose chat it is in, or, before that chat is claimed, the chat.
    struct Key: Hashable {
        let owner: String
        let op: String

        static func chat(_ session: String, op: String) -> Key { Key(owner: "chat:" + session, op: op) }
    }

    struct Entry: Equatable {
        /// The live session it was heard in, so a card kept by its chat can be handed to the bot.
        var session: String?
        /// Every field each row has asked for, first seen first.
        var fields: [String: [ConnectionTarget.Field]] = [:]
        /// What was typed into each row's plain fields.
        var drafts: [String: [String: String]] = [:]
        /// When it was last heard of, typed into or shown, by this Mac's own clock.
        var alive: TimeInterval
        /// It has been on screen as a card.
        var everShown = false
    }

    /// How long a card nobody is shown lasts after it was last heard of.
    static let retention: TimeInterval = 30 * 60
    static let most = 200
    /// How many ended cards are remembered as ended.
    static let endsKept = 200

    /// This Mac's own clock, which only goes forward. Tests set another.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private(set) var entries: [Key: Entry] = [:]
    /// Cards shown as waiting just now, by owner (each chat says which of its own are).
    private var shown: [String: Set<String>] = [:]
    /// Cards that have ended, newest last: an older frame of one does not bring it back.
    private var ended: [Key] = []

    /// Something heard of a card: its request, an update, a chat's snapshot of it. Its rows'
    /// fields are added to what it asked for before; a settled one ends it.
    func heard(_ card: ConnectionRequest, as key: Key, inSession session: String?) {
        prune()
        if card.isSettled { return finish(key) }
        guard !ended.contains(key) else { return }
        var entry = entries[key] ?? Entry(session: session?.isEmpty == false ? session : nil, alive: clock())
        for target in card.targets where !target.fields.isEmpty {
            entry.fields[target.name] = ConnectionTarget.merged(entry.fields[target.name] ?? [], with: target.fields)
        }
        entry.alive = clock()
        entries[key] = entry
        trim(keeping: key)
    }

    /// A card has ended for good: settled, answered settled, or closed on the gateway.
    func finish(_ key: Key) {
        entries[key] = nil
        if !ended.contains(key) {
            ended.append(key)
            if ended.count > Self.endsKept { ended.removeFirst(ended.count - Self.endsKept) }
        }
    }

    /// A chat has been claimed for a bot: what was kept by the chat is the bot's now, and so is
    /// what was kept by any chat for the cards the opening brings (a chat claimed again after a
    /// reconnect comes back under a new live id).
    func adopt(session: String, ops: Set<String> = [], bot: String) {
        for (key, entry) in entries where key.owner == "chat:" + session || (key.owner.hasPrefix("chat:") && ops.contains(key.op)) {
            let mine = Key(owner: bot, op: key.op)
            var merged = entries[mine] ?? entry
            if entries[mine] != nil {
                for (row, fields) in entry.fields { merged.fields[row] = ConnectionTarget.merged(merged.fields[row] ?? [], with: fields) }
                merged.alive = max(merged.alive, entry.alive)
            }
            entries[key] = nil
            if !ended.contains(mine) { entries[mine] = merged }
        }
    }

    /// The cards a chat shows as waiting just now. A card shown is never let go but by its end.
    func setShown(_ ops: Set<String>, owner: String) {
        let before = shown[owner] ?? []
        shown[owner] = ops.isEmpty ? nil : ops
        let now = clock()
        for op in before.symmetricDifference(ops) {
            let key = Key(owner: owner, op: op)
            entries[key]?.alive = now
            if ops.contains(op) { entries[key]?.everShown = true }
        }
    }

    func fields(of key: Key) -> [String: [ConnectionTarget.Field]] {
        live(key)?.fields ?? [:]
    }

    func draft(of key: Key, row: String, field: String) -> String? {
        live(key)?.drafts[row]?[field]
    }

    /// Notes what is typed into a plain field. A card shown as waiting always takes it, even
    /// if nothing was kept for it; one that has ended does not.
    func setDraft(_ value: String?, of key: Key, row: String, field: String) {
        guard !ended.contains(key), live(key) != nil || isShown(key) else { return }
        var entry = entries[key] ?? Entry(alive: clock())
        entry.drafts[row, default: [:]][field] = value
        entry.alive = clock()
        entries[key] = entry
        trim(keeping: key)
    }

    /// Lets go of what was typed into one row (it was skipped).
    func clearDrafts(of key: Key, row: String) {
        entries[key]?.drafts[row] = nil
    }

    /// Lets go of every card not shown that has been quiet past the retention.
    func prune() {
        let now = clock()
        for (key, entry) in entries where !isShown(key) && now - entry.alive > Self.retention { entries[key] = nil }
    }

    /// A bot has been deleted: what was kept for its cards goes, and none of them is shown any
    /// more, so nothing of it outlasts the retention. Other bots' cards are not touched.
    func forget(owner: String) {
        shown[owner] = nil
        entries = entries.filter { $0.key.owner != owner }
    }

    /// The gateway is being left.
    func clear() {
        entries = [:]
        shown = [:]
        ended = []
    }

    private func isShown(_ key: Key) -> Bool { shown[key.owner]?.contains(key.op) == true }

    private func live(_ key: Key) -> Entry? {
        guard let entry = entries[key], isShown(key) || clock() - entry.alive <= Self.retention else { return nil }
        return entry
    }

    /// Over the limit: those never shown nor typed into go first, then those not on screen,
    /// the longest quiet first; never the card just heard of.
    private func trim(keeping kept: Key) {
        guard entries.count > Self.most else { return }
        func tier(_ key: Key, _ entry: Entry) -> Int {
            if isShown(key) { return 2 }
            return !entry.everShown && entry.drafts.isEmpty ? 0 : 1
        }
        let victim = entries.filter { $0.key != kept }.min {
            (tier($0.key, $0.value), $0.value.alive) < (tier($1.key, $1.value), $1.value.alive)
        }?.key
        if let victim { entries[victim] = nil }
    }
}
