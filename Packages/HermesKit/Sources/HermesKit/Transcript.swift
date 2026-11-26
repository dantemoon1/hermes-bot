import Foundation

/// One thing shown in a bot's chat.
public enum TranscriptItem: Sendable, Equatable, Identifiable {
    /// A time stamp between messages.
    case date(Date)
    case user(id: Int, text: String)
    case bot(id: Int, text: String)
    /// Work the bot did between messages, as the names of the tools it used, in order.
    case activity(id: Int, tools: [String])

    public var id: String {
        switch self {
        case .date(let date): "date-\(date.timeIntervalSince1970)"
        case .user(let id, _): "user-\(id)"
        case .bot(let id, _): "bot-\(id)"
        case .activity(let id, _): "activity-\(id)"
        }
    }
}

public enum Transcript {
    /// What a bot says when it chooses to say nothing. The turn is kept but not shown.
    static let silence: Set<String> = ["[SILENT]", "NO_REPLY"]

    /// Turns stored rows into what the chat shows: bubbles for what was said, one quiet line
    /// for each run of tool work, and a time stamp wherever an hour or more passed.
    public static func items(from messages: [ChatMessage], gap: TimeInterval = 3600) -> [TranscriptItem] {
        dated(from: messages, gap: gap).map(\.item)
    }

    /// The same, each with the time of the message it came from (a time stamp's own time;
    /// a line about tools, the time the work started), where the gateway gave one.
    public static func dated(from messages: [ChatMessage], gap: TimeInterval = 3600) -> [(item: TranscriptItem, date: Date?)] {
        var items: [(item: TranscriptItem, date: Date?)] = []
        var tools: [String] = []
        var toolsID = 0
        var toolsDate: Date?
        var lastDate: Date?

        func stamp(_ date: Date?) {
            guard let date else { return }
            if lastDate.map({ date.timeIntervalSince($0) >= gap }) ?? true { items.append((.date(date), date)) }
            // Never backwards: a row stored out of order must not earn a second stamp.
            lastDate = max(lastDate ?? date, date)
        }
        /// The work goes under the time it started, so it reads as part of the turn it led to.
        func flushTools() {
            guard !tools.isEmpty else { return }
            stamp(toolsDate)
            items.append((.activity(id: toolsID, tools: tools), toolsDate))
            tools = []
        }

        for message in messages {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.role {
            case "user":
                // Sent where no one sees it, by a page in the chat or by Hermes itself: the
                // person did not say it, so it is not their bubble.
                guard !text.isEmpty, !message.isHidden else { continue }
                flushTools()
                stamp(message.date)
                items.append((.user(id: message.id, text: text), message.date))
            case "assistant":
                if silence.contains(text) {
                    // A turn the bot chose to keep quiet shows nothing, its work included.
                    tools = []
                    continue
                }
                if !text.isEmpty {
                    flushTools()
                    stamp(message.date)
                    items.append((.bot(id: message.id, text: text), message.date))
                }
                let called = message.toolCalls
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !called.isEmpty {
                    if tools.isEmpty { (toolsID, toolsDate) = (message.id, message.date) }
                    tools += called
                }
            default:
                // Tool results and anything newer are the bot's working, not conversation.
                continue
            }
        }
        flushTools()
        return items
    }
}
