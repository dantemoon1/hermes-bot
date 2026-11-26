import SwiftUI

/// A bot's face: one of thirteen shapes in one of eleven colours.
public struct AvatarLook: Sendable, Hashable, Codable {
    public var shape: AvatarShape
    public var color: AvatarColor

    public init(shape: AvatarShape, color: AvatarColor) {
        self.shape = shape
        self.color = color
    }

    /// The look of the main bot, and of the create dialog before a choice is made.
    public static let main = AvatarLook(shape: .blob, color: .ink)

    /// A stable look for a bot that has none saved: the same name gets the same face on every
    /// device. The two lists below are fixed for that reason; a new shape or colour must not be
    /// added to them, or every unsaved bot would change face.
    public init(seed: String) {
        let shapes: [AvatarShape] = [
            .blob, .cloud, .square, .sparkle, .clover, .heart, .flower, .teardrop, .tablet, .wedge, .house,
            .star, .hex,
        ]
        let colors: [AvatarColor] = [.brown, .red, .orange, .yellow, .green, .teal, .blue, .violet, .pink, .gray]
        let sum = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        self.init(shape: shapes[sum % shapes.count], color: colors[(sum / shapes.count) % colors.count])
    }
}

public enum AvatarColor: String, CaseIterable, Sendable, Codable {
    case ink, brown, red, orange, yellow, green, teal, blue, violet, pink, gray

    /// Ink is white in dark mode and near-black in light mode, so it always stands out.
    public func fill(_ scheme: ColorScheme) -> Color {
        switch self {
        case .ink: Color(hex: scheme == .dark ? 0xFFFFFF : 0x1A1A1A)
        case .brown: Color(hex: 0x9C6B43)
        case .red: Color(hex: 0xE5484D)
        case .orange: Color(hex: 0xE8702E)
        case .yellow: Color(hex: 0xEA9A3B)
        case .green: Color(hex: 0x5AC077)
        case .teal: Color(hex: 0x4FB3A5)
        case .blue: Color(hex: 0x3D82F6)
        case .violet: Color(hex: 0x8B5CF6)
        case .pink: Color(hex: 0xE8479E)
        case .gray: Color(hex: 0x7A7A7A)
        }
    }

    /// Light eyes on a light window and dark eyes on a dark one, whatever the body colour.
    public func eyes(_ scheme: ColorScheme) -> Color {
        Color(hex: scheme == .light ? 0xFFFFFF : 0x161616)
    }
}

public enum AvatarShape: String, CaseIterable, Sendable, Codable {
    case blob, cloud, square, sparkle, clover, heart, flower, teardrop, tablet, wedge, house, star, hex

    /// Where the eyes rest, as a fraction of the avatar's size from its centre: up and to the
    /// right, by as much as the shape has body there.
    var eyeAnchor: CGSize {
        switch self {
        case .blob: CGSize(width: 0.17, height: -0.18)
        case .cloud: CGSize(width: 0.13, height: -0.13)
        case .heart: CGSize(width: 0.16, height: -0.1)
        case .teardrop: CGSize(width: 0.12, height: -0.04)
        case .tablet: CGSize(width: 0.14, height: -0.12)
        case .wedge: CGSize(width: 0.04, height: -0.12)
        case .sparkle, .star: CGSize(width: 0.07, height: -0.04)
        default: CGSize(width: 0.09, height: -0.06)
        }
    }

    /// How far the face leans at rest, in degrees; negative is anticlockwise. Swinging the
    /// other way by this much stands it upright.
    var lean: Double { AvatarSilhouette.lean(of: self) }

    /// How far the eyes travel when they look at something, as a fraction of the avatar's
    /// size. Less on shapes with little room around the eyes.
    var eyeReach: CGFloat {
        switch self {
        case .wedge, .sparkle, .star: 0.06
        default: 0.12
        }
    }
}

/// The size and tilt of the eyes, as fractions of the avatar's size.
enum EyeMetrics {
    static let width: CGFloat = 0.1
    static let height: CGFloat = 0.22
    static let spacing: CGFloat = 0.09
    /// Anticlockwise, like the bodies.
    static let tilt: Double = -20

    /// The very top and bottom of each eye when the pair sits at `center` (a fraction of the
    /// avatar's size from its middle), for checking that eyes stay on the body.
    static func eyeTips(at center: CGSize, in rect: CGRect, tilt: Double = EyeMetrics.tilt) -> [CGPoint] {
        let size = min(rect.width, rect.height)
        let angle = tilt * .pi / 180
        let across = CGVector(dx: cos(angle), dy: sin(angle))
        let along = CGVector(dx: -sin(angle), dy: cos(angle))
        let anchor = center
        return [-1.0, 1.0].flatMap { side in
            [-1.0, 1.0].map { end in
                let offset = side * (width + spacing) / 2
                let reach = end * height / 2
                return CGPoint(
                    x: rect.midX + size * (anchor.width + across.dx * offset + along.dx * reach),
                    y: rect.midY + size * (anchor.height + across.dy * offset + along.dy * reach)
                )
            }
        }
    }
}

/// The outline of an avatar shape, drawn to fill the given rectangle.
public struct AvatarSilhouette: Shape {
    public let shape: AvatarShape

    public init(_ shape: AvatarShape) {
        self.shape = shape
    }

