import Foundation
import HermesBotUI
import HermesKit
import Observation

@MainActor
@Observable
final class RosterModel {
    enum Phase: Equatable {
        /// No gateway has been set up yet.
        case needsSetup
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase = Phase.loading
    private(set) var bots: [Bot] = []
    /// Each bot's face, worked out once per load rather than on every redraw.
    private(set) var looks: [Bot.ID: AvatarLook] = [:]
    /// The last thing said in each bot's chat as one plain line, worked out once per load.
    private(set) var previews: [Bot.ID: String] = [:]
    var selectedID: Bot.ID? {
        didSet {
            guard selectedID != oldValue else { return }
            // A bot left because it went (deleted here or elsewhere) is not a way back. One
            // still being deleted is kept: going back passes over it while it is going, and
            // finds it again if the gateway would not delete it.
            if !isGoingThroughHistory, let oldValue, bots.contains(where: { $0.id == oldValue }) {
                history.left(oldValue)
            }
            // The one turned away from may have something not yet seen; the one turned to is being looked at.
            refreshUnread()
            readSelected()
            lookedAgain()
            if isLookedAt, let selectedID { alerts.clearBot(selectedID) }
        }
    }
    /// Bots that have said something since their chat was last looked at.
    private(set) var unread: Set<Bot.ID> = []
    /// Incremented when the person opens a bot from a system notification, so panels close.
    private(set) var notificationOpens = 0
    /// Bot clicked in a notification before the roster loaded, selected once it does.
    private var pendingNotificationBotID: Bot.ID?
    /// Reopens the main window if the person closed it and clicked a system notification.
    var reopenMainWindow: (() -> Void)? {
        get { alerts.onReopenWindow }
        set { alerts.onReopenWindow = newValue }
    }
    /// Tells the person outside the app when a bot is waiting on them while not in front.
    private let alerts: WaitingAlerts
    /// Questions already seen on this gateway (bounded), so reconnects or switching away do not re-alert.
    private var seenQuestions: [String] = []
    private var seenQuestionSet: Set<String> = []
    /// The window is in front, so the chat showing is being looked at.
    var isLookedAt = true {
        didSet {
            guard isLookedAt != oldValue else { return }
            refreshUnread()
            if isLookedAt {
                catchUpShowing()
                lookedAgain()
                alerts.appCameForward(selectedBotID: selectedID)
            }
        }
    }
    /// How far each chat has been read: the later of what the gateway holds for us and what
    /// has been looked at since.
    private var readThrough: [Bot.ID: Date] = [:]
    /// Savings of how far a chat has been read, each waiting a moment for more to come.
    private var readSaves: [Bot.ID: Task<Void, Never>] = [:]
    /// The listening for the gateway's notices that chats have changed.
    private var watching: Task<Void, Never>?
    /// The connection the watch is on.
    private var watchedClient: GatewayClient?
    /// False once the watched connection's event stream has ended.
    private var isWatchedClientAlive = false
    /// Kept for as long as the roster lives: the connection also carries the bots' events.
    private var client: GatewayClient?
    /// A gateway given outright, which is used and never saved: tests pass one, and
    /// `HERMES_URL` with `HERMES_TOKEN` in the environment is one for development.
    private let given: SavedGateway?
    private let store: GatewayStore
    /// Where the bots are, to show the person. Nil until a gateway is set up.
    private(set) var gatewayAddress: String?
    /// The person's own name for the gateway, if they gave it one.
    private(set) var gatewayNickname: String?
    /// What the gateway is called wherever it is shown: its nickname, or else its address.
    var gatewayName: String? { gatewayNickname ?? gatewayAddress }

    /// Gives the gateway a name of the person's own, kept on this Mac. Nothing, or only
    /// spaces, goes back to showing its address.
    func nameGateway(_ name: String) {
        guard !gatewayIsFixed else { return }
        store.setNickname(name)
        gatewayNickname = store.nickname
    }
    /// A disconnect's clearing of the Keychain, while it runs.
    private var clearing: Task<Void, Never>?
    /// Something the setup screen should say when it opens, such as a token left behind.
    private(set) var setupNotice: String?
    /// Servers that Hermes's own app on this Mac already connects to, offered at setup.
    private(set) var savedConnections: [SavedHermesConnection] = []
    /// Where those are read from. Nil reads none, as in tests.
    private let hermesConnections: URL?
    /// Hermes's own command on this Mac, when it is installed. Nil looks for none.
    private let hermesCommand: URL?
    /// Hermes is running on this Mac and can be connected to with nothing to type.
    private(set) var thisMacIsRunning = false
    /// The helper that hands out passes for the connection to Hermes on this Mac.
    private var local: LocalHermes?
    /// The gateway in use is Hermes on this Mac, which has no token.
    /// Also when it is what was saved and could not be reached just now.
    var isThisMac: Bool { local != nil || (given == nil && store.isThisMac) }

    /// Marks one signed-in session, so that what an old one renews is told from the new.
    private final class SignInMark: Sendable {}

    /// The signed-in session for the gateway in use. It belongs to the gateway and not to
    /// any one connection or load: a refresh token works once, so every connection made
    /// for this gateway shares the one session that holds it.
    private struct SignInInUse {
        let session: SignedInSession
        let mark: SignInMark
        let username: String
        let address: String
        /// What the saved gateway was when this became the one in use. A renewal is saved
        /// only while that still stands.
        let generation: Int
    }
    private var signIn: SignInInUse?
    /// The gateway in use was signed in to with a username and password. Also when that
    /// is what was saved and it could not be reached just now.
    var isSignedIn: Bool { signIn != nil || (given == nil && store.isSignIn) }
    /// A renewed sign-in could not be saved to the Keychain. The session works until the
    /// app quits; after that the person would have to sign in again.
    private(set) var signInNotSaved = false

    /// A session kept current for a gateway signed in to. Each renewal is handed to
    /// `keep`, which saves it while this session is still the one in use.
    private func session(for signedIn: SignedIn, username: String, at endpoint: GatewayEndpoint, plainHTTPChosen: Bool) -> (SignedInSession, SignInMark) {
        let mark = SignInMark()
        let session = SignedInSession(signedIn, at: endpoint) {
            // Asked before every use: where a name leads changes with the network.
            await GatewayProbe.mayCarryToken(to: endpoint, plainHTTPChosen: plainHTTPChosen)
        } renewed: { [weak self] new in
            await self?.keep(new, for: mark)
        }
        return (session, mark)
    }

    /// Saves a renewed session, unless the gateway has been left since. The check is made
    /// again where the saving is done, one change at a time, so a renewal can never undo
    /// a disconnect or overwrite the gateway connected to after it.
    private func keep(_ new: SignedIn, for mark: SignInMark) async {
        for attempt in 0..<3 {
            guard let signIn, signIn.mark === mark else { return }
            // What it holds now: a later renewal may have overtaken this one.
            let latest = attempt == 0 ? new : await signIn.session.latest
            let saving = SavedSignIn(address: signIn.address, provider: latest.provider, username: signIn.username, refreshToken: latest.refreshToken)
            do {
                _ = try await keeper.keep(saving, for: signIn.generation)
                if self.signIn?.mark === mark { signInNotSaved = false }
                return
            } catch {
                // The Keychain refused. Tried again shortly, and said if it goes on refusing.
                if self.signIn?.mark === mark { signInNotSaved = true }
                // Not after the last try: there is nothing left to wait for.
                if attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
            }
        }
    }

    /// Connects to a gateway signed in to at an earlier launch, or again after the line
    /// dropped. The session is made once and shared: only the first use renews it.
    /// `generation` is the count of changes read together with `saved`.
    private func makeSignedInClient(_ saved: SavedSignIn, plainHTTPChosen chosen: Bool, generation: Int, for thisLoad: Int) async throws -> GatewayClient {
        guard let endpoint = GatewayEndpoint(saved.address) else { throw GatewayProblem.BadAddress() }
        gatewayAddress = endpoint.label
        guard await GatewayProbe.mayCarryToken(to: endpoint, plainHTTPChosen: chosen) else { throw GatewayProblem.NoLongerPrivate() }
        guard thisLoad == loadCount else { throw CancellationError() }
        // Nothing is awaited between looking for the session and making it, so two loads
        // can never each make one from the same saved token.
        let session: SignedInSession
        if let signIn, signIn.address == saved.address, signIn.username == saved.username, signIn.generation == generation {
            session = signIn.session
        } else {
            // Nothing that opens the gateway is held yet: the first use renews it.
            let stale = SignedIn(accessToken: "", refreshToken: saved.refreshToken, expiresAt: .distantPast, provider: saved.provider, userID: saved.username)
            let (made, mark) = self.session(for: stale, username: saved.username, at: endpoint, plainHTTPChosen: chosen)
            signIn = SignInInUse(session: made, mark: mark, username: saved.username, address: saved.address, generation: generation)
            session = made
        }
        let client = GatewayClient(endpoint: endpoint, credential: .signedIn(session))
        await client.connect()
        guard thisLoad == loadCount else {
            await client.disconnect()
            throw CancellationError()
        }
        self.client = client
        watch(client, in: thisLoad)
        return client
    }

    /// Signs in to a gateway with a username and password, and connects. The password is
    /// sent once and never kept.
    func signIn(to found: GatewayProbe.Found, username: String, password: String) async -> SetUpFailure? {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else { return SetUpFailure(text: "Enter your username and password.") }
        guard let provider = found.passwordProvider else { return SetUpFailure(text: "This server doesn't sign in with a password.") }
        let endpoint = found.endpoint
        let notPrivate = SetUpFailure(text: "This server's address leads out onto the internet and isn't encrypted, so the password wasn't sent. Use https://, or type http:// in front to allow it.")
        // Asked at the moment of sending, as for a token.
        guard await GatewayProbe.mayCarryToken(to: endpoint, plainHTTPChosen: found.plainHTTPChosen) else { return notPrivate }
        let signedIn: SignedIn
        do {
            signedIn = try await GatewaySignIn.signIn(at: endpoint, provider: provider, username: username, password: password) {
                await GatewayProbe.mayCarryToken(to: endpoint, plainHTTPChosen: found.plainHTTPChosen)
            }
        } catch GatewaySignIn.Failure.notPrivate {
            return notPrivate
        } catch GatewaySignIn.Failure.wrongPassword {
            return SetUpFailure(text: "That username or password wasn't accepted.", tokenRefused: true)
        } catch GatewaySignIn.Failure.tooManyTries {
            return SetUpFailure(text: "Too many tries. Wait a moment, then try again.")
        } catch GatewaySignIn.Failure.unreachable {
            return SetUpFailure(text: "Couldn't reach the gateway.")
        } catch {
            return SetUpFailure(text: "The gateway answered in a way this app doesn't understand.")
        }
        let (session, mark) = session(for: signedIn, username: username, at: endpoint, plainHTTPChosen: found.plainHTTPChosen)
        let trial = GatewayClient(endpoint: endpoint, credential: .signedIn(session))
        await trial.connect()
        let bots: [Bot]
        do {
            bots = try await trial.listBots()
        } catch {
            await trial.disconnect()
            // Signed in a moment ago and turned away all the same.
            if case GatewayError.unauthorized = error { return SetUpFailure(text: "Signed in, but the gateway then turned the app away. Try again.") }
            return SetUpFailure(text: GatewayProblem.text(for: error))
        }
        let address = endpoint.baseURL.absoluteString
        // What the session holds now, not what signing in gave: connecting may already
        // have renewed it, and the token it was given first no longer works then.
        let held = await session.latest
        let generation: Int
        do {
            await clearing?.value
            generation = try await keeper.save(
                SavedSignIn(address: address, provider: held.provider, username: username, refreshToken: held.refreshToken),
                plainHTTPChosen: found.plainHTTPChosen)
        } catch {
            await trial.disconnect()
            return SetUpFailure(text: "Couldn't save the sign-in to the Keychain.")
        }
        let old = forgetConnection()
        signIn = SignInInUse(session: session, mark: mark, username: username, address: address, generation: generation)
        client = trial
        gatewayAddress = endpoint.label
        take(bots)
        selectedID = bots.first?.id
        setupNotice = nil
        phase = .loaded
        watch(trial, in: loadCount)
        // Renewed while it was being saved and adopted: that renewal had nowhere to go.
        let now = await session.latest
        if now.refreshToken != held.refreshToken { await keep(now, for: mark) }
        await old?.disconnect()
        return nil
    }

    /// What went wrong, in words. On this Mac there is no token to have been refused, and
    /// a sign-in that has ended is said to be that.
    func text(for error: any Error) -> String {
        if case GatewayError.unauthorized = error, isSignedIn { return GatewayProblem.signInEnded }
        if case GatewayError.unauthorized = error, isThisMac { return GatewayProblem.thisMacRefused }
        return GatewayProblem.text(for: error)
    }
    private var lookingAtThisMac: Task<Void, Never>?
    /// Helpers of connections to this Mac still being made. Ended when the gateway is
    /// forgotten, so none of them goes on to open a socket after that.
    private var pendingLocals: [LocalHermes] = []

    /// Runs once a connection to this Mac is proven and before it is saved. For tests.
    var beforeSavingThisMac: (() async -> Void)?

    private func noLongerPending(_ helper: LocalHermes) {
        pendingLocals.removeAll { $0 === helper }
    }

    /// What setup offers with nothing to type: Hermes on this Mac, then the servers
    /// Hermes's own app has saved.
    struct SetupOffer: Identifiable, Equatable {
        enum Kind: Equatable {
            case thisMac
            case saved(SavedHermesConnection)
        }
        let kind: Kind
        var id: String {
            switch kind {
            // No server Hermes's app saves can have this id: theirs are never empty.
            case .thisMac: ""
            case .saved(let saved): "saved-\(saved.id)"
            }
        }
        var label: String {
            switch kind {
            case .thisMac: "This Mac"
            case .saved(let saved): saved.label
            }
        }
        var detail: String {
            switch kind {
            case .thisMac: "Hermes is running here"
            case .saved(let saved): "\(saved.endpoint?.label ?? saved.address) · Saved in Hermes"
            }
        }
    }

    var setupOffers: [SetupOffer] {
        (thisMacIsRunning ? [SetupOffer(kind: .thisMac)] : []) + savedConnections.map { SetupOffer(kind: .saved($0)) }
    }
    /// Where every change to the saved gateway is made, one at a time.
    private let keeper: SavedGatewayKeeper
    /// The gateway was given outright, so it can't be changed from inside the app.
    var gatewayIsFixed: Bool { given != nil }

