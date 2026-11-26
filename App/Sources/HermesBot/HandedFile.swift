import AppKit
import HermesBotUI
import HermesKit
import SwiftUI

/// A file a bot handed over in its chat: a picture shown where it stands, anything else as
/// a card with its name and a way to keep it.
///
/// The file is on the gateway, where the bot put it, and is read from there. Nothing a bot
/// hands over is ever run: a picture is drawn, and any other file is only saved, marked as
/// having come from elsewhere so that macOS asks before it is first opened.
struct HandedFile: View {
    let path: String
    let bot: Bot
    let roster: RosterModel
    /// The reply it stands in is finished. Until then the name may be only partly
    /// arrived, and nothing is fetched or saved by it.
    var isSettled = true
    /// The person sent it, in a message of their own.
    var isOwn = false
    /// Why it is shown as a file, when it was to have been shown as something else.
    var why: String?
    /// On screen, or near it. A picture far up a long chat is not fetched until it is.
    @State private var isInSight = false
    @State private var picture: NSImage?
    /// It could not be shown as a picture, and is a file like any other from then on,
    /// whatever is said about saving it.
    @State private var showsCard = false
    @State private var problem: String?
    @State private var isSaving = false
    @State private var saved = false
    @Environment(\.colorScheme) private var scheme

    private var name: String { ReplyFormat.name(of: path) }

