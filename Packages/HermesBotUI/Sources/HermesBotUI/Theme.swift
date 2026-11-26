import SwiftUI

/// The app's colours. Neutral greys only: avatars carry the colour.
public struct Theme: Sendable {
    public let sidebar: Color
    public let canvas: Color
    /// The selected main-bot tile and row.
    public let surface: Color
    /// The lit row of a list on a floating card: a clear step from the card in both appearances.
    public let chosen: Color
    /// Where a message is typed: a floating control, lighter than the bubbles in light mode.
    public let composer: Color
    /// The bubble around what a bot said, and its edge.
    public let bubble: Color
    public let bubbleEdge: Color
    /// A block of code inside a bot's bubble: set into it.
    public let codeBlock: Color
    /// The bubble around what the person sent: a clear step away from `bubble`.
    public let sentBubble: Color
    /// Round buttons and pills that float over content.
    public let control: Color
    /// A button sitting on a card: a step lighter than the card in dark, white in light.
    public let raised: Color
    /// The same two under the pointer: a step lighter in dark, a step darker in light.
    public let controlHover: Color
    public let raisedHover: Color
    /// Under the pointer, for a button that has no fill of its own.
    public let hover: Color
    public let hairline: Color
    /// The dot on a bot that has said something not yet read: the one colour outside the
    /// avatars, as in the reference.
    public let unread: Color
    public let text: Color
    public let secondaryText: Color
    /// Behind each place a find in the chat turned up: a quiet grey, no colour.
    public let findMatch: Color
    /// Behind the find gone to: the colour of a selection, as blue marks selection.
    public let findCurrent: Color
    /// The soft shadow under controls that float over content.
    public let floatShadow: Color

    public init(_ scheme: ColorScheme) {
        let dark = scheme == .dark
        sidebar = Color(hex: dark ? 0x0E0E0E : 0xF5F5F5)
        canvas = Color(hex: dark ? 0x121212 : 0xFCFCFC)
        surface = Color(hex: dark ? 0x1F1F1F : 0xE8E8E8)
        chosen = Color(hex: dark ? 0x2E2E2E : 0xEBEBEB)
        composer = Color(hex: dark ? 0x1F1F1F : 0xFFFFFF)
        floatShadow = .black.opacity(dark ? 0.25 : 0.06)
        bubble = Color(hex: dark ? 0x1F1F1F : 0xF2F2F2)
        bubbleEdge = dark ? .white.opacity(0.08) : .black.opacity(0.05)
        codeBlock = Color(hex: dark ? 0x151515 : 0xFAFAFA)
        sentBubble = Color(hex: dark ? 0x3C3C3C : 0xE5E5E5)
        control = Color(hex: dark ? 0x1C1C1C : 0xFFFFFF)
        raised = Color(hex: dark ? 0x2C2C2C : 0xFFFFFF)
        controlHover = Color(hex: dark ? 0x2A2A2A : 0xF1F1F1)
        // In light a raised button sits on a card nearly its own hover grey, so it goes a
        // clear step darker than the card instead.
        raisedHover = Color(hex: dark ? 0x3A3A3A : 0xE6E6E6)
        hover = dark ? .white.opacity(0.07) : .black.opacity(0.05)
        unread = Color(hex: dark ? 0x4C8DF6 : 0x2F7BF5)
        hairline = dark ? .white.opacity(0.08) : .black.opacity(0.08)
        text = Color(hex: dark ? 0xF2F2F2 : 0x141414)
        secondaryText = Color(hex: dark ? 0x8C8C8C : 0x6E6E6E)
        findMatch = dark ? .white.opacity(0.16) : .black.opacity(0.1)
        // The reference's selection, sampled from its screenshots in light and dark.
        findCurrent = Color(hex: dark ? 0x35557E : 0xB4D0F4)
    }
}

extension Color {
    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Builds a view that looks different under the pointer. The change eases in and out
/// quickly, as a control answering the pointer should.
public struct WhenHovered<Content: View>: View {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: (Bool) -> Content

    public init(@ViewBuilder _ content: @escaping (Bool) -> Content) {
        self.content = content
    }

    public var body: some View {
        // A control that can't be used does not answer the pointer, though it is still
        // told of it; and the change is not eased for someone who has asked for less motion.
        content(isHovered && isEnabled)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered && isEnabled)
    }
}
