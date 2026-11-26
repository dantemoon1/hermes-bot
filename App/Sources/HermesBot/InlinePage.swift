import AppKit
import HermesBotUI
import HermesKit
import SwiftUI
import WebKit

/// A page a bot wrote and placed in its reply with `::preview{file="page.html"}`: a chart,
/// or some small thing to click, shown where it stands and as tall as what is in it.
///
/// What a bot writes is not to be trusted, so the page is kept to itself (`PageFrame`). A
/// page that cannot be shown so is a file like any other.
struct InlinePage: View {
    let path: String
    let bot: Bot
    let roster: RosterModel
    /// The chat it stands in, which sends what the page asks to send, and its place there
    /// (`ChatModel.pageKey`). Without a chat the page can send nothing.
    var chat: ChatModel?
    var key = ""
    /// The reply it stands in is finished. Until then the file may be half written, and
    /// is not fetched.
    var isSettled = true
    /// On screen, or near it. A page far up a long chat is not fetched until it is.
    @State private var isInSight = false
    @State private var page: (source: String, files: PageFiles, rules: WKContentRuleList, store: WKWebsiteDataStore)?
    /// It could not be shown as a page, and is a file like any other from then on,
    /// with why said on it.
    @State private var showsCard = false
    @State private var why = "This page can't be shown here."
    /// As the page says it is, once it has said.
    @State private var height: CGFloat?
    @State private var partMissing = false
    /// Which reading of the file the page shows (`ChatModel.rereads`).
    @State private var reading = 0
    /// The height the page asked for while heights were held, given it once they are not,
    /// and likewise the notice that part of it could not be had.
    @State private var heldHeight: CGFloat?
    @State private var heldPartMissing = false
    /// The page ended while heights were held: it becomes a card once they are not.
    @State private var heldCard = false
    /// Where the line under the page is, or will be, in the chat (`ChatView.pane`).
    @State private var lineAt: CGRect?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chatClear) private var chatClear
    @Environment(\.isCovered) private var isCovered

    /// The page has been laid out, and where its line is, or will be, is in the part of the
    /// chat nothing floats over, with no panel over the window. Only then may the page send,
    /// so that what it sends is seen as it goes. Whether the window itself is in sight is
    /// for the keeper to ask, at the moment of sending (`Keeper.canShowLine`).
    private var lineInSight: Bool {
        guard height != nil || showsCard, !isCovered, let chatClear, let lineAt, lineAt.height > 0 else { return false }
        return lineAt.minY >= chatClear.lowerBound && lineAt.maxY <= chatClear.upperBound
    }

    /// The most a page may weigh to be shown. Anything larger is a file.
    static let limit = 2_000_000

    var body: some View {
        let theme = Theme(scheme)
        VStack(alignment: .leading, spacing: 6) {
            if showsCard {
                HandedFile(path: path, bot: bot, roster: roster, isSettled: isSettled, why: why)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        if height == nil {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(theme.codeBlock)
                                .overlay(ProgressView().controlSize(.small))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.bubbleEdge))
                                .accessibilityLabel("Loading page, \(ReplyFormat.name(of: path))")
                        }
                        if let page {
                            PageFrame(html: PageFrame.document(page.source, scheme: scheme), files: page.files, rules: page.rules, store: page.store, sends: sends, lineInSight: lineInSight, heldAt: chat?.holdsPages == true ? (height ?? 120) : nil) { news in
                                switch news {
                                // Held while a page's message is on its way, so no page can move
                                // the line out of sight once it has been seen to be in sight.
                                case .height(let said): if chat?.holdsPages == true { heldHeight = said } else { height = said }
                                // Nor can the notice above the line push the line down meanwhile.
                                case .partMissing: if chat?.holdsPages == true { heldPartMissing = true } else { partMissing = true }
                                case .ended: if chat?.holdsPages == true { heldCard = true } else { showsCard = true }
                                }
                            }
                            // Not seen until it has said how tall it is.
                            .opacity(height == nil ? 0 : 1)
                        }
                    }
                    .frame(maxWidth: PageFrame.widest)
                    .frame(height: height ?? 120)
                    if partMissing {
                        Text("Part of this page couldn't be loaded here.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.top, 2)
            }
            // Under the page, or under the card it became: what was sent stays in sight.
            if let line = chat?.pageLines[key] {
                SentLine(line: line, theme: theme)
            }
        }
        // Where the line is, or, before there is one, the room just below where it will go.
        .overlay(alignment: .bottom) {
            let hasLine = chat?.pageLines[key] != nil
            Color.clear.frame(height: 20)
                .alignmentGuide(.bottom) { hasLine ? $0[.bottom] : $0[.top] }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatView.pane)) } action: { lineAt = $0 }
                .allowsHitTesting(false)
        }
        .padding(.bottom, showsCard ? 0 : 2)
        .onChange(of: chat?.holdsPages == true) { _, holds in
            guard !holds else { return }
            if let wanted = heldHeight {
                height = wanted
                heldHeight = nil
            }
            if heldPartMissing {
                partMissing = true
                heldPartMissing = false
            }
            if heldCard {
                showsCard = true
                heldCard = false
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { isInSight = $0 }
        // Loaded again in the other colours, where it may ask for other things.
        .onChange(of: scheme) { partMissing = false }
        // Fetched once the reply is finished and the page is in sight, and again only when
        // the bot may have written it again.
        .task(id: Fetch(isReady: isSettled && isInSight, isCard: showsCard, reading: chat?.rereads[path] ?? 0)) {
            let wanted = chat?.rereads[path] ?? 0
            // A card has no page to read again: its line says no more than that it was sent.
            if showsCard {
                if wanted != reading {
                    reading = wanted
                    chat?.pageWasRead(at: key, well: false)
                }
                return
            }
            guard isSettled, isInSight else { return }
            if let shown = page {
                guard wanted != reading else { return }
                do {
                    // The page and the files beside it, all past what was kept and from the one
                    // gateway: the bot may have written any of them again.
                    let scope = roster.filesScope
                    let file = try await roster.file(at: path, from: bot, limit: Self.limit, within: scope, reading: wanted)
                    let source = String(data: file.data, encoding: .utf8)
                    let files = if let source { try await PageFiles.fetch(for: source, at: path, from: bot, roster: roster, within: scope, reading: wanted) } else { PageFiles() }
                    // Nothing is taken as read until all of it has come: one left half way, by
                    // scrolling away, is read again when it is next in sight.
                    guard !Task.isCancelled else { return }
                    reading = wanted
                    // Shown again only if it changed. One that can no longer be read stays as it was.
                    if let source, source != shown.source || files != shown.files {
                        // What the page as it was could not have is not this one's to say.
                        partMissing = false
                        heldPartMissing = false
                        page = (source, files, shown.rules, shown.store)
                    }
                    chat?.pageWasRead(at: key, well: source != nil)
                } catch is CancellationError {
                } catch {
                    reading = wanted
                    chat?.pageWasRead(at: key, well: false)
                }
                return
            }
            do {
                // Without every one of the ways a page is kept in, it is not shown.
                guard PageFrame.canKeepIn, let store = PageFrame.closedStore(), let rules = await PageFrame.rules.value else {
                    showsCard = true
                    return
                }
                // The page and the files beside it, all from the one gateway; past what was kept
                // when the bot may have written it again since.
                let scope = roster.filesScope
                let file = try await roster.file(at: path, from: bot, limit: Self.limit, within: scope, reading: wanted)
                guard !Task.isCancelled else { return }
                guard let source = String(data: file.data, encoding: .utf8) else {
                    showsCard = true
                    if wanted > 0 { chat?.pageWasRead(at: key, well: false) }
                    return
                }
                // Scripts and stylesheets it names beside it, put in its place.
                // Past what was kept too, for a page shown afresh after the bot may have
                // written the files beside it again.
                let files = try await PageFiles.fetch(for: source, at: path, from: bot, roster: roster, within: scope, reading: wanted)
                guard !Task.isCancelled else { return }
                page = (source, files, rules, store)
                reading = wanted
                if wanted > 0 { chat?.pageWasRead(at: key) }
            } catch is CancellationError {
            } catch {
                why = HandedFile.text(for: error)
                showsCard = true
                if wanted > 0 { chat?.pageWasRead(at: key, well: false) }
            }
        }
    }

    private struct Fetch: Equatable {
        let isReady: Bool
        let isCard: Bool
        let reading: Int
    }

    /// What the page asks to send, sent in its chat with the keeper's word on whether the
    /// page is still in sight.
    private var sends: PageFrame.Sends? {
        guard let chat else { return nil }
        return { [bot, roster, key, path] words, seen in
            await chat.send(fromPage: words, at: key, showing: path, to: bot, through: roster, seen: seen)
        }
    }
}