    init(
        gateway: (address: String, token: String)? = nil, store: GatewayStore? = nil, readsEnvironment: Bool = true,
        hermesConnections: URL? = nil, hermesCommand: URL? = nil, alerts: WaitingAlerts = .silent()
    ) {
        self.alerts = alerts
        // HERMES_BOT_HERMES names another command to ask, for trying "This Mac" during
        // development with a pretend one.
        let namedCommand = readsEnvironment ? ProcessInfo.processInfo.environment["HERMES_BOT_HERMES"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } : nil
        self.hermesCommand = hermesCommand ?? namedCommand ?? (readsEnvironment && gateway == nil ? LocalHermes.findCommand() : nil)
        // Only the app proper looks at Hermes's own app's file; a test names one, or none.
        // HERMES_BOT_CONNECTIONS names another file to read them from, for trying setup
        // during development without showing the real ones.
        let named = readsEnvironment ? ProcessInfo.processInfo.environment["HERMES_BOT_CONNECTIONS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } : nil
        self.hermesConnections = hermesConnections ?? named ?? (readsEnvironment && gateway == nil ? HermesDesktopConnections.file : nil)
        let environment = readsEnvironment ? ProcessInfo.processInfo.environment : [:]
        /// Set and not blank: an empty variable is the same as none.
        func value(_ name: String) -> String? {
            environment[name].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let gateway {
            given = SavedGateway(address: gateway.address, token: gateway.token)
        } else if let address = value("HERMES_URL"), let token = value("HERMES_TOKEN") {
            given = SavedGateway(address: address, token: token)
        } else {
            given = nil
        }
        // HERMES_BOT_STORE names a separate place to save a gateway, so trying setup during
        // development leaves the real saved gateway alone.
        // Its preferences and Keychain items go under names that can never be the real store's.
        self.store = store
            ?? value("HERMES_BOT_STORE").map {
                GatewayStore(suite: "HermesBot.trial.\($0)", service: "HermesBot trial store \($0)")
            }
            ?? GatewayStore()
        keeper = SavedGatewayKeeper(store: self.store)
        landLate = self.store.picturesMayLandLate
        files.totalCostLimit = 120_000_000
        gatewayNickname = given == nil ? self.store.nickname : nil
        // Known without waiting: with nothing given and no address saved, open on setup.
        if given == nil, !self.store.hasGateway {
            phase = .needsSetup
            findSavedConnections()
        }
        self.alerts.onSelectBot = { [weak self] id in self?.openFromNotification(id) }
    }

    private func openFromNotification(_ id: String) {
        if bots.contains(where: { $0.id == id && !deleting.contains($0.id) }) {
            pendingNotificationBotID = nil
            selectedID = id
            notificationOpens += 1
        } else if bots.isEmpty {
            pendingNotificationBotID = id
        }
    }

    /// Reads what Hermes's own app on this Mac connects to, for setup to offer.
    func findSavedConnections() {
        savedConnections = hermesConnections.map { HermesDesktopConnections.read(from: $0) } ?? []
        lookAtThisMac()
    }

    /// Asks Hermes's command whether a gateway is running on this Mac. Nothing is started
    /// and nothing is kept: the helper is ended as soon as it has answered.
    private func lookAtThisMac() {
        guard let hermesCommand, lookingAtThisMac == nil else { return }
        lookingAtThisMac = Task { [weak self] in
            let helper = LocalHermes(command: hermesCommand)
            let isRunning = (try? await helper.endpoint()) != nil
            await helper.stop()
            guard let self else { return }
            self.lookingAtThisMac = nil
            if self.thisMacIsRunning != isRunning { self.thisMacIsRunning = isRunning }
        }
    }

    /// Waits for the look at this Mac that is under way, if one is. For tests.
    func settleThisMac() async {
        await lookingAtThisMac?.value
    }
    /// Counts loads, so one that was overtaken by a newer one leaves the newer one's work alone.
    private var loadCount = 0

    var selected: Bot? { bots.first { $0.id == selectedID } }
    var mainBot: Bot? { bots.first(where: \.isDefault) }
    /// The bots below the main one: those pinned first, each group in the gateway's order.
    var otherBots: [Bot] { Self.others(of: bots, pinned: { self.isPinned($0) }) }

    static func others(of bots: [Bot], pinned: (Bot) -> Bool) -> [Bot] {
        let others = bots.filter { !$0.isDefault }
        return others.filter(pinned) + others.filter { !pinned($0) }
    }

    /// Pinned, as asked here and not yet saved, or as the gateway holds it.
    func isPinned(_ bot: Bot) -> Bool { pinning[bot.id]?.value ?? bot.isPinned }

    /// Something asked from a row's menu and not yet answered, shown meanwhile. Each ask has
    /// a number of its own, so the answer to an earlier one never clears a later one that
    /// asked the same.
    private struct Asked<Value> {
        let value: Value
        let number: Int
    }
    private var asks = 0
    private func ask<Value>(_ value: Value) -> Asked<Value> {
        asks += 1
        return Asked(value: value, number: asks)
    }
    private var pinning: [Bot.ID: Asked<Bool>] = [:]
    /// A mark put on (when) or taken off (nil).
    private var marking: [Bot.ID: Asked<Date?>] = [:]
    /// How far Mark as Read read a chat, until the gateway has it. Kept apart from how far
    /// it was read by looking, so a Mark as Read that does not stay gives the dot back.
    private var readAsked: [Bot.ID: Asked<Date>] = [:]
    /// When the person last turned to each bot's chat, or came back to the app with it
    /// showing. A mark made before then has been looked past, wherever it was made.
    private var turnedTo: [Bot.ID: Date] = [:]
    /// Marks looked past that the gateway would not take off: not asked again.
    private var unclearable: [Bot.ID: Date] = [:]

    /// When the person marked a bot unread (here or on another device), as asked or as held.
    private func markedAt(_ bot: Bot) -> Date? {
        if let asked = marking[bot.id] { return asked.value }
        return bot.markedUnread
    }

    /// The bots in the order the roster shows them, the main bot first, less any being
    /// deleted: what the keyboard goes through.
    var order: [Bot.ID] {
        ((mainBot.map { [$0] } ?? []) + otherBots).map(\.id).filter { !deleting.contains($0) }
    }

    /// The bots viewed, for ⌘[ and ⌘].
    private var history = BotHistory()
    /// The selection is being moved by going back or forward, which is not a visit.
    private var isGoingThroughHistory = false

    func goBack() {
        guard let id = history.goBack(from: selectedID, among: Set(order)) else { return }
        isGoingThroughHistory = true
        selectedID = id
        isGoingThroughHistory = false
    }

    func goForward() {
        guard let id = history.goForward(from: selectedID, among: Set(order)) else { return }
        isGoingThroughHistory = true
        selectedID = id
        isGoingThroughHistory = false
    }

    func look(for bot: Bot) -> AvatarLook {
        looks[bot.id] ?? .main
    }

    /// One chat per bot, kept while the app runs, so a bot goes on answering when another
    /// is selected.
    private var chats: [Bot.ID: ChatModel] = [:]

    func chat(for bot: Bot) -> ChatModel { chats[bot.id] ?? newChat(for: bot) }

    /// A chat for a bot, sharing the gateway's memory of connection cards.
    private func newChat(for bot: Bot) -> ChatModel {
        let chat = ChatModel()
        chat.questions.memory = connectionMemory
        chat.questions.owner = bot.name
        chat.approvalsHold = approvalsHold
        chat.questions.onChange = { [weak self] in self?.waitingChanged() }
        return chat
    }

    /// Whose a connection card heard of in a chat is: the bot whose chat it is, once claimed,
    /// or the chat itself until then.
    private func memoryKey(_ opID: String, inSession session: String?) -> ConnectionMemory.Key {
        if let session, let owner = liveSessions[session] { return .init(owner: owner.bot, op: opID) }
        return .chat(session ?? "", op: opID)
    }

    private func take(_ bots: [Bot]) {
        let previousNames = Set(self.bots.map(\.name))
        let newNames = Set(bots.map(\.name))
        self.bots = bots
        if newNames != previousNames {
            approvalsStateChanged(because: "The bots on the gateway changed since this was read.")
        } else {
            invalidateApprovalsIfRosterChanged(to: newNames)
        }
        looks = Dictionary(bots.map { ($0.id, $0.look) }, uniquingKeysWith: { first, _ in first })
        previews = Dictionary(bots.compactMap { bot in
            bot.chat.map { (bot.id, ReplyFormat.preview(of: $0.preview)) }
        }, uniquingKeysWith: { first, _ in first })
        for bot in bots where chats[bot.id] == nil { chats[bot.id] = newChat(for: bot) }
        if let pending = pendingNotificationBotID, !bots.isEmpty {
            pendingNotificationBotID = nil
            if bots.contains(where: { $0.id == pending && !deleting.contains($0.id) }) {
                selectedID = pending
                notificationOpens += 1
            }
        }
        refreshUnread()
        waitingChanged()
        catchUpShowing()
    }

    /// How far each chat's history has been put on screen: the time of the chat as the
    /// roster had it when its messages were last read in. The distant past for one read in
    /// with nothing said.
    private var shownThrough: [Bot.ID: Date] = [:]

    /// A chat's messages have been read in and are on screen, as far as this copy of the bot
    /// knew of. Told by the chat itself, only when they really were.
    func didShow(_ bot: Bot) {
        shownThrough[bot.id] = bot.chat?.lastActive ?? .distantPast
        // A chat put on screen: anything its bot is waiting on the person for is shown with it.
        if bot.id == selectedID { lookForQuestions(of: [bot]) }
        // More may have been said while that was being read in; if so it is read in too.
        // And the chat now on screen in front of the person carries no dot.
        if bot.id == selectedID {
            refreshUnread()
            catchUpShowing()
        }
    }

    /// Brings the chat that is showing up to date when something was said in it that is not
    /// on screen (by a routine, or from another device), and counts as read what is.
    private func catchUpShowing() {
        // One whose history has been read in once: the first reading is the view's own.
        if let bot = selected, let chat = chats[bot.id], let shown = shownThrough[bot.id], !chat.isWorking,
           (bot.chat?.lastActive ?? .distantPast) != shown {
            Task { await chat.load(bot, from: self) }
        }
        readSelected()
    }

    func isWorking(_ bot: Bot) -> Bool { chats[bot.id]?.isWorking ?? false }

    /// The connection, for sending. One that has dropped is made afresh, so a gateway that
    /// was out of reach for a moment can be sent to again without restarting the app.
    func liveClient() async throws -> GatewayClient {
        guard client != nil else { throw GatewayError.notConnected }
        let client = try await connectedClient(for: loadCount)
        // Before any chat is opened on it, so the bots' questions there come to this app.
        await client.answerQuestions()
        return client
    }

    /// Which bot each open chat belongs to, by its live session, with the connection it was
    /// opened on.
    private var liveSessions: [String: (bot: Bot.ID, client: GatewayClient)] = [:]
    /// Questions for an open chat that the roster had not yet been told of, until it is.
    private var unclaimed: [String: [(question: BotQuestion, client: GatewayClient)]] = [:]
    /// Questions the gateway has said are over, lately, on the connection in use: one that
    /// ends while its chat is being opened must not be put up from the opening's snapshot.
    private var endedLately: [EndedQuestion] = []

    /// The newest word the gateway has sent on each open connection card, by operation, on the
    /// connection in use: a card still waiting for its chat to be claimed, or coming back in an
    /// opening's snapshot, is shown as that word says, not as it was first asked.
    private var connectionUpdates: [String: (update: ConnectionRequest, session: String?, client: GatewayClient, order: Int)] = [:]
    private var connectionUpdatesHeard = 0
    /// What is kept for each connection card on this gateway while it may still be answered
    /// (`ConnectionMemory`): one for the gateway, handed to every chat, cleared when it is left.
    let connectionMemory = ConnectionMemory()
    /// Chats not yet claimed here whose turn ended lately, and when. A connection card holds
    /// its turn until it settles, so one in an opening's snapshot taken before that end may be
    /// over, and is checked with the gateway; a card asked after it comes as its own request.
    private var turnsEndedUnclaimed: [String: Date] = [:]
    /// Questions held back from a chat's opening until it is looked at again (#46), by live
    /// session id. The one record of them: every turn end reaches it (`turnEnded`), so a
    /// request it makes obsolete is never put up by the look or its fallback.
    private var heldForRecheck: [String: [(question: BotQuestion, client: GatewayClient)]] = [:]

    /// A question the gateway said was over, by its id and, where the gateway named it, its chat.
    private struct EndedQuestion: Equatable {
        let id: String
        let session: String?

        func names(_ question: BotQuestion) -> Bool {
            id == question.id && (session?.isEmpty != false || session == question.sessionID)
        }
    }
    /// How long a question waits for its chat to be claimed before the gateway is told it
    /// cannot be shown here.
    var unclaimedWait: Duration = .seconds(10)

    /// A bot's chat has been opened on a connection: questions in it go to that bot's chat,
    /// starting with those it was already waiting on.
    func chatOpened(_ open: LiveChat, of bot: Bot, on client: GatewayClient) {
        guard client === self.client, let chat = chats[bot.id] else { return }
        // A bot has one open chat on a connection: one it had before, under another live id,
        // has been let go of, and must not keep the look for waiting chats from this one.
        liveSessions = liveSessions.filter { $0.key == open.sessionID || $0.value.bot != bot.id || $0.value.client !== client }
        liveSessions[open.sessionID] = (bot.id, client)
        // What was kept for cards heard in this chat before it was claimed is its bot's now.
        connectionMemory.adopt(session: open.sessionID,
                               ops: Set(open.waiting.map(\.id) + (unclaimed[open.sessionID] ?? []).map(\.question.id)), bot: bot.name)
        // Kept for its 30 s, not used up by the first opening: every opening of this chat
        // in that time may carry a snapshot from before the end (#46).
        let turnEnded = turnsEndedUnclaimed[open.sessionID].map { Date.now.timeIntervalSince($0) < 30 } ?? false
        if !turnEnded { turnsEndedUnclaimed[open.sessionID] = nil }
        // A turn ended while this chat was opening, so the snapshot may be from before it and
        // hold a question another app has since answered. Such questions are put up only if a
        // fresh look at the chat, taken after that end was heard, still holds them (#46).
        let recheck = turnEnded ? bots.first(where: { $0.id == bot.id })?.chat ?? bot.chat : nil
        var toRecheck: [BotQuestion] = []
        for question in open.waiting where !endedLately.contains(where: { $0.names(question) }) {
            if recheck != nil, !{ if case .connection = question.kind { true } else { false } }() {
                toRecheck.append(question)
                continue
            }
            put(question, in: chat, on: client)
            // A turn ended while this chat was opening, and this card was not known to be its:
            // the gateway says whether it is still open, and one that is not is over here too.
            if turnEnded, case .connection = question.kind {
                let opID = question.id
                Task { [weak self] in
                    guard let open = try? await client.connectionIsOpen(opID, inSession: question.sessionID, profile: bot.name), !open,
                          let self, client === self.client else { return }
                    self.chats[bot.id]?.questions.connectionGone(opID, on: client)
                }
            }
        }
        for waiting in unclaimed.removeValue(forKey: open.sessionID) ?? []
        where waiting.client === client && !endedLately.contains(where: { $0.names(waiting.question) }) {
            put(waiting.question, in: chat, on: client)
        }
        if let recheck, !toRecheck.isEmpty {
            var held = heldForRecheck[open.sessionID] ?? []
            for question in toRecheck where !held.contains(where: { $0.question.id == question.id && $0.client === client }) {
                held.append((question, client))
            }
            heldForRecheck[open.sessionID] = held
            let ids = Set(toRecheck.map(\.id))
            let thisLoad = loadCount
            Task { [weak self] in await self?.recheck(ids, from: open, chat: recheck, of: bot, on: client, in: thisLoad) }
        }
    }

    /// Opens a chat again to see which of the questions held back from its opening are still
    /// asked, puts those up, and ends any of the others shown meanwhile by another way. Tried
    /// twice; if the gateway cannot be asked at all they are put up, since a question lost is
    /// worse than one already answered elsewhere (whose answer the gateway drops).
    private func recheck(_ ids: Set<String>, from open: LiveChat, chat stored: BotChat, of bot: Bot,
                         on client: GatewayClient, in thisLoad: Int) async {
        var fresh: LiveChat?
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            guard thisLoad == loadCount, client === self.client else { return }
            if let opened = try? await client.openChat(stored, profile: bot.name) {
                fresh = opened
                break
            }
        }
        guard thisLoad == loadCount, client === self.client else { return }
        // What is still held of this look's questions: a turn end meanwhile has let go of any
        // request it made obsolete.
        let session = open.sessionID
        let left = heldForRecheck[session] ?? []
        let held = left.filter { ids.contains($0.question.id) && $0.client === client }.map(\.question)
        let rest = left.filter { !(ids.contains($0.question.id) && $0.client === client) }
        heldForRecheck[session] = rest.isEmpty ? nil : rest
        guard let chat = chats[bot.id], liveSessions[session]?.bot == bot.id else { return }
        guard let fresh else {
            for question in held where !endedLately.contains(where: { $0.names(question) }) { put(question, in: chat, on: client) }
            return
        }
        // Opened again under another live id: taken up as any opening is.
        guard fresh.sessionID == open.sessionID else { return chatOpened(fresh, of: bot, on: client) }
        let still = Set(fresh.waiting.map(\.id))
        for question in fresh.waiting where held.contains(where: { $0.id == question.id }) && !endedLately.contains(where: { $0.names(question) }) {
            put(question, in: chat, on: client)
        }
        for question in held where !still.contains(question.id) {
            chat.questions.ended(question.id, inSession: open.sessionID, on: client, reason: nil)
        }
    }

    /// A turn has ended in a chat. Questions open in it that only the turn kept open are over;
    /// for a chat not yet claimed here, connection cards waiting for it are dropped, and one in
    /// its opening's snapshot is not put up (`turnsEndedUnclaimed`).
    func turnEnded(inSession session: String, on client: GatewayClient) {
        guard client === self.client else { return }
        for chat in chats.values { chat.questions.turnEnded(inSession: session, on: client) }
        // Requests held for a look again are over too, as shown ones are; noted as ended so a
        // snapshot taken before this end does not bring them back either.
        if let held = heldForRecheck[session] {
            let over = held.filter { if case .prompt = $0.question.route { false } else { $0.client === client } }
            let kept = held.filter { entry in !over.contains { $0.question.id == entry.question.id && $0.client === entry.client } }
            heldForRecheck[session] = kept.isEmpty ? nil : kept
            endedLately = Array((endedLately + over.map { EndedQuestion(id: $0.question.id, session: session) }).suffix(200))
        }
        guard liveSessions[session] == nil else { return }
        turnsEndedUnclaimed[session] = .now
        if turnsEndedUnclaimed.count > 50, let oldest = turnsEndedUnclaimed.min(by: { $0.value < $1.value })?.key { turnsEndedUnclaimed[oldest] = nil }
        // The cards known for this chat were the ended turn's: over, by their own ids. So are
        // requests heard before the chat was claimed, as `ChatQuestions.turnEnded` takes them
        // for a chat that is shown: the older route drops one another app answered without a
        // word, so one kept here could come back answered (#46). A session authority's prompt
        // is settled by its own event and is kept.
        var over = Set(connectionUpdates.filter { $0.value.client === client && $0.value.session == session }.map(\.key))
        if let waiting = unclaimed[session] {
            for entry in waiting {
                if case .prompt = entry.question.route { continue }
                over.insert(entry.question.id)
            }
            let left = waiting.filter { if case .prompt = $0.question.route { true } else { false } }
            unclaimed[session] = left.isEmpty ? nil : left
        }
        endedLately = Array((endedLately + over.map { EndedQuestion(id: $0, session: session) }).suffix(200))
    }

    /// Puts a question up in a chat; a connection card as the newest word heard on it says.
    private func put(_ question: BotQuestion, in chat: ChatModel, on client: GatewayClient) {
        chat.questions.ask(question, on: client, notBefore: chat.newestShown)
        if case .connection = question.kind, let heard = connectionUpdates[question.id], heard.client === client {
            chat.questions.connectionChanged(heard.update, inSession: heard.session ?? question.sessionID, on: client)
        }
    }

    /// The gateway says what has changed on a connection card. Kept, newest first, for a card
    /// whose chat is still being opened; one that is over is noted as ended, so an opening's
    /// snapshot taken before it ended does not put it up again.
    func connectionChanged(_ update: ConnectionRequest, inSession sessionID: String?, on client: GatewayClient) {
        guard client === self.client else { return }
        // Kept for the card until it settles or its deadline passes, whatever is shown.
        connectionMemory.heard(update, as: memoryKey(update.opID, inSession: sessionID), inSession: sessionID)
        if let kept = connectionUpdates[update.opID], kept.client === client, kept.update.updated(by: update) == nil {
            // Not newer than one already heard: moves nothing.
        } else {
            connectionUpdatesHeard += 1
            connectionUpdates[update.opID] = (update, sessionID, client, connectionUpdatesHeard)
            // Kept for cards still open first; of the rest, the one heard of longest ago goes.
            if connectionUpdates.count > 50, let oldest = connectionUpdates.min(by: {
                ($0.value.update.isSettled ? 0 : 1, $0.value.order) < ($1.value.update.isSettled ? 0 : 1, $1.value.order)
            })?.key {
                connectionUpdates[oldest] = nil
            }
        }
        if update.isSettled {
            let ended = EndedQuestion(id: update.opID, session: sessionID)
            endedLately = Array((endedLately + [ended]).suffix(200))
            for (session, waiting) in unclaimed {
                let left = waiting.filter { !(ended.names($0.question) && $0.client === client) }
                unclaimed[session] = left.isEmpty ? nil : left
            }
        }
        for chat in chats.values { chat.questions.connectionChanged(update, inSession: sessionID, on: client) }
    }

    /// A question from the gateway, for whichever bot's chat it was put in.
    func asked(_ question: BotQuestion, on client: GatewayClient) {
        guard client === self.client, !endedLately.contains(where: { $0.names(question) }) else { return }
        if case .connection(let card) = question.kind {
            connectionMemory.heard(card, as: memoryKey(card.opID, inSession: question.sessionID), inSession: question.sessionID)
        }
        if let owner = liveSessions[question.sessionID], owner.client === client, let chat = chats[owner.bot] {
            put(question, in: chat, on: client)
            return
        }
        // Its chat has not been opened here yet. Keep it and try to open its bot's chat in the
        // background so it can be shown; only a question for a chat that belongs to no bot here
        // (or cannot be opened) is declined once the wait and any claim under way end.
        var waiting = unclaimed[question.sessionID, default: []]
        guard !waiting.contains(where: { $0.question.id == question.id }) else { return }
        let isFirstForSession = waiting.isEmpty
        waiting.append((question, client))
        if waiting.count > 10 { client.declineSoon(waiting.removeFirst().question) }
        unclaimed[question.sessionID] = waiting
        unclaimedGeneration += 1
        if isFirstForSession { claimUnclaimed(sessionID: question.sessionID, on: client) }
        let wait = unclaimedWait
        let thisLoad = loadCount
        Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self else { return }
            await self.waitForBackgroundClaims(in: thisLoad)
            guard var left = self.unclaimed[question.sessionID],
                  let index = left.firstIndex(where: { $0.question.id == question.id && $0.client === client }) else { return }
            left.remove(at: index)
            self.unclaimed[question.sessionID] = left.isEmpty ? nil : left
            client.declineSoon(question)
        }
    }

