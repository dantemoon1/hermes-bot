import SwiftUI

/// What stands at the end of a chat while a bot is working, as in the reference: the bot's
/// face comes in, becomes three dots with a larger one travelling across them while there
/// is nothing yet to say about what it is doing, and comes back with a few grey words
/// beside it once there is, a lighter band passing over them.
public struct WorkingMark: View {
    private let look: AvatarLook
    private let status: String?
    @State private var hasArrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// `status` says what the bot is doing, such as "Thinking…". Nil while that is not known.
    public init(_ look: AvatarLook, status: String?) {
        self.look = look
        self.status = status
    }

    /// The face shows at first and whenever there is something to say; the dots between.
    private var showsDots: Bool { hasArrived && status == nil && !reduceMotion }

    public var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: 8) {
            ZStack {
                // Whichever is hidden is also still: nothing ticks behind the other.
                BotAvatar(look, size: 22, isWorking: !showsDots)
                    .scaleEffect(showsDots ? 0.3 : 1)
                    .opacity(showsDots ? 0 : 1)
                TravellingDots(theme: theme, isMoving: showsDots)
                    .scaleEffect(showsDots ? 1 : 0.5)
                    .opacity(showsDots ? 1 : 0)
            }
            .frame(width: 28, height: 22)
            if let status {
                // The words change in place, at once: eased, the old ones would fade
                // where the mark was while the new ones fade in where it has moved to.
                SweptText(status, theme: theme, isMoving: !reduceMotion)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.32), value: showsDots)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: status != nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status ?? "Working…")
        .task {
            // Long enough for the face to be seen before it turns into the dots.
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            hasArrived = true
        }
    }
}

/// Three dots in a row, one of them larger and lighter, that one moving along and round again.
private struct TravellingDots: View {
    let theme: Theme
    /// Stopped while out of sight.
    let isMoving: Bool

    var body: some View {
        TimelineView(.animation(paused: !isMoving)) { timeline in
            // Where the large dot is, from 0 to 3, going round.
            let at = (timeline.date.timeIntervalSinceReferenceDate / 0.3).truncatingRemainder(dividingBy: 3)
            HStack(spacing: 1) {
                ForEach(0..<3, id: \.self) { index in
                    // How near the large dot is to this place, counting round the ends.
                    let apart = min(abs(at - Double(index)), 3 - abs(at - Double(index)))
                    let near = max(0, 1 - apart)
                    Circle()
                        .fill(theme.text.opacity(0.45 + 0.55 * near))
                        .frame(width: 4 + 4.5 * near, height: 4 + 4.5 * near)
                        .frame(width: 8.5, height: 9)
                }
            }
        }
    }
}

/// A few grey words with a lighter band passing over them from left to right.
public struct SweptText: View {
    let text: String
    let theme: Theme
    let size: CGFloat
    let isMoving: Bool

    public init(_ text: String, theme: Theme, size: CGFloat = 13, isMoving: Bool) {
        self.text = text
        self.theme = theme
        self.size = size
        self.isMoving = isMoving
    }

    public var body: some View {
        let words = Text(text).font(.system(size: size)).lineLimit(1)
        words
            .foregroundStyle(theme.secondaryText)
            .overlay {
                if isMoving {
                    TimelineView(.animation) { timeline in
                        // From before the first letter to past the last, then a short rest.
                        let turn = (timeline.date.timeIntervalSinceReferenceDate / 1.7).truncatingRemainder(dividingBy: 1)
                        let along = min(turn / 0.75, 1)
                        words
                            .foregroundStyle(theme.text)
                            .mask {
                                GeometryReader { space in
                                    // From wholly before the words to wholly past them,
                                    // however few the words.
                                    let band = max(space.size.width * 0.45, 40)
                                    LinearGradient(colors: [.clear, .white, .clear], startPoint: .leading, endPoint: .trailing)
                                        .frame(width: band)
                                        .offset(x: -band + (space.size.width + band) * along)
                                }
                            }
                    }
                }
            }
    }
}
