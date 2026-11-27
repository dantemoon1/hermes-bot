import AppKit
import Testing

extension Tag {
    @Tag static var onScreen: Self
}

enum OnScreenTesting {
    static let enabled = ProcessInfo.processInfo.environment["HERMES_UI_TESTS"] == "1"
    static let whySkipped: Comment = "Set HERMES_UI_TESTS=1 to run this on-screen test."

    @MainActor
    static func panel(width: CGFloat, height: CGFloat) -> NSPanel {
        let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = max(screen.minX, screen.maxX - width - 12)
        let y = screen.minY + 12
        return panel(in: NSRect(x: x, y: y, width: width, height: height))
    }

    @MainActor
    static func panel(in frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        return panel
    }
}
