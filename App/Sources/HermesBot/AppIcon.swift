import AppKit
import HermesBotUI
import SwiftUI

/// The app's icon: the main bot's face on a dark tile. Drawn by the app itself, so the
/// icon is always the face the app shows and there is no artwork to keep in step.
struct AppIconArt: View {
    /// The side of the whole image, in points. The tile sits inside it with the margin
    /// macOS icons keep.
    let side: CGFloat

    var body: some View {
        let tile = side * 0.805
        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2A2A2A), Color(hex: 0x101010)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: max(1, side / 512))
                )
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(0.3), radius: side * 0.02, y: side * 0.012)
            BotAvatar(.main, size: tile * 0.6)
        }
        .frame(width: side, height: side)
        .environment(\.colorScheme, .dark)
    }
}

enum AppIconWriter {
    /// Writes the icon as an `.iconset` folder, for `iconutil` to turn into an `.icns`.
    /// Returns false if any size could not be written.
    @MainActor
    static func write(to folder: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let pixels = points * scale
                    let renderer = ImageRenderer(content: AppIconArt(side: CGFloat(pixels)))
                    renderer.scale = 1
                    guard let image = renderer.cgImage else { return false }
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
                    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                    try png.write(to: folder.appendingPathComponent(name))
                }
            }
            return true
        } catch {
            return false
        }
    }
}
