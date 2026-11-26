import Foundation

/// Something the person attached to a message, once the gateway has it.
public enum Attached: Sendable, Equatable {
    /// A picture, queued to go with the next message in that chat. `path` is where the
    /// gateway put it, which is what takes it back out of the queue.
    case image(path: String, name: String)
    /// Any other file, put in the chat's workspace. `reference` is the word to put in the
    /// message so the bot is given the file.
    case file(reference: String, name: String)
    /// A picture held on the gateway where its session authority handles chats. Nothing
    /// waits in the chat: it goes only with the message that names it (`send`'s `pictures`).
    case staged(StagedPicture)
}

/// A picture the gateway's session authority holds for a message, named on that message
/// by where it is and what kind of picture it is.
public struct StagedPicture: Sendable, Equatable {
    public let path: String
    public let mime: String
    public let name: String

    public init(path: String, mime: String, name: String) {
        self.path = path
        self.mime = mime
        self.name = name
    }
}

extension GatewayClient {
    /// The most that may be attached in one piece. The gateway takes pictures up to 25 MB;
    /// a file's bytes travel inside one message on the socket, so they are held to the same.
    public static let attachmentLimit = 25 * 1024 * 1024

    /// Kinds of picture the gateway takes as pictures, for a bot that can see to look at.
    public static let pictureEndings: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

    /// Queues a picture to go with the next message sent in `chat`. Where the gateway's
    /// session authority handles chats it is only held there, and comes back `.staged`, to
    /// be named on the message it goes with; that route takes png, jpeg, gif and webp.
    /// Not held to this client's own thread of work while the bytes are made into text:
    /// that takes a moment for a large file, and every chat's messages pass through here.
    nonisolated public func attachImage(_ data: Data, named name: String, in chat: LiveChat, profile: String) async throws -> Attached {
        let encoded = data.base64EncodedString()
        let result = try await request("image.attach_bytes", .object([
            "session_id": .string(chat.sessionID),
            "profile": .string(profile),
            "content_base64": .string(encoded),
            "filename": .string(name),
        ]), timeout: .seconds(120))
        guard result["attached"] == .bool(true), let path = result["path"]?.stringValue, !path.isEmpty else {
            throw GatewayError.unexpectedReply(method: "image.attach_bytes")
        }
        let called = result["name"]?.stringValue ?? name
        if await usesSessionAuthority {
            guard let mime = result["mime"]?.stringValue, !mime.isEmpty else {
                throw GatewayError.unexpectedReply(method: "image.attach_bytes")
            }
            return .staged(StagedPicture(path: path, mime: mime, name: called))
        }
        return .image(path: path, name: called)
    }

    /// Puts a file in the chat's workspace, for the bot to read when the message names it.
    nonisolated public func attachFile(_ data: Data, named name: String, type: String, in chat: LiveChat, profile: String) async throws -> Attached {
        let kind = type.isEmpty ? "application/octet-stream" : type
        let encoded = "data:\(kind);base64,\(data.base64EncodedString())"
        let result = try await request("file.attach", .object([
            "session_id": .string(chat.sessionID),
            "profile": .string(profile),
            "data_url": .string(encoded),
            "name": .string(name),
        ]), timeout: .seconds(120))
        guard result["attached"] == .bool(true), let reference = result["ref_text"]?.stringValue, !reference.isEmpty else {
            throw GatewayError.unexpectedReply(method: "file.attach")
        }
        return .file(reference: reference, name: result["name"]?.stringValue ?? name)
    }

    /// Takes a queued picture back, when the message it was for is not going after all.
    /// Returns how many pictures the gateway says are still queued in that chat, when it
    /// says. Asked with a place nothing is at, it takes nothing back and only counts.
    @discardableResult
    public func detachImage(at path: String, in chat: LiveChat, profile: String) async throws -> Int? {
        let result = try await request("image.detach", .object([
            "session_id": .string(chat.sessionID), "profile": .string(profile), "path": .string(path),
        ]))
        guard case .number(let count)? = result["count"] else { return nil }
        return Int(count)
    }

