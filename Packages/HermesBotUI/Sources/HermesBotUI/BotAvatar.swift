import SwiftUI

/// A bot's face. It rests leaning to one side. While the pointer is inside an enclosing
/// `avatarsFollowPointer()` area it swings upright and its eyes follow the pointer, like a
/// head turning to look; and it pulls faces while the bot is working.
public struct BotAvatar: View {
    private let look: AvatarLook
    private let size: CGFloat
    private let isWorking: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.avatarIsWatched) private var isWatched

    public init(_ look: AvatarLook, size: CGFloat, isWorking: Bool = false) {
        self.look = look
        self.size = size
        self.isWorking = isWorking
    }

    public var body: some View {
        let fill = look.color.fill(scheme)
        let silhouette = AvatarSilhouette(look.shape)
        let isUpright = isWatched && !reduceMotion
        ZStack {
            // The stroke rounds every point and corner, which is what makes the shapes soft.
            Group {
                silhouette.fill(fill)
                silhouette.stroke(fill, style: StrokeStyle(lineWidth: size * 0.07, lineJoin: .round))
            }
            // Out of its lean and back into it.
            .rotationEffect(.degrees(isUpright ? -look.shape.lean : 0))
            // The eyes are their own view so that pointer movement redraws only them.
            AvatarEyes(look: look, size: size, isWorking: isWorking, isUpright: isUpright)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.22), value: isUpright)
        .padding(size * 0.035)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct AvatarEyes: View {
    let look: AvatarLook
    let size: CGFloat
    let isWorking: Bool
    /// The face has swung upright to look at the pointer.
    let isUpright: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.avatarPointer) private var pointer
    @State private var face = Face.resting
    @State private var center: CGPoint = .zero

    private var isAnimated: Bool { isWorking && !reduceMotion }

    var body: some View {
        HStack(spacing: size * EyeMetrics.spacing) {
            eye(face.left)
            eye(face.right)
        }
        .rotationEffect(.degrees(isUpright ? 0 : EyeMetrics.tilt))
        .offset(offset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGPoint.self) { proxy in
            let frame = proxy.frame(in: .named(AvatarPointerSpace.name))
            return CGPoint(x: frame.midX, y: frame.midY)
        } action: { center = $0 }
        // The same spring as the body's swing, so face and eyes turn as one.
        .animation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.22), value: offset)
        .task(id: isAnimated) { await pullFaces() }
    }

    private func eye(_ openness: CGFloat) -> some View {
        Capsule()
            .fill(look.color.eyes(scheme))
            .frame(width: size * EyeMetrics.width, height: size * EyeMetrics.height * openness)
            .frame(height: size * EyeMetrics.height)
    }

    /// Where the eyes sit, from the avatar's centre.
    private var offset: CGSize {
        // Upright, the eyes sit in the middle of the face; leaning, up and to one side.
        let rest = isUpright ? CGSize(width: 0, height: 0.02) : look.shape.eyeAnchor
        var x = rest.width, y = rest.height
        let reach = look.shape.eyeReach
        // Under the pointer a bot looks at it even while working: the blinks and the shapes
        // of its eyes go on, and only where it looks is the pointer's.
        if let pointer, !reduceMotion {
            let dx = pointer.x - center.x, dy = pointer.y - center.y
            let distance = hypot(dx, dy)
            if distance > 0.5 {
                // Nothing when the pointer is on the face itself, the full look a little
                // way off, so the eyes never jump as the pointer crosses the avatar.
                let follow = min(1, distance / (size * 1.2))
                x += (dx / distance * reach - x) * follow
                y += (dy / distance * reach - y) * follow
            }
        } else if isAnimated {
            x += face.gaze.width * reach * 0.8
            y += face.gaze.height * reach * 0.8
        }
        return CGSize(width: x * size, height: y * size)
    }

    private func pullFaces() async {
        guard isAnimated else {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35)) { face = .resting }
            return
        }
        do {
            while true {
                withAnimation(.spring(duration: 0.35, bounce: 0.3)) { face = Face.working.randomElement()! }
                try await Task.sleep(for: .milliseconds(Int.random(in: 900...2200)))
                // A blink between faces.
                withAnimation(.easeOut(duration: 0.08)) { face = Face(left: 0.12, right: 0.12, gaze: face.gaze) }
                try await Task.sleep(for: .milliseconds(120))
            }
        } catch {
            // Cancelled: the task that replaces this one puts the face back.
        }
    }
}

/// How open each eye is, and where they look.
private struct Face: Equatable {
    var left: CGFloat = 1
    var right: CGFloat = 1
    var gaze: CGSize = .zero

    static let resting = Face()
    static let working: [Face] = [
        Face(gaze: CGSize(width: -1.6, height: 0.3)),
        Face(gaze: CGSize(width: 0.3, height: 0.4)),
        Face(gaze: CGSize(width: -0.6, height: -0.5)),
        Face(gaze: CGSize(width: -0.8, height: 1.4)),
        Face(left: 0.55, right: 0.55, gaze: CGSize(width: -0.6, height: 0.8)),
        Face(left: 1.2, right: 1.2),
        Face(left: 1, right: 0.5, gaze: CGSize(width: -0.2, height: 0.2)),
    ]
}

enum AvatarPointerSpace {
    static let name = "HermesBotUI.avatarPointer"
}

extension EnvironmentValues {
    /// The pointer's position in the enclosing `avatarsFollowPointer()` area, or nil when it
    /// is outside.
    @Entry var avatarPointer: CGPoint?
    /// Whether the pointer is in that area at all. Kept apart from where it is, so that the
    /// body of an avatar is redrawn when the pointer comes and goes and not as it moves.
    @Entry var avatarIsWatched = false
}

extension View {
    /// Avatars inside this view watch the pointer while it is over the view. Put it on each
    /// bot's own row, so a bot looks only when it is the one being hovered.
    public func avatarsFollowPointer() -> some View {
        modifier(AvatarPointerArea())
    }
}

private struct AvatarPointerArea: ViewModifier {
    @State private var pointer: CGPoint?

    func body(content: Content) -> some View {
        content
            .environment(\.avatarPointer, pointer)
            .environment(\.avatarIsWatched, pointer != nil)
            // The hover is read in this view's own space, and the same space is then named
            // for the avatars inside, so both measure from the same corner.
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location): pointer = location
                case .ended: pointer = nil
                }
            }
            .coordinateSpace(.named(AvatarPointerSpace.name))
    }
}
