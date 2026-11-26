import Foundation

/// What came of running a slash command in a chat, as Hermes answers `slash.exec`.
public enum CommandOutcome: Sendable, Equatable {
    /// What the command printed, with a warning Hermes added, if any. Empty when it printed
    /// nothing.
    case said(String, warning: String?)
    /// A message for the bot, to be sent as the person's next one, with words to show first.
    /// `/retry` sends the last message again this way, and `/plan` and `/goal` their prompts.
    case send(String, notice: String?)
    /// Words to put back in the message box to edit and send again, with words to show:
    /// `/undo` gives back the message it took out.
    case prefill(String, notice: String?)
}

extension GatewayClient {
    /// The names of the slash commands this gateway offers, lower-cased and without their
    /// slash. Its own commands are the same for every bot, so no bot is named: a gateway
    /// older than the field would refuse it.
    public func offeredCommands() async throws -> Set<String> {
        let result = try await outOfSync("commands.catalog") {
            try await request("commands.catalog")
        }
        guard case .array(let pairs)? = result["pairs"] else { throw GatewayError.unexpectedReply(method: "commands.catalog") }
        return Set(pairs.compactMap { pair -> String? in
            guard case .array(let parts) = pair, let name = parts.first?.stringValue else { return nil }
            let bare = name.drop(while: { $0 == "/" }).lowercased()
            return bare.isEmpty ? nil : bare
        })
    }

    /// Runs a slash command in a bot's open chat, as Hermes's own app does. `command` is the
    /// line as typed, with or without its slash. Can take a while: `/compress` summarises the
    /// chat before it answers, so it is given longer `wait`. What a command printed comes back
    /// as printed, indents and all.
    public func runCommand(_ command: String, in chat: LiveChat, profile: String, wait: Duration = .seconds(120)) async throws -> CommandOutcome {
        let line = String(command.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "/" }))
        let result = try await outOfSync("slash.exec") {
            try await request("slash.exec", .object([
                "session_id": .string(chat.sessionID),
                "command": .string(line),
                "profile": .string(profile),
            ]), timeout: wait)
        }
        func words(_ key: String) -> String? {
            result[key]?.stringValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch result["type"]?.stringValue {
        case "send":
            guard let message = words("message") else { throw GatewayError.unexpectedReply(method: "slash.exec") }
            return .send(message, notice: words("notice"))
        case "prefill":
            return .prefill(words("message") ?? "", notice: words("notice"))
        case nil, "exec", "plugin":
            // Hermes says "(no output)" for a command that printed nothing.
            let said = result["output"]?.stringValue ?? ""
            return .said(words("output").map { $0 == "(no output)" } ?? true ? "" : said, warning: words("warning"))
        default:
            // Not followed: an alias (a command of the person's own standing for another)
            // could stand for one this app asks about first, such as `/approvals off`; and a
            // skill's message is Hermes's prompt for the bot, never the person's words.
            throw GatewayError.unexpectedReply(method: "slash.exec")
        }
    }

    /// Asks a question on the side of a bot's chat: a helper that has read the chat answers
    /// it, and nothing is added to the chat or its history. Waits for the answer, which comes
    /// as its own event, at most `wait`.
    public func askAside(_ question: String, in chat: LiveChat, profile: String, wait: Duration = .seconds(180)) async throws -> String {
        // Listening before asking, so a quick answer is not missed.
        let heard = events()
        let result = try await outOfSync("prompt.btw") {
            try await request("prompt.btw", .object([
                "session_id": .string(chat.sessionID),
                "profile": .string(profile),
                "text": .string(question),
            ]))
        }
        guard let task = result["task_id"]?.stringValue, !task.isEmpty else { throw GatewayError.unexpectedReply(method: "prompt.btw") }
        let answer = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await event in heard where event.type == "btw.complete" && event.payload["task_id"]?.stringValue == task {
                    return event.payload["text"]?.stringValue ?? ""
                }
                throw GatewayError.connectionLost("Closed")
            }
            group.addTask {
                try await Task.sleep(for: wait)
                throw GatewayError.timedOut(method: "prompt.btw")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
        // A helper that failed says so in its answer.
        if answer.hasPrefix("error: ") { throw GatewayError.rejected(code: 0, message: String(answer.dropFirst(7))) }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns approvals off for a bot's chat, or on again: with them off, Hermes runs risky
    /// commands without asking. As Hermes's own app does, for this chat only, and never by
    /// toggling: the state wanted is said. Returns whether they are now off.
    public func setApprovalsSkipped(_ skipped: Bool, in chat: LiveChat, profile: String) async throws -> Bool {
        let result = try await outOfSync("config.set") {
            try await request("config.set", .object([
                "session_id": .string(chat.sessionID),
                "profile": .string(profile),
                "key": .string("yolo"),
                "value": .string(skipped ? "on" : "off"),
            ]))
        }
        switch result["value"] {
        case .string("1")?: return true
        case .string("0")?: return false
        default: throw GatewayError.unexpectedReply(method: "config.set")
        }
    }
}
