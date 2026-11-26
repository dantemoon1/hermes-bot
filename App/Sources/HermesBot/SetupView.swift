import HermesBotUI
import HermesKit
import SwiftUI

/// The first thing a new person sees. It offers what Hermes's own app on this Mac already
/// connects to; failing that it asks where Hermes is, and then asks that server what it
/// takes, so the person is only ever asked for what is needed.
struct SetupView: View {
    let roster: RosterModel
    @State private var step = Step.address
    /// The person has moved between the saved servers and the address themselves, so the
    /// screen no longer moves them when what was found on this Mac changes.
    @State private var hasChosenStep = false
    @State private var chosen: RosterModel.SetupOffer.ID?
    /// The person picked a row themselves, so a likelier one turning up later (Hermes on
    /// this Mac takes a moment to answer) does not take the choice from them.
    @State private var hasChosenRow = false
    @State private var address = ""
    @State private var token = ""
    @State private var notice: Notice?
    @State private var isBusy = false
    @State private var username = ""
    @State private var password = ""
    /// The window came forward while a connection was being tried; the saved servers are
    /// read again once it ends.
    @State private var refreshWhenDone = false
    @State private var tokenHelp = TokenHelp.docker
    @State private var copied = 0
    @State private var showsCopied = false
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var scheme

    private enum Field { case list, address, token, username, password }

    private enum Step: Equatable {
        /// Servers found on this Mac, to pick from.
        case saved
        case address
        /// The server was found and takes a username and password.
        case password(GatewayProbe.Found)
        /// The server was found and takes a token.
        case token(GatewayProbe.Found)
        /// The server was found and signs in only in ways this app does not have yet.
        case unsupported(GatewayProbe.Found)
    }

    /// What went wrong, and for a server that did not answer, what to check.
    private struct Notice: Equatable {
        var text: String
        var checks: [String] = []
    }

    /// Where the command that prints the token is run.
    private enum TokenHelp: String, CaseIterable {
        case docker = "Docker"
        case installed = "Mac or Linux"

        var command: String {
            switch self {
            case .docker: "docker exec hermes printenv HERMES_DASHBOARD_SESSION_TOKEN"
            case .installed: "grep HERMES_DASHBOARD_SESSION_TOKEN ~/.hermes/.env"
            }
        }

        var note: String {
            switch self {
            case .docker:
                "Run it in a terminal on the server itself, not inside the container. If your container isn't called hermes, use its name."
            case .installed:
                "The token is what follows the equals sign."
            }
        }
    }

    var body: some View {
        let theme = Theme(scheme)
        VStack(spacing: 0) {
            BotAvatar(.main, size: 64, isWorking: isBusy)
                .avatarsFollowPointer()
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.top, 18)
            subtitle(theme)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 6)

            Group {
                switch step {
                case .saved: savedList(theme)
                case .address: addressCard(theme)
                case .password: passwordCard(theme)
                case .token(let found): tokenCard(found, theme)
                case .unsupported(let found): unsupportedCard(found, theme)
                }
            }
            .padding(.top, 24)