    /// Kinds this app draws itself. Never by what a file says it is, only by its name:
    /// a vector picture can carry a script, and is kept as a file.
    nonisolated static func isPicture(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "tif"].contains((path as NSString).pathExtension.lowercased())
    }

    var body: some View {
        let theme = Theme(scheme)
        Group {
            if Self.isPicture(path), !showsCard {
                if let picture {
                    Image(nsImage: picture)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(picture.size.width, 420), maxHeight: 420, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.bubbleEdge))
                        .contextMenu { Button("Save Picture…") { save() } }
                        .accessibilityLabel("Picture, \(name)")
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.codeBlock)
                        .frame(width: 220, height: 140)
                        .overlay(ProgressView().controlSize(.small))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.bubbleEdge))
                        .accessibilityLabel("Loading picture, \(name)")
                }
            } else {
                card(theme)
            }
        }
        .padding(.vertical, 2)
        .onScrollVisibilityChange(threshold: 0.01) { isInSight = $0 }
        // Fetched once the reply is finished and the picture is in sight, and once only.
        .task(id: isSettled && isInSight) {
            guard isSettled, isInSight, Self.isPicture(path), picture == nil, !showsCard else { return }
            do {
                let file = try await roster.file(at: path, from: bot, limit: Self.pictureLimit)
                guard !Task.isCancelled else { return }
                // Read off the main thread: decoding is the costly part.
                let image = await PictureMaker.shared.picture(from: file.data)
                guard !Task.isCancelled else { return }
                if let image {
                    picture = image
                } else {
                    problem = "This isn't a picture that can be shown here. Save it to look at it."
                    showsCard = true
                }
            } catch is CancellationError {
            } catch {
                problem = Self.text(for: error)
                showsCard = true
            }
        }
    }

    /// The most a picture may weigh to be fetched for showing. Anything larger is a file.
    static let pictureLimit = 15_000_000

    /// A picture made from what the gateway sent, drawn no larger than a chat needs.
    /// What it is is read from the bytes, not the name, and it is turned away before any
    /// of it is unpacked if it is not a plain picture or is of a size no chat needs: a
    /// small file can claim to be a picture of enormous size, to use up memory.
    nonisolated static func picture(from data: Data, noLargerThan most: Int = 1400) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let kind = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp", "public.webp", "public.heic", "public.heif", "com.microsoft.bmp", "public.tiff"].contains(kind),
              let about = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = about[kCGImagePropertyPixelWidth] as? Int, let height = about[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 80_000_000
        else { return nil }
        // Made at the size it will be drawn at most, never unpacked whole.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: most, kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // In points for a display of double density, so it is drawn at its own size.
        return NSImage(cgImage: small, size: NSSize(width: CGFloat(small.width) / 2, height: CGFloat(small.height) / 2))
    }

    private func card(_ theme: Theme) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 15))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(theme.raised, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(problem ?? (saved ? "Saved to Downloads" : why ?? (isOwn ? "You sent this" : "File from \(bot.title)")))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            WhenHovered { isHovered in
                Button(action: save) {
                    Text(isSaving ? "Saving…" : "Save")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(isHovered ? theme.raisedHover : theme.raised, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.hairline))
                }
            }
            .buttonStyle(.plain)
            .disabled(isSaving || !isSettled)
            .help("Save to Downloads")
        }
        .padding(.horizontal, 10)
        .frame(width: 320, height: 50)
        .background(theme.codeBlock, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.bubbleEdge))
        .accessibilityElement(children: .combine)
    }

    /// Saves the file to Downloads under its own name (or that name with a number, if it
    /// is taken) and shows it in the Finder. It is never opened from here.
    private func save() {
        guard !isSaving, isSettled else { return }
        isSaving = true
        problem = nil
        Task {
            defer { isSaving = false }
            do {
                let file = try await roster.file(at: path, from: bot)
                let name = name
                // Written off the main thread: it may be tens of megabytes.
                let place = try await Task.detached { try Self.write(file.data, named: name) }.value
                saved = true
                NSWorkspace.shared.activateFileViewerSelecting([place])
            } catch is CancellationError {
            } catch let error as CocoaError {
                problem = "Couldn't save it: \(error.localizedDescription)"
            } catch {
                problem = Self.text(for: error)
            }
        }
    }

    /// Writes into Downloads without replacing anything there, and marks the file as
    /// having come from outside, so that macOS asks before it is first opened.
    nonisolated static func write(_ data: Data, named name: String, into folder: URL? = nil) throws -> URL {
        let downloads = try folder ?? FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let safe = plainName(name)
        let base = (safe as NSString).deletingPathExtension, kind = (safe as NSString).pathExtension
        var place = downloads.appendingPathComponent(safe)
        var number = 2
        // Anything at all by that name, a link that leads nowhere included.
        while (try? place.checkResourceIsReachable()) == true || (try? FileManager.default.attributesOfItem(atPath: place.path)) != nil {
            place = downloads.appendingPathComponent(kind.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(kind)")
            number += 1
        }
        // Written under a name of its own first, and marked, and only then given its
        // name: a file that could not be marked is never left in Downloads unmarked.
        var staged = downloads.appendingPathComponent(".hermes-bot-\(UUID().uuidString).download")
        do {
            try data.write(to: staged, options: .withoutOverwriting)
            var values = URLResourceValues()
            values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload, kLSQuarantineAgentNameKey as String: "Hermes Bot"]
            try staged.setResourceValues(values)
            // Read back from the file itself, not from what was just set on this value.
            staged.removeAllCachedResourceValues()
            guard try staged.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: staged, to: place)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return place
    }

    /// Only ever a plain name inside the folder, whatever the bot called the file: nothing
    /// that climbs out of it or hides in it, and no marks that make one name look like
    /// another in the Finder.
    nonisolated static func plainName(_ name: String) -> String {
        var safe = String(String.UnicodeScalarView(name.unicodeScalars.filter { scalar in
            // Not control characters, nor the marks that turn the direction of text.
            !CharacterSet.controlCharacters.contains(scalar) && !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
                && scalar.value != 0x200E && scalar.value != 0x200F
        }))
        safe = safe.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespaces)
        // Dots and spaces at the front together, so that neither is left by taking the other.
        while let first = safe.first, first == "." || first == " " { safe.removeFirst() }
        // Room left for a number and for the name the Finder allows.
        while safe.utf8.count > 200 {
            let kind = (safe as NSString).pathExtension, base = (safe as NSString).deletingPathExtension
            safe = kind.isEmpty || kind.utf8.count > 20 ? String(safe.dropLast()) : String(base.dropLast()) + "." + kind
        }
        return safe.isEmpty ? "File" : safe
    }

    static func text(for error: any Error) -> String {
        switch error {
        case GatewayError.unauthorized: "The gateway didn't let the app in. Open Settings to see why."
        case GatewayError.rejected(_, let message) where !message.isEmpty: message
        default: "Couldn't get this file from the gateway."
        }
    }
}

/// Makes pictures one at a time, off the main thread: unpacking even one large picture
/// takes a good deal of memory for a moment, and a chat may hold many.
actor PictureMaker {
    static let shared = PictureMaker()

    /// `most` is its longer side in pixels at the largest: small for a chip, since even a
    /// small picture is megabytes once unpacked.
    func picture(from data: Data, noLargerThan most: Int = 1400) -> NSImage? {
        HandedFile.picture(from: data, noLargerThan: most)
    }
}
