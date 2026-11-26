import Foundation

/// What a single-use pass from Hermes is for.
public enum TicketPurpose: String, Sendable {
    /// Opening the socket. One covers every bot the gateway serves.
    case interactive
    /// One HTTP request, for one bot.
    case http = "native-http"
}

/// Something that hands out single-use passes to a gateway, in place of a token.
public protocol TicketSource: Sendable {
    /// A fresh pass. `profile` names the bot an HTTP request is about.
    func ticket(_ purpose: TicketPurpose, profile: String?) async throws -> String
}

/// What opens a gateway: a token that lasts, or passes asked for one at a time.
public enum GatewayCredential: Sendable {
    case token(String)
    case tickets(any TicketSource)
    /// Signed in with a username and password.
    case signedIn(SignedInSession)
}

extension GatewayCredential: CustomStringConvertible, CustomDebugStringConvertible {
    // A token must not reach a log or a failed test's output by way of a print.
    public var description: String {
        switch self {
        case .token: "GatewayCredential(token: hidden)"
        case .tickets: "GatewayCredential(passes)"
        case .signedIn: "GatewayCredential(signed in)"
        }
    }
    public var debugDescription: String { description }
}

#if os(macOS)
/// Hermes running on this Mac, reached with no token. Only on a Mac: it runs Hermes's
/// own command, which nothing else can.
///
/// Hermes's own command hands out passes to a program run by the same person:
/// `hermes gateway tickets --serve` says where the gateway is, then answers each request
/// with one pass that works once and lasts thirty seconds. This runs that helper and asks
/// it. Nothing is saved: the passes are never written anywhere or printed.
///
/// One of these serves one connection to one address and is used once. When its helper
/// ends, for whatever reason, it gives no more passes and is never started again: the
/// gateway may have come back on another port, and a pass for that one must not be sent
/// to the address the old connection still holds. Make another for another connection.
public actor LocalHermes: TicketSource {
    public enum Failure: Error, Equatable {
        /// The helper ended, or never said where a gateway is: Hermes is not running
        /// here, or is too old to have the command.
        case notRunning
        /// It said something this app does not understand.
        case unexpected
        /// It would not give a pass.
        case refused
        case timedOut
    }

    /// Where Hermes's command is usually installed. A Mac app is not given the shell's
    /// PATH, so the usual places are looked in directly.
    public static var usualPlaces: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".local/bin/hermes"),
            home.appendingPathComponent(".hermes/hermes-agent/.hermes/bin/hermes"),
            URL(fileURLWithPath: "/opt/homebrew/bin/hermes"),
            URL(fileURLWithPath: "/usr/local/bin/hermes"),
        ]
    }

    /// Hermes's command, if it is installed in one of the usual places.
    public static func findCommand(in places: [URL] = usualPlaces) -> URL? {
        places.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private enum Said: Sendable {
        case line(String)
        case end
    }

    /// Someone waiting on the helper, and the clock that stops them waiting for ever.
    private struct Waiting<Value: Sendable> {
        let continuation: CheckedContinuation<Value, any Error>
        let clock: Task<Void, Never>
    }

    private let command: URL
    private let patience: Duration
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var found: GatewayEndpoint?
    /// Why it is over, once it is. Set once and never cleared.
    private var over: Failure?
    private var awaitingHello: [UUID: Waiting<GatewayEndpoint>] = [:]
    private var awaitingTicket: [Int: Waiting<String>] = [:]
    private var nextID = 0
    /// Ends a helper that has not said where the gateway is in time, whoever is or is no
    /// longer waiting to hear.
    private var startClock: Task<Void, Never>?
    /// Where what the helper says is handed on, closed when it is over.
    private var saying: AsyncStream<Said>.Continuation?

    public init(command: URL, patience: Duration = .seconds(20)) {
        self.command = command
        self.patience = patience
    }

    deinit {
        output?.readabilityHandler = nil
        // Closing its input is how the helper is told to end.
        try? input?.close()
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
    }

    /// Where the gateway on this Mac is. Starts the helper the first time it is asked.
    public func endpoint() async throws -> GatewayEndpoint {
        try Task.checkCancellation()
        if let over { throw over }
        if let found { return found }
        if process == nil { start() }
        if let over { throw over }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The helper's own clock ends the wait; see `start`.
                awaitingHello[id] = Waiting(continuation: continuation, clock: Task {})
            }
        } onCancel: {
            Task { await self.forgetHello(id) }
        }
    }

    public func ticket(_ purpose: TicketPurpose, profile: String?) async throws -> String {
        _ = try await endpoint()
        try Task.checkCancellation()
        guard let input else { throw over ?? .notRunning }
        nextID += 1
        let id = nextID
        var line: [String: JSONValue] = ["id": .number(Double(id)), "purpose": .string(purpose.rawValue)]
        // The socket's pass is for every bot; only a request's names one.
        if purpose == .http, let profile, !profile.isEmpty { line["profile"] = .string(profile) }
        let data = try JSONEncoder().encode(JSONValue.object(line)) + Data("\n".utf8)
        // Written without waiting: the pipe is set not to block, so a helper that has
        // stopped reading cannot hold this up. A line is far shorter than what a pipe
        // takes whole, so less than all of it written means the helper is no use.
        let written = data.withUnsafeBytes { write(input.fileDescriptor, $0.baseAddress, $0.count) }
        guard written == data.count else {
            // It has gone, or is not listening.
            end(because: .notRunning)
            throw Failure.notRunning
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                awaitingTicket[id] = Waiting(continuation: continuation, clock: clock {
                    $0.awaitingTicket.removeValue(forKey: id)?.continuation.resume(throwing: Failure.timedOut)
                })
            }
        } onCancel: {
            Task { await self.forgetTicket(id) }
        }
    }

    /// Ends the helper, for good.
    public func stop() {
        end(because: .notRunning)
    }

    private func forgetHello(_ id: UUID) {
        guard let waiting = awaitingHello.removeValue(forKey: id) else { return }
        waiting.clock.cancel()
        waiting.continuation.resume(throwing: CancellationError())
    }

    private func forgetTicket(_ id: Int) {
        guard let waiting = awaitingTicket.removeValue(forKey: id) else { return }
        waiting.clock.cancel()
        waiting.continuation.resume(throwing: CancellationError())
    }

    /// Does `act` when patience runs out, unless cancelled first.
    private func clock(_ act: @escaping @Sendable (isolated LocalHermes) -> Void) -> Task<Void, Never> {
        Task { [weak self, patience] in
            guard (try? await Task.sleep(for: patience)) != nil, let self else { return }
            await act(self)
        }
    }

    private func start() {
        let process = Process()
        process.executableURL = command
        process.arguments = ["gateway", "tickets", "--serve", "--json"]
        let toHelper = Pipe(), fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        // What it says on the side is not for showing and is never kept.
        process.standardError = FileHandle.nullDevice
        // Writing to a helper that has gone is an error to catch, not a signal that
        // ends this app.
        let writing = toHelper.fileHandleForWriting.fileDescriptor
        _ = fcntl(writing, F_SETNOSIGPIPE, 1)
        _ = fcntl(writing, F_SETFL, fcntl(writing, F_GETFL) | O_NONBLOCK)
        do {
            try process.run()
        } catch {
            over = .notRunning
            return
        }
        self.process = process
        input = toHelper.fileHandleForWriting
        let reading = fromHelper.fileHandleForReading
        output = reading
        // Read as it arrives, by a handler of this pipe's own (reading two helpers' pipes
        // as async bytes has the second wait on the first), and handed on in the order
        // read, so that its ending never overtakes the last thing it said.
        let (said, saying) = AsyncStream.makeStream(of: Said.self)
        self.saying = saying
        // A helper that never says where the gateway is will not be waited on, or asked
        // again, whether or not anyone is still waiting to hear.
        startClock = clock { $0.end(because: .timedOut) }
        let lines = Lines(saying)
        reading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            lines.take(data)
        }
        Task { [weak self] in
            for await one in said {
                guard let self else { return }
                switch one {
                case .line(let line): await self.heard(line)
                case .end: await self.end(because: .notRunning)
                }
            }
        }
    }

    /// Cuts what a pipe gives into lines. Only ever called by that pipe's handler, one
    /// call at a time.
    private final class Lines: @unchecked Sendable {
        private var kept = Data()
        private let saying: AsyncStream<Said>.Continuation

        init(_ saying: AsyncStream<Said>.Continuation) {
            self.saying = saying
        }

        /// Empty data is the end of the pipe.
        func take(_ data: Data) {
            guard !data.isEmpty else {
                saying.yield(.end)
                return saying.finish()
            }
            kept.append(data)
            while let end = kept.firstIndex(of: 0x0A) {
                saying.yield(.line(String(decoding: kept[kept.startIndex..<end], as: UTF8.self)))
                kept.removeSubrange(kept.startIndex...end)
            }
            // Nothing Hermes says is this long; more is not kept.
            if kept.count > 1_000_000 { kept.removeAll() }
        }
    }

    private func heard(_ line: String) {
        guard over == nil, let said = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return }
        if said["type"]?.stringValue == "hello" {
            // Said once, in the one form of this that is understood. Only ever this Mac
            // itself, by number, at a port and nothing more, as Hermes says it: a pass is
            // not sent anywhere else, whatever is said.
            guard found == nil, said["protocol"] == .number(1),
                  let origin = said["endpoint"]?["api_origin"]?.stringValue, let endpoint = GatewayEndpoint(origin),
                  endpoint.baseURL.scheme == "http", ["127.0.0.1", "::1"].contains(endpoint.baseURL.host() ?? ""),
                  endpoint.baseURL.port != nil, endpoint.baseURL.path.isEmpty
            else { return end(because: .unexpected) }
            found = endpoint
            startClock?.cancel()
            startClock = nil
            for waiting in awaitingHello.values {
                waiting.clock.cancel()
                waiting.continuation.resume(returning: endpoint)
            }
            awaitingHello.removeAll()
            return
        }
        guard case .number(let number)? = said["id"], let id = Int(exactly: number),
              let waiting = awaitingTicket.removeValue(forKey: id)
        else { return }
        waiting.clock.cancel()
        if said["ok"] == .bool(true), let ticket = said["ticket"]?.stringValue, !ticket.isEmpty {
            waiting.continuation.resume(returning: ticket)
        } else {
            waiting.continuation.resume(throwing: Failure.refused)
        }
    }

    private func end(because failure: Failure) {
        guard over == nil else { return }
        over = failure
        saying?.finish()
        saying = nil
        startClock?.cancel()
        startClock = nil
        output?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        found = nil
        for waiting in awaitingHello.values {
            waiting.clock.cancel()
            waiting.continuation.resume(throwing: failure)
        }
        awaitingHello.removeAll()
        for waiting in awaitingTicket.values {
            waiting.clock.cancel()
            waiting.continuation.resume(throwing: failure)
        }
        awaitingTicket.removeAll()
    }
}
#endif
