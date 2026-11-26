import AppKit
import Foundation
import HermesBotUI
import HermesKit
import SwiftUI
import Testing
@testable import HermesBot

/// What a page in a chat sends its bot, against the pretend gateway: sent as no one's
/// bubble, shown on the line under the page, and the page read again afterwards.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PageSendTests {
    private static let page = "/demo/yield.html"

    private func open(_ pretend: SendingTests.Pretend) async throws -> (RosterModel, Bot, ChatModel, String) {
        let roster = RosterModel(gateway: (pretend.address, "demo"))
        await roster.load()
        let bot = try #require(roster.bots.first { $0.name == "garden" })
        let chat = roster.chat(for: bot)
        await chat.load(bot, from: roster)
        #expect(chat.phase == .loaded)
        // The page's place: the reply it stands in, and its block there.
        let reply = try #require(chat.items.first { if case .bot(_, let text) = $0 { text.contains("::preview") } else { false } })
        let block = try #require(chat.styled[reply.id]?.first { if case .page = $0.kind { $0.raw == Self.page } else { false } })
        return (roster, bot, chat, ChatModel.pageKey(reply.id, block.id))
    }

    /// The chat on screen, as it is in the app, and the pages in it.
    @MainActor
    private final class OnScreen {
        let window: NSWindow

        @MainActor init(_ bot: Bot, _ roster: RosterModel, height: CGFloat = 700) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: ChatView(bot: bot, roster: roster).frame(width: 640, height: height))
            window.orderFrontRegardless()
        }

        @MainActor func pages(_ view: NSView? = nil) -> [PageView] {
            let view = view ?? window.contentView!
            return (view as? PageView).map { [$0] } ?? view.subviews.flatMap(pages)
        }

        @MainActor static func text(of page: PageView) async -> String {
            await withCheckedContinuation { done in
                page.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, _ in done.resume(returning: value as? String ?? "") }
            }
        }

        /// The page's words once they hold `wanted`, or as they last were.
        @MainActor func page(saying wanted: String) async throws -> (PageView?, String) {
            var said = ""
            for _ in 0..<240 {
                for page in pages() {
                    said = await Self.text(of: page)
                    if said.contains(wanted) { return (page, said) }
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            return (nil, said)
        }

        @MainActor func close() { window.orderOut(nil) }
    }

    private func bubbles(_ chat: ChatModel) -> [String] {
        chat.items.compactMap { if case .user(_, let text) = $0 { text } else { nil } }
    }

    /// A hidden message in the stored chat is no one's bubble; it is the line under the
    /// page above it.
    @Test func aHiddenMessageInTheChatIsTheLineUnderThePageAndNoBubble() async throws {
        let pretend = try await SendingTests.Pretend()
        let (_, _, chat, key) = try await open(pretend)
        #expect(!bubbles(chat).contains("Sort the beds by yield"))
        #expect(bubbles(chat).contains("how did each bed do last year?"))
        #expect(chat.pageLines.mapValues(\.words) == [key: "Sort the beds by yield"])
        #expect(chat.pageLines[key]?.status == nil)
    }

    /// Which page a hidden message belongs to, when Hermes keeps nothing to say.
    @Test func aHiddenMessageBelongsToTheNearestPageAboveIt() {
        let messages = [
            ChatMessage(id: 1, role: "user", text: "Before any page", displayKind: "hidden"),
            ChatMessage(id: 2, role: "assistant", text: "One\n\n::preview{file=\"a.html\"}\n\nand two\n\n::preview{file=\"b.html\"}"),
            ChatMessage(id: 3, role: "user", text: "From b", displayKind: "hidden"),
            ChatMessage(id: 4, role: "user", text: "said aloud"),
            ChatMessage(id: 5, role: "user", text: "[System: housekeeping]", displayKind: "hidden"),
            ChatMessage(id: 6, role: "user", text: String(repeating: "x", count: 501), displayKind: "hidden"),
            ChatMessage(id: 7, role: "assistant", text: "No page here."),
            ChatMessage(id: 8, role: "user", text: "  From b again  ", displayKind: "hidden"),
        ]
        let reply = TranscriptItem.bot(id: 2, text: "").id
        let styled = [reply: ReplyFormat.blocks(of: messages[1].text).map { block in
            StyledBlock(id: block.id, kind: block.kind, raw: block.text, text: AttributedString(block.text))
        }]
        let b = styled[reply]?.last { if case .page = $0.kind { true } else { false } }
        let lines = ChatModel.pageLines(in: messages, styled: styled)
        #expect(lines.mapValues(\.words) == [ChatModel.pageKey(reply, b?.id ?? -1): "From b again"])
        #expect(lines.values.first?.path == "b.html")
    }

    /// Sent from a page: no bubble, the composer and what is in it left alone, the line
    /// shows the words at once and Updated once the page has been read again past what was
    /// kept of it; and after the chat is opened again, the line is still there.
    @Test func aPagesMessageGoesHiddenAndThePageIsReadAgain() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        let before = try #require(String(data: try await roster.file(at: Self.page, from: bot).data, encoding: .utf8))
        #expect(before.contains("Kilograms by bed"))
        chat.draft = "half typed"
        let words = "Show the yields in pounds quick"
        let took = Task { await chat.send(fromPage: words, at: key, showing: Self.page, to: bot, through: roster, seen: { true }) }
        for _ in 0..<40 where chat.pageLines[key]?.words != words { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.pageLines[key]?.status == .updating)
        #expect(await took.value)
        while chat.isWorking {
            #expect(!bubbles(chat).contains(words))
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!bubbles(chat).contains(words))
        #expect(chat.draft == "half typed")
        #expect(chat.sendProblem == nil)
        // The bot is done; the page is to be read again, and has not yet been.
        #expect((chat.rereads[Self.page] ?? 0) > 0)
        #expect(chat.pageLines[key]?.status == .updating)
        // What was kept is the page as it was.
        #expect(try await roster.file(at: Self.page, from: bot).data == Data(before.utf8))
        // A page first shown now, as after picking another bot and coming back, is read
        // past that, shows the page as it is now, and the line says so.
        let screen = OnScreen(bot, roster)
        defer { screen.close() }
        let (_, said) = try await screen.page(saying: "Updated for")
        #expect(said.contains("Updated for “\(words)”"))
        for _ in 0..<80 where chat.pageLines[key]?.status != .updated { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.pageLines[key]?.words == words)
        #expect(chat.pageLines[key]?.status == .updated)
        #expect(chat.pageLines.count == 1)

        // Opened again: the last thing the page sent, from the stored chat.
        let (_, _, again, sameKey) = try await open(pretend)
        #expect(sameKey == key)
        #expect(again.pageLines.mapValues(\.words) == [key: words])
        #expect(again.pageLines[key]?.status == nil)
        #expect(!bubbles(again).contains(words))
    }

    /// A page's message still waiting its turn when a change to approvals is asked for is
    /// held back: sent then, it would run under the approvals being left.
    @Test func aPagesMessageWaitingItsTurnIsHeldWhileApprovalsChange() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        let words = "Show the yields in pounds"
        let took = Task { await chat.send(fromPage: words, at: key, showing: Self.page, to: bot, through: roster, seen: { true }) }
        for _ in 0..<40 where chat.pageLines[key]?.words != words { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.pageLines[key]?.words == words)
        // A change to approvals asked for while the message waits for its page's turn, as
        // `/approvals manual` does, and still on its way when that turn comes.
        chat.approvalsChanging += 1
        let went = await took.value
        chat.approvalsChanging -= 1
        #expect(!went)
        #expect(chat.sendProblem == ChatModel.heldForApprovals)
        #expect(chat.pageLines[key]?.words != words)
        try await Task.sleep(for: .milliseconds(300))
        let (_, _, again, _) = try await open(pretend)
        #expect(again.pageLines[key]?.words != words)
    }

    /// Words a page sends while the bot is answering join the answer, as typed ones do,
    /// and are no bubble either.
    @Test func aPagesMessageMidAnswerJoinsItHidden() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        chat.draft = "slow one"
        chat.send(to: bot, through: roster)
        for _ in 0..<200 where !chat.canAddToTurn { try await Task.sleep(for: .milliseconds(20)) }
        #expect(chat.canAddToTurn)
        let words = "Sort them the other way"
        #expect(await chat.send(fromPage: words, at: key, showing: Self.page, to: bot, through: roster, seen: { true }))
        #expect(!bubbles(chat).contains(words))
        #expect(chat.draft.isEmpty)
        for _ in 0..<600 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!bubbles(chat).contains(words))
        #expect(bubbles(chat).contains("slow one"))
        #expect(chat.pageLines[key]?.words == words)
        // It waited its turn rather than steer, so it is stored hidden and stays so.
        let (_, _, again, _) = try await open(pretend)
        #expect(!bubbles(again).contains(words))
        #expect(again.pageLines[key]?.words == words)
    }

    /// Words typed are the person's, even the same words a page sent.
    @Test func theSameWordsTypedAreABubble() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        let words = "Refresh quick"
        #expect(await chat.send(fromPage: words, at: key, showing: Self.page, to: bot, through: roster, seen: { true }))
        for _ in 0..<400 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
        chat.draft = words
        chat.send(to: bot, through: roster)
        for _ in 0..<400 where chat.isWorking || !bubbles(chat).contains(words) { try await Task.sleep(for: .milliseconds(25)) }
        let (_, _, again, _) = try await open(pretend)
        #expect(bubbles(again).filter { $0 == words }.count == 1)
    }

    /// Each page keeps its own line, whatever another sent; one refused gives way to the
    /// one before it.
    @Test func linesAreEachPagesOwn() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        #expect(await chat.send(fromPage: "Refresh quick", at: key, showing: Self.page, to: bot, through: roster, seen: { true }))
        for _ in 0..<400 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.pageLines[key]?.words == "Refresh quick")
        #expect(!(await chat.send(fromPage: "refuse this message", at: key, showing: Self.page, to: bot, through: roster, seen: { true })))
        for _ in 0..<400 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.pageLines[key]?.words == "Refresh quick")

        // Two pages sending the same words keep a line each; a stored line with those words
        // from before the first send from here is another page's and stays; one stored
        // since could be ours, and gives way to it.
        typealias Line = ChatModel.PageLine
        let sent = ["a#1": Line(words: "Refresh", path: "p.html", send: 1), "b#1": Line(words: "Refresh", path: "p.html", send: 2)]
        let read = ["c#1": Line(words: "Refresh", path: "p.html", row: 10), "a#1": Line(words: "Refresh", path: "p.html", row: 30), "d#1": Line(words: "Refresh", path: "p.html", row: 31)]
        let lines = ChatModel.merged(read: read, sent: sent, since: 20)
        #expect(Set(lines.keys) == ["a#1", "b#1", "c#1"])
        #expect(lines["a#1"]?.send == 1)
        #expect(ChatModel.merged(read: read, sent: [:], since: nil).count == 3)
    }

    /// Refused by the gateway: the page is told so, the line goes back to what it was, and
    /// nothing lands in the composer.
    @Test func aRefusedPagesMessageLeavesNoLineAndNothingTyped() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        let was = chat.pageLines
        #expect(!(await chat.send(fromPage: "refuse this message", at: key, showing: Self.page, to: bot, through: roster, seen: { true })))
        for _ in 0..<200 where chat.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        #expect(chat.pageLines == was)
        #expect(chat.draft.isEmpty)
        #expect(!bubbles(chat).contains("refuse this message"))
    }

    /// A page whose line would be out of sight, or covered, or in a window not showing,
    /// cannot send: nothing goes unseen.
    @Test func aPageCanSendOnlyWithItsLineInSight() async throws {
        let inFront = PageFrame.Keeper.inFront
        PageFrame.Keeper.inFront = { $0.isVisible }
        defer { PageFrame.Keeper.inFront = inFront }
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        /// The page in a window of `height`, in a chat whose clear part is `clear` of it.
        func show(height: CGFloat, clear: CGFloat) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: GeometryReader { _ in
                ScrollView {
                    VStack {
                        InlinePage(path: Self.page, bot: bot, roster: roster, chat: chat, key: key)
                        Color.clear.frame(height: 2000)
                    }
                }
                .environment(\.chatClear, 0...clear)
            }
            .coordinateSpace(name: ChatView.pane)
            .frame(width: 560))
            window.orderFrontRegardless()
            return window
        }
        func pages(_ view: NSView) -> [PageView] { (view as? PageView).map { [$0] } ?? view.subviews.flatMap(pages) }
        func send(_ words: String, in window: NSWindow) async throws -> String {
            var page: PageView?
            for _ in 0..<200 {
                if let found = pages(window.contentView!).first,
                   await withCheckedContinuation({ done in found.evaluateJavaScript("document.querySelectorAll('.bar').length") { value, _ in done.resume(returning: (value as? Int) == 4) } }) {
                    page = found
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            let shown = try #require(page)
            try await Task.sleep(for: .seconds(1.2))
            _ = await withCheckedContinuation { done in
                shown.evaluateJavaScript("window.ack = null; hermes.send('\(words)').then(function (a) { window.ack = a.ok ? 'ok' : a.error; }); 1") { _, _ in done.resume() }
            }
            for _ in 0..<120 {
                let ack = await withCheckedContinuation { done in shown.evaluateJavaScript("window.ack") { value, _ in done.resume(returning: value as? String) } }
                if let ack { return ack }
                try await Task.sleep(for: .milliseconds(25))
            }
            return "none"
        }
        // Taller than the window: its foot, where the line goes, is out of sight.
        let short = show(height: 160, clear: 160)
        #expect(try await send("Out of sight", in: short) == "undelivered")
        short.orderOut(nil)
        // All of it in the window, but its foot under what floats over the chat.
        let covered = show(height: 700, clear: 200)
        #expect(try await send("Under the message box", in: covered) == "undelivered")
        covered.orderOut(nil)
        // In sight: it goes, and shows.
        let clear = show(height: 700, clear: 700)
        #expect(try await send("In sight quick", in: clear) == "ok")
        #expect(chat.pageLines[key]?.words == "In sight quick")
        for _ in 0..<400 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
        // The same, with its window no longer showing.
        clear.orderOut(nil)
        #expect(try await send("Window gone", in: clear) == "undelivered")
        #expect(chat.pageLines[key]?.words == "In sight quick")
    }

    /// While a page's message is on its way, no page can move its line out of sight by
    /// changing its height; the height it asked for is given once the message has gone.
    @Test func pagesKeepTheirHeightWhileAMessageIsOnItsWay() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        let screen = OnScreen(bot, roster)
        defer { screen.close() }
        let page = try #require(try await screen.page(saying: "Kilograms").0)
        try await Task.sleep(for: .milliseconds(300))
        let before = page.frame.height
        // As if a page had just sent: this one waits about a second to go, time enough to see it held.
        ChatModel.lastPageMessage = .now
        let took = Task { await chat.send(fromPage: "Hold still quick", at: key, showing: Self.page, to: bot, through: roster, seen: { true }) }
        for _ in 0..<40 where !chat.holdsPages { try await Task.sleep(for: .milliseconds(5)) }
        #expect(chat.holdsPages)
        // The page grows meanwhile, and is not given it.
        _ = await withCheckedContinuation { done in page.evaluateJavaScript("document.body.style.height = '900px'; 1") { _, _ in done.resume() } }
        try await Task.sleep(for: .milliseconds(180))
        #expect(chat.holdsPages)
        #expect(abs(page.frame.height - before) < 1)
        // Held shorter than it asked, it scrolls itself rather than handing scrolling to the chat.
        #expect(!page.fits)
        #expect(await took.value)
        // Once it has gone, the page has its way.
        for _ in 0..<200 where chat.holdsPages { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!chat.holdsPages)
        for _ in 0..<80 where page.frame.height < 800 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(page.frame.height > 800)
        #expect(page.fits)
        for _ in 0..<400 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
    }

    /// The bot may write again only a file beside the page: read again after the exchange,
    /// and when the page is shown afresh (as after picking another bot and coming back),
    /// the page runs the new one, not what was kept of the old.
    @Test func aScriptBesideThePageWrittenAgainIsRunAfterwards() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, _) = try await open(pretend)
        let reply = try #require(chat.items.first { if case .bot(_, let text) = $0 { text.contains("water.html") } else { false } })
        let block = try #require(chat.styled[reply.id]?.first { if case .page = $0.kind { $0.raw == "/demo/charts/water.html" } else { false } })
        let water = ChatModel.pageKey(reply.id, block.id)
        // Shown once, so the script beside it is kept as it was.
        do {
            let screen = OnScreen(bot, roster)
            defer { screen.close() }
            #expect(try await screen.page(saying: "Litres a week").0 != nil)
        }
        // The bot writes only the script again, while the page is not on screen.
        #expect(await chat.send(fromPage: "Draw the line again quick", at: water, showing: "/demo/charts/water.html", to: bot, through: roster, seen: { true }))
        for _ in 0..<400 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
        #expect((chat.rereads["/demo/charts/water.html"] ?? 0) > 0)
        // Shown afresh: the new script runs. Tall enough that the page stays in sight as the
        // bot's replies come in below it.
        let screen = OnScreen(bot, roster, height: 1800)
        defer { screen.close() }
        let (_, said) = try await screen.page(saying: "Drawn again 1")
        #expect(said.contains("Drawn again 1"))
        for _ in 0..<80 where chat.pageLines[water]?.status != .updated { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.pageLines[water]?.status == .updated)
        // On screen as the bot writes only the script again: the page, the same as it was,
        // is drawn again with the new one when the exchange ends.
        #expect(await chat.send(fromPage: "Draw the line once more quick", at: water, showing: "/demo/charts/water.html", to: bot, through: roster, seen: { true }))
        let (_, again) = try await screen.page(saying: "Drawn again 2")
        #expect(again.contains("Drawn again 2"))
    }

    /// Asked in an ordinary message, the bot writes a page's file again and shows it again in
    /// its reply: the new reply's page and the older one both show the file as it is now,
    /// without starting the app again.
    @Test func aPageWrittenAgainInAnOrdinaryReplyIsShownFresh() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, _) = try await open(pretend)
        let screen = OnScreen(bot, roster, height: 1800)
        defer { screen.close() }
        // The page as it was, fetched and kept.
        #expect(try await screen.page(saying: "Kilograms by bed").0 != nil)
        chat.draft = "add a button quick"
        chat.send(to: bot, through: roster)
        for _ in 0..<400 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.items.contains { if case .bot(let id, let text) = $0 { id >= 0 && text.contains("with a button") } else { false } })
        // Both pages showing the file, the new reply's and the older one, show it as it is now.
        var said: [String] = []
        for _ in 0..<240 {
            said = []
            for page in screen.pages() { said.append(await OnScreen.text(of: page)) }
            let yields = said.filter { $0.contains("Bed A") }
            if yields.count == 2, yields.allSatisfy({ $0.contains("With a button now") }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let yields = said.filter { $0.contains("Bed A") }
        #expect(yields.count == 2)
        #expect(yields.allSatisfy { $0.contains("With a button now") }, "\(yields)")
    }

    /// A newer reply that names the page's file only as a file handed over (`MEDIA:`) still
    /// has the page showing it read it again.
    @Test func aPageWhoseFileANewReplyHandsOverIsShownFresh() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, _) = try await open(pretend)
        let screen = OnScreen(bot, roster, height: 1800)
        defer { screen.close() }
        #expect(try await screen.page(saying: "Kilograms by bed").0 != nil)
        chat.draft = "hand me the page file quick"
        chat.send(to: bot, through: roster)
        for _ in 0..<400 where chat.isWorking { try await Task.sleep(for: .milliseconds(25)) }
        let (_, said) = try await screen.page(saying: "Handed over now")
        #expect(said.contains("Handed over now"))
    }

    /// Asked again just before the message goes: a page that went out of sight meanwhile
    /// sends nothing, and leaves no line.
    @Test func aPageOutOfSightByTheTimeItsMessageGoesSendsNothing() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, key) = try await open(pretend)
        var seen = true
        let took = Task { await chat.send(fromPage: "Gone by then", at: key, showing: Self.page, to: bot, through: roster, seen: { seen }) }
        for _ in 0..<40 where chat.pageLines[key]?.words != "Gone by then" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.pageLines[key]?.words == "Gone by then")
        seen = false
        #expect(!(await took.value))
        for _ in 0..<200 where chat.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        #expect(chat.pageLines[key]?.words != "Gone by then")
        #expect(chat.sendProblem == nil)
        let (_, _, again, _) = try await open(pretend)
        #expect(again.pageLines[key]?.words != "Gone by then")
    }

    /// The page in the chat, sent from by a real click, is shown again once the bot has
    /// written it again, with the line under it.
    @Test func thePageIsShownAgainWhenItsFileChanges() async throws {
        let pretend = try await SendingTests.Pretend()
        let (roster, bot, chat, _) = try await open(pretend)
        let inFront = PageFrame.Keeper.inFront
        PageFrame.Keeper.inFront = { $0.isVisible }
        defer { PageFrame.Keeper.inFront = inFront }
        let screen = OnScreen(bot, roster)
        defer { screen.close() }
        let window = screen.window
        let page = try #require(try await screen.page(saying: "Kilograms").0)
        // The line from the stored chat is under it.
        #expect(chat.pageLines.values.map(\.words) == ["Sort the beds by yield"])
        // The button in it, clicked for real.
        let button = try #require(await withCheckedContinuation { (done: CheckedContinuation<NSPoint?, Never>) in
            page.evaluateJavaScript("var r = document.querySelector('[data-hermes-send]').getBoundingClientRect(); [r.left + r.width / 2, r.top + r.height / 2]") { value, _ in
                let at = value as? [Double]
                done.resume(returning: at.map { NSPoint(x: $0[0], y: page.isFlipped ? $0[1] : page.bounds.height - $0[1]) })
            }
        })
        // Tried again if a click did not take, or met another test's page within the second.
        for _ in 0..<6 where !chat.isWorking {
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: kind, location: page.convert(button, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
                if kind == .leftMouseDown { page.mouseDown(with: event) } else { page.mouseUp(with: event) }
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        #expect(chat.pageLines.values.map(\.words) == ["Show the yields in pounds"])
        #expect(chat.pageLines.values.first?.status == .updating)
        // Drawn again once the bot has written it, and says so.
        for _ in 0..<600 where chat.pageLines.values.first?.status != .updated { try await Task.sleep(for: .milliseconds(25)) }
        #expect(chat.pageLines.values.first?.status == .updated)
        let (_, redrawn) = try await screen.page(saying: "Updated for")
        #expect(redrawn.contains("Updated for “Show the yields in pounds”"))
    }
}
