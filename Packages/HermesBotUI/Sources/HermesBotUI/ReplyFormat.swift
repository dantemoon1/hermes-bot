import Foundation

/// One piece of a bot's reply, as it is laid out: a paragraph, a heading, a list item and
/// so on. Bold, italics, links and code inside a line are left in `text` for the view.
public struct ReplyBlock: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        /// 1 is the largest.
        case heading(Int)
        /// `marker` is what stands before the item: a bullet, or the number as typed.
        /// `depth` is 0 for an item of the outermost list.
        case item(marker: String, depth: Int)
        /// Shown exactly as typed, in fixed-width letters.
        case code
        /// Rows of cells, the first row being the headings; see `ReplyFormat.rows(ofTable:)`.
        case table
        case quote
        /// A line across.
        case rule
        /// A file the bot handed over. `text` is where it is on the gateway, as the bot
        /// wrote it.
        case file
        /// A page the bot wrote, to be shown where it stands. `text` is where it is on
        /// the gateway, as the bot wrote it.
        case page
    }

    /// Its place in the reply, which stays the same while more of the reply arrives.
    public let id: Int
    public let kind: Kind
    public let text: String

    public init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public enum ReplyFormat {
    /// Splits a reply into its blocks. Text that is still arriving is read as far as it
    /// goes: a code block not yet closed runs to the end.
    public static func blocks(of text: String) -> [ReplyBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var marked = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        func hasTag(_ line: String) -> Bool { line.contains("MEDIA:") || line.contains("::") }
        var apart = [Bool](repeating: false, count: lines.count)
        // Nearly every reply hands over nothing, and is read once.
        guard marked.contains(where: hasTag) else { return read(lines, marked: nil, apart: &apart) }
        // Code may open on one line and close on a later one, in a paragraph or across the
        // lines of a list, and a tag shown in such code is not a file. Which lines are
        // text and which are blocks of code or tables is for the reading itself to say,
        // so the reply is read once to learn that, taking no tag for a file; then code
        // is marked across each run of lines of text with no gap in it, and the reply
        // is read again with that. Where a file's standing apart would have changed
        // what a later line is, the first reading takes that line for text: at worst a
        // tag is hidden that was a file, never one fetched that was only shown.
        _ = read(lines, marked: nil, apart: &apart)
        var from = 0
        while from < marked.count {
            guard !marked[from].isEmpty, !apart[from] else {
                from += 1
                continue
            }
            var to = from
            var found = false
            while to < marked.count, !marked[to].isEmpty, !apart[to] {
                if hasTag(marked[to]) { found = true }
                to += 1
            }
            if found {
                let hidden = hidingTagsInCode(marked[from..<to].joined(separator: "\n")).components(separatedBy: "\n")
                if hidden.count == to - from { marked.replaceSubrange(from..<to, with: hidden) }
            }
            from = to
        }
        var unused = [Bool](repeating: false, count: lines.count)
        return read(lines, marked: marked, apart: &unused)
    }

    /// Reads the lines of a reply into blocks. `marked` is each line with tags shown in
    /// code hidden, or nil to take no tag for a file; `apart` is set for every line taken
    /// as a block of code or a table.
    private static func read(_ lines: [String], marked: [String]?, apart: inout [Bool]) -> [ReplyBlock] {
        var blocks: [(ReplyBlock.Kind, String)] = []
        var paragraph: [String] = []
        var quote: [String] = []
        /// How far in each open list's markers stand, outermost first.
        var indents: [Int] = []
        /// How far in the text of the last list item stands, for lines that carry it on.
        var itemTextIndent: Int?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append((.paragraph, paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append((.quote, quote.joined(separator: "\n")))
                quote = []
            }
        }
        func endList() {
            indents = []
            itemTextIndent = nil
        }

        var index = 0
        /// Files named in the line just taken, to stand after it.
        var filesToFollow: [String] = []
        func setDownFiles() {
            guard !filesToFollow.isEmpty else { return }
            // After the line they were in, a quote included; the list goes on after them.
            flush()
            for path in filesToFollow { blocks.append((.file, path)) }
            filesToFollow = []
        }
        /// Takes the lines after a fence, up to the one that closes it, as a block of code.
        /// `indent` is how far in the fence stands.
        func takeCode(closedBy fence: String, setIn indent: Int) {
            let began = index - 1
            defer { for at in began..<index { apart[at] = true } }
            var code: [String] = []
            while index < lines.count {
                let next = lines[index]
                index += 1
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                // A fence set well in from where the block opened is part of the code.
                if nextTrimmed.hasPrefix(fence), nextTrimmed.allSatisfy({ $0 == fence.first }),
                   width(ofIndentIn: next) - indent < 4 { break }
                code.append(dropping(indent, from: next))
            }
            blocks.append((.code, code.joined(separator: "\n")))
        }
        /// Begins a list item whose marker stands `indent` in.
        func beginItem(_ marker: String, _ body: Substring, at indent: Int, in trimmed: String) {
            flush()
            // Deeper than the list above it, the same, or back out to one before.
            while let last = indents.last, indent < last { indents.removeLast() }
            if indents.last.map({ indent > $0 }) ?? true { indents.append(indent) }
            itemTextIndent = indent + (trimmed.count - body.count)
        }
        while index < lines.count {
            setDownFiles()
            var line = lines[index]
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = width(ofIndentIn: line)
            index += 1

            if let fence = fence(opening: trimmed), indent < 4 || !indents.isEmpty {
                flush()
                takeCode(closedBy: fence, setIn: indent)
                continue
            }
            if trimmed.isEmpty {
                flush()
                continue
            }
            // Set well in after a gap: code, kept as typed. Under a list item, well in
            // means further in than the item's own words.
            let inList = !indents.isEmpty
            let afterGap = index >= 2 && lines[index - 2].trimmingCharacters(in: .whitespaces).isEmpty
            let codeIndent = inList ? (itemTextIndent ?? 0) + 4 : 4
            if indent >= codeIndent, paragraph.isEmpty, quote.isEmpty, !inList || (afterGap && listItem(trimmed) == nil) {
                var code = [dropping(codeIndent, from: line)]
                var blanks = 0
                let began = index - 1
                defer { for at in began..<index { apart[at] = true } }
                while index < lines.count {
                    let next = lines[index]
                    if next.trimmingCharacters(in: .whitespaces).isEmpty {
                        blanks += 1
                    } else if width(ofIndentIn: next) >= codeIndent {
                        code.append(contentsOf: Array(repeating: "", count: blanks))
                        code.append(dropping(codeIndent, from: next))
                        blanks = 0
                    } else {
                        break
                    }
                    index += 1
                }
                // The blank lines after it are not its own.
                index -= blanks
                blocks.append((.code, code.joined(separator: "\n")))
                continue
            }
            if isTableHeading(trimmed, over: index < lines.count ? lines[index] : "") {
                flush()
                endList()
                // Written with a bar at each end of a row, or only between cells.
                let hasEnds = trimmed.hasPrefix("|")
                let began = index - 1
                defer { for at in began..<index { apart[at] = true } }
                var rows = [trimmed, lines[index].trimmingCharacters(in: .whitespaces)]
                index += 1
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    // Under headings with bars at the ends, a row still arriving has its first
                    // bar and not yet its second. Otherwise a row is a line that is nothing
                    // else and has as many cells as the headings.
                    guard !row.isEmpty else { break }
                    if hasEnds, row.hasPrefix("|") {
                        index += 1
                        rows.append(row)
                        continue
                    }
                    // A row may leave its end bars off whatever the headings did.
                    guard row.contains("|"), !startsAnotherBlock(row), tableCells(row).count == tableCells(trimmed).count else { break }
                    rows.append(row)
                    index += 1
                }
                blocks.append((.table, rows.joined(separator: "\n")))
                continue
            }
            // A block of code that opens on a list item's own line, or on that of an item
            // within it: what follows is code, whatever it looks like, up to the fence
            // that closes it. Found before the line is read for anything else, since
            // what comes after the fence on its line is the code's, not a file's.
            if let (marker, body) = listItem(trimmed) {
                var inner = body
                while let (_, deeper) = listItem(String(inner)) { inner = deeper }
                if let opened = fence(opening: String(inner)) {
                    beginItem(marker, body, at: indent, in: trimmed)
                    blocks.append((.item(marker: marker, depth: min(indents.count - 1, 5)), ""))
                    takeCode(closedBy: opened, setIn: indent + (trimmed.count - inner.count))
                    continue
                }
            }
            // A line that is wholly `::name{...}` is for something added to Hermes's own
            // app to draw. Only a page is drawn here; any other says nothing to a person.
            if let marked, let named = directive(marked[index - 1]), named.name != "preview" {
                flush()
                continue
            }
            // A file handed over. Looked for only here, after code and tables have been
            // taken as what they are.
            if let marked, let pieces = handedOver(marked: marked[index - 1]) {
                let isMarked = listItem(trimmed) != nil || trimmed.hasPrefix(">") || heading(trimmed) != nil
                if !isMarked {
                    // By itself on the line or among words: it stands apart from the
                    // words either side of it.
                    flush()
                    endList()
                    for piece in pieces {
                        blocks.append((piece.isPage ? .page : piece.isFile ? .file : .paragraph, piece.text))
                    }
                    continue
                }
                // In a list item, a quote or a heading: the line keeps its place and its
                // words, with the file's name where the tag was, and the file follows it.
                // The files are set down as they were read, once this line has been
                // taken: read again as text, a name with a quote in it would be cut.
                let reads = pieces.map { $0.isFile ? "`\(name(of: $0.text))`" : $0.text }.joined(separator: " ")
                line = String(repeating: " ", count: indent) + reads
                trimmed = reads
                filesToFollow = pieces.filter(\.isFile).map(\.text)
            }
            // "Title" over a line of dashes or equals signs is a heading written the old way.
            if paragraph.count == 1, quote.isEmpty, trimmed.count >= 2,
               trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                let title = paragraph[0]
                paragraph = []
                endList()
                blocks.append((.heading(trimmed.first == "=" ? 1 : 2), title))
                continue
            }
            if let (level, title) = heading(trimmed) {
                flush()
                endList()
                blocks.append((.heading(level), title))
                continue
            }
            if isRule(trimmed) {
                flush()
                endList()
                blocks.append((.rule, ""))
                continue
            }
            if let (marker, body) = listItem(trimmed) {
                beginItem(marker, body, at: indent, in: trimmed)
                blocks.append((.item(marker: marker, depth: min(indents.count - 1, 5)), String(body)))
                continue
            }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                endList()
                var rest = trimmed.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                quote.append(String(rest))
                continue
            }
            if !quote.isEmpty { flush() }
            // Set in under a list item: more of that item.
            if let itemTextIndent, indent >= min(itemTextIndent, 2), paragraph.isEmpty,
               case .item(let marker, let depth)? = blocks.last?.0 {
                blocks[blocks.count - 1] = (.item(marker: marker, depth: depth), blocks[blocks.count - 1].1 + "\n" + trimmed)
                continue
            }
            endList()
            paragraph.append(trimmed)
        }
        setDownFiles()
        flush()
        return blocks.enumerated().map { ReplyBlock(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    /// The cells of a table block, row by row, headings first. Every row has as many cells
    /// as the longest, so nothing written in a row is left out.
    public static func rows(ofTable text: String) -> [[String]] {
        var rows: [[String]] = []
        // The second line is the rule under the headings, and only that one.
        for (number, line) in text.components(separatedBy: "\n").enumerated() where number != 1 {
            rows.append(tableCells(line))
        }
        let width = rows.map(\.count).max() ?? 0
        return rows.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    /// A row split at its bars. A bar written \\| or inside `code` is part of its cell.
    private static func cells(of row: Substring) -> [String] {
        let characters = Array(row)
        var cells: [String] = []
        var cell = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "`" {
                // Code runs from one run of backticks to the next of the same length, and
                // is code only if that closing run is there.
                var length = 1
                while index + length < characters.count, characters[index + length] == "`" { length += 1 }
                var close = index + length
                var found: Int?
                while close < characters.count {
                    guard characters[close] == "`" else { close += 1; continue }
                    var run = 1
                    while close + run < characters.count, characters[close + run] == "`" { run += 1 }
                    if run == length { found = close; break }
                    close += run
                }
                if let found {
                    // A bar in code needs no backslash, and one written there is not shown.
                    cell += String(characters[index..<found + length]).replacingOccurrences(of: "\\|", with: "|")
                    index = found + length
                } else {
                    cell += String(repeating: "`", count: length)
                    index += length
                }
                continue
            }
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                cell.append("|")
                index += 2
                continue
            }
            if character == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
            index += 1
        }
        cells.append(cell)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A line's cells once any bars at its ends are taken off.
    private static func tableCells(_ line: String) -> [String] {
        var line = Substring(line.trimmingCharacters(in: .whitespaces))
        if line.hasPrefix("|") { line = line.dropFirst() }
        if line.hasSuffix("|"), !line.hasSuffix("\\|") { line = line.dropLast() }
        return cells(of: line)
    }

    /// Whether a line is a table's headings: it has a bar, the line under it is a rule with
    /// as many columns, and it is not something else that happens to hold a bar.
    private static func isTableHeading(_ line: String, over next: String) -> Bool {
        guard line.contains("|"), isTableRule(next) else { return false }
        guard line.hasPrefix("|") || !startsAnotherBlock(line) else { return false }
        return tableCells(line).count == tableCells(next).count
    }

    /// A quote, heading, list item or code fence: never a row of a table without end bars.
    private static func startsAnotherBlock(_ line: String) -> Bool {
        line.hasPrefix(">") || heading(line) != nil || listItem(line) != nil || fence(opening: line) != nil
    }

    /// A reply as one plain line, for a preview: without the marks that lay it out.
    public static func preview(of text: String) -> String {
        // Only as far as a preview can show.
        var length = 0
        return blocks(of: text).prefix { block in
            defer { length += block.text.count }
            return length < 160
        }
        .map { block -> String in
            switch block.kind {
            case .rule: return ""
            case .file, .page: return "Sent " + (block.text as NSString).lastPathComponent
            case .table: return rows(ofTable: block.text).first?.joined(separator: ", ") ?? ""
            case .code: return block.text
            default:
                let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                return (try? AttributedString(markdown: block.text, options: options)).map { String($0.characters) } ?? block.text
            }
        }
        .joined(separator: " ")
        // A preview is often cut off mid-way, leaving marks that never closed.
        .replacingOccurrences(of: "**", with: "")
        .replacingOccurrences(of: "`", with: "")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// How far in a line starts, a tab counting as four.
    private static func width(ofIndentIn line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    /// A line of code without the indent its fence had, so code in a list is not pushed in.
    private static func dropping(_ indent: Int, from line: String) -> String {
        var left = indent
        var rest = Substring(line)
        while left > 0, let first = rest.first, first == " " || first == "\t" {
            left -= first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    /// The run of backticks or tildes that opens a code block, if the line is one.
    private static func fence(opening line: String) -> String? {
        for mark in ["`", "~"] where line.hasPrefix(String(repeating: mark, count: 3)) {
            let run = line.prefix { String($0) == mark }
            // What follows names the language. ```this``` and ~~~this~~~ are words in a line.
            let rest = line.dropFirst(run.count)
            if mark == "`" ? rest.contains("`") : rest.hasSuffix(run) { return nil }
            return String(run)
        }
        return nil
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count) else { return nil }
        let rest = line.dropFirst(marks.count)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // "## Title ##" is the same heading.
        if let close = title.range(of: #"\s+#+$"#, options: .regularExpression) { title.removeSubrange(close) }
        return title.isEmpty ? nil : (marks.count, title)
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// The marker to show and the item's own words, if the line starts a list item.
    private static func listItem(_ line: String) -> (String, Substring)? {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let mark = line[..<space]
        let body = line[space...].drop { $0 == " " || $0 == "\t" }
        guard !body.isEmpty else { return nil }
        if mark == "-" || mark == "*" || mark == "+" || mark == "•" { return ("•", body) }
        guard let last = mark.last, last == "." || last == ")" else { return nil }
        let number = mark.dropLast()
        guard (1...9).contains(number.count), number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber) else { return nil }
        return (String(mark), body)
    }

    /// The line under a table's headings: bars, dashes and colons only.
    private static func isTableRule(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line.contains("|") && line.contains("-") && line.allSatisfy { "|-: ".contains($0) }
    }

    // MARK: Files

    /// A stretch of a line: words, or a file handed over.
    struct Piece: Equatable {
        let text: String
        let isFile: Bool
        /// A file that is a page to show: named by `::preview`, and HTML by its name.
        var isPage = false
    }

    /// The words and files of a line in which a bot hands over one file or more, in order,
    /// or nil for a line that hands over none. A bot hands a file over as Hermes's own
    /// desktop app is told to expect: `MEDIA:` and then where the file is, bare or in
    /// quotes or backticks, or a line holding only `::preview{file="..."}`.
    static func handedOver(in line: String) -> [Piece]? {
        handedOver(marked: hidingTagsInCode(line))
    }

    /// The same for a line in which tags shown in code have already been marked.
    static func handedOver(marked line: String) -> [Piece]? {
        // A line with the look of a directive, or of the start of one still arriving, is
        // one or is words: it is never read for a file named some other way inside it.
        if line.hasPrefix("::"), line.prefixMatch(of: /::[a-z][a-z0-9-]{0,63}\{/) != nil {
            // The last `file`, as in Hermes's own app. Anything but HTML is a file like
            // any other there too. With no file, or a stand-in for one, it is words.
            guard let named = directive(line), named.name == "preview", let file = named.attributes.last(where: { $0.key.lowercased() == "file" })?.value,
                  !file.trimmingCharacters(in: .whitespaces).isEmpty, !isStandIn(file) else { return nil }
            return [Piece(text: file, isFile: true, isPage: file.wholeMatch(of: /.*\.(?i:html?|xhtml)/) != nil)]
        }
        // Not in a row of a table, which is laid out cell by cell.
        guard line.contains("MEDIA:"), !line.hasPrefix("|") else { return nil }
        // A tag shown inside code is not one being sent. Code is found as Markdown finds
        // it, by a run of backticks and the next run of the same length; a span holding
        // nothing but a tag is the tag written in backticks, and is still a tag. In any
        // other span the tag is marked so that it is not read, and unmarked at the end.

        var pieces: [Piece] = []
        var rest = Substring(line)
        var foundOne = false
        // In quotes or backticks; or from the root, the home folder or a drive to the first
        // ending that is a kind of file, which lets a bare name hold spaces; or else a
        // bare run with no space in it. A mark of emphasis may close after the ending,
        // but only at the end of a word: `chart.png_backup.png` is one name.
        let tagged = /[`"']?MEDIA:[ \t]*(`[^`]+`|"[^"]+"|'[^']+'|(?:~\/|\/|[A-Za-z]:[\/\\])[^\s`]+?(?:[ \t]+(?!\S*MEDIA:)[^\s`]+?)*?\.(?i:png|jpe?g|gif|webp|heic|bmp|tiff?|svg|pdf|txt|md|csv|tsv|json|ya?ml|xml|html?|zip|tar|gz|mp3|wav|m4a|ogg|flac|mp4|mov|webm|mkv|docx?|xlsx?|pptx?|ics|log|py|js|ts|sh)(?=[\s`"',;:)\]}!?]|[*_]+(?:[\s`"'.,;:)\]}!?]|$)|\.(?:\s|$)|MEDIA:|$)|[^\s`"]+)[`"']?/
        while let tag = rest.firstMatch(of: tagged) {
            var path = String(tag.1)
            var after = rest[tag.range.upperBound...]
            if let quote = path.first, "`\"'".contains(quote), path.last == quote, path.count > 1 {
                path = String(path.dropFirst().dropLast())
            } else {
                // Written bare, the full stop or comma that ends the sentence is not part of it.
                var cut = ""
                while let last = path.last, ".,;:!?)]`\"'".contains(last), looksLikeAPath(String(path.dropLast())) {
                    cut = String(last) + cut
                    path.removeLast()
                }
                // A closing quote or backtick is the tag's own, not a word after it.
                cut = cut.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
                after = Substring(cut + after)
            }
            // A bot explaining how files are sent writes the tag with a stand-in for a path.
            // Part of a longer word, such as SOCIAL_MEDIA:, it is not the tag.
            let wordBefore = tag.range.lowerBound > rest.startIndex
                ? rest[rest.index(before: tag.range.lowerBound)].isLetter || rest[rest.index(before: tag.range.lowerBound)].isNumber || rest[rest.index(before: tag.range.lowerBound)] == "_"
                : false
            guard looksLikeAPath(path), !isStandIn(path), !wordBefore else {
                // "MEDIA:" in a sentence, with nothing after it that could be a file.
                pieces.append(Piece(text: String(rest[..<tag.range.upperBound]), isFile: false))
                rest = rest[tag.range.upperBound...]
                continue
            }
            // Kept as written for now: words either side of a tag that was not one are
            // put back together below, spaces and all.
            let before = String(rest[..<tag.range.lowerBound])
            if !before.isEmpty { pieces.append(Piece(text: before, isFile: false)) }
            pieces.append(Piece(text: path, isFile: true))
            foundOne = true
            rest = after
        }
        guard foundOne else { return nil }
        if !rest.isEmpty { pieces.append(Piece(text: String(rest), isFile: false)) }
        // Words cut in two by a tag that was not one are put back together.
        var joined: [Piece] = []
        for piece in pieces {
            if !piece.isFile, let last = joined.last, !last.isFile {
                joined[joined.count - 1] = Piece(text: last.text + piece.text, isFile: false)
            } else {
                joined.append(piece)
            }
        }
        // Only now are the spaces round each stretch of words dropped, and with them the
        // full stop or comma that closed the sentence a file ended: by itself on the line
        // after a picture it would be a stray mark.
        var tidy: [Piece] = []
        for piece in joined {
            if piece.isFile {
                tidy.append(piece)
                continue
            }
            var words = Substring(piece.text.trimmingCharacters(in: .whitespaces))
            if tidy.last?.isFile == true {
                while let first = words.first, ".,;:!?".contains(first) { words = words.dropFirst() }
                words = Substring(words.trimmingCharacters(in: .whitespaces))
            }
            if !words.isEmpty { tidy.append(Piece(text: String(words).replacingOccurrences(of: hidden, with: ""), isFile: false)) }
        }
        return tidy
    }

    /// A line that is wholly a directive, `::name{key="value" ...}`, as Hermes's own app
    /// takes one (`transcript-directives.ts`): its name and what it was given. The whole
    /// of what is between the braces must be `key=value` with a space between each, a
    /// value in quotes or with no space in it; anything else there, an escaped quote or a
    /// stray word included, and the line is not a directive at all. So CSS, code and a
    /// directive with a second one inside it are left as the words they are.
    static func directive(_ line: String) -> (name: String, attributes: [(key: String, value: String)])? {
        guard line.hasPrefix("::"), let whole = line.wholeMatch(of: /::([a-z][a-z0-9-]{0,63})\{([^{}]*)\}/),
              whole.2.wholeMatch(of: /\s*(?:[A-Za-z_][A-Za-z0-9_-]*=(?:"[^"]*"|'[^']*'|[^\s"'=]+)(?:\s+|$))*/) != nil
        else { return nil }
        let attributes = whole.2.matches(of: /([A-Za-z_][A-Za-z0-9_-]*)=(?:"([^"]*)"|'([^']*)'|([^\s"'=]+))/).map {
            (key: String($0.1), value: String($0.2 ?? $0.3 ?? $0.4 ?? ""))
        }
        return (String(whole.1), attributes)
    }

    /// A bot explaining how files are sent writes a stand-in where a file would be named.
    private static func isStandIn(_ path: String) -> Bool {
        ["/absolute/path", "/path/to", "path/to/", "<"].contains { path.hasPrefix($0) }
    }

    /// Put after "MEDIA" in a tag that is only being shown, so it is not read as one.
    private static let hidden = "\u{0}"

    private static func hidingTagsInCode(_ line: String) -> String {
        let characters = Array(line)
        var out = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "`" else {
                out.append(characters[index])
                index += 1
                continue
            }
            // After a backslash that is not itself escaped, a backtick is only a mark
            // on the page and opens nothing. (Inside code a backslash escapes nothing,
            // so what closes a span is found as before.)
            var slashes = 0
            while index - slashes > 0, characters[index - slashes - 1] == "\\" { slashes += 1 }
            if slashes % 2 == 1 {
                out.append("`")
                index += 1
                continue
            }
            var run = 0
            while index + run < characters.count, characters[index + run] == "`" { run += 1 }
            // The next run of exactly as many closes it.
            var close: Int?
            var at = index + run
            while at < characters.count {
                if characters[at] == "`" {
                    var length = 0
                    while at + length < characters.count, characters[at + length] == "`" { length += 1 }
                    if length == run {
                        close = at
                        break
                    }
                    at += length
                } else {
                    at += 1
                }
            }
            guard let close else {
                // Never closed: not code, the backticks are as written.
                out.append(String(repeating: "`", count: run))
                index += run
                continue
            }
            let inside = String(characters[(index + run)..<close])
            // The tag and nothing more: `MEDIA:/tmp/a.png --flag` is a command being shown.
            // A name from the root may hold spaces, up to an ending that is a kind of file.
            let isTheTag = run == 1 && inside.trimmingCharacters(in: .whitespaces).wholeMatch(of: /MEDIA:[ \t]*(?:\S+|(?:~\/|\/|[A-Za-z]:[\/\\])[^`\n]*?\.(?i:png|jpe?g|gif|webp|heic|bmp|tiff?|svg|pdf|txt|md|csv|tsv|json|ya?ml|xml|html?|zip|tar|gz|mp3|wav|m4a|ogg|flac|mp4|mov|webm|mkv|docx?|xlsx?|pptx?|ics|log|py|js|ts|sh))/) != nil
            let ticks = String(repeating: "`", count: run)
            out += ticks + (isTheTag ? inside : inside.replacingOccurrences(of: "MEDIA:", with: "MEDIA" + hidden + ":").replacingOccurrences(of: "::", with: ":" + hidden + ":")) + ticks
            index = close + run
        }
        return out
    }

    /// A file's own name, without the folders it is in, however they are written.
    public static func name(of path: String) -> String {
        let last = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path
        return last.isEmpty ? path : last
    }

    private static func looksLikeAPath(_ text: String) -> Bool {
        text.contains("/") || text.contains("\\") || text.firstMatch(of: /\.[^.\s]/) != nil
    }
}
