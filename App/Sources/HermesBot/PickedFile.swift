import AppKit
import HermesBotUI
import HermesKit
import SwiftUI
import UniformTypeIdentifiers

/// A file the person picked to send with a message, read and ready to hand to the gateway.
struct PickedFile: Identifiable, Equatable, Sendable {
    let id = UUID()
    let name: String
    let data: Data
    /// Its kind as the gateway is told it, such as "text/plain".
    let type: String
    /// A kind of picture the gateway takes as a picture, for a bot that can see to look at.
    let isPicture: Bool

    static func == (one: PickedFile, other: PickedFile) -> Bool { one.id == other.id }

    enum Problem: Error {
        case tooLarge(String)
        case unreadable(String)

        var text: String {
            switch self {
            case .tooLarge(let name): "\(name) is too large to attach. The most is 25 MB, and 15 MB for a picture."
            case .unreadable(let name): "\(name) couldn't be read."
            }
        }
    }

    /// Reads a file from disk. A picture of a kind the gateway does not take as one (a
    /// photo in HEIC, a TIFF) is turned into a JPEG so the bot can look at it.
    nonisolated static func read(_ url: URL) -> Result<PickedFile, Problem> {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
            return .failure(.unreadable(name))
        }
        guard (values.fileSize ?? 0) <= GatewayClient.attachmentLimit else { return .failure(.tooLarge(name)) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable(name)) }
        let ending = url.pathExtension.lowercased()
        // Read whole, it is checked again: the size asked of the disk may be out of date.
        guard data.count <= GatewayClient.attachmentLimit else { return .failure(.tooLarge(name)) }
        if GatewayClient.pictureEndings.contains(ending) {
            // No larger than this app will show again once it is in the chat.
            guard data.count <= HandedFile.pictureLimit else { return .failure(.tooLarge(name)) }
            return .success(PickedFile(name: name, data: data, type: mime(for: ending), isPicture: true))
        }
        if ["heic", "heif", "tiff", "tif"].contains(ending), let jpeg = jpeg(from: data) {
            guard jpeg.count <= HandedFile.pictureLimit else { return .failure(.tooLarge(name)) }
            return .success(PickedFile(name: (name as NSString).deletingPathExtension + ".jpg", data: jpeg, type: "image/jpeg", isPicture: true))
        }
        return .success(PickedFile(name: name, data: data, type: mime(for: ending), isPicture: false))
    }

    /// As the gateway's session authority takes it: that route holds png, jpeg, gif and
    /// webp as pictures, so a BMP goes as a PNG. Anything else is as it was.
    nonisolated func asHeldPicture() throws -> PickedFile {
        guard isPicture, (name as NSString).pathExtension.lowercased() == "bmp" else { return self }
        switch Self.picture(data, named: (name as NSString).deletingPathExtension + ".png") {
        case .success(let png): return png
        // Said of the file as it was picked.
        case .failure(.tooLarge): throw GatewayError.rejected(code: 0, message: Problem.tooLarge(name).text)
        case .failure(.unreadable): throw GatewayError.rejected(code: 0, message: Problem.unreadable(name).text)
        }
    }

    /// A picture that was pasted as a picture, with no file behind it.
    /// `data` is a PNG, or a TIFF as the pasteboard often holds a copied picture, which
    /// is made into a PNG here.
    nonisolated static func picture(_ data: Data, named name: String) -> Result<PickedFile, Problem> {
        var png = data
        if !data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            guard data.count <= 4 * GatewayClient.attachmentLimit,
                  let made = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
            else { return .failure(.unreadable(name)) }
            png = made
        }
        guard png.count <= HandedFile.pictureLimit else { return .failure(.tooLarge(name)) }
        return .success(PickedFile(name: name, data: png, type: "image/png", isPicture: true))
    }

    /// A photo of a kind the gateway does not take, as a JPEG the right way up. Its size
    /// is looked at before any of it is unpacked, and it is made no larger than a bot
    /// needs to look at.
    private nonisolated static func jpeg(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let about = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = about[kCGImagePropertyPixelWidth] as? Int, let height = about[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 80_000_000
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }

    private nonisolated static func mime(for ending: String) -> String {
        UTType(filenameExtension: ending)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// One picked file in the message box, with a way to take it out again.
struct PickedChip: View {
    let file: PickedFile
    let remove: () -> Void
    @State private var picture: NSImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        HStack(spacing: 8) {
            Group {
                if let picture {
                    Image(nsImage: picture).resizable().scaledToFill()
                } else {
                    Image(systemName: file.isPicture ? "photo" : "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(width: 30, height: 30)
            .background(theme.raised)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(file.name)
                .font(.system(size: 12.5))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
            WhenHovered { isHovered in
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isHovered ? theme.text : theme.secondaryText)
                        .frame(width: 18, height: 18)
                        .background(theme.hover.opacity(isHovered ? 1 : 0), in: Circle())
                        .contentShape(Circle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(file.name)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 6)
        .frame(height: 40)
        .background(theme.codeBlock, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.bubbleEdge))
        .task {
            guard file.isPicture else { return }
            picture = await PictureMaker.shared.picture(from: file.data, noLargerThan: 96)
        }
        .accessibilityElement(children: .contain)
    }
}

/// What went with a message the person sent, above its words: pictures as pictures, other
/// files by name. For a message on its way these are the files as picked; for a stored
/// one, what the gateway holds.
struct SentAttachments: View {
    let picked: [PickedFile]
    let images: [String]
    let files: [String]
    let bot: Bot
    let roster: RosterModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(picked.filter(\.isPicture)) { file in
                PickedPicture(file: file)
            }
            ForEach(images, id: \.self) { path in
                HandedFile(path: path, bot: bot, roster: roster, isOwn: true)
                    .id(path)
            }
            ForEach(Array((picked.filter { !$0.isPicture }.map(\.name) + files).enumerated()), id: \.offset) { _, name in
                HStack(spacing: 7) {
                    Image(systemName: "doc")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                    Text(name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize()
                .background(theme.sentBubble.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("Attached file, \(name)")
            }
        }
    }
}

/// A picture as picked, shown from what was read from disk while it is on its way.
private struct PickedPicture: View {
    let file: PickedFile
    @State private var picture: NSImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Theme(scheme)
        Group {
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(picture.size.width, 320), maxHeight: 320)
            } else {
                theme.codeBlock.frame(width: 160, height: 110)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.bubbleEdge))
        .task { picture = await PictureMaker.shared.picture(from: file.data, noLargerThan: 800) }
        .accessibilityLabel("Picture, \(file.name)")
    }
}
