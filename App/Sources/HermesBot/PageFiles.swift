import Foundation
import HermesKit

/// Scripts and stylesheets a bot saved beside its page and named in it by a path of the
/// page's own folder: `<script src="./chart.umd.min.js">`, `<link rel="stylesheet"
/// href="look.css">`. A page is handed over as words with no address, so such a name
/// leads nowhere by itself; the app fetches the file as it fetches any file a bot hands
/// over, and the page is given its words in place of the name (`PageFrame.watching`).
/// The page itself still reaches nothing.
///
/// Reading the page here only finds what may be worth fetching. Which elements really
/// are scripts and stylesheets is for the web view's own reading of the page to say, as
/// it lays the page out: something here that only looks like one is fetched and never
/// used, and one missed here is not filled in and fails, as anything else a page cannot
/// reach does, and the page says so.
struct PageFiles: Equatable, Sendable {
    /// Each file's words, by its name as the page gave it (`key`).
    var scripts: [String: String] = [:]
    var styles: [String: String] = [:]

    enum Kind: Equatable, Sendable {
        case script, style
    }

    /// No more files than this are fetched for a page.
    static let most = 8
    /// What they may weigh together. Chart.js is about 200 KB, a full Plotly about 3.6 MB.
    static let limit = 5_000_000
    /// How long they may take together. The page is then shown with what came.
    static let patience = Duration.seconds(20)

    /// The files a page names that may be fetched, each once, in the order they stand,
    /// as many as `most`, each by its `key`.
    static func wanted(in source: String) -> [(kind: Kind, name: String)] {
        var found: [(kind: Kind, name: String)] = []
        tags(in: source) { name, attributes in
            let named: (Kind, String?)
            switch name {
            case "script":
                // `nomodule` keeps only a classic script from running.
                guard isScript(attributes["type"]), attributes["nomodule"] == nil || trimmed(attributes["type"] ?? "").lowercased() == "module" else { return true }
                named = (.script, attributes["src"])
            case "link":
                let rel = Set((attributes["rel"] ?? "").lowercased().split { $0.unicodeScalars.allSatisfy(isSpace) }.map(String.init))
                guard rel.contains("stylesheet"), !rel.contains("alternate") else { return true }
                named = (.style, attributes["href"])
            default: return true
            }
            guard let raw = named.1 else { return true }
            let name = key(raw)
            guard place(name, of: named.0, besidePageAt: "") != nil, !found.contains(where: { $0.kind == named.0 && $0.name == name }) else { return true }
            found.append((named.0, name))
            return found.count < most
        }
        return found
    }

    /// A name as the page gave it, as the page's element is matched to its file: without
    /// the spaces HTML takes off an address, or a `./` in front. `PageFrame.watching` does
    /// the same.
    static func key(_ name: String) -> String {
        var name = trimmed(name)[...]
        while name.hasPrefix("./") { name = name.dropFirst(2) }
        return String(name)
    }

    /// The types of script HTML runs: none, a module, or one of these exactly (in any
    /// case, with the spaces round it taken off). `PageFrame.watching` keeps the same list.
    static let scriptTypes: Set = [
        "", "module", "application/ecmascript", "application/javascript", "application/x-ecmascript", "application/x-javascript",
        "text/ecmascript", "text/javascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2", "text/javascript1.3",
        "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript",
    ]

    /// Whether a script of this `type` is one the web view runs, and so fetches.
    static func isScript(_ type: String?) -> Bool {
        scriptTypes.contains(trimmed(type ?? "").lowercased())
    }