    /// Tries to find which bot owns an unclaimed session and open its chat in the background,
    /// so a question arriving for a chat not yet opened is shown instead of declined.
    private func claimUnclaimed(sessionID: String, on client: GatewayClient) {
        let thisLoad = loadCount
        if let bot = bots.first(where: { $0.chat?.id == sessionID || $0.chat?.liveID == sessionID }) {
            Task { [weak self] in await self?.openInBackground(bot, on: client, in: thisLoad) }
            return
        }
        if bots.contains(where: { $0.chat != nil }) {
            lookForQuestions(of: bots, everyBot: true)
        } else if !bots.isEmpty {
            refreshSoon()
        }
    }

    /// Waits for any background look, roster refresh, or chat opening already under way for
    /// `thisLoad`, so a question whose chat is being opened is not declined while in flight.
    private func waitForBackgroundClaims(in thisLoad: Int) async {
        while thisLoad == loadCount {
            if let refreshing, refreshing.load == thisLoad {
                await refreshing.task.value
                continue
            }
            if let task = lookingTask, lookingIn == thisLoad {
                await task.value
                continue
            }
            if let opening = openingInBackground.values.first(where: { $0.load == thisLoad }) {
                await opening.task.value
                continue
            }
            break
        }
    }

    /// Opens a bot's chat in the background to pick up any question waiting in it, joining an
    /// opening already under way for the same bot, client, and target chat id.
    private func openInBackground(_ bot: Bot, on client: GatewayClient, in thisLoad: Int) async {
        guard let chat = bot.chat else { return }
        if let existing = openingInBackground[bot.id],
           existing.load == thisLoad, existing.client === client, existing.liveID == chat.liveID {
            await existing.task.value
            return
        }
        let task = Task { [weak self] in
            guard let open = try? await client.openChat(chat, profile: bot.name),
                  let self, thisLoad == self.loadCount, client === self.client,
                  // A reply for a chat the bot has since moved on from (a newer chat opened
                  // meanwhile) must not take the place of the newer one.
                  self.bots.first(where: { $0.id == bot.id })?.chat?.liveID == chat.liveID else { return }
            self.chatOpened(open, of: bot, on: client)
        }
        openingInBackground[bot.id] = (thisLoad, client, chat.liveID, task)
        await task.value
        if openingInBackground[bot.id]?.task == task { openingInBackground[bot.id] = nil }
    }

    /// The gateway says a question is over: only the one it names, in the chat it names.
    private func questionEnded(_ id: String, inSession sessionID: String?, on client: GatewayClient, reason: String?) {
        guard client === self.client else { return }
        let ended = EndedQuestion(id: id, session: sessionID)
        endedLately = Array((endedLately + [ended]).suffix(200))
        for chat in chats.values { chat.questions.ended(id, inSession: sessionID, on: client, reason: reason) }
        for (session, waiting) in unclaimed {
            let left = waiting.filter { !(ended.names($0.question) && $0.client === client) }
            unclaimed[session] = left.isEmpty ? nil : left
        }
    }

    /// A connection in use has gone. Questions put on it can no longer be answered there; the
    /// chats they were in are opened again on the next connection, which hands them back if
    /// the bot is still waiting.
    private func questionsLost(on client: GatewayClient) {
        for chat in chats.values { chat.questions.lost(on: client) }
        liveSessions = liveSessions.filter { $0.value.client !== client }
        unclaimed = unclaimed.compactMapValues { waiting in
            let left = waiting.filter { $0.client !== client }
            return left.isEmpty ? nil : left
        }
        heldForRecheck = heldForRecheck.compactMapValues { held in
            let left = held.filter { $0.client !== client }
            return left.isEmpty ? nil : left
        }
        if client === self.client {
            endedLately = []
            turnsEndedUnclaimed = [:]
        }
        connectionUpdates = connectionUpdates.filter { $0.value.client !== client }
        // What cards asked for is kept over a reconnect to the same gateway (Hermes keeps no
        // value from a partial approval); leaving the gateway clears it.
    }

    /// The load a look for chats that may be waiting on the person is under way in. One left
    /// from an earlier load, or another connection, holds nothing up.
    private var lookingIn: Int?
    private var lookingTask: Task<Void, Never>?
    private var isLookingForQuestions: Bool { lookingIn == loadCount }
    /// Chats being opened in the background to pick up waiting questions, keyed by bot, client
    /// and target chat id so a replacement chat or new connection never joins a stale open.
    private var openingInBackground: [Bot.ID: (load: Int, client: GatewayClient, liveID: String, task: Task<Void, Never>)] = [:]
    /// Counts unclaimed questions added on this gateway and the latest generation for which a
    /// roster refresh was already run, so each newly arrived unclaimed question gets one refresh
    /// without looping on truly unknown sessions.
    private var unclaimedGeneration = 0
    private var unclaimedRefreshedThrough = 0
    /// Looks asked for while one was under way, made one: done when it ends, with the roster
    /// and the bot showing as they are then, so a bot listed meanwhile is not passed over.
    private var lookAgain: (ids: Set<Bot.ID>, everyBot: Bool, including: Set<Bot.ID>)?

    /// Opens on the connection in use the chats of these bots whose agents are at work on the
    /// gateway, so that a question one of them is waiting on is shown without the person
    /// having to send anything (a question asked before this app was started, or in a turn
    /// begun elsewhere). Only chats the gateway lists as at work are opened, so no idle bot is
    /// woken; one already attached on this connection is left unless it was replaced, released,
    /// or missed a waiting question. A gateway that will not list them is not asked to.
    /// Where the session authority handles chats each bot is asked about on its own, so after
    /// the first look only the bot showing and any bot whose chat just changed are (`everyBot` false).
    func lookForQuestions(of bots: [Bot], everyBot: Bool = true, including: Set<Bot.ID> = []) {
        // No chat to look at (as when the roster is not read yet): nothing to do, and nothing
        // held up by doing it.
        guard let client, !cannotListChatsAtWork, bots.contains(where: { $0.chat != nil }) else { return }
        guard !isLookingForQuestions else {
            lookAgain = (
                (lookAgain?.ids ?? []).union(bots.map(\.id)),
                (lookAgain?.everyBot ?? false) || everyBot,
                (lookAgain?.including ?? []).union(including)
            )
            return
        }
        let thisLoad = loadCount
        let showing = selectedID
        lookingIn = thisLoad
        lookingTask = Task {
            defer {
                if lookingIn == thisLoad {
                    lookingIn = nil
                    lookingTask = nil
                    if let again = lookAgain {
                        lookAgain = nil
                        lookForQuestions(
                            of: self.bots.filter { again.ids.contains($0.id) },
                            everyBot: again.everyBot, including: again.including
                        )
                    }
                }
            }
            // Which way to ask is known only once the gateway has greeted this connection.
            let authority = await client.sessionAuthorityOnceGreeted()
            let candidates = bots.filter { $0.chat != nil && (everyBot || !authority || $0.id == showing || including.contains($0.id)) }
            var atWork: [ChatAtWork] = []
            // One bot's list that could not be had does not hide what the others' say, nor
            // the reading of the roster below for a question no list matched.
            var someListFailed = false
            for profile in authority ? candidates.map(\.name) : [nil] {
                do {
                    atWork += try await client.chatsAtWork(profile: profile)
                } catch GatewayError.unsupported {
                    if client === self.client { cannotListChatsAtWork = true }
                    return
                } catch {
                    someListFailed = true
                }
            }
            for bot in candidates {
                guard thisLoad == loadCount, client === self.client, let chat = bot.chat else { return }
                let ids: Set<String> = [chat.id, chat.liveID]
                guard let matched = atWork.first(where: {
                    ($0.mayBeAsking || unclaimed[$0.id] != nil || unclaimed[$0.storedID] != nil) && (ids.contains($0.storedID) || ids.contains($0.id))
                }) else { continue }
                let attached = liveSessions[matched.id]?.bot == bot.id && liveSessions[matched.id]?.client === client
                let missedWaiting = matched.status == "waiting" && !isWaiting(bot)
                let movedElsewhere = including.contains(bot.id) && !isWorking(bot)
                guard !attached || missedWaiting || movedElsewhere else { continue }
                await openInBackground(bot, on: client, in: thisLoad)
            }
            // An unclaimed question in a brand-new chat not yet listed on our cached roster: read
            // the roster once for the current unclaimed generation so that bot gets its chat and
            // can be opened. On the session authority, bots without a chat were skipped above so
            // `atWork` will not list them yet.
            if unclaimedRefreshedThrough < unclaimedGeneration, thisLoad == loadCount, client === self.client, !unclaimed.isEmpty {
                let unmatched = authority || someListFailed || atWork.contains { row in
                    (unclaimed[row.id] != nil || unclaimed[row.storedID] != nil) && !self.bots.contains { bot in
                        guard let chat = bot.chat else { return false }
                        return chat.id == row.storedID || chat.liveID == row.storedID || chat.id == row.id || chat.liveID == row.id
                    }
                }
                if unmatched {
                    unclaimedRefreshedThrough = unclaimedGeneration
                    _ = await refreshBots()
                }
            }
        }
    }

    /// This gateway answered `session.active_list` as unknown.
    private var cannotListChatsAtWork = false

    /// Opens again, on a new connection, the chats whose questions went with the last one.
    private func askAgain(on client: GatewayClient, in thisLoad: Int) {
        let waiting = bots.filter { bot in chats[bot.id]?.questions.lost.isEmpty == false && bot.chat != nil }
        guard !waiting.isEmpty else { return }
        Task {
            await client.answerQuestions()
            for bot in waiting {
                guard thisLoad == loadCount, client === self.client, let chat = bot.chat else { return }
                if let open = try? await client.openChat(chat, profile: bot.name), thisLoad == loadCount {
                    chatOpened(open, of: bot, on: client)
                }
            }
        }
    }

    /// What a bot is waiting on the person for, if anything.
    func waitingText(for bot: Bot) -> String? {
        guard !deleting.contains(bot.id), let first = chats[bot.id]?.questions.open.first else { return nil }
        return Self.waitingText(for: first.question.kind)
    }

    static func waitingText(for kind: BotQuestion.Kind) -> String {
        switch kind {
        case .approval: "Waiting for approval"
        case .clarify: "Waiting for your answer"
        case .secret: "Waiting for a secret"
        case .sudo: "Waiting for a password"
        case .connection: "Waiting to connect"
        }
    }

    func isWaiting(_ bot: Bot) -> Bool {
        !deleting.contains(bot.id) && chats[bot.id]?.questions.isWaiting == true
    }

    /// Whether a bot's row, tile, rail face or search result carries the blue dot: unread, or
    /// waiting on an answer in a chat not currently in front of the person.
    func showsDot(for bot: Bot) -> Bool {
        unread.contains(bot.id) || (isWaiting(bot) && !(bot.id == selectedID && isLookedAt))
    }

    /// Every bot carrying a blue dot, for View Unread to step through.
    var needsAttention: Set<Bot.ID> {
        unread.union(bots.filter { isWaiting($0) && !($0.id == selectedID && isLookedAt) }.map(\.id))
    }

    /// When bots stop to ask leave, as Settings shows it.
    enum Approvals: Equatable {
        /// Not read yet, or a read before the setting was ever offered did not settle:
        /// Settings shows nothing.
        case unknown
        /// Discovered on first check that this gateway does not offer per-bot approvals:
        /// Settings shows nothing.
        case unavailable
        /// Every bot listed by the gateway just now has this mode.
        case every(ApprovalMode)
        /// The bots listed by the gateway just now differ.
        case mixed
        /// Being read or changed just now: what was shown before is no longer known to hold.
        case checking
        /// The gateway did not confirm every bot's mode, or the connection or bots changed
        /// since it did. Nothing said before is shown in its place; Settings offers Try Again.
        case unconfirmed
    }

    private(set) var approvals = Approvals.unknown
    /// Why the approval mode is not confirmed, or why a change did not go through everywhere.
    private(set) var approvalsProblem: String?
    /// Once this gateway has been seen to offer per-bot approvals, the card stays shown
    /// (with Try Again when unconfirmed) until the gateway is left.
    private var approvalsOffered = false
    /// The connection and exact bot set for which the currently shown mode was confirmed.
    private var approvalsClient: GatewayClient?
    private var approvalsBots: Set<String>?
    /// What the person's last change asked for and what kept it from every bot, kept across
    /// rechecks until they ask again or the gateway confirms what they asked for.
    private var approvalsChangeNote: (asked: ApprovalMode, problem: String)?
    /// Why the latest move of `approvalsEpoch` that was not a change of bots happened, so a
    /// check it stopped says that rather than blaming the bots.
    private var approvalsInterruption: String?
    /// Counts readings and changes as they begin. Only the latest may say what is shown;
    /// leaving the gateway counts too, so nothing begun for it says anything after.
    private var approvalsAsked = 0
    /// Monotonic generation bumped whenever roster membership, connection liveness, or a
    /// chat `/approvals` command changes state that could outdate an in-flight check.
    private var approvalsEpoch = 0
    /// The change of every bot's mode under way, by its count. Held until that change has
    /// unwound, even once overtaken by leaving the gateway; Settings offers no other change
    /// meanwhile, while it is the latest ask.
    private var settingApprovals: Int?
    var isSettingApprovals: Bool { settingApprovals != nil && settingApprovals == approvalsAsked }
    /// The writes of the last change, done once they have unwound. A change waits for the one
    /// before, even one overtaken by leaving the gateway and coming back, so two never reach a
    /// bot out of order from this app. A write already on the wire when its connection drops
    /// may still land late on the gateway: only a revision on the gateway's config could order that.
    private var approvalsWrites: Task<Void, Never>?
    /// Timeout per RPC for reading or changing approval modes. Shortened in tests.
    var approvalRequestTimeout: Duration = .seconds(30)
    /// How often an open Settings panel quietly re-proves a shown mode against the gateway,
    /// since Hermes emits no push event when another client creates/deletes a bot or changes
    /// `approvals.mode` on idle bots. Shortened in tests.
    var approvalsRecheckInterval: Duration = .seconds(5)

    private enum ApprovalsAsk: Equatable { case read, set(ApprovalMode) }
    private enum ApprovalsFound {
        /// The gateway has just confirmed what every bot it lists has.
        /// `through`: the number of the last bot list the connection had heard when it was proved.
        case confirmed(Approvals, bots: Set<String>, on: GatewayClient, problem: String?, through: Int)
        /// The gateway does not offer per-bot approvals.
        case unavailable(problem: String?)
        /// Nothing the gateway has just confirmed can be shown.
        case unconfirmed(problem: String?)
    }

    /// Reads every bot's approval mode straight from the gateway's own profile list.
    func readApprovals() async { await askApprovals(.read, quiet: false) }

    /// Quietly re-proves the mode while Settings remains open, without flickering "Checking…".
    /// Updates the shown mode if the gateway changed, expires to Not confirmed if the recheck
    /// fails, and keeps asking from Not confirmed, or from a first read that did not settle,
    /// so a passing failure heals by itself. A gateway found not to offer it is not asked again.
    func recheckApprovals() async {
        guard !isSettingApprovals else { return }
        switch approvals {
        case .every, .mixed, .unconfirmed, .unknown: await askApprovals(.read, quiet: true)
        case .checking, .unavailable: break
        }
    }

    /// Sets every bot's approval mode (from the gateway's own profile list), then reads them
    /// back and verifies the profile list did not change. One change at a time.
    func setApprovals(_ mode: ApprovalMode) async {
        guard !isSettingApprovals else { return }
        approvalsChangesAsked += 1
        approvalsLastEvery = nil
        approvalsChangeNote = nil
        await askApprovals(.set(mode), quiet: false)
    }

    /// Changes of every bot's mode asked for, so a mode carried to a new bot is not written over one asked since.
    private var approvalsChangesAsked = 0
    /// Changes of a bot's mode in chat (`/approvals`), for the same reason.
    private var approvalsChatChanges = 0
    /// The mode the gateway last confirmed for every bot, kept apart from what is shown, so a bot
    /// made just after another (when what is shown is Not confirmed) is still given it. Let go when a read finds otherwise, a change is asked for, a chat
    /// changes a bot's mode, or the gateway is left.
    private var approvalsLastEvery: ApprovalMode?
    /// Writes of approval modes under way, which every chat holds its messages for.
    let approvalsHold = ApprovalsHold()

    /// Try Again: the person moving on from what was said before, so the last change's note goes.
    func tryApprovalsAgain() async {
        guard !isSettingApprovals else { return }
        approvalsChangeNote = nil
        await askApprovals(.read, quiet: false)
    }

    /// Called when `/approvals <mode>` begins or finishes in chat so an open Settings panel
    /// never keeps showing an outdated mode or lets a concurrent check confirm one.
    func approvalsChangedInChat() {
        approvalsChatChanges += 1
        approvalsLastEvery = nil
        approvalsChangeNote = nil
        approvalsStateChanged(because: "A bot's approval mode was changed in chat.", interrupting: true)
    }

    /// `interrupting`: the reason is not a change of bots, and a check it stops says so.
    private func approvalsStateChanged(because reason: String, interrupting: Bool = false) {
        approvalsEpoch += 1
        approvalsInterruption = interrupting ? reason : nil
        invalidateApprovals(because: reason)
    }

    private func invalidateApprovals(because reason: String) {
        switch approvals {
        case .every, .mixed:
            approvals = .unconfirmed
            approvalsProblem = withChangeNote(reason)
            approvalsClient = nil
            approvalsBots = nil
        default: break
        }
    }

    /// A bot list heard on a connection: a claim proved there for other bots no longer holds.
    /// Every bot list heard lately, by connection and number, so a check about to confirm can be
    /// held to any that came after the ones it read, whether or not a claim was shown when they came.
    private var approvalsListings: [(client: ObjectIdentifier, number: Int, names: Set<String>)] = []
    /// The highest number let go of from `approvalsListings`, by connection.
    private var approvalsListingsLost: [ObjectIdentifier: Int] = [:]
    /// The number of the last bot list the shown claim was proved through.
    private var approvalsThrough: Int?
    /// Runs after a check's last read and before it confirms, so a test can have a bot list
    /// arrive in between. For tests.
    var approvalsWillCommit: (@MainActor () async -> Void)?

    /// Which bots refused the latest change, by its count, kept apart from why it stopped so the
    /// note left afterwards is only that.
    private var approvalsRefused: (ask: Int, text: String)?

    /// A reason, with what else is known to have gone wrong after it when that is not already said.
    private func joined(_ reason: String, _ problem: String?) -> String {
        guard let problem, !reason.contains(problem) else { return reason }
        return "\(reason) \(problem)"
    }

    /// Why the shown state is what it is, with what kept the person's last change from every
    /// bot after it when that is not already said.
    private func withChangeNote(_ reason: String?) -> String? {
        guard let note = approvalsChangeNote?.problem else { return reason }
        guard let reason, !reason.contains(note) else { return reason ?? note }
        return "\(reason) \(note)"
    }