            Button(action: act) { Text(buttonTitle) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canAct)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 20)

            if let other = otherWay {
                Button(other.title, action: other.go)
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, 14)
                    .disabled(isBusy)
            }

            // Always there, so nothing jumps when something goes wrong. Grey like the rest:
            // colour is the bots' alone.
            VStack(alignment: .leading, spacing: 4) {
                if let notice {
                    Label(notice.text, systemImage: "exclamationmark.circle")
                        .labelStyle(.titleAndIcon)
                    ForEach(notice.checks, id: \.self) { check in
                        // A hanging indent: a check that wraps stays clear of its bullet.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(check)
                        }
                        .padding(.leading, 20)
                    }
                } else if let left = roster.setupNotice {
                    Text(left)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
        }
        .frame(width: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        .onAppear(perform: settle)
        .onChange(of: roster.setupOffers) { settle() }
        // Hermes's own app may have been set right while this was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isBusy { refreshWhenDone = true } else { roster.findSavedConnections() }
        }
        // Hermes on this Mac may be started, or stopped, while this is open and in front.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled, !isBusy, roster.phase == .needsSetup { roster.findSavedConnections() }
            }
        }
        // Escape goes back a step.
        .onExitCommand {
            guard !isBusy else { return }
            switch step {
            case .password, .token, .unsupported: go(to: .address)
            case .address: if !roster.setupOffers.isEmpty { leave(to: .saved) }
            case .saved: break
            }
        }
        .task(id: copied) {
            guard copied > 0 else { return }
            showsCopied = true
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { showsCopied = false }
        }
    }

    // MARK: What each step says

    private var title: String {
        switch step {
        case .saved, .address: "Connect to Hermes"
        case .password, .token, .unsupported: "Sign in to Hermes"
        }
    }

    @ViewBuilder
    private func subtitle(_ theme: Theme) -> some View {
        switch step {
        case .saved: Text("Choose a Hermes found on this Mac.")
        case .address: Text("Enter the address of your Hermes server.")
        case .password(let found), .token(let found), .unsupported(let found):
            HStack(spacing: 6) {
                // In full, with how it is reached and any path: this is where the token goes.
                Text(found.endpoint.baseURL.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change") { go(to: .address) }
                    .buttonStyle(.plain)
                    .underline()
                    .disabled(isBusy)
            }
        }
    }

    private var buttonTitle: String {
        switch step {
        case .saved, .token: isBusy ? "Connecting…" : "Connect"
        case .password: isBusy ? "Signing In…" : "Sign In"
        case .address: isBusy ? "Checking…" : "Continue"
        case .unsupported: "Use Another Address"
        }
    }

    private var canAct: Bool {
        guard !isBusy else { return false }
        switch step {
        case .saved: return roster.setupOffers.contains { $0.id == chosen }
        case .address: return !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .token: return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .password: return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        case .unsupported: return true
        }
    }

    /// The quiet way to the other step: typing an address when servers were found, and back.
    private var otherWay: (title: String, go: () -> Void)? {
        switch step {
        case .saved: ("Connect to another server…", { leave(to: .address) })
        case .address: roster.setupOffers.isEmpty ? nil : ("Back to the list", { leave(to: .saved) })
        // A server that takes either: the other is one click away.
        case .password(let found): found.takesToken == true ? ("Use an access token instead", { go(to: .token(found)) }) : nil
        case .token(let found): found.passwordProvider != nil ? ("Use a username and password instead", { go(to: .password(found)) }) : nil
        case .unsupported: nil
        }
    }

    // MARK: The steps

    private func savedList(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            ForEach(roster.setupOffers) { saved in
                Button {
                    // By keyboard or VoiceOver as well as by pointer.
                    if !isBusy {
                        chosen = saved.id
                        hasChosenRow = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(saved.label)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.text)
                            Text(saved.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                        if chosen == saved.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.text)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 50)
                    .background(theme.chosen.opacity(chosen == saved.id ? 1 : 0), in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen == saved.id ? .isSelected : [])
            }
        }
        .padding(4)
        .background(theme.bubble, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.bubbleEdge))
        // The arrow keys move the choice, and Return connects.
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .list)
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        // Not while connecting: the choice being acted on stays the one shown.
        .allowsHitTesting(!isBusy)
    }

    private func addressCard(_ theme: Theme) -> some View {
        VStack(spacing: 0) {
            card(theme) {
                field("Address", theme) {
                    TextField("nas.local or 192.168.1.20", text: $address)
                        .focused($focus, equals: .address)
                        .onSubmit(act)
                        // What is being checked stays what is shown.
                        .disabled(isBusy)
                }
            }
            Text("The same address you open Hermes's dashboard at in a browser.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 10)
        }
    }

    private func passwordCard(_ theme: Theme) -> some View {
        VStack(spacing: 10) {
            card(theme) {
                VStack(spacing: 0) {
                    field("Username", theme) {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .focused($focus, equals: .username)
                            .onSubmit { focus = .password }
                            .disabled(isBusy)
                    }
                    Rectangle().fill(theme.hairline).frame(height: 1)
                    field("Password", theme) {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .onSubmit(act)
                            .disabled(isBusy)
                    }
                }
            }
            Text("The ones you use for Hermes's dashboard. Your password is sent to this server once and isn't kept.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tokenCard(_ found: GatewayProbe.Found, _ theme: Theme) -> some View {
        VStack(spacing: 10) {
            card(theme) {
                field("Token", theme) {
                    SecureField("Paste access token", text: $token)
                        .focused($focus, equals: .token)
                        .onSubmit(act)
                        .disabled(isBusy)
                }
            }
            // Where to find it, with a command to copy: nobody should have to know what a
            // session token is to get past this.
            VStack(alignment: .leading, spacing: 8) {
                Text("Run this where Hermes is installed, then paste the token above.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    ForEach(TokenHelp.allCases, id: \.self) { help in
                        Button(help.rawValue) { tokenHelp = help }
                            .buttonStyle(.plain)
                            .foregroundStyle(tokenHelp == help ? theme.text : theme.secondaryText)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(theme.raised.opacity(tokenHelp == help ? 1 : 0), in: RoundedRectangle(cornerRadius: 6))
                            // An edge, so the chosen one shows on a light canvas too.
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.hairline.opacity(tokenHelp == help ? 1 : 0)))
                            .accessibilityAddTraits(tokenHelp == help ? .isSelected : [])
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(tokenHelp.command)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(showsCopied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tokenHelp.command, forType: .string)
                        copied += 1
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(theme.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.hairline))
                }
                .padding(9)
                .background(theme.codeBlock, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.bubbleEdge))
                Text(tokenHelp.note + " If it prints nothing, the token isn't kept that way on this server: ask whoever set it up.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 4)
        }
    }

    private func unsupportedCard(_ found: GatewayProbe.Found, _ theme: Theme) -> some View {
        let ways = found.signInWays.isEmpty ? "a way Hermes Bot doesn't have yet" : found.signInWays.formatted(.list(type: .or))
        return Text("This server signs in with \(ways), and not with a token. Hermes Bot can't sign in that way yet.")
            .font(.system(size: 13))
            .foregroundStyle(theme.text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.bubbleEdge))
    }

    private func card(_ theme: Theme, @ViewBuilder content: () -> some View) -> some View {
        content()
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.bubbleEdge))
    }

    private func field(_ label: String, _ theme: Theme, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(theme.text)
                .frame(width: 72, alignment: .leading)
            content()
                .textFieldStyle(.plain)
                .foregroundStyle(theme.text)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    // MARK: What it does

    /// Keeps the screen in step with what was found on this Mac: it opens on the saved
    /// servers when there are any, keeps a choice that is still there, and leaves the list
    /// when it empties. Once the person has moved between the two themselves, they stay put.
    private func settle() {
        guard !isBusy else { return }
        let saved = roster.setupOffers
        if !hasChosenRow || !saved.contains(where: { $0.id == chosen }) { chosen = saved.first?.id }
        switch step {
        case .saved: if saved.isEmpty { go(to: .address) }
        case .address: if !saved.isEmpty, !hasChosenStep, address.isEmpty { go(to: .saved) } else if focus == nil { focus = .address }
        case .password, .token, .unsupported: break
        }
    }

    /// A move the person asked for, between the saved servers and the address.
    private func leave(to next: Step) {
        hasChosenStep = true
        go(to: next)
    }

    private func go(to next: Step) {
        // A password is never left behind in a step that is no longer showing.
        if case .password = step, !isSameServer(step, next) || !isPassword(next) { password = "" }
        // Nor a token; and a username belongs to the server it was typed for.
        if case .token = step { token = "" }
        if !isSameServer(step, next), isSameServer(step, step) { username = "" }
        step = next
        notice = nil
        switch next {
        case .saved: focus = .list
        case .address: focus = .address
        case .token: focus = .token
        case .password: focus = username.isEmpty ? .username : .password
        case .unsupported: focus = nil
        }
    }

    private func isPassword(_ step: Step) -> Bool {
        if case .password = step { return true }
        return false
    }

    private func isSameServer(_ one: Step, _ other: Step) -> Bool {
        func server(_ step: Step) -> GatewayEndpoint? {
            switch step {
            case .password(let found), .token(let found), .unsupported(let found): found.endpoint
            case .saved, .address: nil
            }
        }
        return server(one) != nil && server(one) == server(other)
    }

    /// Puts the caret back in the address, after what was typed and not over it, so that
    /// adding a port is a matter of typing it.
    private func returnToAddress() {
        focus = .address
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        let saved = roster.setupOffers
        guard !isBusy, let at = saved.firstIndex(where: { $0.id == chosen }) else {
            if !isBusy { chosen = saved.first?.id }
            return .handled
        }
        chosen = saved[(at + by + saved.count) % saved.count].id
        hasChosenRow = true
        return .handled
    }

    private func act() {
        guard canAct else { return }
        if case .unsupported = step {
            go(to: .address)
            return
        }
        isBusy = true
        notice = nil
        Task {
            defer {
                isBusy = false
                // What is on offer may have changed while this was busy (Hermes on this
                // Mac turned out not to be running): the screen catches up, and what
                // went wrong is still said.
                let said = notice
                settle()
                if notice == nil { notice = said }
                // A look that was asked for while this was busy happens now.
                if refreshWhenDone, roster.phase == .needsSetup {
                    refreshWhenDone = false
                    roster.findSavedConnections()
                }
            }
            switch step {
            case .saved:
                guard let offer = roster.setupOffers.first(where: { $0.id == chosen }) else { return }
                guard case .saved(let saved) = offer.kind else {
                    if let failure = await roster.connectToThisMac() { notice = Notice(text: failure.text) }
                    return
                }
                guard let failure = await roster.connect(address: saved.address, token: saved.token, plainHTTPChosen: true) else { return }
                // The token Hermes's app holds is out of date. The address still stands,
                // so a new token is asked for at exactly that address.
                // No other port or scheme is tried: a server answering somewhere else is not
                // the one Hermes's app was connected to.
                if failure.tokenRefused, let endpoint = GatewayEndpoint(saved.address),
                   case .found(let found) = await GatewayProbe.look(atExactly: endpoint),
                   found.endpoint == endpoint, found.takesToken != false || found.passwordProvider != nil {
                    address = saved.address
                    token = ""
                    // Whichever the server takes now: it may have stopped taking tokens.
                    if found.passwordProvider != nil {
                        go(to: .password(found))
                        notice = Notice(text: "The token saved in Hermes for \(saved.label) no longer works. Sign in to reconnect.")
                    } else {
                        go(to: .token(found))
                        notice = Notice(text: "The token saved in Hermes for \(saved.label) no longer works. Paste its new one to reconnect.")
                    }
                } else {
                    notice = Notice(text: "Couldn't connect to \(saved.label). \(failure.text)")
                }
            case .address:
                await look(at: address)
            case .password(let found):
                if let failure = await roster.signIn(to: found, username: username, password: password) {
                    notice = Notice(text: failure.text)
                    // Typed again, not corrected: what was there is not shown to be fixed.
                    if failure.tokenRefused {
                        password = ""
                        // Once the field is enabled again, which it is not until this ends.
                        Task {
                            try? await Task.sleep(for: .milliseconds(60))
                            if case .password = step { focus = .password }
                        }
                    }
                } else {
                    password = ""
                }
            case .token(let found):
                if let failure = await roster.connect(address: found.endpoint.baseURL.absoluteString, token: token, plainHTTPChosen: found.plainHTTPChosen) {
                    notice = Notice(text: failure.tokenRefused ? "That token wasn't accepted. Check it and try again." : failure.text)
                }
            case .unsupported:
                break
            }
        }
    }

    /// Asks the address what is there, and goes on to whatever that server needs.
    private func look(at typed: String) async {
        let probe = await GatewayProbe.look(at: typed)
        if case .found = probe {} else { returnToAddress() }
        switch probe {
        case .badAddress:
            notice = Notice(text: "That doesn't look like a server address. Try something like nas.local or 192.168.1.20.")
        case .unreachable(let tried):
            let namedPort = GatewayEndpoint(typed)?.baseURL.port != nil
            let namedScheme = GatewayProbe.namesScheme(typed)
            var checks = [
                "Is Hermes running on that computer?",
                "Is this Mac on the same network or Tailscale?",
                namedPort ? "Is the port right? Hermes's usual one is \(GatewayProbe.usualPort)."
                    : "Does Hermes use a port other than \(GatewayProbe.usualPort)? Add it, like nas.local:8080.",
            ]
            // A server out on the internet is only asked over https unless told otherwise.
            if !namedScheme, tried.allSatisfy({ $0.baseURL.scheme == "https" }) {
                checks.append("If it isn't served over https, type http:// in front.")
            }
            notice = Notice(text: "Nothing answered at \(tried.map(\.label).formatted(.list(type: .or))).", checks: checks)
        case .notHermes(let endpoint, let tried):
            let host = endpoint.baseURL.host() ?? endpoint.label
            let triedUsual = tried.contains { $0.baseURL.port == GatewayProbe.usualPort }
            notice = Notice(text: triedUsual
                ? "Something answered at \(endpoint.label), but it isn't Hermes. Check the address, and the port if Hermes uses its own."
                : "Something answered at \(endpoint.label), but it isn't Hermes. Try Hermes's port, like \(host):\(GatewayProbe.usualPort).")
        case .found(let found):
            token = ""
            password = ""
            // A username and password where the server takes them, as its own dashboard
            // asks; otherwise a token. A server that says tokens are not one of its ways
            // in is not asked for one.
            if found.passwordProvider != nil {
                go(to: .password(found))
            } else {
                go(to: found.takesToken == false ? .unsupported(found) : .token(found))
            }
        }
    }
}

/// The one filled button on a screen. Its disabled look is its own, since the system's
/// dims the label past reading in dark.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = Theme(scheme)
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isEnabled ? theme.canvas : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(isEnabled ? theme.text : theme.surface, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
