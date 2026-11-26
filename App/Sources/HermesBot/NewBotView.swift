import HermesBotUI
import HermesKit
import SwiftUI

/// Create New Bot: a face, a name, and that is all.
struct NewBotView: View {
    let roster: RosterModel
    let close: () -> Void
    @State private var name = ""
    @State private var look = AvatarLook(
        shape: AvatarShape.allCases.randomElement() ?? .square,
        color: AvatarColor.allCases.filter { $0 != .ink }.randomElement() ?? .green
    )
    @State private var problem: String?
    @State private var isCreating = false
    /// A bot this dialog made, or may have made, that is not finished. Create then finishes it.
    @State private var unnamed: String?
    /// Whether that bot is known to be there and the person's to name; see `RosterModel.NewBot`.
    @State private var isConfirmed = true
    @FocusState private var isNaming: Bool
    @Environment(\.colorScheme) private var scheme

    private var canCreate: Bool {
        // Once the gateway is found unable to make bots, there is nothing to try again:
        // the dialog says so once and can only be closed.
        !isCreating && !roster.cannotMakeBots && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let theme = Theme(scheme)
        VStack(spacing: 0) {
            HStack {
                Text("Create New Bot")
                    .font(.system(size: 14, weight: .semibold))
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
                // Not while the bot is being made: it would be made all the same.
                .disabled(isCreating)
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 52)
            theme.hairline.frame(height: 1)

            VStack(spacing: 0) {
                BotAvatar(look, size: 96, isWorking: isCreating)
                    .avatarsFollowPointer()
                    .padding(.top, 22)
                    .accessibilityHidden(true)

                TextField("Name your Bot", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .focused($isNaming)
                    .onSubmit(create)
                    .frame(height: 36)
                    .padding(.horizontal, 12)
                    // Level with the card, marked out by its edge alone, as in the reference.
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.hairline))
                    .padding(.top, 20)

                FacePicker(look: $look)
                    .padding(.top, 22)

                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
            .disabled(isCreating || roster.cannotMakeBots)

            theme.hairline.frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                Button(unnamed == nil && !roster.cannotMakeBots ? "Cancel" : "Close", action: close)
                    .buttonStyle(PillButtonStyle(isPrimary: false))
                    .disabled(isCreating)
                Button(isCreating ? (unnamed != nil && isConfirmed ? "Saving…" : "Creating…") : unnamed == nil ? "Create" : "Try Again", action: create)
                    .buttonStyle(PillButtonStyle(isPrimary: true))
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .frame(height: 58)
        }
        .frame(width: 400)
        .background(theme.control, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.hairline))
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        // Once the dialog is in the window: asked for as it appears, focus is not given.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            isNaming = true
        }
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        problem = nil
        Task {
            switch await roster.createBot(named: name, look: look, finishing: unnamed, isConfirmed: isConfirmed) {
            case .made:
                close()
            case .failed(let why):
                unnamed = nil
                isConfirmed = true
                problem = why.isEmpty ? nil : why
            case .madeButUnnamed(let id, let why):
                unnamed = id
                isConfirmed = true
                problem = why
            case .unconfirmed(let id, let why):
                unnamed = id
                isConfirmed = false
                problem = why
            }
            isCreating = false
        }
    }
}

/// The pills at the foot of a dialog. The one that goes ahead is filled.
struct PillButtonStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let theme = Theme(scheme)
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(!isEnabled ? theme.secondaryText : isPrimary ? theme.canvas : theme.text)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(!isEnabled ? theme.surface : isPrimary ? theme.text : theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(isPrimary && isEnabled ? .clear : theme.hairline))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// The shapes and colours a bot's face is chosen from.
struct FacePicker: View {
    @Binding var look: AvatarLook
    /// Smaller, to fit a narrow pane.
    var isCompact = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(spacing: isCompact ? 16 : 20) {
            grid(AvatarShape.allCases, columns: 5, spacing: isCompact ? 10 : 14) { shape in
                choice(isChosen: look.shape == shape, label: shape.rawValue, ring: RoundedRectangle(cornerRadius: 10), gap: 4, theme) {
                    look.shape = shape
                } content: {
                    BotAvatar(AvatarLook(shape: shape, color: look.color), size: isCompact ? 30 : 36)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shape")

            grid(AvatarColor.allCases, columns: 6, spacing: isCompact ? 10 : 12) { color in
                choice(isChosen: look.color == color, label: color.rawValue, ring: Circle(), gap: 3, theme) {
                    look.color = color
                } content: {
                    Circle().fill(color.fill(scheme)).frame(width: 22, height: 22)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Colour")
        }
    }

    /// Rows of at most `columns`, each centred, as the reference wraps its choices.
    private func grid<Item: Hashable>(
        _ items: [Item], columns: Int, spacing: CGFloat, @ViewBuilder cell: @escaping (Item) -> some View
    ) -> some View {
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        return VStack(spacing: spacing) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { cell($0) }
                }
            }
        }
    }

    private func choice(
        isChosen: Bool, label: String, ring: some InsettableShape, gap: CGFloat, _ theme: Theme,
        action: @escaping () -> Void, @ViewBuilder content: () -> some View
    ) -> some View {
        Button(action: action) {
            content()
                .padding(gap)
                .overlay(ring.strokeBorder(theme.secondaryText.opacity(isChosen ? 0.7 : 0), lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}