    /// A bot list heard on a connection: kept for a check about to confirm, and a shown claim
    /// proved there before it, for other bots, no longer holds (Sol, rounds 4 and 5).
    private func approvalsHeard(_ number: Int, _ names: Set<String>, on heardOn: GatewayClient) {
        let id = ObjectIdentifier(heardOn)
        approvalsListings.append((id, number, names))
        if approvalsListings.count > 256 {
            let gone = approvalsListings.removeFirst()
            approvalsListingsLost[gone.client] = max(approvalsListingsLost[gone.client] ?? 0, gone.number)
        }
        guard heardOn === approvalsClient, let proven = approvalsBots, let through = approvalsThrough,
              number > through, names != proven else { return }
        invalidateApprovals(because: "The bots on the gateway changed since this was read.")
    }

    /// Whether a bot list heard on `client` after number `through` names other bots, or may have.
    private func approvalsContradicted(_ bots: Set<String>, on client: GatewayClient, after through: Int) -> Bool {
        let id = ObjectIdentifier(client)
        if let lost = approvalsListingsLost[id], lost > through { return true }
        return approvalsListings.contains { $0.client == id && $0.number > through && $0.names != bots }
    }

    private func invalidateApprovalsIfRosterChanged(to names: Set<String>) {
        if let proven = approvalsBots, names != proven {
            approvalsStateChanged(because: "The bots on the gateway changed since this was read.")
        }
    }

    private func approvalsConnectionChanged(replacedBy next: GatewayClient? = nil, lost: GatewayClient? = nil) {
        if let lost {
            approvalsEpoch += 1
            approvalsInterruption = "Lost the connection to the gateway."
            if approvalsClient === lost {
                invalidateApprovals(because: "Lost the connection to the gateway.")
            }
        } else if let confirmed = approvalsClient, confirmed !== next {
            approvalsEpoch += 1
            approvalsInterruption = "The connection to the gateway changed meanwhile."
            invalidateApprovals(because: "The connection to the gateway changed since this was read.")
        }
        // A fresh connection on a gateway where the setting was never offered may now offer it.
        if next != nil, !approvalsOffered, approvals == .unavailable {
            approvals = .unknown
        }
    }

    /// The one place the approval mode shown changes. While an explicit ask runs, an already-offered
    /// setting shows "Checking…" (or "Saving…") and drops its previous claim; however the ask ends,
    /// it settles into a mode the gateway just confirmed for every bot it lists, or Not confirmed
    /// with Try Again (or hidden if never offered). An ask overtaken by a later one leaves the
    /// showing to that one. A reading during a change is left to the change's own readback.
    private func askApprovals(_ ask: ApprovalsAsk, quiet: Bool) async {
        guard !isSettingApprovals else { return }
        // While a change is written, no message goes in any chat, those made meanwhile too: it
        // would run under the mode being left.
        let hold = approvalsHold
        let holds = if case .set = ask { true } else { false }
        if holds { hold.count += 1 }
        defer { if holds { hold.count -= 1 } }
        approvalsAsked += 1
        let thisAsk = approvalsAsked
        if case .set = ask {
            settingApprovals = thisAsk
            approvalsOffered = true
        }
        // What was said about an earlier ask is not shown under "Checking…" or "Saving…".
        if !quiet { approvalsProblem = nil }
        if approvalsOffered, !quiet {
            approvals = .checking
            approvalsClient = nil
            approvalsBots = nil
        }
        // Default outcome if any unforeseen exit path unwinds this call.
        var found = ApprovalsFound.unconfirmed(problem: nil)
        defer {
            // A bot list heard after the last one the check read, naming other bots, outweighs it,
            // however its word reached here.
            if case .confirmed(_, let bots, let on, let problem, let through) = found,
               approvalsContradicted(bots, on: on, after: through) {
                found = .unconfirmed(problem: joined(ask == .read
                    ? "The bots on the gateway changed while this was read."
                    : "The bots on the gateway changed meanwhile, so not every bot may have it.", problem))
            }
            if settingApprovals == thisAsk { settingApprovals = nil }
            if thisAsk == approvalsAsked {
                // Closing Settings cancels a quiet background recheck; leave an already-settled
                // state alone instead of flashing Not confirmed behind a closed panel.
                if quiet, Task.isCancelled {
                    // Nothing to change: a quiet recheck never entered `.checking`.
                } else {
                    if case .set(let asked) = ask {
                        let refused = approvalsRefused?.ask == thisAsk ? approvalsRefused?.text : nil
                        switch found {
                        case .confirmed(.every(asked), _, _, _, _): approvalsChangeNote = nil
                        case .confirmed(_, _, _, let problem?, _), .unconfirmed(let problem?):
                            approvalsChangeNote = (asked, refused ?? problem)
                        case .unavailable:
                            if let refused { approvalsChangeNote = (asked, refused) }
                        default: break
                        }
                    }
                    switch found {
                    case .confirmed(let shown, let bots, let on, var problem, let through):
                        if let note = approvalsChangeNote {
                            // A quiet recheck keeps saying why the last change did not reach
                            // every bot, until the gateway holds what was asked for.
                            if shown == .every(note.asked) { approvalsChangeNote = nil } else { problem = problem ?? note.problem }
                        }
                        approvalsOffered = true
                        approvals = shown
                        if case .every(let mode) = shown { approvalsLastEvery = mode } else { approvalsLastEvery = nil }
                        approvalsBots = bots
                        approvalsClient = on
                        approvalsThrough = through
                        approvalsProblem = problem
                    case .unavailable(let problem):
                        approvalsBots = nil
                        approvalsClient = nil
                        if approvalsOffered {
                            approvals = .unconfirmed
                            approvalsProblem = withChangeNote(problem ?? (quiet ? approvalsProblem : nil))
                        } else {
                            approvals = .unavailable
                            approvalsProblem = nil
                        }
                    case .unconfirmed(let problem):
                        approvalsBots = nil
                        approvalsClient = nil
                        if approvalsOffered {
                            // Do not clobber a more specific invalidation reason recorded while
                            // a quiet recheck was in flight.
                            let keepExisting = quiet && approvals == .unconfirmed && problem == nil
                            approvals = .unconfirmed
                            approvalsProblem = withChangeNote(keepExisting ? approvalsProblem : problem)
                        } else {
                            approvals = .unknown
                            approvalsProblem = nil
                        }
                    }
                }
            }
        }
        found = await findApprovals(ask, thisAsk)
    }

    /// Runs one reading or change against the gateway's own `profiles.list` bookends.
    /// Called only by `askApprovals`.
    private func findApprovals(_ ask: ApprovalsAsk, _ thisAsk: Int) async -> ApprovalsFound {
        let timeout = approvalRequestTimeout
        let thisLoad = loadCount
        let client: GatewayClient
        do {
            client = try await self.client(in: thisLoad)
        } catch is CancellationError {
            if case .set = ask {
                return .unconfirmed(problem: "The change was stopped before it reached every bot.")
            }
            return .unconfirmed(problem: nil)
        } catch {
            if case .set = ask {
                return .unconfirmed(problem: "Couldn't change it: the gateway couldn't be reached.")
            }
            return .unconfirmed(problem: nil)
        }

        // Captured after acquiring `client` (and for `.set`, after waiting on prior writes), so
        // any roster, connection, or chat `/approvals` change during the check aborts confirmation.
        var startingEpoch = approvalsEpoch
        // Every `profiles.list` answer this connection hears from here on, whoever asked for it
        // and whatever became of it, must list the bots the check proves.
        var listingsFrom = await client.listingMark()

        /// Still the latest ask, of the same load and epoch on the same live connection: what the
        /// gateway says now may be shown. Checked before each step and before confirming.
        func stillAsked() -> Bool {
            thisAsk == approvalsAsked && thisLoad == loadCount && approvalsEpoch == startingEpoch
                && client === self.client && (client !== watchedClient || isWatchedClientAlive) && !Task.isCancelled
        }
        let botsChanged = ask == .read
            ? "The bots on the gateway changed while this was read."
            : "The bots on the gateway changed meanwhile, so not every bot may have it."
        func stopped(_ problem: String? = nil) -> ApprovalsFound {
            if thisLoad == loadCount, thisAsk == approvalsAsked, approvalsEpoch != startingEpoch, !Task.isCancelled {
                return .unconfirmed(problem: joined(approvalsInterruption ?? botsChanged, problem))
            }
            if case .set = ask {
                return .unconfirmed(problem: joined("The change was stopped before it reached every bot.", problem))
            }
            return .unconfirmed(problem: problem)
        }
        func transportProblem(_ error: any Error) -> String {
            switch error {
            case is CancellationError:
                return "The change was stopped before it reached every bot."
            case GatewayError.timedOut:
                return "The gateway stopped answering before the change reached every bot."
            case GatewayError.connectionLost, GatewayError.notConnected:
                return "Lost the connection before the change reached every bot."
            case GatewayError.unauthorized:
                return "Couldn't change it: \(text(for: error))"
            default:
                return "Couldn't change it: the gateway didn't answer."
            }
        }

        guard stillAsked() else { return stopped() }

        /// Whether every `profiles.list` answer heard on this connection since the check began
        /// lists these bots.
        func listingsAgree(with names: Set<String>) async -> Int? {
            guard let listed = await client.listings(since: listingsFrom),
                  listed.heard.allSatisfy({ $0 == names }) else { return nil }
            return listed.through
        }
        /// A read that failed: said as what stopped it when something interrupted the check.
        func failed(_ problem: String?) -> ApprovalsFound {
            approvalsEpoch != startingEpoch ? stopped(problem) : .unconfirmed(problem: problem)
        }

        var problem: String?
        let beforeBots: [Bot]
        let beforeNames: Set<String>

        if case .set(let mode) = ask {
            let (unwound, done) = AsyncStream<Void>.makeStream()
            let before = approvalsWrites
            approvalsWrites = Task { for await _ in unwound {} }
            defer { done.finish() }
            await before?.value
            // Re-anchor the epoch and the bot lists heard once prior writes have unwound, before
            // reading `beforeBots`: what came while waiting belongs to no check.
            startingEpoch = approvalsEpoch
            listingsFrom = await client.listingMark()
            guard stillAsked() else { return stopped() }

            do {
                guard try await client.keepsSettingsPerBot() else {
                    return stillAsked() ? .unavailable(problem: "This gateway doesn't allow changing approvals per bot.") : stopped()
                }
            } catch GatewayError.unsupported {
                return stillAsked() ? .unavailable(problem: "This gateway doesn't allow changing approvals.") : stopped()
            } catch {
                return .unconfirmed(problem: transportProblem(error))
            }
            guard stillAsked() else { return stopped() }

            do {
                beforeBots = try await client.allBots(timeout: timeout)
            } catch {
                return .unconfirmed(problem: transportProblem(error))
            }
            guard stillAsked() else { return stopped() }
            beforeNames = Set(beforeBots.map(\.name))
            guard !beforeNames.isEmpty else { return .unavailable(problem: nil) }
            guard await listingsAgree(with: beforeNames) != nil else { return .unconfirmed(problem: botsChanged) }
            guard stillAsked() else { return stopped() }

            // Refusals are noted as they come, so a stop at a later bot still says them.
            var failed: [String] = []
            func refused(_ title: String) {
                failed.append(title)
                let text = "Couldn't change it for \(failed.joined(separator: ", "))."
                problem = text
                approvalsRefused = (thisAsk, text)
            }
            for bot in beforeBots {
                guard stillAsked() else { return stopped(problem) }
                do {
                    let now = try await client.setApprovalMode(mode, of: bot.name, timeout: timeout)
                    if now != mode { refused(bot.title) }
                } catch is CancellationError {
                    return stopped(problem)
                } catch let error as GatewayError {
                    switch error {
                    case .timedOut, .connectionLost, .notConnected, .unauthorized:
                        // Stop at the first transport failure: never multiply timeouts across bots.
                        return .unconfirmed(problem: joined(transportProblem(error), problem))
                    case .unsupported:
                        return stillAsked() ? .unavailable(problem: joined("This gateway doesn't allow changing approvals.", problem)) : stopped(problem)
                    case .rejected(code: 4064, _):
                        return .unconfirmed(problem: joined(botsChanged, problem))
                    case .rejected, .unexpectedReply:
                        // Per-bot refusal (e.g. administrator-managed 4030 or locked 4002):
                        // record the bot and continue so readback shows what the gateway still has.
                        refused(bot.title)
                        if !stillAsked() { return stopped(problem) }
                    }
                } catch {
                    refused(bot.title)
                    if !stillAsked() { return stopped(problem) }
                }
            }
        } else {
            do {
                guard try await client.keepsSettingsPerBot() else {
                    return stillAsked() ? .unavailable(problem: nil) : stopped()
                }
            } catch GatewayError.unsupported {
                return stillAsked() ? .unavailable(problem: nil) : stopped()
            } catch {
                return failed(nil)
            }
            guard stillAsked() else { return stopped() }

            do {
                beforeBots = try await client.allBots(timeout: timeout)
            } catch {
                return failed(nil)
            }
            guard stillAsked() else { return stopped() }
            beforeNames = Set(beforeBots.map(\.name))
            guard !beforeNames.isEmpty else { return .unavailable(problem: nil) }
        }

        var modes: Set<ApprovalMode> = []
        for bot in beforeBots {
            guard stillAsked() else { return stopped(problem) }
            do {
                let mode = try await client.approvalMode(of: bot.name, timeout: timeout)
                // The gateway answered for a bot while this ask is still valid: it offers per-bot approvals.
                if stillAsked() { approvalsOffered = true }
                modes.insert(mode)
            } catch is CancellationError {
                return stopped(problem)
            } catch GatewayError.unsupported {
                // After a change, or once offered, keep Not confirmed with Try Again.
                if case .set = ask { return .unconfirmed(problem: problem) }
                return stillAsked() ? .unavailable(problem: problem) : stopped(problem)
            } catch GatewayError.rejected(code: 4064, _) {
                return .unconfirmed(problem: joined(botsChanged, problem))
            } catch {
                // Stop at the first readback error: never multiply timeouts and never claim a mode.
                return failed(problem)
            }
        }

        // Re-read the gateway's own profile list after readback: a bot added or removed
        // meanwhile would make a claim about every bot untrue.
        guard stillAsked() else { return stopped(problem) }
        let afterBots: [Bot]
        do {
            afterBots = try await client.allBots(timeout: timeout)
        } catch is CancellationError {
            return stopped(problem)
        } catch {
            return failed(problem)
        }
        let afterNames = Set(afterBots.map(\.name))
        let through = await listingsAgree(with: afterNames)
        if let willCommit = approvalsWillCommit { await willCommit() }
        guard stillAsked() else { return stopped(problem) }
        guard afterNames == beforeNames, let through else {
            return .unconfirmed(problem: joined(botsChanged, problem))
        }
        guard let mode = modes.first else { return .unavailable(problem: problem) }
        return .confirmed(modes.count == 1 ? .every(mode) : .mixed, bots: afterNames, on: client, problem: problem, through: through)
    }

    /// What a bot's row says under its name: what it is waiting on the person for, if
    /// anything, else the last thing said in its chat.
    func rowPreview(for bot: Bot) -> String {
        waitingText(for: bot) ?? previews[bot.id] ?? ""
    }

    /// Keeps outside-the-app cues in step with every bot's open questions.
    private func waitingChanged() {
        var openKeys: Set<String> = []
        for bot in bots where !deleting.contains(bot.id) {
            guard let open = chats[bot.id]?.questions.open, !open.isEmpty else { continue }
            for asked in open {
                let key = "\(bot.id)\n\(asked.question.id)"
                openKeys.insert(key)
                if seenQuestionSet.insert(key).inserted {
                    seenQuestions.append(key)
                    if seenQuestions.count > 200 {
                        seenQuestionSet.remove(seenQuestions.removeFirst())
                    }
                    if !isLookedAt {
                        alerts.notify(WaitingAlerts.Notice(
                            id: key, botID: bot.id, botTitle: bot.title,
                            body: Self.waitingText(for: asked.question.kind)
                        ))
                    }
                }
            }
        }
        alerts.reconcile(openIDs: openKeys)
    }

    /// Whether the connection in use is up just now. For tests.
    var isConnectedNow: Bool { get async { await client?.isConnected ?? false } }

    /// The connection to the gateway a piece of work began on, or a failure if the app has
    /// moved to another since. What changes a gateway asks for this, so nothing meant for
    /// one gateway is ever sent to the next.
    private func client(in thisLoad: Int) async throws -> GatewayClient {
        guard thisLoad == loadCount else { throw CancellationError() }
        guard client != nil else { throw GatewayError.notConnected }
        let client = try await connectedClient(for: thisLoad)
        guard thisLoad == loadCount else { throw CancellationError() }
        return client
    }

    /// Counts changes made to the roster here, ahead of the gateway being read again.
    private var changeCount = 0
    /// Counts readings of the roster as they begin, and the latest one shown, so one that
    /// began earlier and came back later is not shown over it.
    private var readingsBegun = 0
    private var readingShown = 0

    /// Reads the roster again without showing it loading, after something changed a bot.
    /// On failure the roster stays as it was. A connection that dropped is made afresh.
    @discardableResult
    func refreshBots() async -> Bool {
        let thisLoad = loadCount
        // A reading begun before a change made here may not have it, and is read again
        // rather than shown over the change.
        for _ in 0..<3 {
            let changes = changeCount
            readingsBegun += 1
            let reading = readingsBegun
            let bots: [Bot]
            do {
                bots = try await client(in: thisLoad).listBots()
            } catch {
                // A token no longer taken is not tried again and again by the watch.
                if case GatewayError.unauthorized = error, thisLoad == loadCount {
                    if let helper = local {
                        // On this Mac it was one pass that was refused, and the next is a
                        // new one: the connection and its helper are let go, and the watch
                        // goes on to try again with others.
                        // The connection is kept, closed: the watch tells by it that there
                        // is still a gateway to come back to, and the next try replaces it.
                        local = nil
                        let refused = client
                        Task {
                            await refused?.disconnect()
                            await helper.stop()
                        }
                    } else {
                        tokenRefused = true
                        // A sign-in that has ended is said, not left as a roster that
                        // quietly stops keeping up.
                        if signIn != nil { phase = .failed(GatewayProblem.signInEnded) }
                    }
                }
                return false
            }
            guard thisLoad == loadCount else { return false }
            // The gateway has answered: a later drop is retried soon, not after a long wait.
            watchWait = 3
            tokenRefused = false
            // A later reading is already on screen: the roster is at least this new.
            if reading < readingShown { return true }
            if changes == changeCount {
                readingShown = reading
                let changed = Set(bots.filter { bot in
                    guard let chat = bot.chat else { return false }
                    return self.bots.first(where: { $0.id == bot.id })?.chat != chat
                }.map(\.id))
                take(bots)
                // A chat changed: a bot at work may have begun to wait on the person. The one
                // showing and any whose chat moved, or every bot where one look costs no more.
                lookForQuestions(of: bots, everyBot: false, including: changed)
                return true
            }
        }
        return false
    }

    /// The latest messages of a bot's chat. A bot that has never chatted has none.
    func messages(for bot: Bot, limit: Int = GatewayClient.chatReadLimit) async throws -> [ChatMessage] {
        guard let chat = bot.chat else { return [] }
        guard let client else { throw GatewayError.notConnected }
        return try await client.chatMessages(sessionID: chat.id, profile: bot.name, limit: limit)
    }