/// The line under a page that sent its bot something, drawn by the app and never by the
/// page: the words exactly as sent, and how the page is getting on with them.
struct SentLine: View {
    let line: ChatModel.PageLine
    let theme: Theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9.5, weight: .medium))
                // On one line, so nothing can stand below it unseen; all of it on hover.
                Text(verbatim: "Sent \u{201C}\(Self.oneLine(line.words))\u{201D}")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(line.words)
            Spacer(minLength: 0)
            // Never cut or wrapped: the words give way to it.
            Group {
                switch line.status {
                case .updating?: SweptText("Updating…", theme: theme, size: 11.5, isMoving: !reduceMotion)
                case .updated?: Text("Updated").lineLimit(1)
                case nil: EmptyView()
                }
            }
            .fixedSize()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(theme.secondaryText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sent \(line.words)" + (line.status == .updating ? ", updating" : line.status == .updated ? ", updated" : ""))
    }

    /// The words on one line: every run of spaces, tabs and line breaks as one space, so
    /// none can push the rest out of sight.
    static func oneLine(_ words: String) -> String {
        words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The frame a bot's page is shown in, and everything that keeps the page inside it.
///
/// A page may run its own scripts, since a chart is drawn by one. It may do nothing else:
/// - It reaches no network at all, the gateway and this Mac's own network included. Its
///   own first line is a policy that allows nothing from anywhere (`policy`), a rule
///   given to the web view turns every request away whatever the page says (`rules`),
///   and the ways round both are turned off: calls between browsers, the camera and
///   microphone, and connections opened ahead of a link being followed (`closedStore`).
/// - It is handed to the web view as words, never as an address: it comes from nowhere,
///   so it shares nothing with the gateway, with files on this Mac or with another page,
///   and what it stores is gone when it is.
/// - It can go nowhere. The frame loads the page once and refuses everything after.
///   A link to the web opens in the person's browser when the person clicks it or
///   presses Return on it, once for each time, and never because a script did.
/// - It is told nothing but the app's colours and font, and given nothing but the files
///   it names beside it (`PageFiles`), which the app fetched for it. It says nothing back
///   but how tall it is and what it sends its bot. It takes the keyboard only when clicked.
/// - It can send its bot a message as in Hermes's own app:
///   by a real click on something marked `data-hermes-send`, or by `window.hermes.send`
///   from its scripts. Every one is shown on the line under it, which the app draws, and
///   goes only while that line is in sight in a window in front (`Keeper.canShowLine`),
///   asked when the page sends and again just before the message goes; one a second at
///   most in the whole app. It is told only whether it went (`Keeper.admit`).
struct PageFrame: NSViewRepresentable {
    let html: String
    var files = PageFiles()
    let rules: WKContentRuleList
    let store: WKWebsiteDataStore
    /// Sends the bot what the page asked to send, and says whether it went. Nil where the
    /// page has no chat to send in.
    var sends: Sends?
    /// Where the line under the page goes is in the clear part of the chat.
    var lineInSight = false
    /// The height the frame is held at while heights are held, which may be less than the
    /// page asked for: then it scrolls itself.
    var heldAt: CGFloat?
    let tell: (News) -> Void

    /// Sends words, asking the second, just before they go, whether the page is still in
    /// sight with its line.
    typealias Sends = (String, @escaping @MainActor () -> Bool) async -> Bool

    enum News: Equatable {
        case height(CGFloat)
        /// Something it asked for could not be had: a file beside it, or anything from the
        /// network. Only as the web view itself makes it known, or as our own script
        /// finds it.
        case partMissing
        /// The page's process ended: it crashed, or used more than it may.
        case ended
    }

    /// As Hermes tells a bot: the frame is as wide as the chat up to 960, and as tall as
    /// what is in it up to 1200, past which the page scrolls.
    static let widest: CGFloat = 960
    static let tallest: CGFloat = 1200

    /// Allows a page what is written in it and nothing from anywhere else.
    static let policy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data:; font-src data:; media-src data:; base-uri 'none'; form-action 'none'"

    /// Turns away every request a page makes, whatever its own policy has come to.
    static let rules: Task<WKContentRuleList?, Never> = Task { @MainActor in
        try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "hermes-bot-page", encodedContentRuleList: #"[{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}}]"#
        )
    }

    /// Settings the web view has no public name for, by the names it answers to.
    private static let turnedOff = [("peerConnectionEnabled", "_setPeerConnectionEnabled:"), ("mediaDevicesEnabled", "_setMediaDevicesEnabled:")]

    /// Whether calls between browsers can be turned off, which neither the policy nor the
    /// rule covers. Where they cannot, no page is shown; nor where `closedStore` makes
    /// nothing.
    static let canKeepIn: Bool = {
        let preferences = WKPreferences()
        return turnedOff.allSatisfy { preferences.responds(to: NSSelectorFromString($0.1)) }
    }()

    /// The page as it is given to the web view: a head of our own, with the policy and
    /// then the app's look, and after it the page exactly as written. Nothing of the
    /// page's is read to decide where ours goes, so nothing in it can come before the
    /// policy; its own styles, coming after the look, can change it. Every page is
    /// laid out as a page of today, whether or not it says it is one.
    static func document(_ source: String, scheme: ColorScheme) -> String {
        let theme = Theme(scheme)
        // No colour but the page's own: what stands out is in the colour of the words.
        let look = [
            "color-scheme": scheme == .dark ? "dark" : "light",
            "--foreground": css(theme.text), "--muted-foreground": css(theme.secondaryText), "--accent": css(theme.text),
            "--border": css(theme.hairline), "--card": css(theme.codeBlock),
        ].sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ";")
        return "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
            + "<style>:root{\(look)}html,body{margin:0;padding:0;background:transparent;color:var(--foreground);font:14px -apple-system,system-ui,sans-serif}</style>"
            + source
    }

    private static func css(_ color: Color) -> String {
        let color = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let parts = [color.redComponent, color.greenComponent, color.blueComponent].map { String(Int(($0 * 255).rounded())) }
        return "rgba(\(parts.joined(separator: ",")),\((color.alphaComponent * 1000).rounded() / 1000))"
    }

    /// Run apart from the page's own scripts, which can neither see it nor speak as it.
    private static let world = WKContentWorld.world(name: "hermes-bot")

    /// Our own script, run in every page before anything of the page's, given the files
    /// the page names beside it. Handed over as a JSON value inside a script, never as
    /// part of the page, so nothing in a file can end the element it is placed in.
    static func watching(besides files: PageFiles) -> String {
        let given: [String: Any] = ["script": files.scripts, "style": files.styles, "types": PageFiles.scriptTypes.sorted()]
        let json = (try? JSONSerialization.data(withJSONObject: given, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{\"script\": {}, \"style\": {}, \"types\": []}"
        return "(function (files) {\n" + watchingBody + "\n})(" + json + ");"
    }

    private static let watchingBody = """
        var say = function (what) { window.webkit.messageHandlers.page.postMessage(what); };
        // Taken before the page has anything in it. An element of the page's can stand in
        // for a document's or a window's own by its name (`<img name="createElement">`),
        // never for these.
        var listen = EventTarget.prototype.addEventListener;
        var make = Document.prototype.createElement;
        var bodyOf = Object.getOwnPropertyDescriptor(Document.prototype, "body").get;
        var rootOf = Object.getOwnPropertyDescriptor(Document.prototype, "documentElement").get;
        var stateOf = Object.getOwnPropertyDescriptor(Document.prototype, "readyState").get;
        var told = false;
        var missing = function () { if (!told) { told = true; say({ missed: true }); } };
        // Only what the web view itself made known, heard before the page's own scripts
        // can hear it, and never an event a script made up: a request it refused, and a
        // part of the page it could not load.
        listen.call(window, "securitypolicyviolation", function (event) { if (event.isTrusted) missing(); }, true);
        listen.call(window, "error", function (event) { if (event.isTrusted && event.target instanceof Element) missing(); }, true);
        // The files the page names beside it, put in place of the names as the web view
        // reads the page, before a script is run or a stylesheet looked for. What the web
        // view takes for a script or a stylesheet is one; nothing else is.
        var own = Object.prototype.hasOwnProperty;
        var follows = Node.prototype.compareDocumentPosition;
        var tell = EventTarget.prototype.dispatchEvent;
        var trim = function (text) { return String(text || "").replace(/^[\\t\\n\\f\\r ]+|[\\t\\n\\f\\r ]+$/g, ""); };
        var key = function (name) { return trim(name).replace(/^(?:\\.\\/)+/, ""); };
        var tokens = function (text) { return " " + String(text || "").toLowerCase().replace(/[\\t\\n\\f\\r ]+/g, " ") + " "; };
        var typeOf = function (script) { return trim(script.getAttribute("type")).toLowerCase(); };
        var runs = function (script) { return files.types.indexOf(typeOf(script)) >= 0 && (typeOf(script) === "module" || !script.hasAttribute("nomodule")); };
        // Scripts run as the page is read, given their file, still to be told they have
        // loaded: told once the web view has read past them, so after they have run.
        // A deferred script or a module is not told.
        var running = [];
        var loaded = function (script) { try { tell.call(script, new Event("load")); } catch (error) {} };
        var placed = new WeakMap();
        var take = function (node) {
            if (node instanceof HTMLScriptElement) {
                // Only one the web view is reading from the page. One a script of the page's
                // made (which the web view marks as running whenever it is ready, though no
                // attribute says so) has been tried already, and failed.
                if (stateOf.call(document) !== "loading" || node.async && !node.hasAttribute("async")) return;
                if (!node.hasAttribute("src") || !runs(node)) return;
                var name = key(node.getAttribute("src"));
                if (!own.call(files.script, name)) return missing();
                var text = files.script[name];
                var module = typeOf(node) === "module";
                node.removeAttribute("src");
                if (!module && node.hasAttribute("defer") && !node.hasAttribute("async")) {
                    // To run when the page has been read, in its turn among the others: a
                    // module, which the web view runs then, that runs the file as the
                    // script it is.
                    text = '{ const script = Document.prototype.createElement.call(document, "script"); script.text = ' + JSON.stringify(text)
                        + '; Node.prototype.appendChild.call(Object.getOwnPropertyDescriptor(Document.prototype, "documentElement").get.call(document), script); }';
                    node.setAttribute("type", "module");
                    module = true;
                }
                node.text = text;
                placed.set(node, text);
                if (!module) running.push(node);
            } else if (node instanceof HTMLLinkElement) {
                var rel = tokens(node.getAttribute("rel"));
                if (!node.hasAttribute("href") || rel.indexOf(" stylesheet ") < 0 || rel.indexOf(" alternate ") >= 0) return;
                var sheet = key(node.getAttribute("href"));
                if (!own.call(files.style, sheet)) return missing();
                var style = make.call(document, "style");
                Array.prototype.forEach.call(node.attributes, function (attribute) {
                    if (!/^(rel|href|disabled)$/i.test(attribute.name)) style.setAttribute(attribute.name, attribute.value);
                });
                style.textContent = files.style[sheet];
                node.replaceWith(style);
                if (node.hasAttribute("disabled") && style.sheet) style.sheet.disabled = true;
            }
        };
        // The web view hands over what it reads one element at a time, each as it comes.
        new MutationObserver(function (records) {
            records.forEach(function (record) {
                // Words the page wrote inside the element itself, added after ours.
                var mine = placed.get(record.target);
                if (mine !== undefined && record.target.text !== mine) record.target.text = mine;
                record.addedNodes.forEach(function (node) {
                    running = running.filter(function (script) {
                        // Read past: something after it, in the page (not the words that
                        // were inside it, which ours took the place of).
                        var where = follows.call(script, node);
                        if (script === node || where & 1 || !(where & 4) || where & 16) return true;
                        loaded(script);
                        return false;
                    });
                    try { take(node); } catch (error) {}
                });
            });
        }).observe(document, { childList: true, subtree: true });
        listen.call(window, "DOMContentLoaded", function (event) {
            if (event.isTrusted) running.splice(0).forEach(loaded);
        }, true);
        // A link the person followed: a click the web view itself says is real, whose
        // nearest thing that a click does something to is the link (not a box to tick
        // that happens to stand inside one), and which the page did not call off.
        listen.call(window, "click", function (event) {
            if (!event.isTrusted || !event.target || !event.target.closest) return;
            // Something marked to send its bot the words it holds, clicked, unless the
            // page called the click off.
            var sender = event.target.closest("[data-hermes-send]");
            var words = sender ? sender.getAttribute("data-hermes-send") : null;
            // A link the person followed: a click the web view itself says is real, whose
            // nearest thing that a click does something to is the link (not a box to tick
            // that happens to stand inside one), and which the page did not call off.
            var acted = event.target.closest("a, area, button, input, select, textarea, label, summary, [contenteditable]:not([contenteditable='false'])");
            var to = null;
            if (acted && /^(a|area)$/i.test(acted.localName) && (acted.hasAttribute("href") || acted.hasAttribute("xlink:href"))) {
                to = typeof acted.href === "string" ? acted.href : acted.href && acted.href.baseVal;
            }
            if (typeof words !== "string" && typeof to !== "string") return;
            setTimeout(function () {
                if (event.defaultPrevented) return;
                if (typeof words === "string") say({ send: words });
                if (typeof to === "string") say({ open: to.trim() });
            }, 0);
        }, true);
        var last = -1;
        var measure = function () {
            var body = bodyOf.call(document), root = rootOf.call(document);
            var height = Math.ceil(body ? Math.max(body.scrollHeight, body.offsetHeight) : root.scrollHeight);
            if (height !== last) { last = height; say({ height: height, frame: innerHeight }); }
        };
        listen.call(document, "DOMContentLoaded", function () {
            var watcher = new ResizeObserver(measure);
            watcher.observe(rootOf.call(document));
            if (bodyOf.call(document)) watcher.observe(bodyOf.call(document));
            measure();
        });
        listen.call(window, "load", measure);
    """

    /// Run as one of the page's own scripts: `window.hermes.send(words)`, as Hermes's own
    /// app gives a page, answered with whether it went. What it asks is decided by `Keeper`,
    /// so a page's script calling the handler itself gains nothing.
    private static let speaking = """
    (function () {
        var handlers = window.webkit && window.webkit.messageHandlers;
        var handler = handlers && handlers.hermesSend;
        if (!handler) return;
        var send = function (words) {
            if (typeof words !== "string") return Promise.resolve({ ok: false, error: "invalid" });
            // As Hermes's own app does: no answer in five seconds is undelivered, whatever then becomes of it.
            var late = new Promise(function (done) { setTimeout(function () { done({ ok: false, error: "undelivered" }); }, 5000); });
            return Promise.race([handler.postMessage(words).catch(function () { return { ok: false, error: "undelivered" }; }), late]);
        };
        Object.defineProperty(window, "hermes", { value: Object.freeze({ send: send, maxLength: \(Keeper.longest) }) });
    })();
    """

    /// A place for what a page stores that is kept in memory only, and that never opens
    /// a connection to a server ahead of being asked to fetch from it. The web view does
    /// that for a link as it is followed, before it asks whether the link may be, so a
    /// page's script following a link of its own could reach any address with it, past
    /// the policy and the rule both. Turning it off has no public name; where a WebKit
    /// no longer answers to these, there is no such place and no page is shown.
    @MainActor
    static func closedStore() -> WKWebsiteDataStore? {
        let make = NSSelectorFromString("initNonPersistentConfiguration"), use = NSSelectorFromString("_initWithConfiguration:")
        guard let kind = NSClassFromString("_WKWebsiteDataStoreConfiguration") as? NSObject.Type,
              kind.instancesRespond(to: make), kind.instancesRespond(to: NSSelectorFromString("setAllowsServerPreconnect:")),
              WKWebsiteDataStore.instancesRespond(to: use),
              let settings = (kind.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject)?.perform(make)?.takeRetainedValue() as? NSObject
        else { return nil }
        settings.setValue(false, forKey: "allowsServerPreconnect")
        let store = (WKWebsiteDataStore.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject)?.perform(use, with: settings)?.takeRetainedValue() as? WKWebsiteDataStore
        return store?.isPersistent == false ? store : nil
    }

    /// The web view for a page. `store` is one made by `closedStore`, for this page
    /// alone; only where `canKeepIn` says a page can be kept in.
    @MainActor
    static func makeView(rules: WKContentRuleList, store: WKWebsiteDataStore, keeper: Keeper) -> PageView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.userContentController.add(rules)
        configuration.userContentController.add(keeper, contentWorld: world, name: "page")
        configuration.userContentController.addScriptMessageHandler(keeper, contentWorld: .page, name: "hermesSend")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        for (setting, _) in turnedOff { configuration.preferences.setValue(false, forKey: setting) }
        let view = PageView(frame: .zero, configuration: configuration)
        view.navigationDelegate = keeper
        view.uiDelegate = keeper
        view.allowsLinkPreview = false
        // Clear, so the page sits on the bubble; and never taking the keyboard because the
        // page asked for it, which would take it from the message box. (A click in the
        // page still gives it the keyboard.) Neither has a public name, and without
        // either the page is still kept in.
        for (setting, value) in [("drawsBackground", false), ("shouldSuppressFirstResponderChanges", true)] {
            let setter = "_set" + setting.prefix(1).uppercased() + setting.dropFirst() + ":"
            if view.responds(to: NSSelectorFromString(setter)) { view.setValue(value, forKey: setting) }
        }
        return view
    }

    func makeCoordinator() -> Keeper { Keeper() }

    func makeNSView(context: Context) -> PageView {
        let view = Self.makeView(rules: rules, store: store, keeper: context.coordinator)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: PageView, context: Context) {
        context.coordinator.tell = tell
        context.coordinator.sends = sends
        context.coordinator.lineInSight = lineInSight
        context.coordinator.heldAt = heldAt
        context.coordinator.view = view
        context.coordinator.show(html, besides: files, in: view)
    }

    /// The web view's settings hold on to the keeper, and so to all it tells, until told
    /// to let go.
    static func dismantleNSView(_ view: PageView, coordinator: Keeper) {
        coordinator.stop()
        view.stopLoading()
        view.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Decides what the page may do, which is to be loaded once, to say how tall it is, and
    /// to send its bot a message now and then.
    @MainActor
    final class Keeper: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
        var tell: (News) -> Void = { _ in }
        var opens: (URL) -> Void = { NSWorkspace.shared.open($0) }
        var sends: Sends?
        /// Where the line under the page goes is in the clear part of the chat, as last laid out.
        var lineInSight = false
        weak var view: WKWebView? { didSet { refit() } }
        var heldAt: CGFloat? { didSet { if heldAt != oldValue { refit() } } }
        /// How tall the page last said it is, and the height its frame was then to have.
        private var asked: (height: Double, frame: CGFloat)?
        /// Stands in for the whole of `canShowLine` in tests, whose windows are never in front.
        var seen: (() -> Bool)?
        /// Goes up with each page shown: a message the page as it was asked to send does
        /// not go from the page as it now is.
        private var shownCount = 0
        private var stopped = false
        /// The most a page may send at once, as in Hermes's own app; longer is refused, not cut.
        nonisolated static let longest = 500
        /// How long after one page sends anything any page must wait to send again.
        static let gap = Duration.seconds(1)
        /// When a page last sent, in the whole app: not each page's own, or two pages, or one
        /// page shown afresh, would send twice as often.
        static var lastSent: ContinuousClock.Instant?
        /// How long a page has to say how tall it is before it is given up on.
        var patience = Duration.seconds(10)
        private var shown: (html: String, files: PageFiles)?
        /// How many times the page has been handed over and not yet begun to load: twice,
        /// when the appearance changes before the first has begun.
        private var awaited = 0
        private var deadline: Task<Void, Never>?
        /// How much taller than its frame the page last said it was.
        private var lastOver = 0.0
        /// A height not yet passed on, and the wait before it is.
        private var wanted: CGFloat?
        private var passing: Task<Void, Never>?
        private var lastPassed = ContinuousClock.now - .seconds(1)

        /// Loads the page, or loads it again when it has changed: the app's colours are
        /// part of it, and change with the appearance.
        func show(_ html: String, besides files: PageFiles = PageFiles(), in view: WKWebView) {
            guard shown?.html != html || shown?.files != files else { return }
            shown = (html, files)
            shownCount += 1
            awaited += 1
            lastOver = 0
            // Our own script, with the files this page is given, ready before it loads.
            let controller = view.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(source: PageFrame.watching(besides: files), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: PageFrame.world))
            // And `window.hermes.send`, for the page's own scripts.
            controller.addUserScript(WKUserScript(source: PageFrame.speaking, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            view.loadHTMLString(html, baseURL: nil)
            // A page whose script never lets it finish loading says nothing, ever.
            deadline?.cancel()
            deadline = Task { [weak self, patience] in
                try? await Task.sleep(for: patience)
                if !Task.isCancelled { self?.tell(.ended) }
            }
        }

        func stop() {
            deadline?.cancel()
            passing?.cancel()
            tell = { _ in }
            sends = nil
            stopped = true
        }

        /// Whether what the page sends now would be seen: the frame still here, its line in
        /// the clear part of the chat, and its window showing, in front, in an app in front.
        func canShowLine() -> Bool {
            guard !stopped else { return false }
            if let seen { return seen() }
            guard lineInSight, let window = view?.window else { return false }
            return Self.inFront(window)
        }

        /// A window showing, not behind another or in the Dock, in the app in front. Tests,
        /// whose app is never in front, ask less.
        static var inFront: (NSWindow) -> Bool = { window in
            NSApp.isActive && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
                // Nor with a sheet, an alert or a file picker over it, as the message box asks too.
                && window.isKeyWindow && window.attachedSheet == nil && NSApp.modalWindow == nil
        }

        /// Whether all of the page shows, so the chat takes scrolling up and down: against the
        /// height its frame is held at, while it is held.
        private func refit() {
            guard let asked else { return }
            (view as? PageView)?.fits = asked.height <= Double(heldAt.map { min($0, asked.frame) } ?? asked.frame)
        }

        /// Asks `canShowLine` later, for the page as it is now and no other.
        private func stillSeen() -> @MainActor () -> Bool {
            let count = shownCount
            return { [weak self] in self.map { $0.shownCount == count && $0.canShowLine() } ?? false }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let address = action.request.url?.absoluteString ?? ""
            if action.targetFrame?.isMainFrame == true, !action.shouldPerformDownload {
                // The page itself, which was handed over as words and so comes from nowhere.
                if awaited > 0, action.navigationType == .other, address == "about:blank" {
                    awaited -= 1
                    return .allow
                }
                // To another place in the same page. Not loading it again, which would
                // leave it empty: the page was words, and has no address to load from.
                if address.hasPrefix("about:blank#"), action.navigationType == .linkActivated || action.navigationType == .other { return .allow }
            }
            return .cancel
        }

        /// A new window is never made.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
            .deny
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            tell(.ended)
        }

        nonisolated static func isOnTheWeb(_ url: URL) -> Bool {
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
        }

        /// What our own script says of the page. The page's scripts cannot say it.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let said = message.body as? [String: Any] else { return }
            if let height = said["height"] as? Double, let frame = said["frame"] as? Double, height.isFinite, frame.isFinite {
                deadline?.cancel()
                // A page laid out by the height of its frame is taller than it by the same
                // amount however tall the frame is made. Given what it asks once, it asks
                // again, and is not given it twice running, or it would grow without end.
                let over = height - frame
                let asksAgain = over > 0 && abs(over - lastOver) < 1
                lastOver = over
                // All of it shows, at the height the frame is about to have, or it does
                // not and the page scrolls.
                let next = asksAgain ? frame : min(max(height, 20), PageFrame.tallest)
                asked = (height, next)
                if view == nil { view = message.webView }
                refit()
                if !asksAgain { pass(next) }
            }
            if said["missed"] as? Bool == true { tell(.partMissing) }
            // Something marked to send was clicked.
            if let words = said["send"] as? String, case .success(let words) = admit(words), let sends {
                let seen = stillSeen()
                Task { _ = await sends(words, seen) }
            }
            // A link the person clicked, or pressed Return on: once for each time they
            // did, and only to the web.
            if let link = said["open"] as? String, let url = URL(string: link), Self.isOnTheWeb(url) { opens(url) }
        }

        /// `window.hermes.send`, from the page's own scripts: whatever they say, only words,
        /// and answered only with whether it went.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame else { return replyHandler(Self.refusal("undelivered"), nil) }
            switch admit(message.body) {
            case .failure(let refusal): replyHandler(refusal.ack, nil)
            case .success(let words):
                guard let sends else { return replyHandler(Self.refusal("undelivered"), nil) }
                let seen = stillSeen()
                Task { replyHandler(await sends(words, seen) ? ["ok": true] : Self.refusal("undelivered"), nil) }
            }
        }

        struct Refusal: Error {
            let ack: [String: Any]
        }

        private static func refusal(_ error: String, _ more: [String: Any] = [:]) -> [String: Any] {
            more.merging(["ok": false, "error": error]) { _, ours in ours }
        }

        /// Words a page could have sent: some, at most `longest` as a page's script counts
        /// them, and nothing the line under the page could not show as it is: no control
        /// character but a tab or line break, nothing unseen that shapes or hides text (a
        /// change of writing direction, a joiner, a tag character, a filler drawn as nothing),
        /// nothing unassigned. Not
        /// in the form of one of Hermes's own notices to the bot, either.
        nonisolated static func mayBeSent(_ words: String) -> Bool {
            guard !words.isEmpty, words.utf16.count <= longest, !words.lowercased().hasPrefix("[system:") else { return false }
            var previous: Unicode.Scalar?
            for scalar in words.unicodeScalars {
                defer { previous = scalar }
                if scalar == "\n" || scalar == "\t" { continue }
                // The text or picture form of an emoji, right after it: seen, and no words.
                if scalar.value == 0xFE0E || scalar.value == 0xFE0F, previous?.properties.isEmoji == true { continue }
                // Drawn as nothing: Unicode's ignorables (a grapheme joiner, a Hangul filler, a
                // variation selector anywhere else), and the blank Braille pattern.
                if scalar.properties.isDefaultIgnorableCodePoint || scalar.value == 0x2800 { return false }
                switch scalar.properties.generalCategory {
                case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: return false
                default: continue
                }
            }
            return true
        }

        /// Whether the page may send `body` now, and if so the words, trimmed: words a page
        /// may send, from a page that can send just now and be seen to (`canShowLine`), and one a second at most
        /// in the whole app. Decided at once, in the order the pages spoke.
        func admit(_ body: Any) -> Result<String, Refusal> {
            guard let raw = body as? String else { return .failure(Refusal(ack: Self.refusal("invalid"))) }
            let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if words.utf16.count > Self.longest { return .failure(Refusal(ack: Self.refusal("too_long", ["maxLength": Self.longest]))) }
            guard Self.mayBeSent(words) else { return .failure(Refusal(ack: Self.refusal("invalid"))) }
            guard sends != nil, canShowLine() else { return .failure(Refusal(ack: Self.refusal("undelivered"))) }
            let now = ContinuousClock.now
            if let last = Self.lastSent, now - last < Self.gap {
                let wait = Self.gap - (now - last)
                return .failure(Refusal(ack: Self.refusal("throttled", ["retryAfterMs": Int((wait / .milliseconds(1)).rounded(.up))])))
            }
            Self.lastSent = now
            return .success(words)
        }

        /// Passes a height on, at most ten times a second: the chat is laid out again for
        /// each, and a page may change its height as often as it likes.
        private func pass(_ height: CGFloat) {
            wanted = height
            guard passing == nil else { return }
            let wait = max(.zero, .milliseconds(100) - (ContinuousClock.now - lastPassed))
            passing = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled, let height = wanted else { return }
                passing = nil
                wanted = nil
                lastPassed = .now
                tell(.height(height))
            }
        }
    }
}

/// The web view a page is shown in.
final class PageView: WKWebView {
    /// All of the page is showing, so there is nothing in it to scroll up or down.
    var fits = true

    /// Scrolling up and down is the chat's, unless the page is taller than its frame.
    override func scrollWheel(with event: NSEvent) {
        if fits, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// Only Copy: the rest of a web view's menu reloads, opens windows or downloads.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items where item.identifier?.rawValue != "WKMenuItemIdentifierCopy" { menu.removeItem(item) }
    }
}