    /// A place no picture is at: asking to take it back only counts what is queued.
    public static let noPicture = "hermes-bot:none"

    /// Whether the bot is at work in a chat just now, as the gateway says on opening it;
    /// nil when it does not say.
    public func isAnswering(in chat: BotChat, profile: String) async -> Bool? {
        let result = try? await request("session.resume", .object([
            "session_id": .string(chat.liveID), "profile": .string(profile),
            "omit_messages": .bool(true), "source": .string(interfaceKind),
        ]), timeout: .seconds(90))
        guard case .bool(let running)? = result?["running"] else { return nil }
        return running
    }

    /// Closes the open chat on the gateway. What is stored of it stays; anything waiting
    /// in it to go with a next message is dropped.
    public func close(_ chat: LiveChat, profile: String) async throws {
        _ = try await request("session.close", .object(["session_id": .string(chat.sessionID), "profile": .string(profile)]))
    }
}

/// What the person sent, read back out of the chat as the gateway stores it.
///
/// A message that had attachments is stored as what was sent, then anything the gateway
/// added: what it had to say about the files, a block for the bot holding their contents,
/// and at the very end a line for each picture saying where it is. Only the words and
/// what was attached are for showing.
///
/// A file is one only when the gateway's own lines name the very reference the message
/// holds: the line that heads each file in its block, or a line saying why it was left
/// out. A reference that was only typed, or sits inside a file's contents, stays words.
///
/// A picture is one on the last lines of the message and nowhere else, read the way
/// Hermes's own app reads them: lines of `@image:` and a place, then either a stand-in
/// for each or none at all. Hermes writes them both ways, and has no other record. Where
/// its session authority handles chats the lines read `[Image attached at: <place>]`
/// instead, after a blank line.
public struct SentParts: Sendable, Equatable {
    /// What the person typed.
    public let words: String
    /// The files attached, by name.
    public let files: [String]
    /// Where on the gateway the pictures attached are.
    public let images: [String]
    /// The message as it went: the words and the references, without what the gateway
    /// added after them. What a stored message is compared by, to know it for our own.
    public let asSent: String

    private static let contextHeading = "\n\n--- Attached Context ---\n\n"
    private static let warningsHeading = "\n\n--- Context Warnings ---\n"