    /// Files bots have handed over, kept while the gateway is the one in use so that a
    /// picture is not fetched again each time its chat is shown.
    private final class KeptFile {
        let file: GatewayClient.File
        /// The reading it was fetched for (`ChatModel.rereads`); 0 for one fetched for no
        /// reading in particular.
        let reading: Int
        init(_ file: GatewayClient.File, reading: Int) {
            self.file = file
            self.reading = reading
        }
    }
    /// Goes up for a file each time what was kept of it is let go, so that a fetch begun
    /// before then, which may bring the old file, does not put it back.
    private var keptSince: [String: Int] = [:]
    private let files = NSCache<NSString, KeptFile>()
    /// Open chats in which pictures may be waiting on the gateway for a message that has
    /// not gone, with the places of those known. Kept here, by open chat, so it outlasts
    /// the chat's screen and a change of gateway: a gateway hands the same open chat back
    /// to whoever opens it again.
    private var waitingPictures: [String: [String]] = [:]

    /// The handing over or taking back of pictures still going on in an open chat. Kept
    /// here for the same reason: the chat's screen may be gone before it ends, and
    /// whoever sends into that chat next waits for it.
    private var pictureWork: [String: Task<Void, Never>] = [:]

    /// Does `work` after whatever is already going on in `chat`.
    func afterPictureWork(in chat: LiveChat, _ work: @escaping @MainActor () async -> Void) {
        let before = pictureWork[chat.sessionID]
        pictureWork[chat.sessionID] = Task {
            await before?.value
            await work()
        }
    }

    /// Returns once nothing is being handed over or taken back in `chat`.
    func pictureWorkEnded(in chat: LiveChat) async {
        while let work = pictureWork[chat.sessionID] {
            await work.value
            if pictureWork[chat.sessionID] == work { pictureWork[chat.sessionID] = nil }
        }
    }

    /// Pictures are about to be handed over for a message in `chat`.
    func picturesMayWait(in chat: LiveChat) { waitingPictures[chat.sessionID, default: []] += [] }
    /// The gateway has this picture, waiting.
    func pictureWaits(at path: String, in chat: LiveChat) { waitingPictures[chat.sessionID, default: []].append(path) }
    /// The places of pictures that may wait in `chat`; nil when none can be.
    func picturesWaiting(in chat: LiveChat) -> [String]? { waitingPictures[chat.sessionID] }
    /// None wait any more: they went with a message, or the gateway said it has none.
    func picturesWent(in chat: LiveChat) {
        waitingPictures[chat.sessionID] = nil
        landLate.remove(chat.sessionID)
    }

    /// Open chats already asked, in this run of the app, whether pictures wait in them.
    private var asked: Set<String> = []
    /// The first time in this run of the app that `chat` is opened, pictures may wait in
    /// it that no note here knows of: left by a run that was quit before taking them back.
    /// The gateway hands the same open chat back for a while after a connection ends, so
    /// it is asked once, by the same means as after a message that did not go.
    func opened(_ chat: LiveChat) {
        if asked.insert(chat.sessionID).inserted { picturesMayWait(in: chat) }
    }

    /// Open chats where a picture went to the gateway with no answer back yet: noted
    /// before it goes, and kept on disk, so that the connection going, the wait being
    /// given up on, or the app being quit leaves it noted. The gateway may still be
    /// queuing it after any count it gives, so a count of none settles nothing here:
    /// only closing the open chat does.
    private var landLate: Set<String> { didSet { store.setPicturesMayLandLate(landLate) } }
    func pictureGoes(in chat: LiveChat) {
        landLate.insert(chat.sessionID)
        picturesMayWait(in: chat)
    }
    /// The gateway answered about the picture, so it has done what it will with it.
    func pictureAnswered(in chat: LiveChat) { landLate.remove(chat.sessionID) }
    func picturesMayLandLate(in chat: LiveChat) -> Bool { landLate.contains(chat.sessionID) }

    /// The names what is kept goes by, for each bot, so that one bot's can be let go.
    private var keptFiles: [String: Set<String>] = [:]

    /// A bot has answered. It may have written again to a file it handed over before, so
    /// what was kept of its files is let go: the next look at one fetches it afresh.
    func answered(_ bot: Bot) {
        for key in keptFiles[bot.name] ?? [] { files.removeObject(forKey: key as NSString) }
        keptFiles[bot.name] = nil
    }

    /// Lets go of what was kept of these files of a bot's, so the next look at one fetches it afresh.
    func forget(_ paths: Set<String>, of bot: Bot) {
        for path in paths { letGo("\(bot.name)\n\(path)", of: bot) }
    }

    private func letGo(_ key: String, of bot: Bot) {
        files.removeObject(forKey: key as NSString)
        keptFiles[bot.name]?.remove(key)
        keptSince[key, default: 0] += 1
    }

    /// How many fetches are running, and who is waiting for one to end: a chat full of
    /// pictures does not ask the gateway for all of them at once.
    private var fetchesRunning = 0
    private var fetchesWaiting: [(id: UUID, turn: CheckedContinuation<Bool, Never>)] = []
    /// Goes up whenever what was fetched stops being good for whoever asked: the gateway
    /// is left, or a bot is forgotten. A fetch begun before then hands nothing back.
    private var filesEpoch = 0
    /// Which gateway, and which bots on it, a fetch begun now is for. Several fetches made
    /// for one thing (a page and the files beside it) pass it to `file`, so that none of
    /// them goes on once the gateway is left.
    var filesScope: Int { filesEpoch }

    /// A file a bot handed over in its chat, read from the gateway. Nothing larger than
    /// `limit` bytes is taken. Cancelling the asker stops it, also while it waits its turn.
    /// `reading` asks for the file as it was at that reading or later (`ChatModel.rereads`,
    /// for a file the bot may have written again): what was kept from an earlier one is let
    /// go and the file fetched afresh, once, for every asker of that reading.
    func file(at path: String, from bot: Bot, limit: Int = 30_000_000, within scope: Int? = nil, reading: Int = 0) async throws -> GatewayClient.File {
        guard scope == nil || scope == filesEpoch else { throw GatewayError.notConnected }
        let key = "\(bot.name)\n\(path)" as NSString
        if let kept = files.object(forKey: key), kept.reading < reading { letGo(key as String, of: bot) }
        if let kept = files.object(forKey: key) {
            guard kept.file.data.count <= limit else { throw GatewayError.rejected(code: 413, message: "This file is too large to show here.") }
            return kept.file
        }
        let since = keptSince[key as String] ?? 0
        guard let client else { throw GatewayError.notConnected }
        let epoch = scope ?? filesEpoch
        try await takeATurn()
        defer { endATurn() }
        // No longer wanted, or no longer for this gateway, by the time its turn came.
        try Task.checkCancellation()
        guard self.client === client, epoch == filesEpoch else { throw GatewayError.notConnected }
        // Fetched meanwhile by another asker, for this reading or a later one.
        if let kept = files.object(forKey: key), kept.reading >= reading, kept.file.data.count <= limit { return kept.file }
        let file = try await client.file(at: path, forBot: bot.name, inChat: bot.chat?.id, limit: limit)
        // Still the same gateway and the same bot: what one gave is neither kept nor
        // handed on for another.
        guard self.client === client, epoch == filesEpoch else { throw GatewayError.notConnected }
        // Kept only if nothing let go of the file since this fetch began: it may be the old one.
        if keptSince[key as String] ?? 0 == since {
            files.setObject(KeptFile(file, reading: reading), forKey: key, cost: file.data.count)
            keptFiles[bot.name, default: []].insert(key as String)
        }
        return file
    }

    /// Waits until fewer than two fetches are running. A waiter that is cancelled gives
    /// up its place at once, so what has scrolled out of sight is not fetched ahead of
    /// what is wanted now.
    private func takeATurn() async throws {
        if fetchesRunning < 2 {
            fetchesRunning += 1
            return
        }
        let id = UUID()
        let got = await withTaskCancellationHandler {
            await withCheckedContinuation { (turn: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled { return turn.resume(returning: false) }
                fetchesWaiting.append((id, turn))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.giveUpTurn(id) }
        }
        // Handed a turn that it then holds, or told it has none.
        if !got { throw CancellationError() }
    }

    private func giveUpTurn(_ id: UUID) {
        guard let at = fetchesWaiting.firstIndex(where: { $0.id == id }) else { return }
        fetchesWaiting.remove(at: at).turn.resume(returning: false)
    }

    private func endATurn() {
        // The turn passes straight to whoever is next, or is given back.
        if fetchesWaiting.isEmpty { fetchesRunning -= 1 } else { fetchesWaiting.removeFirst().turn.resume(returning: true) }
    }

    /// Connects if needed and reads the roster. Also the retry after a failure.
    func load() async {
        loadCount += 1
        let thisLoad = loadCount
        approvalsStateChanged(because: "The roster was reloaded since this was read.", interrupting: true)
        // Readings waiting to be noted belonged to the load before; left in place they
        // would stand in the way of every later one for their bot.
        for save in readSaves.values { save.cancel() }
        readSaves = [:]
        // So are pins and marks still being asked: what the gateway holds is shown.
        pinning = [:]
        marking = [:]
        readAsked = [:]
        unclearable = [:]
        // Nothing to load from: stay on setup, without a flash of the empty main window.
        if client == nil, given == nil, !store.hasGateway {
            phase = .needsSetup
            findSavedConnections()
            return
        }
        phase = .loading
        var used: GatewayClient?
        do {
            let client = try await connectedClient(for: thisLoad)
            used = client
            let bots = try await client.listBots()
            guard thisLoad == loadCount else { return }
            take(bots)
            if selected == nil { selectedID = bots.first?.id }
            phase = .loaded
            watchWait = 3
            // The gateway took the token this time, whatever it said to a try before.
            tokenRefused = false
            // Watched for this load, also when the connection was already there: the watch
            // of the load before it has stood down.
            watch(client, in: thisLoad)
        } catch is CancellationError {
            // The window went away mid-load. Nothing is wrong with the gateway.
        } catch is GatewayProblem.NotSetUp {
            guard thisLoad == loadCount else { return }
            phase = .needsSetup
            findSavedConnections()
        } catch {
            guard thisLoad == loadCount else {
                // Overtaken: leave the newer load's connection alone, close only our own.
                if used !== client { await used?.disconnect() }
                return
            }
            if client === used {
                client = nil
                // Its helper goes with it; the next try makes another.
                if let helper = local {
                    local = nil
                    Task { await helper.stop() }
                }
            }
            watching?.cancel()
            watching = nil
            if case GatewayError.unauthorized = error, given == nil, store.isThisMac {
                // There is no token to have been wrong.
                phase = .failed(GatewayProblem.thisMacRefused)
            } else if case GatewayError.unauthorized = error, isSignedIn {
                phase = .failed(GatewayProblem.signInEnded)
            } else {
                phase = .failed(GatewayProblem.text(for: error))
            }
            await used?.disconnect()
        }
    }

    /// The making of a connection now under way, so that two askers share the one made.
    private var connecting: (load: Int, task: Task<GatewayClient, any Error>)?

    private func connectedClient(for thisLoad: Int) async throws -> GatewayClient {
        // Asked of the connection in use as it is once the answer is in: another may have
        // taken its place while this one was being asked whether it had dropped.
        while let current = client {
            if await current.isConnected { return current }
            if client === current { break }
        }
        if let connecting, connecting.load == thisLoad { return try await connecting.task.value }
        // A task of its own: whoever asked first may be cancelled, and the connection made
        // is still everyone's.
        let task = Task { try await makeClient(for: thisLoad) }
        connecting = (thisLoad, task)
        defer { if connecting?.task == task { connecting = nil } }
        return try await task.value
    }

    private func makeClient(for thisLoad: Int) async throws -> GatewayClient {
        let gateway: SavedGateway
        var plainHTTPChosen = false
        // A disconnect still clearing what was saved finishes first: read before it, the
        // gateway just left would be connected to again.
        if given == nil { await clearing?.value }
        if let given {
            gateway = given
        } else if store.isThisMac {
            return try await makeLocalClient(for: thisLoad)
        } else {
            // Off the main thread (the Keychain may stop to ask the person's leave), and
            // read together with the count of changes, in the one place changes are made:
            // what is read and its count can then never belong to different gateways.
            let (saved, chosen, generation) = await keeper.read()
            plainHTTPChosen = chosen
            // Overtaken while the Keychain was being asked: what it said is no longer wanted.
            guard thisLoad == loadCount else { throw CancellationError() }
            switch saved {
            case .gateway(let saved): gateway = saved
            case .nothing, .thisMac: throw GatewayProblem.NotSetUp()
            case .signedIn(let saved): return try await makeSignedInClient(saved, plainHTTPChosen: chosen, generation: generation, for: thisLoad)
            case .unreadable(let address):
                // Still shown, so the person can see which gateway it is and disconnect from it.
                gatewayAddress = GatewayEndpoint(address)?.label ?? address
                throw GatewayProblem.TokenUnreadable()
            }
        }
        guard thisLoad == loadCount else { throw CancellationError() }
        guard let endpoint = GatewayEndpoint(gateway.address) else { throw GatewayProblem.BadAddress() }
        let token = gateway.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GatewayProblem.NotSetUp() }
        gatewayAddress = endpoint.label
        // Where a name leads changes with the network this Mac is on. One given by hand,
        // for development, is taken as it stands.
        if given == nil {
            guard await GatewayProbe.mayCarryToken(to: endpoint, plainHTTPChosen: plainHTTPChosen) else { throw GatewayProblem.NoLongerPrivate() }
            guard thisLoad == loadCount else { throw CancellationError() }
        }
        let client = GatewayClient(endpoint: endpoint, token: token)
        await client.connect()
        guard thisLoad == loadCount else {
            await client.disconnect()
            throw CancellationError()
        }
        self.client = client
        watch(client, in: thisLoad)
        return client
    }

    /// How long the watch waits before trying a dropped connection again. It grows with
    /// each try and goes back to the start once the gateway has answered.
    private var watchWait = 3.0
    /// The gateway no longer takes the token, so the watch has stopped trying.
    private var tokenRefused = false
    /// A reading of the roster asked for by the watch is under way (scoped to its load), and
    /// whether another was asked for meanwhile within that load.
    private var refreshing: (load: Int, task: Task<Void, Never>)?
    private var refreshWantedIn: Int?

    /// Reads the roster again on the watch's behalf, in a task of its own, so that nothing
    /// done to the watch can cut a reading short. Asks made while one is under way for the
    /// same load are answered by one more reading after it.
    private func refreshSoon() {
        let thisLoad = loadCount
        if refreshing?.load == thisLoad {
            refreshWantedIn = thisLoad
            return
        }
        var task: Task<Void, Never>?
        task = Task {
            repeat {
                if refreshWantedIn == thisLoad { refreshWantedIn = nil }
                await refreshBots()
            } while refreshWantedIn == thisLoad && loadCount == thisLoad
            if let task, refreshing?.task == task { refreshing = nil }
        }
        if let task { refreshing = (thisLoad, task) }
    }

    /// Hears the gateway say that some chat has changed, and reads the roster again: this is
    /// how a bot that speaks unasked, or is spoken to from elsewhere, shows up here. Every
    /// connection that becomes the one in use is watched, and only that one. If it drops,
    /// the roster is read again, which makes a new connection with a watch of its own: at
    /// first soon and then less often, and not at all once the token is refused.
    private func watch(_ client: GatewayClient, in thisLoad: Int) {
        // A connection taken over by another: its questions can no longer be answered on it,
        // whether or not its own watch got to say so before it was replaced.
        // Bot lists heard are kept for the connection in use only: a connection let go of may
        // have its identity taken by the next.
        if watchedClient !== client {
            approvalsListings = []
            approvalsListingsLost = [:]
        }
        if let previous = watchedClient, previous !== client {
            questionsLost(on: previous)
            approvalsConnectionChanged(replacedBy: client, lost: previous)
        } else {
            approvalsConnectionChanged(replacedBy: client)
        }
        watchedClient = client
        isWatchedClientAlive = true
        watching?.cancel()
        watching = Task { [weak self] in
            // Any bot list this connection hears from here on withdraws a shown claim about
            // every bot that it contradicts, even one confirmed in the moment it came.
            await client.hearBotListings { [weak self, weak client] number, names in
                Task { @MainActor in
                    guard let self, let client else { return }
                    self.approvalsHeard(number, names, on: client)
                }
            }
            let events = await client.events()
            // This app puts the bots' questions to the person, and answers the rest itself.
            await client.answerQuestions()
            self?.askAgain(on: client, in: thisLoad)
            // And any bot already waiting on the person, as when the app has just started.
            if let self { self.lookForQuestions(of: self.bots) }
            for await event in events {
                guard let self, !Task.isCancelled, thisLoad == self.loadCount else { return }
                if event.type == "sessions.changed" {
                    self.refreshSoon()
                } else if let question = BotQuestion(event) {
                    self.asked(question, on: client)
                } else if event.type == "connection.update", let update = ConnectionRequest(payload: event.payload) {
                    // An account's card (Hermes's Connectors page) is no chat's.
                    let owner = event.payload["owner"]
                    if owner?["type"]?.stringValue != "account" {
                        self.connectionChanged(update, inSession: event.sessionID ?? owner?["session_id"]?.stringValue, on: client)
                    }
                } else if let ended = BotQuestion.ended(by: event) {
                    self.questionEnded(ended.id, inSession: event.sessionID, on: client, reason: ended.reason)
                } else if event.type == "message.complete", let session = event.sessionID, client === self.client {
                    self.turnEnded(inSession: session, on: client)
                }
            }
            // Only when the connection really went: a watch replaced by another ends here too.
            if let self, !Task.isCancelled, thisLoad == self.loadCount {
                if self.watchedClient === client { self.isWatchedClientAlive = false }
                self.questionsLost(on: client)
                self.approvalsConnectionChanged(lost: client)
            }
            while !Task.isCancelled {
                guard let self, thisLoad == self.loadCount, self.client != nil, !self.tokenRefused else { return }
                let wait = self.watchWait
                self.watchWait = min(wait * 2, 60)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, thisLoad == self.loadCount, self.client != nil, !self.tokenRefused else { return }
                // In a task of its own: making the connection ends this watch for the new one.
                _ = await Task { await self.refreshBots() }.value
            }
        }
    }

    /// Tries a gateway the person typed in and, if it answers with its bots, saves it and
    /// starts using it. Returns what went wrong, or nil when it is now the gateway in use.
    func setUp(address: String, token: String) async -> String? {
        await connect(address: address, token: token)?.text
    }

    /// Why a gateway could not be set up.
    struct SetUpFailure: Equatable {
        let text: String
        /// The gateway answered and would not take the token: the address is right, and
        /// another token is what is needed.
        var tokenRefused = false
    }

