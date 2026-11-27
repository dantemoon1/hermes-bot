import Foundation

/// A bot asking to connect the person's app accounts or install MCP servers, as one card
/// (Hermes's `manage_connections`, `tools/connectors`). The gateway opens it with a
/// `connection.request` event, says what changes with `connection.update` (a row connected,
/// failed, skipped; the whole settled), and takes the person's moves by `connection.respond`.
/// A hosted app's account is connected in the person's browser, at the row's `connectURL`,
/// and the gateway notices by itself; an MCP server is installed, enabled or authorized when
/// the person approves its row, with any values it needs. The bot waits on the card until
/// every row is settled, the person presses Continue, or the deadline passes.
public struct ConnectionRequest: Sendable, Equatable {
    public let opID: String
    /// Goes up with each change: a snapshot whose seq is not higher than the one shown is older.
    public let seq: Int
    /// When the gateway stops waiting. Nil when the gateway gave none that makes sense.
    public let deadline: Date?
    public let targets: [ConnectionTarget]
    /// The directory card (`manage_connections` action `display`): every connector, with
    /// these suggested. Nil for an ordinary card. Only the request carries it; an update
    /// does not, so a card keeps what its request said (`updated(by:)`).
    public let suggested: [String]?
    /// The card is over, and why (`all_resolved`, `continue`, `deadline`, `interrupt`).
    public let settledBy: String?
    public let isSettled: Bool

    public init(opID: String, seq: Int, deadline: Date?, targets: [ConnectionTarget], suggested: [String]? = nil,
                settledBy: String? = nil, isSettled: Bool = false) {
        self.opID = opID
        self.seq = seq
        self.deadline = deadline
        self.targets = targets
        self.suggested = suggested
        self.settledBy = settledBy
        self.isSettled = isSettled
    }

    /// Reads a `connection.request` or `connection.update` payload, a chat snapshot's
    /// `pending_connection`, or the operation `connectors.connect` answers with. Nil without
    /// an operation id. A row named twice is taken once, as first given.
    public init?(payload: JSONValue) {
        guard let opID = payload["op_id"]?.stringValue, !opID.isEmpty else { return nil }
        self.opID = opID
        // A whole number only: one rounded up would hold back the next real frame.
        seq = payload["seq"]?.numberValue.flatMap { $0.isFinite && abs($0) < 1e15 ? Int(exactly: $0) : nil } ?? 0
        deadline = payload["deadline_at"]?.numberValue.flatMap(Self.date(secondsSince1970:))
        var seen: Set<String> = []
        if case .array(let rows)? = payload["targets"] {
            targets = rows.compactMap(ConnectionTarget.init(row:)).filter { seen.insert($0.name).inserted }
        } else {
            targets = []
        }
        if case .array(let names)? = payload["display"]?["suggested"] {
            suggested = names.compactMap(\.stringValue)
        } else {
            suggested = nil
        }
        settledBy = payload["settled_by"]?.stringValue
        isSettled = payload["settled"] == .bool(true) || payload["settled_at"]?.numberValue != nil
    }

