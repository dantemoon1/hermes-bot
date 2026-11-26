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
    private let updates = UpdateCheck.shared
    let close: () -> Void
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @State private var isConfirmingSignOut = false
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
                        Text(updates.available.map { "Version \($0.version) is available. You have \(current)." } ?? "Version \(current)")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText)
                        Spacer(minLength: 12)
                        if let newer = updates.available {
                            pill("Download", theme) { openURL(newer.page) }
                                .help("Opens the release on GitHub in your browser")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
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
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.bubbleEdge))
    }

    private func pill(_ title: String, _ theme: Theme, action: @escaping () -> Void) -> some View {
        WhenHovered { isHovered in
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(isHovered ? theme.raisedHover : theme.raised, in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.hairline))
            }
        }
        .buttonStyle(.plain)
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