    /// Where on the gateway a file the page names is, or nil when it is not one this app
    /// fetches: anything but a plain path within the page's own folder, made of letters,
    /// digits, `.`, `_` and `-` in each part, to a file ending as a script (`.js`, `.mjs`)
    /// or a stylesheet (`.css`) as the element calls for. So no scheme, no path from the
    /// root, no `..`, no part beginning with a dot but `./`, no `%` or `&` that the
    /// gateway or the page might read as something else, and no query.
    static func place(_ name: String, of kind: Kind, besidePageAt page: String) -> String? {
        guard name.utf8.count <= 300 else { return nil }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false)
        // Only ever at the start: `./chart.js`.
        while parts.count > 1, parts.first == "." { parts.removeFirst() }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".unicodeScalars)
        guard let last = parts.last?.lowercased(), parts.allSatisfy({ part in
            !part.isEmpty && part.first != "." && part.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        let endings = kind == .script ? [".js", ".mjs"] : [".css"]
        guard endings.contains(where: { last.hasSuffix($0) }) else { return nil }
        let folder = page.lastIndex(of: "/").map { String(page[...$0]) } ?? ""
        return folder + parts.joined(separator: "/")
    }

    /// The files the page names, fetched for a page at `path` from the gateway it came
    /// from (`scope`, from `RosterModel.filesScope` when the page was asked for). One that
    /// cannot be fetched or is not words is left out, and its element fails in the page.
    /// Once they weigh `limit` together, or `patience` has passed, no more are fetched,
    /// and the page is shown with what came. Once the gateway is left, nothing more is
    /// fetched for the page at all.
    @MainActor
    /// `reading` asks for each as it was at that reading or later (`RosterModel.file`).
    static func fetch(for source: String, at path: String, from bot: Bot, roster: RosterModel, within scope: Int, reading: Int = 0,
                      limit: Int = limit, patience: Duration = patience) async throws -> PageFiles {
        var files = PageFiles()
        var left = limit
        let deadline = ContinuousClock.now + patience
        // Read away from the main thread: a page may be 2 MB.
        let wanted = await Task.detached { wanted(in: source) }.value
        for (kind, name) in wanted {
            guard left > 0, let place = place(name, of: kind, besidePageAt: path) else { continue }
            let file: GatewayClient.File
            let room = left
            do {
                guard let got = try await by(deadline, { try await roster.file(at: place, from: bot, limit: room, within: scope, reading: reading) }) else { break }
                file = got
            } catch is CancellationError {
                throw CancellationError()
            } catch GatewayError.notConnected {
                throw GatewayError.notConnected
            } catch GatewayError.rejected(code: 413, _) {
                // What is left would not hold it: as much as is left was spent finding so.
                break
            } catch {
                try Task.checkCancellation()
                continue
            }
            // Counted whether or not it turns out to be words.
            left -= file.data.count
            guard let words = String(data: file.data, encoding: .utf8) else { continue }
            if kind == .script { files.scripts[name] = words } else { files.styles[name] = words }
        }
        return files
    }

    /// What `work` gives, or nil when it has not given it by `deadline`, and then it is
    /// stopped.
    @MainActor
    private static func by<T: Sendable>(_ deadline: ContinuousClock.Instant, _ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(until: deadline)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    /// The spaces HTML takes off the ends of an address.
    static func trimmed(_ text: String) -> String {
        var scalars = text.unicodeScalars[...]
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { [" ", "\t", "\n", "\r", "\u{C}"].contains(scalar) }

    /// Each opening tag in the page, read as HTML's own tokenizer reads one (its name in
    /// lower case, the first of each attribute kept), handed to `each` until it says to
    /// stop. Comments, a doctype and the like are passed over, and so is what stands
    /// inside an element whose words are not markup (a script, a style, a textarea…),
    /// so a tag written in those is not taken for one.
    private static func tags(in source: String, _ each: (String, [String: String]) -> Bool) {
        let bytes = Array(source.utf8)
        let count = bytes.count
        var at = 0
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D }
        func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
        func lower(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }
        func text(_ from: Int, _ to: Int) -> String { String(decoding: bytes[from..<to], as: UTF8.self) }
        func lowered(_ from: Int, _ to: Int) -> String { String(decoding: bytes[from..<to].map(lower), as: UTF8.self) }
        /// Whether `what` (in lower case) stands at `at`, in any case.
        func has(_ what: [UInt8], at: Int) -> Bool {
            at + what.count <= count && (0..<what.count).allSatisfy { lower(bytes[at + $0]) == what[$0] }
        }
        /// Where `what` (in lower case) next stands from `from`, in any case.
        func find(_ what: String, from: Int) -> Int? {
            let wanted = Array(what.utf8)
            guard let first = wanted.first else { return nil }
            var at = from
            while at + wanted.count <= count {
                if lower(bytes[at]) == first, has(wanted, at: at) { return at }
                at += 1
            }
            return nil
        }
        /// Reads a tag's attributes from `at` to its `>`, and whether it closed itself
        /// (`/>`); nil for a tag the page ends in the middle of, which is no tag.
        func attributes() -> (found: [String: String], closed: Bool)? {
            var found: [String: String] = [:]
            var closed = false
            while at < count {
                closed = false
                while at < count, isSpace(bytes[at]) || bytes[at] == UInt8(ascii: "/") {
                    closed = bytes[at] == UInt8(ascii: "/")
                    at += 1
                }
                guard at < count else { return nil }
                guard bytes[at] != UInt8(ascii: ">") else { break }
                let nameStart = at
                at += 1
                while at < count, !isSpace(bytes[at]), ![UInt8(ascii: "/"), UInt8(ascii: ">"), UInt8(ascii: "=")].contains(bytes[at]) { at += 1 }
                let name = lowered(nameStart, at)
                while at < count, isSpace(bytes[at]) { at += 1 }
                var value = ""
                if at < count, bytes[at] == UInt8(ascii: "=") {
                    at += 1
                    while at < count, isSpace(bytes[at]) { at += 1 }
                    if at < count, bytes[at] == UInt8(ascii: "\"") || bytes[at] == UInt8(ascii: "'") {
                        let quote = bytes[at]
                        let valueStart = at + 1
                        at = valueStart
                        while at < count, bytes[at] != quote { at += 1 }
                        value = text(valueStart, at)
                        at = min(at + 1, count)
                    } else {
                        let valueStart = at
                        while at < count, !isSpace(bytes[at]), bytes[at] != UInt8(ascii: ">") { at += 1 }
                        value = text(valueStart, at)
                    }
                }
                if found[name] == nil { found[name] = value }
            }
            guard at < count else { return nil }
            at += 1
            return (found, closed)
        }
        // Elements whose words are not markup, and so hold no tags. A template's are
        // markup, but nothing in it is used until a script uses it.
        let unread: Set = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "noscript", "template"]
        // How deep in a drawing (`<svg>`) or a formula (`<math>`) the reading is: there, a
        // `<script>` or a `<title>` is not HTML's, and its words are markup.
        var foreign = 0
        let breakers: Set = [
            "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6",
            "head", "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p", "pre", "ruby", "s", "small", "span", "strong",
            "strike", "sub", "sup", "table", "tt", "u", "ul", "var",
        ]
        while at < count {
            guard bytes[at] == UInt8(ascii: "<"), at + 1 < count else { at += 1; continue }
            let next = bytes[at + 1]
            if next == UInt8(ascii: "!"), has(Array("<!--".utf8), at: at) {
                // A comment ends at the first `-->`, which may share its dashes with the
                // opening (`<!-->`), or at the first `--!>` after the opening (not `<!--!>`).
                // One pass: a page full of comments is read in the time it takes to read it.
                var end: Int?
                var look = at + 2
                while end == nil, let dashes = find("--", from: look) {
                    if dashes + 2 < count, bytes[dashes + 2] == UInt8(ascii: ">") {
                        end = dashes + 3
                    } else if dashes >= at + 4, dashes + 3 < count, bytes[dashes + 2] == UInt8(ascii: "!"), bytes[dashes + 3] == UInt8(ascii: ">") {
                        end = dashes + 4
                    } else {
                        look = dashes + 1
                    }
                }
                guard let end else { return }
                at = end
            } else if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") || next == UInt8(ascii: "/") && !(at + 2 < count && isLetter(bytes[at + 2])) {
                // A doctype, or something read as a comment to the next `>`.
                guard let end = bytes[at...].firstIndex(of: UInt8(ascii: ">")) else { return }
                at = end + 1
            } else if next == UInt8(ascii: "/") {
                // A closing tag, whose attributes are read and thrown away.
                at += 2
                let start = at
                while at < count, !isSpace(bytes[at]), bytes[at] != UInt8(ascii: "/"), bytes[at] != UInt8(ascii: ">") { at += 1 }
                let name = lowered(start, at)
                guard attributes() != nil else { return }
                if foreign > 0, name == "svg" || name == "math" { foreign -= 1 }
            } else if isLetter(next) {
                let start = at + 1
                at = start
                while at < count, !isSpace(bytes[at]), bytes[at] != UInt8(ascii: "/"), bytes[at] != UInt8(ascii: ">") { at += 1 }
                let name = lowered(start, at)
                guard let tag = attributes() else { return }
                // An HTML element of these kinds ends a drawing or formula left open.
                if foreign > 0, breakers.contains(name) || name == "font" && ["color", "face", "size"].contains(where: { tag.found[$0] != nil }) { foreign = 0 }
                if foreign > 0 {
                    if name == "svg" || name == "math", !tag.closed { foreign += 1 }
                    continue
                }
                if name == "svg" || name == "math" {
                    if !tag.closed { foreign = 1 }
                    continue
                }
                guard each(name, tag.found) else { return }
                if name == "plaintext" { return }
                if unread.contains(name) {
                    // Its words run to the tag that closes it.
                    var from = at
                    while true {
                        guard let end = find("</" + name, from: from) else { return }
                        let after = end + 2 + name.utf8.count
                        if after >= count || isSpace(bytes[after]) || bytes[after] == UInt8(ascii: "/") || bytes[after] == UInt8(ascii: ">") {
                            at = end
                            break
                        }
                        from = end + 1
                    }
                }
            } else {
                at += 1
            }
        }
    }
}
