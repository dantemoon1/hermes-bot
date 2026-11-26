import Foundation
import Testing
@testable import HermesBotUI

@Suite struct ReplyFormatTests {
    private func kinds(_ text: String) -> [ReplyBlock.Kind] { ReplyFormat.blocks(of: text).map(\.kind) }
    private func texts(_ text: String) -> [String] { ReplyFormat.blocks(of: text).map(\.text) }

    @Test func plainRepliesStayParagraphsWithTheirLineBreaks() {
        let blocks = ReplyFormat.blocks(of: "Two things.\nBoth small.\n\n\nNothing else.")
        #expect(blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(blocks.map(\.text) == ["Two things.\nBoth small.", "Nothing else."])
        #expect(blocks.map(\.id) == [0, 1])
        #expect(ReplyFormat.blocks(of: "").isEmpty)
        #expect(ReplyFormat.blocks(of: " \n\n ").isEmpty)
    }

    @Test func headingsListsQuotesAndRulesAreToldApart() {
        let reply = """
        ## Plan for today ##
        Here it is:
        - Water the beds
        - Check **frost** cover
          and the fleece
        1. First
        2) Second
        > Mind the step
        > at the gate

        ---
        Done.
        """
        #expect(kinds(reply) == [
            .heading(2), .paragraph,
            .item(marker: "•", depth: 0), .item(marker: "•", depth: 0),
            .item(marker: "1.", depth: 0), .item(marker: "2)", depth: 0),
            .quote, .rule, .paragraph,
        ])
        #expect(texts(reply)[0] == "Plan for today")
        #expect(texts(reply)[3] == "Check **frost** cover\nand the fleece")
        #expect(texts(reply)[6] == "Mind the step\nat the gate")
    }

    @Test func listsInsideListsGoDeeperAndComeBackOut() {
        let reply = "- Fruit\n  - Apples\n    - Bramley\n  - Pears\n- Veg\n\n1. One\n   - under one\n2. Two"
        #expect(kinds(reply) == [
            .item(marker: "•", depth: 0), .item(marker: "•", depth: 1), .item(marker: "•", depth: 2),
            .item(marker: "•", depth: 1), .item(marker: "•", depth: 0),
            .item(marker: "1.", depth: 0), .item(marker: "•", depth: 1), .item(marker: "2.", depth: 0),
        ])
    }

    @Test func codeIsKeptExactlyAndAnOpenBlockRunsToTheEnd() {
        let reply = "Run this:\n```sh\nls -la\n\n  # not a heading\n- not a list\n```\nThen stop."
        #expect(kinds(reply) == [.paragraph, .code, .paragraph])
        #expect(texts(reply)[1] == "ls -la\n\n  # not a heading\n- not a list")
        // Still arriving: no closing fence yet.
        #expect(kinds("Look:\n```\nlet a = 1") == [.paragraph, .code])
        #expect(texts("Look:\n```\nlet a = 1")[1] == "let a = 1")
        // Code under a list item loses the item's indent, not its own.
        #expect(texts("1. Try\n   ```\n   if x:\n       go()\n   ```")[1] == "if x:\n    go()")
        // Three backticks or tildes around words in a line are not a block.
        #expect(kinds("```not a block```") == [.paragraph])
        #expect(kinds("~~~note~~~\nmore") == [.paragraph])
        // A tilde in what names the language is fine.
        #expect(kinds("~~~text title=~draft\n# Sample\n~~~\nDone.") == [.code, .paragraph])
        #expect(kinds("~~~~text title=~~~\n# Sample\n~~~~\nDone.") == [.code, .paragraph])
        // A fence set well in is part of the code, not its end.
        let nested = "```python\nexample = \"\"\"\n    ```\n\"\"\"\nprint(example)\n```\nDone."
        #expect(kinds(nested) == [.code, .paragraph])
        #expect(texts(nested)[0] == "example = \"\"\"\n    ```\n\"\"\"\nprint(example)")
        // Code set in under a list item keeps its own indents; words carrying the item on do not become code.
        let under = "- Run this:\n\n      if ready:\n          go()\n\n- Next\n  and more\n      still the item"
        #expect(kinds(under) == [.item(marker: "•", depth: 0), .code, .item(marker: "•", depth: 0)])
        #expect(texts(under)[1] == "if ready:\n    go()")
        #expect(texts(under)[2] == "Next\nand more\nstill the item")
        // Code written by setting it in, with its own indents and gaps kept.
        let setIn = "Add this:\n\n    # Keep the backup\n    if ok:\n        cp a b\n\n    done\n\nThen run it."
        #expect(kinds(setIn) == [.paragraph, .code, .paragraph])
        #expect(texts(setIn)[1] == "# Keep the backup\nif ok:\n    cp a b\n\ndone")
    }

    @Test func aTitleOverALineIsAHeading() {
        #expect(kinds("Important\n---\nrest") == [.heading(2), .paragraph])
        #expect(kinds("Important\n===\nrest") == [.heading(1), .paragraph])
        #expect(texts("Important\n---\nrest")[0] == "Important")
        // Under more than one line, dashes are a line across and nothing is lost.
        #expect(kinds("One\nTwo\n---\nrest") == [.paragraph, .rule, .paragraph])
        #expect(texts("One\nTwo\n===\nrest") == ["One\nTwo\n===\nrest"])
    }

    @Test func nothingWrittenIsEverLeftOut() {
        // Every letter and digit of some awkward replies is still there after reading.
        for reply in [
            "| a |\n|-|\n| 1 | 2 | 3\n| prose with a | inside",
            "```a`b\ncode\n```\nafter",
            "- one\n    two\n\n      three\n> q\n# h\n1) x\n\n    code\n---\n===\nend",
            "Title\n===\n\n| x\n|-\n~~~\nopen",
        ] {
            let read = ReplyFormat.blocks(of: reply).map { block -> String in
                if block.kind == .table { return ReplyFormat.rows(ofTable: block.text).joined().joined() }
                if case .item(let marker, _) = block.kind { return marker + block.text }
                return block.text
            }.joined()
            #expect(read.filter { $0.isLetter || $0.isNumber }.sorted() == reply.filter { $0.isLetter || $0.isNumber }.sorted(), "\(reply)")
        }
    }

    @Test func aPreviewIsOnePlainLine() {
        #expect(ReplyFormat.preview(of: "## Plan\n- a\n- b\n- c\n- d\n- e") == "Plan a b c d e")
        #expect(ReplyFormat.preview(of: "## Lisbon, three days\n\nHere is a **first** pass.\n- one\n- `two`") == "Lisbon, three days Here is a first pass. one two")
        #expect(ReplyFormat.preview(of: "Anytime.") == "Anytime.")
        // Cut off by the gateway in the middle of bold or code: the marks go.
        #expect(ReplyFormat.preview(of: "All I have, but **everything arr") == "All I have, but everything arr")
        #expect(ReplyFormat.preview(of: "run `trip sho") == "run trip sho")
        #expect(ReplyFormat.preview(of: "") == "")
    }

    @Test func aTableIsReadIntoCellsAndLookalikesAreLeftAlone() {
        let reply = "| Day | Rain |\n|---|:--:|\n| Mon | 2mm |\nAfter."
        #expect(kinds(reply) == [.table, .paragraph])
        #expect(ReplyFormat.rows(ofTable: texts(reply)[0]) == [["Day", "Rain"], ["Mon", "2mm"]])
        // Short rows are filled out and long ones kept whole; nothing in a row is left out.
        #expect(ReplyFormat.rows(ofTable: "| A | B |\n|-|-|\n| 1 |\n| 1 | 2 | 3 |\n| a \\| b | c |")
            == [["A", "B", ""], ["1", "", ""], ["1", "2", "3"], ["a | b", "c", ""]])
        // A bar inside code is not the end of a cell; a lone backtick does not swallow the row.
        #expect(ReplyFormat.rows(ofTable: "| Syntax | Meaning |\n|---|---|\n| `a | b` | either |\n| it`s | fine |")
            == [["Syntax", "Meaning"], ["`a | b`", "either"], ["it`s", "fine"]])
        // Code marked by two backticks, and a bar escaped inside code.
        #expect(ReplyFormat.rows(ofTable: "| Syntax | Meaning |\n|---|---|\n| ``a | b`` | either |\n| `a \\| b` | or |")
            == [["Syntax", "Meaning"], ["``a | b``", "either"], ["`a | b`", "or"]])
        // A quote, list item or heading holding a bar is not a table's headings.
        #expect(kinds("> a | b\n|---|---|\n| 1 | 2 |").first == .quote)
        #expect(kinds("- use a|b\n-|-").first == .item(marker: "•", depth: 0))
        #expect(kinds("# Option A | Option B\n|---|---|").first == .heading(1))
        // A table without end bars stops at a quote, and at prose with a different number of cells.
        #expect(kinds("Key | Value\n--- | ---\nColor | Red\n> Use A | B.") == [.table, .quote])
        #expect(kinds("A | B | C\n---|---|---\n1 | 2 | 3\nUse the a|b trick.") == [.table, .paragraph])
        // Rows may have bars at their ends even when the headings do not.
        let mixed = "Day | Plan\n--- | ---\n| Fri | Walk |\nSat | Train"
        #expect(kinds(mixed) == [.table])
        #expect(ReplyFormat.rows(ofTable: texts(mixed)[0]) == [["Day", "Plan"], ["Fri", "Walk"], ["Sat", "Train"]])
        // And the other way about.
        let other = "| A | B |\n|---|---|\n1 | 2\n| 3 | 4 |\n\nDone."
        #expect(kinds(other) == [.table, .paragraph])
        #expect(ReplyFormat.rows(ofTable: texts(other)[0]) == [["A", "B"], ["1", "2"], ["3", "4"]])
        // The rule must have as many columns as the headings.
        #expect(kinds("a | b | c\n---|---") == [.paragraph])
        // A row of dashes below the rule is a row.
        #expect(ReplyFormat.rows(ofTable: "| Q1 | Q2 |\n|---|---|\n| - | - |") == [["Q1", "Q2"], ["-", "-"]])
        // Straight after a paragraph, and written without bars at the ends.
        #expect(kinds("Prices:\n| Day | Cost |\n|---|---|\n| Fri | 15 |") == [.paragraph, .table])
        let bare = "Day | Cost\n--- | ---\nFri | 15\n\nDone."
        #expect(kinds(bare) == [.table, .paragraph])
        #expect(ReplyFormat.rows(ofTable: texts(bare)[0]) == [["Day", "Cost"], ["Fri", "15"]])
        // A row still arriving stays in the table.
        #expect(kinds("| Day | Cost |\n|---|---|\n| Fri") == [.table])
        #expect(ReplyFormat.rows(ofTable: texts("| Day | Cost |\n|---|---|\n| Fri")[0]) == [["Day", "Cost"], ["Fri", ""]])
        // Things that look like marks but are not.
        #expect(kinds("#hashtag and 3.14 are fine") == [.paragraph])
        #expect(kinds("**Note** this") == [.paragraph])
        #expect(kinds("-5 degrees") == [.paragraph])
        #expect(kinds("2026. A year.") == [.item(marker: "2026.", depth: 0)])
        #expect(kinds("| just a bar | here") == [.paragraph])
        #expect(kinds("* * *") == [.rule])
    }

    // MARK: Files a bot hands over

    private func kinds(_ text: String) -> [String] {
        ReplyFormat.blocks(of: text).map { block in
            switch block.kind {
            case .file: "file(\(block.text))"
            case .page: "page(\(block.text))"
            case .paragraph: "words(\(block.text))"
            case .code: "code(\(block.text))"
            default: "other(\(block.text))"
            }
        }
    }

    @Test func aFileHandedOverStandsApartFromTheWordsRoundIt() {
        #expect(kinds("Here it is:\n\nMEDIA:/home/bot/chart.png\n\nAnything else?") == ["words(Here it is:)", "file(/home/bot/chart.png)", "words(Anything else?)"])
        // On the line after the words with no gap, and with words after it on its own line.
        #expect(kinds("Done.\nMEDIA: /tmp/a.pdf\nSee page 2.") == ["words(Done.)", "file(/tmp/a.pdf)", "words(See page 2.)"])
        // Among words, and ending a sentence: the full stop is not the file's.
        #expect(kinds("I saved it as MEDIA:/tmp/notes.txt. Have a look.") == ["words(I saved it as)", "file(/tmp/notes.txt)", "words(Have a look.)"])
        #expect(kinds("MEDIA:/a/one.png and MEDIA:/a/two.png") == ["file(/a/one.png)", "words(and)", "file(/a/two.png)"])
    }

    @Test func aFilesNameMayBeQuotedSoItCanHoldSpaces() {
        #expect(kinds("MEDIA:\"/home/bot/my chart.png\"") == ["file(/home/bot/my chart.png)"])
        #expect(kinds("MEDIA:`/home/bot/my chart.png`") == ["file(/home/bot/my chart.png)"])
        #expect(kinds("`MEDIA:/home/bot/chart.png`") == ["file(/home/bot/chart.png)"])
        // The whole tag in backticks, with a space in the name.
        #expect(kinds("`MEDIA:/tmp/my chart.png`") == ["file(/tmp/my chart.png)"])
        #expect(kinds("Here: `MEDIA:~/Pictures/holiday photo.jpg` for you") == ["words(Here:)", "file(~/Pictures/holiday photo.jpg)", "words(for you)"])
        #expect(kinds("MEDIA:'C:\\Users\\bot\\a b.png'") == ["file(C:\\Users\\bot\\a b.png)"])
    }

    /// A mark inside a block of code pairs with nothing outside it, so it cannot hide a
    /// file handed over just after the block.
    @Test func aMarkInsideABlockOfCodeDoesNotHideAFileAfterIt() {
        let blocks = ReplyFormat.blocks(of: "~~~sh\necho '`'\n~~~\nMEDIA:/tmp/chart.png\nUse `this` command")
        #expect(blocks.map(\.kind) == [.code, .file, .paragraph])
        #expect(blocks[1].text == "/tmp/chart.png")
        // The same for code set in by four spaces, and for a row of a table.
        let setIn = ReplyFormat.blocks(of: "    echo '`'\nMEDIA:/tmp/chart.png\nUse `this` command")
        #expect(setIn.map(\.kind).contains(.file))
        let table = ReplyFormat.blocks(of: "| a | ` |\n|---|---|\n| 1 | 2 |\nMEDIA:/tmp/chart.png\nUse `this` command")
        #expect(table.map(\.kind).contains(.file))
        // A line that begins with a bar and is no table breaks nothing: code goes on.
        let piped = ReplyFormat.blocks(of: "Use `printf a\n| cat\nMEDIA:/tmp/secret.png\nend` as an example.")
        #expect(!piped.map(\.kind).contains(.file))
        // Lines set in under an item of a list are the item going on, code and all.
        let listed = ReplyFormat.blocks(of: "- Item\n\n    Use `example\n    MEDIA:/tmp/secret.png\n    end` to show it")
        #expect(!listed.map(\.kind).contains(.file))
        // A fence set in by four spaces is itself code, and opens nothing.
        let setInFence = ReplyFormat.blocks(of: "    ~~~\n\nUse `example\nMEDIA:/tmp/secret.png\nend` to show it")
        #expect(!setInFence.map(\.kind).contains(.file))
        // And a tag shown as code in the lines after a block is still not a file.
        let shown = ReplyFormat.blocks(of: "```\nx\n```\nRun `echo MEDIA:/tmp/a.png\nto see` it")
        #expect(!shown.map(\.kind).contains(.file))
    }

    /// Written bare from the root, a name runs to its ending and so may hold spaces, as
    /// Hermes's own app reads it.
    @Test func aBareNameFromTheRootMayHoldSpaces() {
        #expect(kinds("The calendar: MEDIA:/demo/planting calendar.pdf.") == ["words(The calendar:)", "file(/demo/planting calendar.pdf)"])
        #expect(kinds("MEDIA:~/Pictures/my holiday photo.JPG") == ["file(~/Pictures/my holiday photo.JPG)"])
        #expect(kinds("MEDIA:/a/one two.png and then MEDIA:/a/three.png") == ["file(/a/one two.png)", "words(and then)", "file(/a/three.png)"])
        // An ending part way through a name is not where the name ends.
        #expect(kinds("MEDIA:/tmp/chart.png_backup.png") == ["file(/tmp/chart.png_backup.png)"])
        #expect(kinds("MEDIA:/tmp/my chart.png_old.pdf is here") == ["file(/tmp/my chart.png_old.pdf)", "words(is here)"])
        // A backtick written with a backslash opens no code: the span after it is whole.
        #expect(kinds("Type \\` then `echo MEDIA:/tmp/a.png` to try") == ["words(Type \\` then `echo MEDIA:/tmp/a.png` to try)"])
        #expect(kinds("A \\` mark, and MEDIA:/tmp/a.png") == ["words(A \\` mark, and)", "file(/tmp/a.png)"])
        // Nor into code shown after it.
        #expect(kinds("MEDIA:/tmp/archive.bin; run `unzip archive.zip` to extract it.") == ["file(/tmp/archive.bin)", "words(run `unzip archive.zip` to extract it.)"])
        // Not from the root, it stops at the first space as before.
        #expect(kinds("MEDIA:out/chart.png is ready") == ["file(out/chart.png)", "words(is ready)"])
        // A name with an ending that is not known does not run on into the next file.
        #expect(kinds("MEDIA:/tmp/archive.bin and MEDIA:/tmp/chart.png") == ["file(/tmp/archive.bin)", "words(and)", "file(/tmp/chart.png)"])
        // With no known ending to run to, the same.
        #expect(kinds("MEDIA:/tmp/data.bin is ready") == ["file(/tmp/data.bin)", "words(is ready)"])
    }

    @Test func aNameWithTwoEndingsIsOneFile() {
        #expect(kinds("MEDIA:/tmp/archive.tar.gz") == ["file(/tmp/archive.tar.gz)"])
        #expect(kinds("MEDIA:/tmp/my file.png.zip is the lot") == ["file(/tmp/my file.png.zip)", "words(is the lot)"])
        #expect(kinds("It is at MEDIA:/tmp/a.png. Enjoy.") == ["words(It is at)", "file(/tmp/a.png)", "words(Enjoy.)"])
        // Part of another word, it is not the tag.
        #expect(kinds("SOCIAL_MEDIA:/tmp/a.png is a label") == ["words(SOCIAL_MEDIA:/tmp/a.png is a label)"])
    }

    /// In a list item, a quote or a heading the line keeps its place, and the file follows it.
    @Test func aFileInAListItemOrAQuoteFollowsItsLine() {
        let list = ReplyFormat.blocks(of: "- See MEDIA:/tmp/a.png\n- And this")
        #expect(list.map(\.text) == ["See `a.png`", "/tmp/a.png", "And this"])
        #expect(list.map { $0.kind == .file } == [false, true, false])
        if case .item = list[0].kind {} else { Issue.record("The first line was not kept as a list item") }
        let quote = ReplyFormat.blocks(of: "> MEDIA:/tmp/b.pdf")
        #expect(quote.map(\.text) == ["`b.pdf`", "/tmp/b.pdf"])
        #expect(quote.first?.kind == .quote)
        // The file's name is taken as it was read, quotes inside it and all, and a list
        // goes on after it at the depth it had.
        let odd = ReplyFormat.blocks(of: "- Here: MEDIA:'/tmp/a\"b.png'\n  - nested")
        #expect(odd.map(\.text) == ["Here: `a\"b.png`", "/tmp/a\"b.png", "nested"])
        if case .item(_, let depth) = odd[2].kind { #expect(depth == 1) } else { Issue.record("The nested item was not kept as one") }
        // Set in under a list item after a gap, it is code as before.
        let code = ReplyFormat.blocks(of: "- Example:\n\n      MEDIA:/tmp/a.png")
        #expect(code.allSatisfy { $0.kind != .file })
    }

    @Test func aPreviewLineIsAPageToShow() {
        #expect(kinds("Here is the chart:\n\n::preview{file=\"/tmp/chart.html\"}") == ["words(Here is the chart:)", "page(/tmp/chart.html)"])
        #expect(kinds("::preview{title=\"x\" file=\"out/page.html\" height=300}") == ["page(out/page.html)"])
        // Only by itself on a line.
        #expect(kinds("use ::preview{file=\"a.html\"} like so") == ["words(use ::preview{file=\"a.html\"} like so)"])
        #expect(kinds("::preview{file='out/page.HTM'}") == ["page(out/page.HTM)"])
        // `file` as the end of another word names no file.
        #expect(kinds("::preview{profile=\"work\"}") == ["words(::preview{profile=\"work\"})"])
        // Only HTML is a page: anything else named so is a file like any other, and so
        // is a name that only has `.html` somewhere in it.
        #expect(kinds("::preview{file=\"/tmp/chart.png\"}") == ["file(/tmp/chart.png)"])
        #expect(kinds("::preview{file=\"/tmp/page.html.zip\"}") == ["file(/tmp/page.html.zip)"])
        #expect(kinds("::preview{file=\"/tmp/html\"}") == ["file(/tmp/html)"])
        #expect(ReplyFormat.preview(of: "::preview{file=\"/tmp/chart.html\"}") == "Sent chart.html")
    }

    /// Hermes's own app can be given more of these to draw. This one draws none of them,
    /// and a line that is only for such a thing is left out rather than shown as written.
    @Test func aLineForSomethingThisAppCannotDrawIsLeftOut() {
        #expect(kinds("Here you go.\n\n::weather-card{city=\"Lisbon\"}\n\nAnything else?") == ["words(Here you go.)", "words(Anything else?)"])
        #expect(kinds("One\n::map{}\nTwo") == ["words(One)", "words(Two)"])
        // Among words, shown in code, or not of that form, it stays as written.
        #expect(kinds("write ::map{place=\"x\"} for a map") == ["words(write ::map{place=\"x\"} for a map)"])
        #expect(kinds("`::map{place=\"x\"}`") == ["words(`::map{place=\"x\"}`)"])
        #expect(kinds("```\n::map{place=\"x\"}\n```") == ["code(::map{place=\"x\"})"])
        #expect(kinds("Use `this\n::map{place=\"x\"}\nform` for one.") == ["words(Use `this\n::map{place=\"x\"}\nform` for one.)"])
        #expect(kinds("::Map{place=\"x\"}") == ["words(::Map{place=\"x\"})"])
        #expect(kinds("::map{a{b}}") == ["words(::map{a{b}})"])
        #expect(kinds("std::vector{1, 2}") == ["words(std::vector{1, 2})"])
        #expect(kinds("::map") == ["words(::map)"])
        // One directly after another, and a page among them.
        #expect(kinds("::map{}\n::preview{file=\"a.html\"}\n::map{}") == ["page(a.html)"])
        #expect(kinds("::preview{file=\"a.html\"}\n::preview{file=\"b.html\"}") == ["page(a.html)", "page(b.html)"])
        // Words that only have the look of one: styles, code, a sentence in braces. A
        // title written the old way over a line of signs is still a title.
        for words in ["::before{content: \"hello\"}", "::selection{background: blue}", "::point{1, 2}", "::widget{The text being discussed}", "::map{place}", "::map{a=1b=2 c}"] {
            #expect(kinds(words) == ["words(\(words))"], "\(words)")
        }
        #expect(ReplyFormat.blocks(of: "::widget{The text being discussed}\n=====").map(\.kind) == [.heading(1)])
        // What is between the braces is read whole: a quote escaped inside a value, a
        // stray word or a value left open names no file.
        for words in [
            "::preview{title=\"say \\\" file=evil.html \\\"\"}", "::preview{title='don't file=evil.html'}", "::preview{note=\"a\\\" file=\\\"/etc/passwd\\\"\"}",
            "::preview{file=evil.html\"}", "::preview{file= name=\"page.html\"}", "::preview{not file=\"page.html\"}", "::preview{file=\"a.html\"title=\"x\"}",
            "::preview{file=\"/path/to/page.html\"}", "::preview{file=\"\"}",
        ] {
            #expect(kinds(words) == ["words(\(words))"], "\(words)")
        }
        // The last file named, as in Hermes's own app.
        #expect(kinds("::preview{file=\"a.html\" file=\"b.html\"}") == ["page(b.html)"])
        // A block of code that opens on a list item's own line is code: nothing in it
        // is fetched or left out.
        #expect(kinds("- ```text\n  ::preview{file=\"page.html\"}\n  ```\n- next") == ["other()", "code(::preview{file=\"page.html\"})", "other(next)"])
        #expect(kinds("1. ```\n   ::map{}\n   MEDIA:/tmp/a.png\n   ```") == ["other()", "code(::map{}\nMEDIA:/tmp/a.png)"])
        // On the line of an item within an item, and with words after the fence that
        // have the look of a file being sent.
        #expect(kinds("- - ```text\n    ::preview{file=\"page.html\"}\n    ```") == ["other()", "code(::preview{file=\"page.html\"})"])
        #expect(kinds("- ```text MEDIA:/tmp/example.png\n  ::preview{file=\"example.html\"}\n  ```") == ["other()", "code(::preview{file=\"example.html\"})"])
        // A line with the look of a directive that is not one is words, whatever it holds.
        #expect(kinds("::preview{note=\"MEDIA:/tmp/example.png\" garbage}") == ["words(::preview{note=\"MEDIA:/tmp/example.png\" garbage})"])
        #expect(kinds("::preview{file=\"   \"}") == ["words(::preview{file=\"   \"})"])
        // Nor one still arriving, whose closing brace has not come.
        #expect(kinds("::preview{note=\"MEDIA:/tmp/example.png\"") == ["words(::preview{note=\"MEDIA:/tmp/example.png\")"])
        #expect(kinds("> ```\n> ::preview{file=\"page.html\"}\n> ```").allSatisfy { !$0.hasPrefix("page") && !$0.hasPrefix("file") })
        // Its own form inside its contents: not one, and names no file.
        #expect(kinds("::preview{title=\"::preview{file='x.html'}\"}") == ["words(::preview{title=\"::preview{file='x.html'}\"})"])
    }

    @Test func whatOnlyLooksLikeAFileBeingHandedOverIsLeftAsWords() {
        #expect(kinds("The MEDIA: tag is how files are sent.") == ["words(The MEDIA: tag is how files are sent.)"])
        #expect(kinds("MEDIA: nothing") == ["words(MEDIA: nothing)"])
        // Shown inside a longer stretch of code, or in a table's cell: not being sent.
        #expect(kinds("Run `echo MEDIA:/tmp/a.png` to try it.") == ["words(Run `echo MEDIA:/tmp/a.png` to try it.)"])
        #expect(ReplyFormat.blocks(of: "| Tag | Use |\n|---|---|\n| MEDIA:/tmp/a.png | sends it |").allSatisfy { $0.kind != .file })
        // In code written with two backticks, or with a backtick inside it.
        #expect(kinds("Use ``MEDIA:/tmp/a.png`` like that.") == ["words(Use ``MEDIA:/tmp/a.png`` like that.)"])
        #expect(kinds("Try ``echo `x` MEDIA:/tmp/a.png`` now") == ["words(Try ``echo `x` MEDIA:/tmp/a.png`` now)"])
        // A command shown in code that happens to begin with the tag.
        #expect(kinds("Run `MEDIA:/tmp/a.png --flag` to see.") == ["words(Run `MEDIA:/tmp/a.png --flag` to see.)"])
        #expect(kinds("::preview{title=\"a\"} and {file=\"b.html\"}") == ["words(::preview{title=\"a\"} and {file=\"b.html\"})"])
        // Code that opens on one line and closes on a later one.
        #expect(ReplyFormat.blocks(of: "To send one, write `echo hi\nMEDIA:/tmp/a.png` in the reply.").allSatisfy { $0.kind != .file })
        #expect(ReplyFormat.blocks(of: "Like ``this\nMEDIA:/tmp/a.png\nand more`` there.").allSatisfy { $0.kind != .file })
        // A backtick that is never closed is only a backtick: the file after it is one.
        #expect(kinds("It's a ` mark.\nMEDIA:/tmp/a.png") == ["words(It's a ` mark.)", "file(/tmp/a.png)"])
        // Code that opens in a list item and closes lines later.
        #expect(ReplyFormat.blocks(of: "- Use `code\nMEDIA:/tmp/secret.png\nmore code`.").allSatisfy { $0.kind != .file })
        // A page line shown inside code that runs over several lines.
        #expect(ReplyFormat.blocks(of: "Use `example\n::preview{file=\"/tmp/secret.png\"}\nend` for a page.").allSatisfy { $0.kind != .file })
        // A page whose title only mentions a file names none.
        #expect(kinds("::preview{title=\"set file=x.html here\"}") == ["words(::preview{title=\"set file=x.html here\"})"])
        #expect(kinds("::preview{title=\"file=a.html\" file=\"real.html\"}") == ["page(real.html)"])
        // After a first file on the line, a second one shown in code is still only shown.
        #expect(kinds("MEDIA:/a/one.png then run `cat MEDIA:/a/two.png` yourself") == ["file(/a/one.png)", "words(then run `cat MEDIA:/a/two.png` yourself)"])
        // A bot saying how it sends files, as a real one did when asked.
        #expect(kinds("a bare `MEDIA:/absolute/path` line is intercepted and delivered") == ["words(a bare `MEDIA:/absolute/path` line is intercepted and delivered)"])
        #expect(kinds("Write MEDIA:/path/to/file.png to send one.") == ["words(Write MEDIA:/path/to/file.png to send one.)"])
        // Inside code it is code.
        #expect(kinds("```\nMEDIA:/tmp/a.png\n```") == ["code(MEDIA:/tmp/a.png)"])
        #expect(ReplyFormat.preview(of: "MEDIA:/home/bot/chart.png") == "Sent chart.png")
    }

    /// A long reply is split in time that grows with its length, not with its square:
    /// it is split again each time more of it arrives. Thread CPU time at two sizes is
    /// compared, so time spent waiting behind other processes does not decide it.
    @Test func aLongReplyIsSplitQuickly() {
        func reply(items: Int, lines: Int) -> String {
            (1...items).map { "- item \($0) with `cat MEDIA:/tmp/a.png` shown in passing" }.joined(separator: "\n")
                + "\n\n" + (1...lines).map { "line \($0) of one long paragraph with `code`" }.joined(separator: "\n")
        }
        func threadCPUSeconds() -> Double {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        }
        func measureCPU(_ work: () -> Void) -> Double {
            let started = threadCPUSeconds()
            work()
            return threadCPUSeconds() - started
        }
        // Small replies are enough: the growth is what carries the check, and even a
        // regression is quick enough to be reported rather than merely timing out.
        let short = reply(items: 10, lines: 4)
        let long = reply(items: 40, lines: 16)
        // Thread CPU time, not wall-clock time: waiting behind other processes is not
        // counted. The quietest of interleaved reads is taken, so even a cache or clock
        // change is not read as slower work.
        _ = ReplyFormat.blocks(of: short)
        var shortest = Double.greatestFiniteMagnitude
        var longest = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            shortest = min(shortest, measureCPU { _ = ReplyFormat.blocks(of: short) })
            longest = min(longest, measureCPU { _ = ReplyFormat.blocks(of: long) })
        }
        let growth = longest / shortest
        #expect(growth < 10, "grew \(growth)x for 4x the lines (short \(shortest)s of CPU, long \(longest)s)")
        #expect(longest < 2, "4x the lines took \(longest)s of CPU")
        #expect(ReplyFormat.blocks(of: short).count == 11)
        #expect(ReplyFormat.blocks(of: long).count == 41)
    }
}
