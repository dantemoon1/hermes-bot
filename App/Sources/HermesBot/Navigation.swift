import HermesKit

/// Going from bot to bot by the keyboard, in the order the roster shows them.
enum BotOrder {
    /// The bot in a place of the roster, counting from one: the main bot is the first.
    static func bot(at place: Int, in order: [Bot.ID]) -> Bot.ID? {
        order.indices.contains(place - 1) ? order[place - 1] : nil
    }

    /// The bot a step above or below the one showing. None past either end: the list does
    /// not go round. With none showing, the first.
    static func step(_ by: Int, from id: Bot.ID?, in order: [Bot.ID]) -> Bot.ID? {
        guard let id, let at = order.firstIndex(of: id) else { return order.first }
        let to = at + by
        return order.indices.contains(to) ? order[to] : nil
    }

    /// The next bot after the one showing with something unread, going round to the top.
    static func nextUnread(after id: Bot.ID?, in order: [Bot.ID], unread: Set<Bot.ID>) -> Bot.ID? {
        guard !order.isEmpty else { return nil }
        let start = id.flatMap { order.firstIndex(of: $0) } ?? -1
        return (1...order.count).lazy.map { order[(start + $0 + order.count) % order.count] }
            .first { unread.contains($0) && $0 != id }
    }
}

/// The bots viewed, for going back and forward between them as a browser does.
struct BotHistory {
    private(set) var back: [Bot.ID] = []
    private(set) var forward: [Bot.ID] = []

    /// Another bot was chosen, other than by going back or forward: the one left is
    /// the way back, and what was ahead is gone.
    mutating func left(_ id: Bot.ID) {
        if back.last != id { back.append(id) }
        forward = []
        // Enough to go back through, not a record of the day.
        if back.count > 50 { back.removeFirst(back.count - 50) }
    }

    /// The bot to go back to from the one showing, passing over any no longer there.
    mutating func goBack(from current: Bot.ID?, among existing: Set<Bot.ID>) -> Bot.ID? {
        while let id = back.popLast() {
            guard existing.contains(id), id != current else { continue }
            if let current { forward.append(current) }
            return id
        }
        return nil
    }

    mutating func goForward(from current: Bot.ID?, among existing: Set<Bot.ID>) -> Bot.ID? {
        while let id = forward.popLast() {
            guard existing.contains(id), id != current else { continue }
            if let current { back.append(current) }
            return id
        }
        return nil
    }
}