    public func path(in rect: CGRect) -> Path {
        // Shapes are described in a unit square from -1 to 1, y down, then tilted and fitted.
        let (unit, tilt) = Self.unitPaths[shape]!
        let scale = min(rect.width, rect.height) / 2
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .rotated(by: tilt * .pi / 180)
        return unit.applying(transform)
    }

    /// Built once: the outlines never change and are drawn on every frame of an animation.
    /// How far a shape leans as it is drawn. Some carry it as a tilt; others have it in
    /// the angles they are drawn at, and that is read off here.
    static func lean(of shape: AvatarShape) -> Double {
        switch shape {
        // A point or bump at 240 degrees where straight up is 270.
        case .wedge, .teardrop: -30
        // Corners at 5 degrees where flat sides would have them at 30; leaves at 20 for 45.
        case .hex, .clover: -25
        // Petals and points 20 degrees round from upright.
        case .flower, .star: -20
        // Round: there is no lean to see, and no turn to make.
        case .blob: 0
        default: unitPaths[shape]!.tilt
        }
    }

    private static let unitPaths: [AvatarShape: (Path, tilt: Double)] = Dictionary(
        uniqueKeysWithValues: AvatarShape.allCases.map { ($0, unitPath($0)) }
    )

    /// Every shape is plump and leans to the left. Angles are in degrees with 0 to the right
    /// and 90 down; a negative tilt is anticlockwise.
    private static func unitPath(_ shape: AvatarShape) -> (Path, tilt: Double) {
        switch shape {
        case .blob:
            (polar { _ in 0.88 }, 0)
        case .cloud:
            (circles([(-0.38, 0.12, 0.5), (0.36, 0.14, 0.52), (-0.1, -0.24, 0.54), (0.44, -0.14, 0.42), (0, 0.12, 0.46)]), -13)
        case .square:
            (polygon([(-0.72, -0.72), (0.72, -0.72), (0.72, 0.72), (-0.72, 0.72)], corner: 0.26), -25)
        case .sparkle:
            (polar { 0.6 + 0.36 * pow(abs(cos(2 * $0)), 1.5) }, -10)
        case .clover:
            (circles(ring(count: 4, distance: 0.48, radius: 0.44, firstAt: 20) + [(0, 0, 0.4)]), 0)
        case .heart:
            // A round pebble with a shallow dip on top and a blunt point below.
            (polar { angle in
                0.8 * (1 - 0.4 * bump(angle, at: 270, width: 20)) + 0.2 * bump(angle, at: 90, width: 26)
            }.applying(CGAffineTransform(scaleX: 1.08, y: 1)), -22)
        case .flower:
            (circles(ring(count: 6, distance: 0.52, radius: 0.38, firstAt: 10) + [(0, 0, 0.5)]), 0)
        case .teardrop:
            (polar { 0.74 + 0.22 * bump($0, at: 240, width: 24) }, 0)
        case .tablet:
            (Path(roundedRect: CGRect(x: -0.9, y: -0.62, width: 1.8, height: 1.24), cornerRadius: 0.58), -14)
        case .wedge:
            (polygon([125, 240, 355].map { point(at: $0, distance: 1.3) }, corner: 0.36), 0)
        case .house:
            (polygon([(-0.06, -0.92), (0.82, -0.34), (0.72, 0.8), (-0.72, 0.8), (-0.82, -0.3)], corner: 0.24), -25)
        case .star:
            (polar { 0.76 + 0.17 * cos(6 * ($0 - 10 * .pi / 180)) }, 0)
        case .hex:
            (polygon(stride(from: 5.0, to: 365, by: 60).map { point(at: $0, distance: 0.92) }, corner: 0.26), 0)
        }
    }

    private static func point(at degrees: Double, distance: Double) -> (Double, Double) {
        (distance * cos(degrees * .pi / 180), distance * sin(degrees * .pi / 180))
    }

    /// A smooth bump: 1 at the given angle, falling to 0 within a couple of widths either side.
    private static func bump(_ angle: Double, at degrees: Double, width: Double) -> Double {
        var distance = abs(angle * 180 / .pi - degrees).truncatingRemainder(dividingBy: 360)
        if distance > 180 { distance = 360 - distance }
        return exp(-pow(distance / width, 2))
    }

    /// Circles spaced evenly around the centre.
    private static func ring(count: Int, distance: Double, radius: Double, firstAt degrees: Double) -> [(Double, Double, Double)] {
        (0..<count).map { index in
            let (x, y) = point(at: degrees + 360 * Double(index) / Double(count), distance: distance)
            return (x, y, radius)
        }
    }

    /// A closed curve whose distance from the centre depends on the angle.
    private static func polar(_ radius: (Double) -> Double) -> Path {
        var path = Path()
        let steps = 240
        for step in 0..<steps {
            let angle = 2 * Double.pi * Double(step) / Double(steps)
            let point = CGPoint(x: radius(angle) * cos(angle), y: radius(angle) * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func polygon(_ corners: [(Double, Double)], corner radius: Double) -> Path {
        let points = corners.map { CGPoint(x: $0.0, y: $0.1) }
        var path = Path()
        let last = points[points.count - 1], first = points[0]
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for index in points.indices {
            path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % points.count], radius: radius)
        }
        path.closeSubpath()
        return path
    }

    private static func circles(_ circles: [(Double, Double, Double)]) -> Path {
        var path = Path()
        for (x, y, radius) in circles {
            path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        return path
    }
}