    /// A time the gateway gave in seconds since 1970, if it is one: finite and between 2001
    /// and 2100. Anything else is taken as no deadline rather than shown as nonsense.
    static func date(secondsSince1970 seconds: Double) -> Date? {
        guard seconds.isFinite, seconds > 978_307_200, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// This card as a later snapshot says it now stands, keeping what only the request
    /// carries (the directory card's suggestions). Nil when the snapshot is not newer, so
    /// moves no row, unless it is the one that settles the card.
    public func updated(by update: ConnectionRequest) -> ConnectionRequest? {
        guard update.opID == opID, update.seq > seq || (update.isSettled && !isSettled && update.seq >= seq) else { return nil }
        return ConnectionRequest(opID: opID, seq: update.seq, deadline: update.deadline ?? deadline, targets: update.targets,
                                 suggested: update.suggested ?? suggested, settledBy: update.settledBy, isSettled: update.isSettled)
    }

    /// Every row needs nothing more from the person.
    public var allResolved: Bool { !targets.isEmpty && targets.allSatisfy(\.isResolved) }
}

/// One row of a connection card, as the gateway's snapshot gives it (`Target.snapshot` in
/// Hermes's `tools/connectors/operation.py`). What a person may do on it follows Hermes's
/// own state machine (`tools/connectors/contract.py`): the card only ever skips a row,
/// approves a pending one, asks for a failed or expired one to be tried again, or opens a
/// link the gateway has minted. Every `connected` is the gateway's to say.
public struct ConnectionTarget: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case connector, mcp, plugin, skill }
    public enum Action: String, Sendable, Equatable { case authorize, connect, enable, install, reconnect }
    public enum State: String, Sendable, Equatable { case pending, initiated, connected, skipped, failed, expired, notConnected = "not_connected" }
    /// How far a catalog entry is vouched for.
    public enum Tier: String, Sendable, Equatable { case official, verified, community }

    /// One value an install needs. A secret one is masked, never shown again, and never has
    /// a default: what is sent is only what the person typed.
    public struct Field: Sendable, Equatable, Identifiable {
        public let name: String
        public let isRequired: Bool
        public let isSecret: Bool
        public let defaultValue: String
        public let prompt: String?
        public var id: String { name }

        public init(name: String, isRequired: Bool, isSecret: Bool, defaultValue: String = "", prompt: String? = nil) {
            self.name = name
            self.isRequired = isRequired
            self.isSecret = isSecret
            self.defaultValue = isSecret ? "" : defaultValue
            self.prompt = prompt
        }

        /// What this field holds given what was typed: the typed text, else (for a value
        /// that is not secret) the default. The one rule for what is shown, what counts as
        /// filled in, and what is sent.
        public func value(typed: String?) -> String {
            if let typed { return typed }
            return isSecret ? "" : defaultValue
        }

        /// Filled in, for a required field: a secret as typed, anything else once trimmed.
        public func isFilled(typed: String?) -> Bool {
            let value = value(typed: typed)
            return isSecret ? !value.isEmpty : !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// What an MCP row will run (a command line) or contact (an address), as the gateway
    /// words it with values taken out: with the folder it runs in and the names of the
    /// environment variables it is given, which change what runs.
    public struct Launch: Sendable, Equatable {
        public let isRemote: Bool
        public let target: String
        public let cwd: String?
        public let env: [String]

        public init(isRemote: Bool, target: String, cwd: String? = nil, env: [String] = []) {
            self.isRemote = isRemote
            self.target = target
            self.cwd = cwd
            self.env = env
        }
    }

    /// Where a catalog plugin or skill comes from, which the person approves along with it.
    public struct Source: Sendable, Equatable {
        public let repo: String?
        public let sha: String?
        public let subdir: String?
        /// The bot it is installed into.
        public let targetProfile: String?
        public let platforms: [String]

        /// The commit as Hermes takes it for a pin (`ref`): forty hexadecimal digits, or nil.
        /// Approving sends it, so what installs is the commit the card showed.
        public var pinnedCommit: String? {
            guard let sha, sha.count == 40, sha.allSatisfy(\.isHexDigit) else { return nil }
            return sha
        }

        public init(repo: String? = nil, sha: String? = nil, subdir: String? = nil, targetProfile: String? = nil, platforms: [String] = []) {
            self.repo = repo
            self.sha = sha
            self.subdir = subdir
            self.targetProfile = targetProfile
            self.platforms = platforms
        }
    }

    /// The gateway's id for the row, which the card's answer names.
    public let name: String
    public let kind: Kind
    public let action: Action
    public let state: State
    /// The gateway's own word on whether the row needs anything more from the person; nil
    /// where it gave none.
    public let resolvedByGateway: Bool?
    /// The name to show, where the gateway gives one (catalog rows only).
    public let title: String?
    /// The account of a hosted app this row connects or repairs, where the gateway names one.
    public let alias: String?
    public let description: String?
    /// Why it failed, or what happened, or what it still waits for.
    public let detail: String?
    /// Where the person signs in, once the gateway has minted it. Opened only when they click.
    public let connectURL: URL?
    /// The gateway gave a link that this app will not hand to the browser.
    public let hasUnopenableLink: Bool
    public let fields: [Field]
    /// What an MCP row will run or contact. Nil where the gateway could not say.
    public let launch: Launch?
    public let tools: [String]
    public let tier: Tier?
    /// The catalog's security scan of what will be installed, when it was not clean.
    public let scan: String?
    /// Where a catalog plugin or skill comes from.
    public let source: Source?
    /// What did not come right on a row that is connected all the same: its tools could not
    /// be listed, it still needs a value, a server it brought did not start, or it was
    /// installed and left off. Said on the row and in the line the card leaves.
    public let caveat: String?

    public var id: String { name }

    /// Needs nothing more from the person, as Hermes counts it: connected or skipped, and for
    /// a catalog row also failed (it carries its reason; it can still be tried again while
    /// the card is open). An expired sign-in still waits on the person. The gateway's own
    /// flag wins where it gives one.
    public var isResolved: Bool {
        if let resolvedByGateway { return resolvedByGateway }
        switch state {
        case .connected, .skipped: return true
        case .failed: return kind == .plugin || kind == .skill
        default: return false
        }
    }

    /// A catalog plugin or skill: third-party code installed into the bot.
    public var isCatalog: Bool { kind == .plugin || kind == .skill }

    /// What the person can do on this row now, apart from skipping it.
    public enum Move: Equatable, Sendable {
        /// Nothing: the gateway is at work (minting a link, installing), or it is done.
        case none
        /// Approve it: install, enable or add it, with any values it asks for.
        case approve
        /// Open the sign-in the gateway minted, in the browser.
        case open(URL)
        /// Ask the gateway to try again: a fresh sign-in, or the install run again.
        case retry
    }

    /// The row's one move, from Hermes's state machine and its own cards
    /// (`connector-tool.tsx`, `mcp-setup-tool.tsx`). A pending authorize is the gateway still
    /// minting its link; an initiated row with a link is that link waiting, whatever the
    /// action; an initiated row with none is the gateway at work. A failed or expired row is
    /// tried again; its old link is dead. A connector is never approved: only its sign-in
    /// connects it.
    public var move: Move {
        switch state {
        case .connected, .skipped, .notConnected:
            return .none
        case .failed, .expired:
            return .retry
        case .initiated:
            return connectURL.map(Move.open) ?? .none
        case .pending:
            if kind == .connector || action == .authorize { return connectURL.map(Move.open) ?? .none }
            return .approve
        }
    }

    /// A failed or expired hosted app is tried again by asking the gateway to mint its sign-in
    /// afresh (`connectors.connect` with `reconnect`, `run.reissue`), since it is never approved.
    /// Any other row, an MCP server's authorization included, is tried again by approving it,
    /// with its values: Hermes runs a failed or expired MCP row again on approval (`_RETRY`, a
    /// fresh sign-in for an authorization), and `connectors.connect` would refuse an MCP
    /// server's name that is not also a connector's slug (`calendar.work`).
    public var retriesByReissue: Bool { kind == .connector }

    /// Approving it would run something the card can show: an MCP server's launch line, a
    /// catalog plugin's repository and commit, a skill's name in the hub. Otherwise the card
    /// does not offer to approve it.
    public var canBeApproved: Bool {
        switch kind {
        case .connector: return false
        case .mcp: return action == .authorize || launch != nil
        case .plugin: return source?.repo != nil && source?.pinnedCommit != nil
        case .skill: return true
        }
    }

    init?(row: JSONValue) {
        guard let name = row["name"]?.stringValue, !name.isEmpty,
              let kind = row["kind"]?.stringValue.flatMap(Kind.init(rawValue:)),
              let action = row["action"]?.stringValue.flatMap(Action.init(rawValue:)),
              let state = row["state"]?.stringValue.flatMap(State.init(rawValue:))
        else { return nil }
        func text(_ value: JSONValue?) -> String? {
            value?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        func texts(_ value: JSONValue?) -> [String] {
            guard case .array(let items)? = value else { return [] }
            return items.compactMap { text($0) }
        }
        self.name = name
        self.kind = kind
        self.action = action
        self.state = state
        resolvedByGateway = if case .bool(let resolved)? = row["resolved"] { resolved } else { nil }
        title = text(row["display"])
        alias = text(row["alias"])
        // A catalog row's one sentence, or the setup words Hermes gives an MCP row.
        description = text(row["description"]) ?? text(row["instructions"])
        detail = text(row["detail"])
        let link = text(row["connect_url"])
        connectURL = link.flatMap(Self.openable)
        hasUnopenableLink = link != nil && connectURL == nil
        fields = Self.fields(row["required_env"])
        if let target = text(row["launch"]?["target"]), let kind = row["launch"]?["kind"]?.stringValue, kind == "stdio" || kind == "remote" {
            launch = Launch(isRemote: kind == "remote", target: target,
                            cwd: text(row["launch"]?["cwd"]), env: texts(row["launch"]?["env"]))
        } else {
            launch = nil
        }
        tools = texts(row["tools"])
        tier = row["tier"]?.stringValue.flatMap(Tier.init(rawValue:))
        if let status = text(row["scan"]?["status"]), status != "passed" {
            scan = [status, text(row["scan"]?["summary"])].compactMap { $0 }.joined(separator: ": ")
        } else {
            scan = nil
        }
        var caveats: [String] = []
        if text(row["discovery_error"]) != nil { caveats.append("its tools couldn't be listed") }
        let missing = texts(row["missing_env"])
        if !missing.isEmpty { caveats.append("it still needs " + missing.joined(separator: ", ")) }
        if case .array(let errors)? = row["server_errors"], !errors.isEmpty { caveats.append("a server it brought didn't start") }
        if row["enabled"] == .bool(false) { caveats.append("it isn't turned on") }
        caveat = caveats.isEmpty ? nil : caveats.joined(separator: "; ")
        if kind == .plugin || kind == .skill {
            source = Source(repo: text(row["repo"]), sha: text(row["sha"]), subdir: text(row["subdir"]),
                            targetProfile: text(row["target_profile"]), platforms: texts(row["platforms"]))
        } else {
            source = nil
        }
    }

    /// The values a row asks for. A name given twice is one field, and secret if either is,
    /// so a value is never echoed into a plain field.
    static func fields(_ value: JSONValue?) -> [Field] {
        guard case .array(let rows)? = value else { return [] }
        var fields: [Field] = []
        for row in rows {
            guard let name = row["name"]?.stringValue, !name.isEmpty else { continue }
            // Secret unless it plainly says it is not: what is not understood is masked.
            let prompt = row["prompt"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let field = Field(name: name, isRequired: row["required"] != .bool(false), isSecret: row["secret"] != .bool(false),
                              defaultValue: row["default"]?.stringValue ?? "", prompt: prompt)
            fields = merged(fields, with: [field])
        }
        return fields
    }

    /// Two lists of fields as one, first seen first: a name given again is one field, secret
    /// and required if either says so. A card keeps every field a row has asked for, since
    /// Hermes asks again only for what is still missing and keeps nothing it was sent then.
    public static func merged(_ fields: [Field], with more: [Field]) -> [Field] {
        var all = fields
        for field in more {
            if let index = all.firstIndex(where: { $0.name == field.name }) {
                let first = all[index]
                all[index] = Field(name: field.name, isRequired: first.isRequired || field.isRequired, isSecret: first.isSecret || field.isSecret,
                                   defaultValue: first.defaultValue, prompt: first.prompt ?? field.prompt)
            } else {
                all.append(field)
            }
        }
        return all
    }

    public init(name: String, kind: Kind, action: Action, state: State, resolved: Bool? = nil, title: String? = nil,
                description: String? = nil, detail: String? = nil, connectURL: URL? = nil, fields: [Field] = [],
                launch: Launch? = nil, tools: [String] = [], tier: Tier? = nil, scan: String? = nil, source: Source? = nil, caveat: String? = nil,
                alias: String? = nil) {
        self.name = name
        self.kind = kind
        self.action = action
        self.state = state
        self.resolvedByGateway = resolved
        self.title = title
        self.alias = alias
        self.description = description
        self.detail = detail
        self.connectURL = connectURL
        self.hasUnopenableLink = false
        self.fields = fields
        self.launch = launch
        self.tools = tools
        self.tier = tier
        self.scan = scan
        self.source = source
        self.caveat = caveat
    }

    /// A sign-in address the app will hand to the browser: https, or http only to this Mac
    /// (a local sign-in flow). Anything else (a file, a script, another app's scheme, a
    /// password in the address) is not offered at all.
    public static func openable(_ text: String) -> URL? {
        guard let url = URL(string: text), let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http": return ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) ? url : nil
        default: return nil
        }
    }
}

/// The person's moves on a connection card.
public struct ConnectionAnswer: Sendable, Equatable {
    public enum Move: Sendable, Equatable {
        case skip
        /// Install, enable, authorize or try again, with the values the row asked for.
        case approve(values: [String: String])
    }

    public var moves: [String: Move]
    /// Done with the card, whatever is not finished.
    public var isContinue: Bool

    public init(moves: [String: Move] = [:], isContinue: Bool = false) {
        self.moves = moves
        self.isContinue = isContinue
    }

    var wire: JSONValue {
        var result: [String: JSONValue] = [:]
        if !moves.isEmpty {
            result["targets"] = .array(moves.sorted { $0.key < $1.key }.map { name, move in
                switch move {
                case .skip:
                    return .object(["name": .string(name), "status": .string("skipped")])
                case .approve(let values):
                    var row: [String: JSONValue] = ["name": .string(name), "status": .string("approved")]
                    if !values.isEmpty { row["env"] = .object(values.mapValues { .string($0) }) }
                    return .object(row)
                }
            })
        }
        if isContinue { result["settled_by"] = .string("continue") }
        return .object(result)
    }
}

extension ConnectionAnswer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Never the values typed.
    public var description: String {
        "connection(\(moves.count) moves\(isContinue ? ", continue" : ""))"
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension ConnectionAnswer.Move: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Never the values typed.
    public var description: String {
        switch self {
        case .skip: "skip"
        case .approve(let values): "approve(\(values.count) values)"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension GatewayClient {
    /// The gateway no longer has the card's operation open (`UNKNOWN_OPERATION`): it settled
    /// and was closed, here or elsewhere, before this move reached it.
    public struct ConnectionOver: Error, Sendable, Equatable {}

    /// The gateway refused a move or reissue on a connection card, carrying its structured
    /// `error.data.reason` (`ConnectorErrorReason` in Hermes's `tui_gateway/contracts/connectors.py`).
    public struct ConnectionRefusal: Error, Sendable, Equatable {
        public let code: Int
        public let reason: String?
        public let message: String

        public init(code: Int, reason: String?, message: String) {
            self.code = code
            self.reason = reason
            self.message = message
        }
    }

    /// Whether a 4004 refusal means the operation itself is gone (`UNKNOWN_OPERATION` in
    /// `error.data.reason`, falling back to message text only when `reason` is absent).
    private static func isOperationGone(_ rejection: Rejection) -> Bool {
        guard rejection.code == 4004 else { return false }
        if let reason = rejection.reason { return reason == "UNKNOWN_OPERATION" }
        return !rejection.message.lowercased().contains("target")
    }

    /// Makes the person's moves on a connection card, in the chat it was put in. Returns
    /// whether the card is now settled. Values typed go only into this request. Throws
    /// `ConnectionOver` when the gateway has closed the card already, or `ConnectionRefusal`
    /// when the gateway refuses the move.
    @discardableResult
    public func respond(to connection: ConnectionRequest, inSession sessionID: String, with answer: ConnectionAnswer, profile: String) async throws -> Bool {
        do {
            let result = try await requestWithReason("connection.respond", .object([
                "profile": .string(profile),
                "owner": .object(["type": .string("session"), "session_id": .string(sessionID)]),
                "op_id": .string(connection.opID),
                "result": answer.wire,
            ]), timeout: .seconds(60))
            return result["settled"] == .bool(true)
        } catch let rejection as Rejection {
            if Self.isOperationGone(rejection) { throw ConnectionOver() }
            throw ConnectionRefusal(code: rejection.code, reason: rejection.reason, message: rejection.message)
        }
    }

    /// Whether the gateway still has this card open in the chat (`connectors.operation.status`).
    /// Throws `GatewayError.unsupported` where it cannot say, or `ConnectionRefusal` if refused.
    public func connectionIsOpen(_ opID: String, inSession sessionID: String, profile: String) async throws -> Bool {
        do {
            let now = try await requestWithReason("connectors.operation.status", .object([
                "profile": .string(profile),
                "owner": .object(["type": .string("session"), "session_id": .string(sessionID)]),
                "op_id": .string(opID),
            ]), timeout: .seconds(20))
            // Only an answer about this very card, saying whether it is settled, is an answer.
            guard now["op_id"]?.stringValue == opID, case .bool(let settled)? = now["settled"] else {
                throw GatewayError.unexpectedReply(method: "connectors.operation.status")
            }
            return !settled
        } catch let rejection as Rejection {
            if Self.isOperationGone(rejection) { return false }
            throw ConnectionRefusal(code: rejection.code, reason: rejection.reason, message: rejection.message)
        }
    }

    /// Asks the gateway to try a failed or expired row again (`connectors.connect` with
    /// `reconnect`, as Hermes's own cards do): a fresh sign-in link for a hosted app, the
    /// sign-in or install run again for an MCP server or catalog entry. Answers with the
    /// card as it now stands; a new link is in it, to be opened only when the person clicks.
    /// Throws `ConnectionOver` when the gateway has closed the card already, or
    /// `ConnectionRefusal` when the gateway refuses the retry.
    public func retry(_ name: String, of connection: ConnectionRequest, inSession sessionID: String, profile: String) async throws -> ConnectionRequest? {
        // `connectors.connect` acts on whatever card is open in the chat now, so first make sure
        // it is still this one: a card settled elsewhere must not re-mint another's sign-in.
        // Where the gateway cannot say, nothing is tried. A moment between the two calls
        // remains, which only the gateway could close.
        guard try await connectionIsOpen(connection.opID, inSession: sessionID, profile: profile) else { throw ConnectionOver() }
        do {
            let result = try await requestWithReason("connectors.connect", .object([
                "profile": .string(profile),
                "owner": .object(["type": .string("session"), "session_id": .string(sessionID)]),
                "connectors": .array([.string(name)]),
                "reconnect": .bool(true),
            ]), timeout: .seconds(45))
            return ConnectionRequest(payload: result).flatMap { $0.opID == connection.opID ? $0 : nil }
        } catch let rejection as Rejection {
            if Self.isOperationGone(rejection) { throw ConnectionOver() }
            throw ConnectionRefusal(code: rejection.code, reason: rejection.reason, message: rejection.message)
        }
    }
}