    /// Connects to Hermes on this Mac for a load: a fresh helper each time, since the
    /// gateway may have restarted on another port since the last one.
    private func makeLocalClient(for thisLoad: Int) async throws -> GatewayClient {
        gatewayAddress = "This Mac"
        guard let hermesCommand else { throw GatewayProblem.ThisMacNotRunning() }
        let helper = LocalHermes(command: hermesCommand)
        pendingLocals.append(helper)
        defer { noLongerPending(helper) }
        guard let endpoint = try? await helper.endpoint() else {
            await helper.stop()
            guard thisLoad == loadCount else { throw CancellationError() }
            throw GatewayProblem.ThisMacNotRunning()
        }
        guard thisLoad == loadCount else {
            await helper.stop()
            throw CancellationError()
        }
        let client = GatewayClient(endpoint: endpoint, credential: .tickets(helper))
        await client.connect()
        guard thisLoad == loadCount else {
            await client.disconnect()
            await helper.stop()
            throw CancellationError()
        }
        // Kept only now that its connection is the one in use: an overtaken one's helper
        // was ended just above.
        if let old = local { Task { await old.stop() } }
        local = helper
        self.client = client
        watch(client, in: thisLoad)
        return client
    }

    /// Connects to Hermes running on this Mac, with nothing to type and no token.
    func connectToThisMac() async -> SetUpFailure? {
        guard let hermesCommand else { return SetUpFailure(text: GatewayProblem.text(for: GatewayProblem.ThisMacNotRunning())) }
        let helper = LocalHermes(command: hermesCommand)
        pendingLocals.append(helper)
        defer { noLongerPending(helper) }
        guard let endpoint = try? await helper.endpoint() else {
            await helper.stop()
            thisMacIsRunning = false
            return SetUpFailure(text: GatewayProblem.text(for: GatewayProblem.ThisMacNotRunning()))
        }
        let trial = GatewayClient(endpoint: endpoint, credential: .tickets(helper))
        await trial.connect()
        let bots: [Bot]
        do {
            bots = try await trial.listBots()
        } catch {
            await trial.disconnect()
            await helper.stop()
            if case GatewayError.unauthorized = error { return SetUpFailure(text: GatewayProblem.thisMacRefused) }
            return SetUpFailure(text: GatewayProblem.text(for: error))
        }
        await beforeSavingThisMac?()
        // A disconnect still clearing the Keychain must finish first, as for a token.
        await clearing?.value
        // Disconnected while this was being made: it is not what the person wants now,
        // and nothing is saved for it. Its helper was ended with the old gateway.
        func wasCalledOff() -> Bool { !pendingLocals.contains { $0 === helper } }
        guard !wasCalledOff() else {
            await trial.disconnect()
            return SetUpFailure(text: "Disconnected.")
        }
        guard (try? await keeper.saveThisMac()) != nil else {
            await trial.disconnect()
            await helper.stop()
            return SetUpFailure(text: "Couldn't remove the last server's token from the Keychain, so nothing was changed.")
        }
        // Or while it was being saved: what was just saved is taken back, once the
        // disconnect's own clearing is done, so that neither undoes the other.
        guard !wasCalledOff() else {
            await clearing?.value
            await keeper.forgetThisMac()
            await trial.disconnect()
            return SetUpFailure(text: "Disconnected.")
        }
        // Proven, and about to be the one in use: no longer one to end with the old gateway.
        noLongerPending(helper)
        let old = forgetConnection()
        local = helper
        client = trial
        gatewayAddress = "This Mac"
        take(bots)
        selectedID = bots.first?.id
        setupNotice = nil
        phase = .loaded
        watch(trial, in: loadCount)
        await old?.disconnect()
        return nil
    }

