import Foundation
import HermesKit
import Testing
@testable import HermesBot

/// Files a bot hands over in its chat, against the pretend gateway.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FilesTests {
    @Test func aFileABotHandedOverIsReadFromTheGateway() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let bot = try #require(roster.bots.first { $0.name == "garden" })

        let picture = try await roster.file(at: "/demo/beds.png", from: bot)
        #expect(picture.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(picture.type == "image/png")
        #expect(picture.name == "beds.png")
        // A name with a space in it, as a bot may write it.
        #expect(try await roster.file(at: "/demo/planting calendar.pdf", from: bot).data.starts(with: Data("%PDF".utf8)))
        // One that is not there is said to be gone, not taken for a lost connection.
        let gone = GatewayError.rejected(code: 404, message: "This file is no longer on the gateway.")
        await #expect(throws: gone) { try await roster.file(at: "/demo/missing.png", from: bot) }
        #expect(HandedFile.text(for: gone) == "This file is no longer on the gateway.")
        // Asked for again, what was fetched is handed back whole: its kind and name too.
        #expect(try await roster.file(at: "/demo/beds.png", from: bot) == picture)
        // Once the bot has answered again, the file is fetched afresh: it may have been
        // written again under the same name.
        roster.answered(bot)
        #expect(try await roster.file(at: "/demo/beds.png", from: bot).data == picture.data)
        // One still on its way when the gateway is left hands nothing back: it would be
        // the old gateway's file, for whoever asks the next one for the same name.
        let late = Task { try await roster.file(at: "/demo/streamed.bin", from: bot) }
        try await Task.sleep(for: .milliseconds(30))
        await roster.signOut()
        await #expect(throws: GatewayError.notConnected) { try await late.value }
        // And nothing fetched from one gateway is kept once it is left.
        await #expect(throws: GatewayError.notConnected) { try await roster.file(at: "/demo/beds.png", from: bot) }
    }

    /// Two at a time, and one that is no longer wanted gives up its place without ever
    /// being fetched.
    @Test func aFetchNoLongerWantedGivesUpItsPlace() async throws {
        let pretend = try await SendingTests.Pretend()
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let bot = try #require(roster.bots.first { $0.name == "garden" })
        // Two slow ones take both places; a third waits behind them and is called off.
        let slow = (1...2).map { number in Task { try await roster.file(at: "/demo/endless.bin?\(number)", from: bot) } }
        try await Task.sleep(for: .milliseconds(20))
        let unwanted = Task { try await roster.file(at: "/demo/beds.png", from: bot) }
        try await Task.sleep(for: .milliseconds(20))
        unwanted.cancel()
        await #expect(throws: CancellationError.self) { try await unwanted.value }
        for task in slow { task.cancel() }
        for task in slow { _ = await task.result }
        // The places were given back: a fetch asked for now goes through.
        #expect(try await !roster.file(at: "/demo/beds.png", from: bot).data.isEmpty)
    }

    /// Called off before it has begun, or as it begins, a fetch ends at once: it is not
    /// left waiting on a download that is already over, holding one of the two places.
    @Test func aFetchCalledOffAsItStartsDoesNotHang() async throws {
        let pretend = try await SendingTests.Pretend()
        let client = GatewayClient(endpoint: GatewayEndpoint(pretend.address)!, token: "demo")
        for wait in [0, 0, 1, 2, 5, 0, 1, 3, 0, 2] {
            let fetch = Task { try await client.file(at: "/demo/endless.bin", forBot: "garden") }
            if wait > 0 { try await Task.sleep(for: .milliseconds(wait)) }
            fetch.cancel()
            await #expect(throws: CancellationError.self) { try await fetch.value }
        }
        // And one cancelled before it is even asked for.
        let never = Task { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.file(at: "/demo/beds.png", forBot: "garden").data.count
        }
        await #expect(throws: CancellationError.self) { try await never.value }
    }

    @Test func aFileLargerThanTheLimitIsNotTaken() async throws {
        let pretend = try await SendingTests.Pretend()
        let client = GatewayClient(endpoint: GatewayEndpoint(pretend.address)!, token: "demo")
        await #expect(throws: GatewayError.rejected(code: 413, message: "This file is too large to show here.")) {
            try await client.file(at: "/demo/beds.png", forBot: "garden", limit: 100)
        }
        // The same when the gateway does not say how large it is: it is stopped as it arrives.
        await #expect(throws: GatewayError.rejected(code: 413, message: "This file is too large to show here.")) {
            try await client.file(at: "/demo/endless.bin", forBot: "garden", limit: 50_000)
        }
        #expect(try await client.file(at: "/demo/streamed.bin", forBot: "garden", limit: 400_000).data.count == 200_000)
        // A token that is refused is that, and a file the gateway keeps to itself is that.
        let stranger = GatewayClient(endpoint: GatewayEndpoint(pretend.address)!, token: "wrong")
        await #expect(throws: GatewayError.unauthorized(gatewayUsesSignIn: false)) { try await stranger.file(at: "/demo/beds.png", forBot: "garden") }
        await #expect(throws: GatewayError.rejected(code: 403, message: "The gateway wouldn't give this file.")) {
            try await client.file(at: "/demo/kept.env", forBot: "garden")
        }
    }

    /// What is drawn is what the bytes are, not what the name says, and no larger than a
    /// chat needs however large the picture.
    @Test func aPictureIsKnownByItsBytesAndDrawnSmall() async throws {
        let pretend = try await SendingTests.Pretend()
        let client = GatewayClient(endpoint: GatewayEndpoint(pretend.address)!, token: "demo")
        let real = try await client.file(at: "/demo/beds.png", forBot: "garden")
        let drawn = try #require(HandedFile.picture(from: real.data))
        #expect(drawn.size.width == 170 && drawn.size.height == 105)
        // Not pictures, whatever they are called: words, a page, a vector drawing with a script.
        #expect(HandedFile.picture(from: Data("hello".utf8)) == nil)
        #expect(HandedFile.picture(from: Data("<html><script>alert(1)</script></html>".utf8)) == nil)
        #expect(HandedFile.picture(from: Data("<svg xmlns='http://www.w3.org/2000/svg'><script>1</script></svg>".utf8)) == nil)
        #expect(HandedFile.picture(from: Data()) == nil)
        // The start of a picture and no more: nothing to draw, and nothing that crashes.
        #expect(HandedFile.picture(from: real.data.prefix(40)) == nil)
    }

    /// The route is asked for the bot and the chat the file was handed over in.
    @Test func aFileIsAskedForByBotAndByChat() async throws {
        let pretend = try await SendingTests.Pretend()
        let client = GatewayClient(endpoint: GatewayEndpoint(pretend.address)!, token: "demo")
        #expect(try await !client.file(at: "/demo/beds.png", forBot: "garden", inChat: "chat-garden").data.isEmpty)
        await #expect(throws: GatewayError.rejected(code: 404, message: "This file is no longer on the gateway.")) {
            try await client.file(at: "/demo/beds.png", forBot: "garden", inChat: "no-such-chat")
        }
    }

    @Test func onlyPicturesAreDrawnAndNeverOnesThatCanCarryAScript() {
        for name in ["/a/b.png", "chart.JPG", "x.jpeg", "y.gif", "z.webp", "p.heic"] { #expect(HandedFile.isPicture(name), "\(name)") }
        for name in ["/a/b.svg", "page.html", "doc.pdf", "run.command", "app.app", "noending", "archive.png.zip"] { #expect(!HandedFile.isPicture(name), "\(name)") }
    }

    /// Saved under a plain name inside the folder, never over what is there, and marked as
    /// having come from outside so macOS asks before it is first opened.
    @Test func aSavedFileKeepsToItsFolderAndReplacesNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try HandedFile.write(Data("one".utf8), named: "notes.txt", into: folder)
        let second = try HandedFile.write(Data("two".utf8), named: "notes.txt", into: folder)
        #expect(first.lastPathComponent == "notes.txt")
        #expect(second.lastPathComponent == "notes 2.txt")
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        // A name that tries to climb out, or to hide, is only ever a plain name in the folder.
        let odd = try HandedFile.write(Data("x".utf8), named: "../../.hidden/evil.command", into: folder)
        #expect(odd.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(!odd.lastPathComponent.hasPrefix("."))
        #expect(try HandedFile.write(Data(), named: "", into: folder).lastPathComponent == "File")
        // Marks that would make one name read as another in the Finder are taken out,
        // and a name too long for a folder is cut, keeping its ending.
        #expect(HandedFile.plainName("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(HandedFile.plainName("  a\nb\0c.txt ") == "abc.txt")
        #expect(HandedFile.plainName(".   .txt") == "txt")
        let long = HandedFile.plainName(String(repeating: "x", count: 400) + ".pdf")
        #expect(long.utf8.count <= 200 && long.hasSuffix(".pdf"))
        let marked = try first.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(marked?[kLSQuarantineAgentNameKey as String] as? String == "Hermes Bot")
    }
}
