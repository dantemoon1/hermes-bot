import HermesBotUI
import HermesKit
import SwiftUI

/// How the app looks: the system's way, or always light or dark.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Settings, shown over the window.
struct SettingsView: View {
    let roster: RosterModel
    private let updates = Updates.shared
    let close: () -> Void
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingNeverAsk = false
    @State private var isNaming = false
    @State private var name = ""
    @FocusState private var isNamingFocused: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                WhenHovered { isHovered in
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(theme.hover.opacity(isHovered ? 1 : 0), in: Circle())
                            .contentShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }

            section("Gateway", theme)
            card(theme) {
                HStack(spacing: 12) {
                    GatewayBadge(isOnCard: true)
                    VStack(alignment: .leading, spacing: 2) {
                        if isNaming {
                            TextField(roster.gatewayAddress ?? "Name", text: $name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .foregroundStyle(theme.text)
                                .focused($isNamingFocused)
                                .onSubmit(finishNaming)
                                // Escape leaves the name as it was, and Settings open.
                                .onExitCommand { isNaming = false }
                                .accessibilityLabel("Gateway name")
                        } else {
                            HStack(spacing: 6) {
                                Text(roster.gatewayName ?? "Not connected")
                                    .font(.system(size: 14))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if roster.gatewayAddress != nil, !roster.gatewayIsFixed {
                                    // A name of the person's own in place of a long address.
                                    WhenHovered { isHovered in
                                        Button {
                                            name = roster.gatewayNickname ?? ""
                                            isNaming = true
                                            isNamingFocused = true
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                                                .frame(width: 20, height: 20)
                                                .background(theme.hover.opacity(isHovered ? 1 : 0), in: Circle())
                                                .contentShape(Circle())
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help("Rename")
                                    .accessibilityLabel("Rename gateway")
                                }
                            }
                        }
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer()
                    if !roster.gatewayIsFixed {
                        pill("Disconnect", theme) { isConfirmingSignOut = true }
                    }
                }
                .padding(14)
            }

            // Only where the gateway scopes settings per bot and knows approvals.mode.
            if roster.approvals != .unknown, roster.approvals != .unavailable {
                section("Permissions", theme)
                card(theme) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Approvals")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.text)
                            Text(roster.approvalsProblem ?? approvalsNote)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            if roster.approvals == .unconfirmed {
                                pill("Try Again", theme) { Task { await roster.tryApprovalsAgain() } }
                                    .padding(.top, 6)
                            }
                        }
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(ApprovalMode.allCases, id: \.self) { mode in
                                Toggle(isOn: Binding(
                                    get: { roster.approvals == .every(mode) },
                                    set: { _ in
                                        guard roster.approvals != .every(mode) else { return }
                                        if mode == .off { isConfirmingNeverAsk = true } else { Task { await roster.setApprovals(mode) } }
                                    }
                                )) {
                                    Text(Self.name(of: mode))
                                    Text(Self.summary(of: mode))
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(approvalsLabel)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(theme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(theme.raised, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.hairline))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .accessibilityLabel("Approvals")
                        // One change at a time, as it goes to every bot in turn.
                        .disabled(roster.isSettingApprovals || roster.approvals == .checking)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }

            section("Appearance", theme)
            card(theme) {
                HStack {
                    Text("Theme")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Menu {
                        Picker("Theme", selection: $appearance) {
                            ForEach(Appearance.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 5) {
                            Text(appearance.name)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(theme.raised, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.hairline))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel("Theme")
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
            }

            // Out of the way, for anyone who wants to say thanks.
            section("About", theme)
            card(theme) {
                HStack {
                    Text("Hermes Bot is free. If it's useful to you, you can buy me a coffee.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    pill("Ko-fi", theme) {
                        if let link = URL(string: "https://ko-fi.com/dantemoony") { openURL(link) }
                    }
                    .help("Opens ko-fi.com/dantemoony in your browser")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if let current = updates.current {
                    theme.hairline.frame(height: 1)
                    HStack {
                        Text("Version \(current)")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 12)
                        if updates.isOn {
                            pill("Check for Updates", theme, isEnabled: updates.canCheck) { updates.check() }
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    if updates.isOn {
                        theme.hairline.frame(height: 1)
                        HStack {
                            Text("Check for updates automatically")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.text)
                            Spacer(minLength: 12)
                            Toggle("Check for updates automatically", isOn: Bindable(updates).checksAutomatically)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                // Neutral: blue is for unread and selection.
                                .tint(theme.secondaryText)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 46)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(theme.canvas, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.hairline))
        // One shadow, under the panel as a whole, not one under every card inside it.
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        // Reads when Settings opens, again once the roster finishes loading, and quietly rechecks
        // while Settings stays visible so remote bot or mode changes cannot leave a stale claim.
        .task(id: roster.phase) {
            guard roster.phase == .loaded else { return }
            await roster.readApprovals()
            while !Task.isCancelled {
                try? await Task.sleep(for: roster.approvalsRecheckInterval)
                guard !Task.isCancelled else { return }
                await roster.recheckApprovals()
            }
        }
        // Cancel is what Return does, matching /approvals off in chat, with no colour tint.
        .alert("Turn off command approvals?", isPresented: $isConfirmingNeverAsk) {
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
            Button("Never Ask") { Task { await roster.setApprovals(.off) } }
        } message: {
            Text("Every bot on \(roster.gatewayName ?? "this gateway") will stop asking before running commands, including ones that delete files.")
        }
        .confirmationDialog(roster.isThisMac ? "Disconnect from Hermes on this Mac?" : "Disconnect from this gateway?", isPresented: $isConfirmingSignOut) {
            Button("Disconnect", role: .destructive) {
                close()
                Task { await roster.signOut() }
            }
        } message: {
            Text(roster.isThisMac ? "Your bots and their chats stay in Hermes."
                : roster.isSignedIn ? "Its address and your sign-in are removed from this Mac. Your bots and their chats stay on the gateway."
                : "Its address and token are removed from this Mac. Your bots and their chats stay on the gateway.")
        }
    }

    private var status: String {
        if roster.gatewayIsFixed { return "Set by HERMES_URL for this run" }
        switch roster.phase {
        case .loaded:
            if roster.signInNotSaved { return "Your sign-in couldn't be saved to the Keychain. You'll be asked to sign in again next time." }
            let bots = roster.bots.count == 1 ? "1 bot" : "\(roster.bots.count) bots"
            // With a name of its own showing, the address is still to be found here.
            if roster.gatewayNickname != nil, let address = roster.gatewayAddress { return "\(address) · \(bots)" }
            return bots
        case .loading: return "Connecting…"
        case .failed(let problem): return problem
        case .needsSetup: return ""
        }
    }

    /// Hermes's own modes, in words.
    static func name(of mode: ApprovalMode) -> String {
        switch mode {
        case .manual: "Ask every time"
        case .smart: "Ask for risky things"
        case .off: "Never ask"
        }
    }

    /// Brief explanation shown under each choice in the Approvals menu.
    static func summary(of mode: ApprovalMode) -> String {
        switch mode {
        case .manual: "Pause before any command Hermes counts as risky."
        case .smart: "Let safe checks run; ask when a command still seems risky."
        case .off: "Run commands without stopping to ask."
        }
    }

    private var approvalsLabel: String {
        if roster.isSettingApprovals { return "Saving…" }
        switch roster.approvals {
        case .every(let mode): return Self.name(of: mode)
        case .mixed: return "Mixed"
        case .checking: return "Checking…"
        default: return "Not confirmed"
        }
    }

    private var approvalsNote: String {
        let gateway = roster.gatewayName ?? "this gateway"
        if roster.isSettingApprovals { return "Saving for every bot on \(gateway)…" }
        switch roster.approvals {
        case .every(.manual): return "Bots stop and ask before any command Hermes counts as risky. For every bot on \(gateway)."
        case .every(.smart): return "Hermes takes a second look and asks only when a command still seems risky. For every bot on \(gateway)."
        case .every(.off): return "Bots run commands without stopping to ask. For every bot on \(gateway)."
        case .checking: return "Checking how bots on \(gateway) ask before acting."
        case .unconfirmed: return "Couldn't confirm how bots on \(gateway) ask before acting."
        default: return "Your bots don't all ask the same way. Picking one sets it for every bot on \(gateway)."
        }
    }

    private func finishNaming() {
        roster.nameGateway(name)
        isNaming = false
    }

    private func section(_ title: String, _ theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .padding(.leading, 2)
    }

    private func card(_ theme: Theme, @ViewBuilder content: () -> some View) -> some View {
        // One stack, so a card of several rows has one background and one edge, not one each.
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.bubbleEdge))
    }

    private func pill(_ title: String, _ theme: Theme, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        WhenHovered { isHovered in
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isEnabled ? theme.text : theme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    // A control that is disabled does not answer the pointer.
                    .background(isHovered && isEnabled ? theme.raisedHover : theme.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.hairline))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize()
    }
}

/// The gateway, wherever it is shown: the same mark in the sidebar's footer and in Settings.
struct GatewayBadge: View {
    /// On a card the disc is a step off the card, as it is a step off the sidebar there.
    var isOnCard = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        Image(systemName: "server.rack")
            .font(.system(size: 13))
            .foregroundStyle(theme.secondaryText)
            .frame(width: 34, height: 34)
            .background(isOnCard ? theme.raised : theme.surface, in: Circle())
    }
}