    /// The same as `setUp`, saying also whether it was the token that was refused.
    func connect(address: String, token: String, plainHTTPChosen: Bool = false) async -> SetUpFailure? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return SetUpFailure(text: "Enter the gateway's token.") }
        guard let endpoint = GatewayEndpoint(address) else { return SetUpFailure(text: GatewayProblem.text(for: GatewayProblem.BadAddress())) }
        // Asked again at the moment of sending: the look that found this server was a while ago.
        guard await GatewayProbe.mayCarryToken(to: endpoint, plainHTTPChosen: plainHTTPChosen) else {
            return SetUpFailure(text: GatewayProblem.text(for: GatewayProblem.NoLongerPrivate()))
        }
        let trial = GatewayClient(endpoint: endpoint, token: token)
        await trial.connect()
        let bots: [Bot]
        do {
            bots = try await trial.listBots()
        } catch {
            await trial.disconnect()
            if case GatewayError.unauthorized = error { return SetUpFailure(text: GatewayProblem.text(for: error), tokenRefused: true) }
            return SetUpFailure(text: GatewayProblem.text(for: error))
        }
        do {
            // The address as the app understood it, never as typed: a pasted link can carry
            // a token in its query, and that must not end up in preferences. Off the main
            // thread, as every Keychain call is: it may stop to ask the person's leave.
            let gateway = SavedGateway(address: endpoint.baseURL.absoluteString, token: token)
            // A disconnect still clearing the Keychain would take this gateway's token with it.
            await clearing?.value
            _ = try await keeper.save(gateway, plainHTTPChosen: plainHTTPChosen)
        } catch {
            await trial.disconnect()
            return SetUpFailure(text: "Couldn't save the token to the Keychain.")
        }
        // The connection that was just proven is the one to use.
        let old = forgetConnection()
        client = trial
        gatewayAddress = endpoint.label
        take(bots)
        selectedID = bots.first?.id
        setupNotice = nil
        phase = .loaded
        watch(trial, in: loadCount)
        await old?.disconnect()
        return nil
    }

    /// How making a bot went.
    enum NewBot: Equatable {
        case made
        /// Nothing was made.
        case failed(String)
        /// A bot of this id exists but its name and face are not saved. Trying again saves
        /// them, and is the person's say that the bot is theirs to name.
        case madeButUnnamed(id: String, String)
        /// It is not known whether a bot of this id was made: the gateway did not confirm and
        /// could not be asked. Trying again looks first, and writes nothing without asking.
        case unconfirmed(id: String, String)
    }

    /// A bot is being made. The dialog that asked stays up until it is known how it went:
    /// the gateway cannot be told to stop, and a bot made after its dialog was dismissed
    /// would be one nobody asked to keep.
    private(set) var isMakingBot = false
    /// This gateway can't make bots, so the way to ask is not offered.
    private(set) var cannotMakeBots = false

    /// Makes a new bot and selects it. `unnamed` is a bot an earlier try made without
    /// managing to save its name and face: only the saving is done again.
    func createBot(
        named title: String, look: AvatarLook, finishing unnamed: String? = nil, isConfirmed: Bool = true
    ) async -> NewBot {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failed("Give the bot a name.") }
        guard !isMakingBot else { return .failed("") }
        isMakingBot = true
        defer { isMakingBot = false }
        let thisLoad = loadCount
        // Hermes starts a new bot at its default mode, not the one every bot was last confirmed
        // to have here: that one is written to it too, once it is made.
        let carry = approvalsLastEvery.map { (mode: $0, changes: approvalsChangesAsked, chats: approvalsChatChanges) }
        let client: GatewayClient
        do {
            // Made afresh if the connection has dropped, as it is for sending.
            client = try await self.client(in: thisLoad)
        } catch {
            guard thisLoad == loadCount else { return .failed("") }
            let problem = text(for: error)
            guard let unnamed else { return .failed("Couldn't make the bot. \(problem)") }
            return isConfirmed
                ? .madeButUnnamed(id: unnamed, "Couldn't save the bot's name and face. \(problem)")
                : .unconfirmed(id: unnamed, "Couldn't reach the gateway to finish the bot. Try again when it is back.")
        }

        var id = unnamed ?? BotID.make(for: title, taken: Set(bots.map(\.name)))
        var isFinishing = unnamed != nil
        if isFinishing {
            // The bot being finished may never have been made, if its making went unconfirmed.
            // The roster says, once it can be read; until then the id is kept and nothing done.
            guard await refreshBots() else {
                guard thisLoad == loadCount else { return .failed("") }
                let message = "Couldn't reach the gateway to finish the bot. Try again when it is back."
                return isConfirmed ? .madeButUnnamed(id: id, message) : .unconfirmed(id: id, message)
            }
            guard thisLoad == loadCount else { return .failed("") }
            if !bots.contains(where: { $0.id == id }) {
                // It was never made: make it now.
                isFinishing = false
            } else if !isConfirmed {
                // It is there, and may be ours or someone else's. Ask before writing to it.
                return .madeButUnnamed(id: id, Self.isItYours(id))
            }
        }
        if !isFinishing {
            var triesLeft = 2
            making: while true {
                triesLeft -= 1
                do {
                    try await client.createBot(id: id)
                    approvalsStateChanged(because: "The bots on the gateway changed since this was read.")
                    if let carry { carryApprovals(carry.mode, to: id, titled: title, on: client, changes: carry.changes, chats: carry.chats) }
                    break making
                } catch GatewayError.unsupported {
                    cannotMakeBots = true
                    return .failed("This gateway doesn't offer making bots.")
                } catch GatewayError.rejected(let code, let message) where code != 5062 {
                    // Refused, so nothing was made. (5062 is the gateway saying a bot may have
                    // been made all the same; that goes the uncertain way below.) If the id
                    // was taken since the roster was read, that bot is someone else's: pick
                    // another id, once.
                    await refreshBots()
                    guard thisLoad == loadCount else { return .failed("") }
                    if triesLeft > 0, bots.contains(where: { $0.id == id }) {
                        id = BotID.make(for: title, taken: Set(bots.map(\.name)))
                        continue making
                    }
                    return .failed(message.isEmpty ? "The gateway didn't make the bot." : "The gateway didn't make the bot: \(message)")
                } catch {
                    // No answer either way. A bot of that id may be there now, and may be
                    // ours or one someone else made at the same moment: the person decides
                    // before anything is written to it.
                    approvalsStateChanged(because: "The bots on the gateway changed since this was read.")
                    let couldRead = await refreshBots()
                    guard thisLoad == loadCount else { return .failed("") }
                    guard couldRead else {
                        // Not known either way. The id is kept, so that trying again looks
                        // for this bot first and does not make a second beside it.
                        return .unconfirmed(id: id, "The gateway didn't confirm the bot was made. Try again when it is back.")
                    }
                    guard bots.contains(where: { $0.id == id }) else {
                        if case GatewayError.rejected(_, let message) = error, !message.isEmpty {
                            return .failed("The gateway didn't make the bot: \(message)")
                        }
                        return .failed("Couldn't make the bot. \(text(for: error))")
                    }
                    return .madeButUnnamed(id: id, Self.isItYours(id))
                }
            }
        }

        let meta: JSONValue = .object([
            "title": .string(title),
            "avatar": .object(["shape": .string(look.shape.rawValue), "color": .string(look.color.rawValue)]),
        ])
        // A bot made earlier whose making went unconfirmed, finished now: given the mode too.
        if isFinishing, let carry { carryApprovals(carry.mode, to: id, titled: title, on: client, changes: carry.changes, chats: carry.chats) }
        var unsaved = false
        do { try await client.saveMeta(meta, forBot: id) } catch { unsaved = true }
        await refreshBots()
        // The gateway was left meanwhile: nothing here is this roster's to show.
        guard thisLoad == loadCount else { return .failed("") }
        guard bots.contains(where: { $0.id == id }) else {
            // The bot was made; it is the list of bots that couldn't be read. Its id is kept,
            // so trying again finishes this bot and does not make a second.
            return .madeButUnnamed(id: id, "The bot was made, but setting it up couldn't be finished.")
        }
        selectedID = id
        return unsaved ? .madeButUnnamed(id: id, "The bot was made, but its name and face couldn't be saved.") : .made
    }

    /// Writes `mode` to a bot just made, after any change of every bot's mode already under way,
    /// holding every chat's messages meanwhile. Left alone if a change of every bot's mode, or a
    /// chat `/approvals`, was asked for since, which says for itself what the bots have. A read
    /// that has since confirmed another mode for every bot is followed instead. Ends by making a shown mode Not
    /// confirmed, so it is read again rather than claimed: what was shown before is no longer known.
    private func carryApprovals(_ mode: ApprovalMode, to id: String, titled title: String, on client: GatewayClient, changes changesBefore: Int, chats chatsBefore: Int) {
        let thisLoad = loadCount
        let hold = approvalsHold
        hold.count += 1
        let (unwound, done) = AsyncStream<Void>.makeStream()
        let before = approvalsWrites
        approvalsWrites = Task { for await _ in unwound {} }
        let timeout = approvalRequestTimeout
        Task { [weak self] in
            defer {
                done.finish()
                hold.count -= 1
            }
            await before?.value
            guard let self, thisLoad == self.loadCount, changesBefore == self.approvalsChangesAsked,
                  chatsBefore == self.approvalsChatChanges else { return }
            let mode = self.approvalsLastEvery ?? mode
            var given = false
            do { given = try await client.setApprovalMode(mode, of: id, timeout: timeout) == mode } catch {}
            guard thisLoad == self.loadCount else { return }
            if given {
                self.approvalsStateChanged(because: "The bots on the gateway changed since this was read.")
            } else {
                // Kept as the change's note, so it is said whatever is being shown or read just
                // now, until the person asks again or every bot has the mode.
                let failed = "Couldn't give \(title) the same approval mode as the other bots."
                self.approvalsLastEvery = nil
                self.approvalsChangeNote = (mode, failed)
                self.approvalsStateChanged(because: failed)
                // Said after whatever reason is already shown, not in its place.
                if self.approvals == .unconfirmed { self.approvalsProblem = self.withChangeNote(self.approvalsProblem) }
            }
        }
    }

    private static func isItYours(_ id: String) -> String {
        "The gateway didn't confirm, but a bot with the id “\(id)” is there now. If it's the one you were making, Try Again gives it this name and face."
    }

    /// Works out which bots have said something not yet looked at. A bot seen for the first
    /// time with a chat already going, and nothing noted of how far it was read, counts as
    /// read: there is no telling. One seen with nothing said yet is unread at its first word.
    private func refreshUnread() {
        var unread: Set<Bot.ID> = []
        for bot in bots {
            let known = [bot.readThrough, readThrough[bot.id]].compactMap { $0 }.max()
            // Something has been said: counted, or failing a count, there to be previewed.
            guard let chat = bot.chat, let last = chat.lastActive, chat.messageCount > 0 || !chat.preview.isEmpty else {
                // Nothing said yet: read as far as the beginning of time, and noted so.
                if known == nil { readThrough[bot.id] = Date(timeIntervalSince1970: 0) }
                // Until the gateway holds it: a noting cut short by a reload is made again.
                if bot.readThrough == nil { noteRead(bot.id) }
                continue
            }
            guard let known else {
                // Read as far as it went when first seen, and noted on the gateway so that
                // the next launch does not take it for a first sight all over again and
                // count as read whatever was said in between.
                readThrough[bot.id] = last
                noteRead(bot.id)
                continue
            }
            readThrough[bot.id] = known
            // Seen before but not yet noted on the gateway, as when the roster was loaded
            // again before the noting went: it is made again.
            if bot.readThrough == nil { noteRead(bot.id) }
            // The chat on screen in front of the person carries no dot, even for the moment
            // it takes to read in what was just said there. (How far it is read is still
            // only noted once that is on screen; see `readSelected`.)
            if bot.id == selectedID, isLookedAt, shownThrough[bot.id] != nil { continue }
            // Both are the gateway's own times for the chat, so later is later. Read as far
            // as Mark as Read went, while the gateway is being told.
            let shown = max(known, readAsked[bot.id]?.value ?? known)
            if last.timeIntervalSince(shown) > 0.01 { unread.insert(bot.id) }
        }
        // Marked unread by the person: a dot whatever has been read, until looked at again.
        for bot in bots where !deleting.contains(bot.id) {
            guard let marked = markedAt(bot) else { continue }
            // Looked at since it was marked: the mark is taken off (or the gateway would not).
            if let turned = turnedTo[bot.id], turned > marked, !cannotEditBots {
                if unclearable[bot.id] != marked { takeOff(marked, from: bot) }
                if unclearable[bot.id] != marked { continue }
            }
            unread.insert(bot.id)
        }
        // Left alone when nothing changed, so the sidebar is not redrawn for nothing.
        if unread != self.unread { self.unread = unread }
    }

    /// The gateway turned out not to keep how far a chat was read, so it is no longer told.
    private var cannotKeepRead = false

    /// The chat showing has been looked at, if the window is in front: it is read as far as
    /// it goes, here at once and on the gateway shortly, so another device knows too.
    private func readSelected() {
        guard isLookedAt, let bot = selected, let latest = bot.chat?.lastActive, !deleting.contains(bot.id) else { return }
        // Only as far as is on screen: a turn of ours in progress is, as it happens; anything
        // else once its history has been read in.
        let onScreen = chats[bot.id]?.isWorking == true ? latest : shownThrough[bot.id]
        guard let onScreen else { return }
        let last = min(latest, onScreen)
        // A mark the person put on it stays until the chat is turned to again.
        if latest.timeIntervalSince(last) <= 0.01, markedAt(bot) == nil { unread.remove(bot.id) }
        readThrough[bot.id] = max(readThrough[bot.id] ?? last, last)
        // Already noted on the gateway as read this far, or it keeps nothing from this app.
        guard last > .distantPast, bot.readThrough.map({ last.timeIntervalSince($0) > 0.01 }) ?? true, !cannotEditBots, !cannotKeepRead else { return }
        noteRead(bot.id)
    }

    /// Notes on the gateway, in a moment, how far a bot's chat is read here. A reply arriving
    /// moves that many times in a few seconds; the one saving already waiting covers them,
    /// taking how far the chat is read when it goes.
    private func noteRead(_ id: Bot.ID) {
        guard readSaves[id] == nil, !cannotEditBots, !cannotKeepRead, !deleting.contains(id) else { return }
        let thisLoad = loadCount
        readSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, thisLoad == self.loadCount else { return }
            self.readSaves[id] = nil
            // Found out meanwhile that it is not kept, or the bot is on its way out.
            guard !self.cannotEditBots, !self.cannotKeepRead, !self.deleting.contains(id), let read = self.readThrough[id] else { return }
            let earlier = self.saving[id]
            let save = Task { [weak self] () -> Saved? in
                _ = await earlier?.value
                // The save ahead of this one may be how it was found out that none is kept.
                guard let self, !self.cannotKeepRead, !self.deleting.contains(id) else { return nil }
                let saved = await self.save(title: nil, look: nil, read: read, forBot: id, in: thisLoad)
                // Refused, not merely out of reach: asking again each time a chat is read
                // would be asking for ever. Known before the next save in line begins.
                if case .refused = saved, thisLoad == self.loadCount { self.cannotKeepRead = true }
                return saved
            }
            self.saving[id] = Task { await save.value?.problem }
            _ = await save.value
        }
    }

    /// The chat showing has just been turned to, or the app brought to the front with it
    /// showing: noted, and a mark made before now is taken off. Not on every reading of the
    /// roster, so a bot marked while it is showing keeps its dot until it is looked at again;
    /// and a mark made on another device and heard of later is taken off if this one has
    /// looked since.
    private func lookedAgain() {
        guard isLookedAt, let bot = selected else { return }
        turnedTo[bot.id] = .now
        refreshUnread()
    }

    /// Takes off a mark the person has looked past. Not said if it fails: nobody asked.
    private func takeOff(_ marked: Date, from bot: Bot) {
        let id = bot.id
        let thisLoad = loadCount
        marking[id] = ask(nil)
        // Only a mark from before the look: one made since, by another device, stays.
        saveNotes(of: bot, mark: .off(before: turnedTo[id] ?? .now), asked: false) { [weak self] saved in
            // Refused or failed in this load; a reload tries again.
            guard let self, !saved, thisLoad == self.loadCount else { return }
            self.unclearable[id] = marked
        }
    }

    /// Puts a dot on a bot until its chat is next looked at, as the reference's Mark as
    /// Unread does. How far it was read is left alone, never moved back: another device
    /// goes by it. The mark is kept beside it, in our notes on the gateway, as the time it
    /// was made, so every device shows the dot and the first to have looked since takes it off.
    func markAsUnread(_ bot: Bot) async -> String? {
        guard !cannotEditBots, !deleting.contains(bot.id) else { return nil }
        let now = Date.now
        marking[bot.id] = ask(now)
        refreshUnread()
        return await saveNotes(of: bot, mark: .on(now), asked: true).value
    }

    /// Takes a bot's dot away without looking at its chat: read as far as it has gone, and
    /// any mark taken off. Only ever forward.
    func markAsRead(_ bot: Bot) async -> String? {
        guard !cannotEditBots, !deleting.contains(bot.id) else { return nil }
        let now = Date.now
        let last = bot.chat?.lastActive
        if let last { readAsked[bot.id] = ask(last) }
        marking[bot.id] = ask(nil)
        refreshUnread()
        // Any mark made before now is taken off, whether or not this device has heard of it:
        // another device may have marked it since the roster was last read here. One made
        // after now stays.
        return await saveNotes(of: bot, read: last, mark: .off(before: now), asked: true).value
    }

    /// Pins a bot to the top of the roster, under the main bot, or unpins it. Kept in our
    /// notes on the gateway, so it is pinned on every device.
    func pin(_ bot: Bot, _ pinned: Bool) async -> String? {
        guard !cannotEditBots, !deleting.contains(bot.id), !bot.isDefault else { return nil }
        pinning[bot.id] = ask(pinned)
        return await saveNotes(of: bot, pinned: pinned, asked: true).value
    }

    /// A mark put on, at a time, or taken off if it was made before a time: a mark made
    /// since, on another device, is not the one that was looked past.
    enum Mark {
        case on(Date)
        case off(before: Date)
    }

    /// Puts a mark into our notes as the gateway holds them this moment.
    static func apply(_ mark: Mark, to ours: inout [String: JSONValue]) {
        switch mark {
        case .on(let at): ours["unread"] = .number(at.timeIntervalSince1970)
        case .off(let before):
            if let made = ours["unread"]?.numberValue, made < before.timeIntervalSince1970 { ours["unread"] = nil }
        }
    }

    /// Saves pins, marks and how far a chat is read, after every save to this bot before it.
    /// What was asked here stays shown until the gateway answers, and then what it holds is
    /// shown, whether or not it kept it. `asked` is whether the person asked for this.
    @discardableResult
    private func saveNotes(of bot: Bot, read: Date? = nil, pinned: Bool? = nil, mark: Mark? = nil, asked: Bool, then: (@MainActor (Bool) -> Void)? = nil) -> Task<String?, Never> {
        let thisLoad = loadCount
        let earlier = saving[bot.id]
        let id = bot.id
        // The asks this save answers, by number.
        let pinAsk = pinned == nil ? nil : pinning[id]?.number
        let markAsk = mark == nil ? nil : marking[id]?.number
        let readAsk = read == nil ? nil : readAsked[id]?.number
        let save = Task { [weak self] () -> String? in
            _ = await earlier?.value
            guard let self else { return nil }
            let saved = await self.save(title: nil, look: nil, read: read, pinned: pinned, mark: mark, asked: asked, forBot: id, in: thisLoad)
            let kept: Bool = { if case .done = saved { return thisLoad == self.loadCount }; return false }()
            // Read as far as was asked, now the gateway has it; never back.
            if kept, let read { self.readThrough[id] = max(self.readThrough[id] ?? read, read) }
            // Shown now as the gateway has it, unless something was asked since.
            if let pinAsk, self.pinning[id]?.number == pinAsk { self.pinning[id] = nil }
            if let markAsk, self.marking[id]?.number == markAsk { self.marking[id] = nil }
            if let readAsk, self.readAsked[id]?.number == readAsk { self.readAsked[id] = nil }
            then?(kept)
            self.refreshUnread()
            return saved.problem
        }
        saving[id] = save
        return save
    }

    /// How a saving of our notes on a bot went.
    private enum Saved {
        case done
        /// Deleted from elsewhere: nothing was written, and there is nothing to say.
        case gone
        /// The gateway answered and would not: not for want of reaching it.
        case refused(String)
        case failed(String)

        var problem: String? {
            switch self {
            case .done, .gone: nil
            case .refused(let text), .failed(let text): text
            }
        }
    }

    /// Saves of what this app keeps about each bot, one at a time per bot: the gateway
    /// replaces our notes whole, so two at once could each undo the other.
    private var saving: [Bot.ID: Task<String?, Never>] = [:]

    /// Changes what this app keeps about a bot: its shown name, its face, or both. Returns
    /// what went wrong, or nil. Only what is being changed is written, on top of the notes
    /// as they are once every earlier change to this bot has been saved.
    func update(_ bot: Bot, title: String? = nil, look: AvatarLook? = nil) async -> String? {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, title.isEmpty { return "A bot needs a name." }
        // Refused here, not once queued: a change taken before Delete was asked is still
        // saved, so it is there if the gateway then refuses to delete the bot.
        guard !deleting.contains(bot.id) else { return "This bot is being deleted." }
        let thisLoad = loadCount
        let earlier = saving[bot.id]
        let id = bot.id
        let save = Task { [weak self] () -> String? in
            _ = await earlier?.value
            return await self?.save(title: title, look: look, read: nil, asked: true, forBot: id, in: thisLoad).problem
        }
        saving[id] = save
        return await save.value
    }

    private func save(title: String?, look: AvatarLook?, read: Date?, pinned: Bool? = nil, mark: Mark? = nil, asked: Bool = false, forBot id: Bot.ID, in thisLoad: Int) async -> Saved {
        // A bot that has gone, or another gateway by now: nothing to save to.
        guard thisLoad == loadCount, let bot = bots.first(where: { $0.id == id }) else { return .done }
        var ours: [String: JSONValue] = [:]
        do {
            let client = try await client(in: thisLoad)
            // On top of our notes as the gateway holds them this moment, not as last read
            // here: another device may have renamed the bot or read further since. (The
            // gateway replaces our notes whole, so what is not sent back is lost.)
            // No copy, no write: an old one sent back whole could undo theirs.
            let held = try await client.listBots().first { $0.id == id }
            guard thisLoad == loadCount else { return .done }
            // Deleted from elsewhere: there is nothing to keep notes on.
            guard let held else { return .gone }
            if case .object(let current)? = held.uiMeta["hermes-bot"] { ours = current }
            let fresh = ours
            if title == nil, look == nil, pinned == nil, mark == nil, let read, let theirs = held.readThrough, read.timeIntervalSince(theirs) <= 0.01 {
                // Already read this far on another device: nothing to write, only to know.
                if let index = bots.firstIndex(where: { $0.id == id }) {
                    changeCount += 1
                    bots[index] = bots[index].keeping(.object(ours))
                }
                return .done
            }
            if let title { ours["title"] = .string(title) }
            if let look {
                ours["avatar"] = .object(["shape": .string(look.shape.rawValue), "color": .string(look.color.rawValue)])
            }
            if let read {
                // Never back: another device may have read further.
                ours["read"] = .number(max(ours["read"]?.numberValue ?? 0, read.timeIntervalSince1970))
            }
            // Written only when true, and taken out when not, so our notes carry only what is so.
            if let pinned { ours["pinned"] = pinned ? .bool(true) : nil }
            if let mark { Self.apply(mark, to: &ours) }
            // A mark to take off that was already gone, or is newer than the look: nothing to
            // write, only to show as the gateway has it.
            if title == nil, look == nil, pinned == nil, read == nil, ours == fresh {
                if let index = bots.firstIndex(where: { $0.id == id }) {
                    changeCount += 1
                    bots[index] = bots[index].keeping(.object(ours))
                }
                return .done
            }
            try await client.saveMeta(.object(ours), forBot: bot.name)
        } catch GatewayError.unsupported {
            guard thisLoad == loadCount else { return .done }
            // Not a failure: names and faces stop being offered for change, and the person
            // who has just changed one is told why it did not stay. Only when they asked
            // for a change, though: a reading noted behind their back takes nothing away
            // from what the app offers, least of all a name they are in the middle of typing.
            if title != nil || look != nil || asked { cannotEditBots = true }
            return .refused(title != nil || look != nil ? "This gateway doesn't keep names and faces from this app." : "This gateway doesn't keep this app's pins and marks.")
        } catch is GatewayClient.NotKept {
            guard thisLoad == loadCount else { return .done }
            // The gateway answered that it did not keep our notes, as against a bot being gone
            // or it not being reached (which is `failed` below, and changes nothing offered).
            // Asked for by the person, it is put away as for a gateway without the method.
            if title != nil || look != nil || asked { cannotEditBots = true }
            return .refused(title != nil || look != nil ? "This gateway didn't keep the name or face." : "This gateway didn't keep this app's pins and marks.")
        } catch let error as GatewayError {
            guard thisLoad == loadCount else { return .done }
            // Not reached, timed out, or refused for another reason: nothing to put away.
            return .failed("Couldn't save that. \(text(for: error))")
        } catch {
            guard thisLoad == loadCount else { return .done }
            return .failed("Couldn't save that. \(text(for: error))")
        }
        guard thisLoad == loadCount else { return .done }
        // Shown from what was saved, whether or not the roster can be read again just now.
        if let index = bots.firstIndex(where: { $0.id == id }) {
            changeCount += 1
            bots[index] = bots[index].keeping(.object(ours))
            looks[id] = bots[index].look
        }
        return .done
    }

    /// A bot's description and soul, for showing and changing. Nil when they can't be read:
    /// the card is then left out.
    func personality(of bot: Bot) async -> BotPersonality? {
        guard let client = try? await liveClient() else { return nil }
        return try? await client.personality(of: bot.name)
    }

    /// How a change to a bot's description or soul went.
    struct PersonalitySave: Equatable {
        /// The gateway has it.
        let saved: Bool
        /// What to tell the person, if anything: why it was not saved, or a word about when
        /// it takes effect.
        let said: String?
    }

    /// Changes a bot's description, its soul, or both; nil leaves one as it is. These are
    /// Hermes's own, not in our notes, but saved in the same line as them, so the latest
    /// change asked for is the one that stays. Taken in hand before this returns, so a
    /// message sent the moment after a new soul is saved waits for it (`personalitySettled`).
    func update(_ bot: Bot, description: String? = nil, soul: String? = nil) -> Task<PersonalitySave, Never> {
        guard !deleting.contains(bot.id) else { return Task { PersonalitySave(saved: false, said: "This bot is being deleted.") } }
        let thisLoad = loadCount
        let earlier = saving[bot.id]
        let id = bot.id
        let save = Task { [weak self] () -> PersonalitySave in
            _ = await earlier?.value
            return await self?.savePersonality(description: description, soul: soul, forBot: id, in: thisLoad)
                ?? PersonalitySave(saved: true, said: nil)
        }
        // The next save to this bot waits for this one, and so does its next message if
        // this changes how it talks.
        let settled = Task { await save.value.saved ? nil : save.value.said }
        saving[id] = settled
        if soul != nil {
            soulSaves += 1
            soulSaving[id] = (soulSaves, settled)
        }
        return save
    }

    /// The last soul save asked for on each bot, with the asking of its chat to take it up,
    /// and a count telling one save from the next.
    private var soulSaving: [Bot.ID: (count: Int, task: Task<String?, Never>)] = [:]
    private var soulSaves = 0

    /// Waits for every new soul being saved to a bot, so its next turn has the last.
    func personalitySettled(for bot: Bot) async {
        while let (count, task) = soulSaving[bot.id] {
            _ = await task.value
            // Another may have been asked for meanwhile.
            if soulSaving[bot.id]?.count == count { return }
        }
    }

    /// Chats this app started, by bot, by their stored id, until the roster is read with
    /// them in it. A save of a soul must not take a bot the roster knows no chat for as one
    /// with nothing to refresh: its chat may be one just started here, whose agent is warm.
    private var startedChats: [Bot.ID: String] = [:]

    /// This app started a bot's chat.
    func started(_ chat: LiveChat, for bot: Bot) {
        if let stored = chat.storedID { startedChats[bot.id] = stored }
    }

    /// The person let go of the soul that failed to save.
    func discardUnsavedSoul(for bot: Bot) { unsavedSouls[bot.id] = nil }

    /// Souls whose save failed, by bot, so a pane opened again offers them back.
    private(set) var unsavedSouls: [Bot.ID: String] = [:]

    private func savePersonality(description: String?, soul: String?, forBot id: Bot.ID, in thisLoad: Int) async -> PersonalitySave {
        // A bot that has gone, or another gateway by now: nothing to save to.
        guard thisLoad == loadCount, let bot = bots.first(where: { $0.id == id }) else { return PersonalitySave(saved: true, said: nil) }
        let client: GatewayClient
        do {
            client = try await self.client(in: thisLoad)
            try await client.savePersonality(description: description, soul: soul, forBot: bot.name)
        } catch GatewayError.unsupported {
            guard thisLoad == loadCount else { return PersonalitySave(saved: true, said: nil) }
            cannotEditBots = true
            // Nothing to offer back: it can't be saved here.
            unsavedSouls[id] = nil
            return PersonalitySave(saved: false, said: "This gateway doesn't let this app change bots.")
        } catch {
            guard thisLoad == loadCount else { return PersonalitySave(saved: true, said: nil) }
            if let soul { unsavedSouls[id] = soul }
            return PersonalitySave(saved: false, said: "Couldn't save that. \(text(for: error))")
        }
        guard thisLoad == loadCount else { return PersonalitySave(saved: true, said: nil) }
        if soul != nil { unsavedSouls[id] = nil }
        if let description, let index = bots.firstIndex(where: { $0.id == id }) {
            changeCount += 1
            bots[index] = bots[index].describing(description.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // A chat carries on with the soul it began with, so the model's cache stays warm,
        // until it is told to build its instructions afresh. A bot with no chat yet begins
        // with the new one.
        if soul != nil, let chat = bots.first(where: { $0.id == id })?.chat?.liveID ?? bot.chat?.liveID ?? startedChats[id] {
            do {
                try await client.renewInstructions(ofChat: chat, forBot: bot.name)
            } catch {
                guard thisLoad == loadCount else { return PersonalitySave(saved: true, said: nil) }
                return PersonalitySave(saved: true, said: "Saved, but the gateway couldn't refresh this chat, so the bot may keep its old personality for now.")
            }
        }
        return PersonalitySave(saved: true, said: nil)
    }

    /// How full a bot's chat is and what it has used. Only a chat open on the gateway can
    /// say, so nil until one has been sent to in this run of the app.
    func usage(of bot: Bot) async -> ChatUsage? {
        await chats[bot.id]?.usage(for: bot)
    }

    /// A bot's routines, for showing. Nil when they can't be read, which is not worth a word
    /// on screen: the section is simply left out.
    func routines(of bot: Bot) async -> [Routine]? {
        guard let client = try? await liveClient() else { return nil }
        return try? await client.routines(of: bot.name, isMain: bot.isDefault)
    }

    /// The gateway turned out not to keep what this app notes about a bot, so its name and
    /// face stop being offered for change.
    private(set) var cannotEditBots = false

    /// The slash commands this gateway offers, by name, read once per gateway. None where
    /// it has no list of them (then the message box offers no commands at all) or until read.
    private(set) var offeredCommands: Set<String> = []
    /// The list has been read, or the gateway has none: what is offered is known.
    private(set) var commandsKnown = false
    /// The gateway's Hermes is new enough to keep `/yolo` to the chat named; see
    /// `GatewayClient.keepsYoloToOneChat`. Read with the list.
    private(set) var yoloKeptToOneChat = false
    /// The one read under way, which every chat that asks waits for. The roster's, not a
    /// view's: a view going away must not cancel it for the next.
    private var commandsReading: Task<Void, Never>?

    /// Whether the gateway's Hermes keeps `/yolo` to one chat, asked afresh when what was
    /// read with the list said not: that read takes a failed look at the version for an old
    /// Hermes, and one failure must not keep `/yolo` from a current one for the connection.
    func keepsYoloToOneChat() async -> Bool {
        guard !yoloKeptToOneChat else { return true }
        let thisLoad = loadCount
        guard let client = try? await client(in: thisLoad) else { return false }
        let kept = GatewayClient.keepsYoloToOneChat(version: await client.hermesVersion())
        guard thisLoad == loadCount else { return false }
        if kept { yoloKeptToOneChat = true }
        return kept
    }

    func readCommands() async {
        guard !commandsKnown else { return }
        if let commandsReading { return await commandsReading.value }
        let thisLoad = loadCount
        let reading = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await self.client(in: thisLoad)
                var offered = try await client.offeredCommands()
                let version = await client.hermesVersion()
                // Where the session authority handles chats it refuses these through slash.exec.
                if await client.usesSessionAuthority { offered.subtract(SlashCommand.refusedBySessionAuthority) }
                guard thisLoad == self.loadCount else { return }
                self.offeredCommands = offered
                self.yoloKeptToOneChat = GatewayClient.keepsYoloToOneChat(version: version)
                self.commandsKnown = true
            } catch GatewayError.unsupported {
                if thisLoad == self.loadCount { self.commandsKnown = true }
            } catch {
                // Asked again the next time a chat opens or a command is typed.
            }
        }
        commandsReading = reading
        await reading.value
        if commandsReading == reading { commandsReading = nil }
    }

    /// Asks for the selected bot's details to be shown, and its model picker opened, as
    /// `/model` and `/reasoning` with nothing after them do.
    private(set) var detailsAsks = 0
    private(set) var modelPickAsks = 0
    func showDetails(pickingModel: Bool) {
        if pickingModel { modelPickAsks += 1 }
        detailsAsks += 1
    }

    /// The gateway turned out not to list models or not to save one on a bot, so a bot's
    /// model is shown as words and not offered for change.
    private(set) var cannotPickModel = false
    /// The gateway turned out not to read or save how hard a bot thinks.
    private(set) var cannotSetReasoning = false
    /// Saves of a bot's model and reasoning, one at a time per bot and in the order asked,
    /// so a quick second choice is never overtaken by the first.
    private var settingsSaving: [Bot.ID: Task<Void, Never>] = [:]

    /// Counts the models this app has saved on each bot, in the order saved.
    private var modelSavesMade: [Bot.ID: Int] = [:]
    func modelSaves(of bot: Bot) -> Int { modelSavesMade[bot.id] ?? 0 }

    /// The models a bot could run on, or nil when there are none to offer: the gateway
    /// does not list them (then never asked again on this gateway), could not just now,
    /// or is signed in to no provider.
    func modelOptions(for bot: Bot) async -> ModelOptions? {
        await modelsRead(for: bot)?.options
    }

    /// The models a bot could run on, with how many of its model saves had been made when
    /// they were asked for: the model the list names as the bot's is the newest word on it
    /// until this app saves another (`modelSaves(of:)` moves on).
    func modelsRead(for bot: Bot) async -> (options: ModelOptions, savesBefore: Int)? {
        guard !cannotPickModel else { return nil }
        let thisLoad = loadCount
        // After any change still being saved, so a pane opened meanwhile shows what it made.
        _ = await settingsSaving[bot.id]?.value
        let savesBefore = modelSaves(of: bot)
        do {
            let options = try await client(in: thisLoad).modelOptions(forBot: bot.name)
            return options.providers.isEmpty ? nil : (options, savesBefore)
        } catch GatewayError.unsupported {
            if thisLoad == loadCount { cannotPickModel = true }
            return nil
        } catch {
            return nil
        }
    }

    /// How hard a bot thinks, as saved on it. Nil when that can't be read.
    func reasoning(of bot: Bot) async -> ReasoningLevel? {
        guard !cannotSetReasoning else { return nil }
        let thisLoad = loadCount
        _ = await settingsSaving[bot.id]?.value
        do {
            return try await client(in: thisLoad).reasoning(ofBot: bot.name)
        } catch GatewayError.unsupported {
            if thisLoad == loadCount { cannotSetReasoning = true }
            return nil
        } catch {
            return nil
        }
    }

    enum ModelSaving: Equatable {
        case saved
        /// Hermes wants the person to agree first, in these words. Nothing was saved.
        case needsConfirming(String)
        case failed(String)
    }

    /// Saves the model a bot runs on, on the bot. `confirmed` once the person has agreed
    /// to what Hermes asked.
    func setModel(_ choice: ModelChoice, for bot: Bot, confirmed: Bool = false) async -> ModelSaving {
        guard !deleting.contains(bot.id) else { return .failed("This bot is being deleted.") }
        let thisLoad = loadCount
        let name = bot.name
        let outcome: ModelSaving = await oneAtATime(for: bot.id) { [weak self] in
            guard let self else { return .failed("") }
            do {
                let client = try await self.client(in: thisLoad)
                switch try await client.setModel(choice, forBot: name, confirmed: confirmed) {
                case .saved:
                    // Shown from what was saved, in the order saved, whether or not the roster
                    // can be read again just now.
                    if thisLoad == self.loadCount, let index = self.bots.firstIndex(where: { $0.id == name }) {
                        self.changeCount += 1
                        self.bots[index] = self.bots[index].running(choice.model, on: choice.provider)
                        self.modelSavesMade[name, default: 0] += 1
                    }
                    return .saved
                case .needsConfirming(let said): return .needsConfirming(said)
                }
            } catch GatewayError.unsupported {
                if thisLoad == self.loadCount { self.cannotPickModel = true }
                return .failed("This gateway doesn't let this app change a bot's model.")
            } catch GatewayError.rejected(code: 0, message: GatewayClient.modelNotSaved) {
                return .failed(GatewayClient.modelNotSaved)
            } catch {
                return .failed("Couldn't save that. \(self.text(for: error))")
            }
        }
        // Shown from the gateway, which now holds it.
        if outcome == .saved, thisLoad == loadCount { await refreshBots() }
        return outcome
    }

    /// Saves how hard a bot thinks, on the bot. Returns what went wrong, or nil.
    func setReasoning(_ level: ReasoningLevel, for bot: Bot) async -> String? {
        guard !deleting.contains(bot.id) else { return "This bot is being deleted." }
        let thisLoad = loadCount
        let name = bot.name
        return await oneAtATime(for: bot.id) { [weak self] in
            guard let self else { return nil }
            do {
                try await self.client(in: thisLoad).setReasoning(level, forBot: name)
                if thisLoad == self.loadCount { self.reasoningSaved[name] = level }
                return nil
            } catch GatewayError.unsupported {
                if thisLoad == self.loadCount { self.cannotSetReasoning = true }
                return "This gateway doesn't let this app change how hard a bot thinks."
            } catch GatewayError.rejected(code: 4030, _) {
                // Hermes's own words name a settings key and file, which are not for here.
                return "An administrator has fixed how hard this bot thinks, so it can't be changed here."
            } catch {
                return "Couldn't save that. \(self.text(for: error))"
            }
        }
    }

    /// The reasoning this app last saved on each bot, for a pane already open to follow a
    /// change made from the message box.
    private(set) var reasoningSaved: [Bot.ID: ReasoningLevel] = [:]

    /// Runs `work` once every earlier save of this bot's model or reasoning has ended.
    private func oneAtATime<T: Sendable>(for id: Bot.ID, _ work: @escaping @MainActor () async -> T) async -> T {
        let earlier = settingsSaving[id]
        let task = Task { @MainActor in
            _ = await earlier?.value
            return await work()
        }
        settingsSaving[id] = Task { _ = await task.value }
        return await task.value
    }

    /// Bots being deleted, so one is not asked for twice.
    private(set) var deleting: Set<Bot.ID> = []
    /// The gateway turned out not to offer deleting bots, so the app stops offering it.
    private(set) var cannotDeleteBots = false

    /// Deletes a bot for good, with its chat. The main bot can't be deleted. Returns what
    /// went wrong, or nil.
    func delete(_ bot: Bot) async -> String? {
        guard !bot.isDefault else { return "The main bot can't be deleted." }
        guard !deleting.contains(bot.id) else { return nil }
        let thisLoad = loadCount
        deleting.insert(bot.id)
        waitingChanged()
        // Nothing more is noted on a bot on its way out.
        readSaves[bot.id]?.cancel()
        readSaves[bot.id] = nil
        // Only this gateway's: by then the app may be on another, with a bot of the same name.
        defer {
            if thisLoad == loadCount {
                deleting.remove(bot.id)
                waitingChanged()
            }
        }
        do {
            // After any change to it still being saved, so that cannot land on a bot of the
            // same name made later. Nothing new is taken for it from here on; see `update`.
            _ = await saving[bot.id]?.value
            _ = await settingsSaving[bot.id]?.value
            let client = try await client(in: thisLoad)
            try await client.deleteBot(id: bot.name)
        } catch {
            guard thisLoad == loadCount else { return nil }
            // No clear answer does not mean it was not done: see whether the bot is still there.
            let unclear: Bool
            switch error {
            // A refusal too: a gateway can take the bot away and still report trouble
            // clearing up after it, as one did when files of the bot's were still open.
            case GatewayError.timedOut, GatewayError.connectionLost, GatewayError.rejected: unclear = true
            default: unclear = false
            }
            if unclear {
                approvalsStateChanged(because: "The bots on the gateway changed since this was read.")
                let read = await refreshBots()
                guard thisLoad == loadCount else { return nil }
                if read, !bots.contains(where: { $0.id == bot.id }) {
                    forget(bot)
                    return nil
                }
                if case GatewayError.rejected(let code, let message) = error, code != 5016 {
                    let said = Self.gist(of: message)
                    if read { return said.isEmpty ? "The gateway didn't delete the bot." : "The gateway didn't delete the bot: \(said)" }
                    return "The gateway reported a problem deleting the bot, and then couldn't be reached to see whether it is gone."
                }
                return read
                    ? "The gateway didn't finish deleting the bot. It is still there."
                    : "The gateway didn't answer, so the bot may or may not be deleted. Check again when it is back in reach."
            }
            switch error {
            case GatewayError.unsupported:
                // Not a failure: Delete is no longer offered, and the person who has just
                // confirmed one is told why nothing happened, as when making a bot.
                cannotDeleteBots = true
                return "Delete isn't offered from here on. The bot can still be deleted from Hermes itself."
            default:
                return "Couldn't delete the bot. \(text(for: error))"
            }
        }
        guard thisLoad == loadCount else { return nil }
        forget(bot)
        await refreshBots()
        guard thisLoad == loadCount else { return nil }
        if selected == nil { selectedID = mainBot?.id ?? bots.first?.id }
        return nil
    }

    /// The point of what a command said when it failed: its line marked as the error, or
    /// failing that its last line, and not the screenful that came before.
    static func gist(of output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let line = lines.last { $0.hasPrefix("Error:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) } ?? lines.last ?? ""
        return line.count > 240 ? String(line.prefix(240)) + "…" : line
    }

    /// Takes a deleted bot off the roster at once, without waiting to read it again.
    /// Nothing the bot had begun goes on.
    private func forget(_ bot: Bot) {
        // A bot made later under the same name is not shown this one's files, nor handed
        // one that was still being fetched for it.
        files.removeAllObjects()
        filesEpoch += 1
        chats[bot.id]?.questions.onChange = nil
        chats[bot.id]?.abandon()
        chats[bot.id] = nil
        openingInBackground[bot.id] = nil
        // What was kept for its connection cards, which being shown as waiting kept from expiring.
        connectionMemory.forget(owner: bot.id)
        saving[bot.id] = nil
        settingsSaving[bot.id] = nil
        // A bot made again under the same name is another bot.
        soulSaving[bot.id] = nil
        startedChats[bot.id] = nil
        unsavedSouls[bot.id] = nil
        readSaves[bot.id]?.cancel()
        readSaves[bot.id] = nil
        readThrough[bot.id] = nil
        shownThrough[bot.id] = nil
        pinning[bot.id] = nil
        marking[bot.id] = nil
        readAsked[bot.id] = nil
        turnedTo[bot.id] = nil
        unclearable[bot.id] = nil
        previews[bot.id] = nil
        unread.remove(bot.id)
        changeCount += 1
        bots.removeAll { $0.id == bot.id }
        approvalsStateChanged(because: "The bots on the gateway changed since this was read.")
        looks[bot.id] = nil
        waitingChanged()
        if selectedID == bot.id || selected == nil { selectedID = mainBot?.id ?? bots.first?.id }
    }

    /// Forgets the saved gateway and goes back to setting one up. The app stops using the
    /// gateway even if the Keychain will not give the token up, and then says so.
    func signOut() async {
        let old = forgetConnection()
        phase = .needsSetup
        findSavedConnections()
        let clearing = Task { () -> Bool in
            (try? await keeper.clear()) != nil
        }
        // Setup waits for this before it saves; see `setUp`.
        self.clearing = Task { _ = await clearing.value }
        let cleared = await clearing.value
        // Said only while setup is still what is on screen: a gateway connected since then
        // has its own token, safely saved after this finished.
        if phase == .needsSetup {
            setupNotice = cleared ? nil
                : "Disconnected, but the token could not be removed from the Keychain. Remove “HermesBot gateway token” in Keychain Access."
        }
        await old?.disconnect()
    }

    /// Drops everything belonging to the current gateway, at once, before anything is
    /// awaited: nothing begun for it may go on to reach the next one. Returns the old
    /// connection for the caller to close.
    private func forgetConnection() -> GatewayClient? {
        loadCount += 1
        for chat in chats.values { chat.abandon() }
        let old = client
        client = nil
        // The helper for Hermes on this Mac goes with the connection it served, and so
        // does that of any connection still being made: with no helper it gets no pass.
        signIn = nil
        signInNotSaved = false
        let helpers = pendingLocals + (local.map { [$0] } ?? [])
        local = nil
        pendingLocals = []
        if !helpers.isEmpty { Task { for helper in helpers { await helper.stop() } } }
        bots = []
        looks = [:]
        previews = [:]
        for chat in chats.values {
            chat.questions.onChange = nil
            chat.questions.forget()
        }
        chats = [:]
        liveSessions = [:]
        unclaimed = [:]
        openingInBackground = [:]
        lookingTask = nil
        unclaimedGeneration = 0
        unclaimedRefreshedThrough = 0
        refreshing = nil
        refreshWantedIn = nil
        pendingNotificationBotID = nil
        seenQuestions = []
        seenQuestionSet = []
        alerts.clearAll()
        approvals = .unknown
        approvalsProblem = nil
        approvalsOffered = false
        approvalsClient = nil
        approvalsBots = nil
        approvalsChangeNote = nil
        approvalsInterruption = nil
        approvalsLastEvery = nil
        approvalsListings = []
        approvalsListingsLost = [:]
        approvalsThrough = nil
        // Nothing asked of the gateway left says anything now. A change still under way stops
        // at its next step and lets go of its hold as it unwinds.
        approvalsAsked += 1
        approvalsEpoch += 1
        connectionUpdates = [:]
        connectionMemory.clear()
        turnsEndedUnclaimed = [:]
        heldForRecheck = [:]
        // A look asked for on the gateway being left is not for the next one.
        lookAgain = nil
        endedLately = []
        selectedID = nil
        // The bots viewed were another gateway's.
        history = BotHistory()
        gatewayAddress = nil
        files.removeAllObjects()
        keptFiles = [:]
        filesEpoch += 1
        // A name belonged to the gateway being left.
        gatewayNickname = nil
        // What one gateway can't do says nothing about the next.
        cannotMakeBots = false
        cannotListChatsAtWork = false
        cannotDeleteBots = false
        cannotEditBots = false
        cannotPickModel = false
        cannotSetReasoning = false
        offeredCommands = []
        commandsKnown = false
        commandsReading = nil
        yoloKeptToOneChat = false
        reasoningSaved = [:]
        settingsSaving = [:]
        watching?.cancel()
        watching = nil
        watchedClient = nil
        isWatchedClientAlive = false
        for save in readSaves.values { save.cancel() }
        readSaves = [:]
        readThrough = [:]
        pinning = [:]
        marking = [:]
        readAsked = [:]
        turnedTo = [:]
        unclearable = [:]
        unread = []
        cannotKeepRead = false
        watchWait = 3
        tokenRefused = false
        shownThrough = [:]
        connecting = nil
        saving = [:]
        // Bots are known by name only within a gateway: another gateway's are other bots.
        soulSaving = [:]
        unsavedSouls = [:]
        startedChats = [:]
        deleting = []
        return old
    }
}

/// What went wrong, in words for the person using the app.
enum GatewayProblem {
    struct NotSetUp: Error {}
    struct BadAddress: Error {}
    static let signInEnded = "Your sign-in to this gateway has ended. Disconnect in Settings and sign in again."
    static let thisMacRefused = "Hermes on this Mac didn't let the app in. Update Hermes and try again."
    /// Hermes on this Mac was connected to, and is not running now.
    struct ThisMacNotRunning: Error {}
    /// The address is reached over plain http and now leads out onto the internet.
    struct NoLongerPrivate: Error {}
    struct TokenUnreadable: Error {}

    static func text(for error: any Error) -> String {
        switch error {
        case is NotSetUp: "No gateway is set up."
        case is NoLongerPrivate: "This server's address leads out onto the internet from this network, and it isn't encrypted, so the token wasn't sent. Connect from your own network, or set it up again with https:// (or http:// to allow it)."
        case is ThisMacNotRunning: "Hermes isn't running on this Mac. Start it and try again."
        case is BadAddress: "That doesn't look like a gateway address. It should be like nas.local:9119."
        case is TokenUnreadable: "The token for this gateway couldn't be read from the Keychain. Disconnect in Settings and connect again."
        case GatewayError.unauthorized(gatewayUsesSignIn: true):
            "The gateway refused the token. It may want you to sign in with a username and password: disconnect in Settings and connect again."
        case GatewayError.unauthorized: "The gateway refused the token."
        case GatewayError.unsupported(method: "sessions.messages"): "This gateway doesn't offer chat history."
        case GatewayError.unsupported: "This gateway doesn't offer bots."
        // Said as the client put it: nothing was sent, or this one request was refused.
        case GatewayError.rejected(code: 0, message: GatewayClient.notPrivate): GatewayClient.notPrivate
        case GatewayError.rejected(code: 403, message: "The gateway turned the request away."): "The gateway turned the request away."
        case GatewayError.rejected, GatewayError.unexpectedReply:
            "The gateway answered in a way this app doesn't understand."
        default: "Couldn't reach the gateway."
        }
    }
}

/// Every change to the saved gateway is made here, one at a time, each counted. A renewed
/// sign-in is saved only if nothing else has been saved or cleared since its session came
/// into use, and that is checked here, where the saving is done: checked anywhere else, a
/// disconnect could slip in between the check and the write.
actor SavedGatewayKeeper {
    private let store: GatewayStore
    private var generation = 0

    init(store: GatewayStore) {
        self.store = store
    }

    /// What is saved, whether plain http was chosen for it, and the count of changes, all
    /// as they stand at one moment.
    func read() -> (GatewayStore.Saved, plainHTTPChosen: Bool, generation: Int) {
        (store.read(), store.plainHTTPChosen, generation)
    }

    func save(_ gateway: SavedGateway, plainHTTPChosen: Bool) throws -> Int {
        try store.save(gateway, plainHTTPChosen: plainHTTPChosen)
        generation += 1
        return generation
    }

    func save(_ signIn: SavedSignIn, plainHTTPChosen: Bool) throws -> Int {
        try store.save(signIn, plainHTTPChosen: plainHTTPChosen)
        generation += 1
        return generation
    }

    /// Saves a renewal of the sign-in saved at `generation`. Returns false, having saved
    /// nothing, when what is saved has changed since.
    @discardableResult
    func keep(_ signIn: SavedSignIn, for generation: Int) throws -> Bool {
        guard generation == self.generation else { return false }
        try store.save(signIn, plainHTTPChosen: store.plainHTTPChosen)
        return true
    }

    func saveThisMac() throws {
        try store.saveThisMac()
        generation += 1
    }

    func forgetThisMac() {
        store.forgetThisMac()
        generation += 1
    }

    func clear() throws {
        // Counted first: even if the Keychain refuses, the gateway has been left.
        generation += 1
        try store.clear()
    }
}

extension Bot {
    /// The face saved for this bot by this app, or a stable one made from its name.
    var look: AvatarLook {
        if let saved = try? uiMeta["hermes-bot"]?["avatar"]?.decode(AvatarLook.self) { return saved }
        return isDefault ? .main : AvatarLook(seed: name)
    }

    /// Pinned to the top of the roster, by this app on any device.
    var isPinned: Bool {
        if case .bool(true)? = uiMeta["hermes-bot"]?["pinned"] { return true }
        return false
    }

    /// When the person marked this bot unread, by this app on any device; until looked at.
    var markedUnread: Date? {
        uiMeta["hermes-bot"]?["unread"]?.numberValue.map(Date.init(timeIntervalSince1970:))
    }

    /// How far this bot's chat has been read, as this app last noted on the gateway.
    var readThrough: Date? {
        uiMeta["hermes-bot"]?["read"]?.numberValue.map(Date.init(timeIntervalSince1970:))
    }
}