    public init(stored content: String) {
        var rest = content
        // Pictures: the stand-ins at the very end, and before them the places.
        var images: [String] = []
        var lines = rest.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        var end = lines.count
        var standIns = 0
        while end > 0, lines[end - 1].wholeMatch(of: /\[(?:image|screenshot(?: [^\]\n]*)?)\]/) != nil {
            standIns += 1
            end -= 1
        }
        var places: [String] = []
        while end > 0, let found = lines[end - 1].wholeMatch(of: /@image:(?:`([^`\n]+)`|"([^"\n]+)"|'([^'\n]+)'|(\S+))/) {
            places.insert(String(found.1 ?? found.2 ?? found.3 ?? found.4 ?? ""), at: 0)
            end -= 1
        }
        // Where the session authority handles chats, each is a line saying where it was
        // attached, after a gap, with exactly one `[screenshot]` for each, as Hermes's own
        // app reads them (`persistedImageRefs`). A place runs to the line's last bracket.
        if places.isEmpty, standIns > 0, lines[end..<(end + standIns)].allSatisfy({ $0 == "[screenshot]" }) {
            var at = end
            var hinted: [String] = []
            while at > 0, let found = lines[at - 1].wholeMatch(of: /\[Image attached(?: at)?: (.+)\]/) {
                hinted.insert(String(found.1), at: 0)
                at -= 1
            }
            if hinted.count == standIns, at >= 2, lines[at - 1].isEmpty {
                places = hinted
                // The gap goes with them.
                end = at - 1
            }
        }
        // A place is one from its root, as the gateway writes where it put a picture.
        if !places.isEmpty, standIns == 0 || standIns == places.count,
           places.allSatisfy({ $0.hasPrefix("/") || $0.hasPrefix("~/") || $0.wholeMatch(of: /[A-Za-z]:[\/\\].*/) != nil }) {
            images = places
            rest = lines[..<end].joined(separator: "\n")
        }
        // Files: the gateway's block. It begins where its heading is followed by the line
        // that heads a file the message names, looked for from the front: a file's own
        // contents may hold the same heading further on.
        var named: Set<String> = []
        var from = rest.startIndex
        while let heading = rest.range(of: Self.contextHeading, range: from..<rest.endIndex) {
            let block = rest[heading.upperBound...]
            let before = rest[..<heading.lowerBound]
            if let first = block.prefixMatch(of: Self.head), before.matches(of: Self.reference).contains(where: { before[$0.range] == first.1 }) {
                // Each file's contents follow the line that heads it, so a line that
                // reads like one may be a file's own. The gateway's are where one file
                // ends and the next begins: the first line, or after a gap that follows
                // the end of a file's contents or a file given in one line.
                let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                for (at, line) in lines.enumerated() {
                    guard let head = line.prefixMatch(of: Self.head) else { continue }
                    let begins = at == 0 || (at >= 2 && lines[at - 1].isEmpty
                        && (lines[at - 2] == "```" || lines[at - 2].prefixMatch(of: Self.head) != nil))
                    if begins { named.insert(String(head.1)) }
                }
                rest = String(rest[..<heading.lowerBound])
                break
            }
            from = heading.upperBound
        }
        // What it had to say about them comes before that block, or alone when no file
        // could be read: a line for each, naming it.
        if let warned = rest.range(of: Self.warningsHeading, options: .backwards) {
            let said = rest[warned.upperBound...].split(separator: "\n", omittingEmptySubsequences: false)
            // Each begins with the reference it is about, as the gateway writes them.
            if !said.isEmpty, said.allSatisfy({ $0.prefixMatch(of: /- @[a-z_]+(?::\S|\b)/) != nil }) {
                for line in said {
                    if let about = line.prefixMatch(of: Self.warning) { named.insert(String(about.1)) }
                }
                rest = String(rest[..<warned.lowerBound])
            }
        }
        asSent = rest.trimmingCharacters(in: .whitespacesAndNewlines)

        var files: [String] = []
        var words = asSent
        if !named.isEmpty {
            for found in asSent.matches(of: Self.reference).reversed() {
                guard named.contains(String(asSent[found.range])) else { continue }
                let path = String(found.1 ?? found.2 ?? found.3 ?? found.4 ?? "")
                files.insert((path as NSString).lastPathComponent, at: 0)
                words.removeSubrange(found.range)
            }
        }
        // What stands in for the words when only pictures were sent.
        if !images.isEmpty {
            words = words.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces).wholeMatch(of: /\[User attached image: [^\]\n]*\]/) == nil }
                .joined(separator: "\n")
        }
        self.words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        self.files = files
        self.images = images
    }

    /// A reference: `@file:` and a path, in backticks or quotes when the path has spaces.
    nonisolated(unsafe) private static let reference = /@(?:file|folder):(?:`([^`\n]+)`|"([^"\n]+)"|'([^'\n]+)'|(\S+))/
    /// The line that heads a file in the gateway's block: a mark, the reference, and what
    /// it is in brackets.
    nonisolated(unsafe) private static let head = /\S+ (@(?:file|folder):(?:`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|\S+)) \(/
    /// A line saying why a file was left out.
    nonisolated(unsafe) private static let warning = /- (@(?:file|folder):(?:`[^`\n]+`|"[^"\n]+"|'[^'\n]+'|[^\s:]+)):[ ]/
}
