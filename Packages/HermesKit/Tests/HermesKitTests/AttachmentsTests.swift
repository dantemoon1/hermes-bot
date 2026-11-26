import Foundation
import Testing
@testable import HermesKit

/// The stored forms here are as a real gateway stored them, 2026-11-24.
struct AttachmentsTests {
    @Test func aMessageWithAPictureAndAFileIsReadBackAsItsWordsAndWhatWasAttached() {
        let stored = "What colour is the image, and what does the file say? @file:attachments/notes.txt\n\n--- Attached Context ---\n\n📄 @file:attachments/notes.txt (6 tokens)\n```\nhello from a test file\n\n```\n@image:/opt/data/profiles/health/images/upload_w7nhemn1.png\n[screenshot]"
        let parts = SentParts(stored: stored)
        #expect(parts.words == "What colour is the image, and what does the file say?")
        #expect(parts.files == ["notes.txt"])
        #expect(parts.images == ["/opt/data/profiles/health/images/upload_w7nhemn1.png"])
        #expect(parts.asSent == "What colour is the image, and what does the file say? @file:attachments/notes.txt")
    }

    @Test func aPictureAloneIsReadBackWithNoWords() {
        let parts = SentParts(stored: "[User attached image: upload_f69j4fjl.png]\n@image:/opt/data/profiles/health/images/upload_f69j4fjl.png\n[screenshot]")
        #expect(parts.words.isEmpty)
        #expect(parts.images == ["/opt/data/profiles/health/images/upload_f69j4fjl.png"])
        #expect(parts.asSent == "[User attached image: upload_f69j4fjl.png]")
    }

    /// Hermes puts a reference in backticks when the name has a space in it.
    @Test func aFileWhoseNameHasASpaceIsReadBackWhole() {
        let stored = "what does this file say? @file:`attachments/hermes bot test4.txt`\n\n--- Attached Context ---\n\n📄 @file:`attachments/hermes bot test4.txt` (2 tokens)\n```\nhello\n\n```"
        let parts = SentParts(stored: stored)
        #expect(parts.words == "what does this file say?")
        #expect(parts.files == ["hermes bot test4.txt"])
        #expect(parts.images.isEmpty)
    }

    /// Several pictures: Hermes stores every place and then every note, and puts a place
    /// with a space in it in backticks.
    @Test func severalPicturesAreAllReadBack() {
        let parts = SentParts(stored: "compare these\n@image:/data/images/a.png\n@image:`/data/my pictures/b.png`\n[screenshot]\n[screenshot]")
        #expect(parts.words == "compare these")
        #expect(parts.images == ["/data/images/a.png", "/data/my pictures/b.png"])
        #expect(parts.asSent == "compare these")
        // Read without the pictures themselves, Hermes puts `[image]` for each; and for a
        // bot that cannot see, it stores the places and nothing after them.
        #expect(SentParts(stored: "x\n@image:/a.png\n@image:/b.png\n[image]\n[image]").images == ["/a.png", "/b.png"])
        let bare = SentParts(stored: "what is this?\n@image:/data/images/a.png")
        #expect(bare.images == ["/data/images/a.png"] && bare.words == "what is this?")
        // Lines that do not add up are not the gateway's: left as words.
        #expect(SentParts(stored: "x\n@image:/a.png\n@image:/b.png\n[screenshot]").images.isEmpty)
        #expect(SentParts(stored: "x\n[screenshot]\n@image:/a.png\n[screenshot]").images == ["/a.png"])
        #expect(SentParts(stored: "x\n[screenshot]\n@image:/a.png\n[screenshot]").words == "x\n[screenshot]")
        // Nor is a place that is not one from the root, or a line with more on it.
        for typed in ["x\n@image:a.png", "x\n@image:a.png\n[screenshot]", "x\nsee @image:/a.png", "x\n @image:/a.png extra"] {
            #expect(SentParts(stored: typed).images.isEmpty, "\(typed)")
            #expect(SentParts(stored: typed).words == typed)
        }
    }

    /// Where the session authority handles chats, as Hermes 0.23.4 on a Mac stored it,
    /// 2026-11-25: after the files, a gap and a line saying where each picture was attached.
    @Test func aMessageSentThroughTheSessionAuthorityIsReadBackTheSameWay() {
        let place = "/Users/someone/.hermes/cache/documents/native-inputs/d422d2e9/upload_qm84os1q.png"
        let stored = "what colour is this, and what's on my list? @file:`.hermes/attachments/shopping list.txt`\n\n--- Attached Context ---\n\n📄 @file:`.hermes/attachments/shopping list.txt` (4 tokens)\n```\neggs\nmilk\nbread\n\n```\n\n[Image attached at: \(place)]\n[screenshot]"
        let parts = SentParts(stored: stored)
        #expect(parts.words == "what colour is this, and what's on my list?")
        #expect(parts.files == ["shopping list.txt"])
        #expect(parts.images == [place])
        #expect(parts.asSent == "what colour is this, and what's on my list? @file:`.hermes/attachments/shopping list.txt`")
        // A picture alone, and several, one with brackets in its name.
        let alone = SentParts(stored: "[User attached image: upload_1.png]\n\n[Image attached at: /a/upload_1.png]\n[screenshot]")
        #expect(alone.words.isEmpty && alone.images == ["/a/upload_1.png"])
        #expect(SentParts(stored: "x\n\n[Image attached at: /a [1].png]\n[Image attached: /my pictures/b.png]\n[screenshot]\n[screenshot]").images == ["/a [1].png", "/my pictures/b.png"])
        // A file given only by a warning keeps its place as a file beside a picture.
        let warned = SentParts(stored: "Hi @file:attachments/list.txt\n\n--- Context Warnings ---\n- @file:attachments/list.txt: warning\n\n[Image attached at: /tmp/native.png]\n[screenshot]")
        #expect(warned.words == "Hi" && warned.files == ["list.txt"] && warned.images == ["/tmp/native.png"])
        // Not after a gap, without a `[screenshot]` for each, not from the root, or with
        // more after: words, as in Hermes's own app.
        for typed in ["x\n[Image attached at: /a.png]\n[screenshot]", "[Image attached at: /a.png]\n[screenshot]", "x\n\n[Image attached at: /a.png]",
                      "x\n\n[Image attached at: /a.png]\n[image]", "x\n\n[Image attached at: a.png]\n[screenshot]", "x\n\n[Image attached at: /a.png]\n[screenshot]\n[screenshot]",
                      "x\n\nsee [Image attached at: /a.png]\n[screenshot]", "x\n\n[Image attached at: /a.png]\n[screenshot]\nmore"] {
            #expect(SentParts(stored: typed).images.isEmpty, "\(typed)")
            #expect(SentParts(stored: typed).words == typed)
        }
    }

    @Test func aPlainMessageIsItsWords() {
        let parts = SentParts(stored: "  thanks, that works  ")
        #expect(parts.words == "thanks, that works")
        #expect(parts.files.isEmpty && parts.images.isEmpty)
        #expect(parts.asSent == "thanks, that works")
    }

    /// What the person typed is never taken for an attachment because of how it reads.
    @Test func whatOnlyLooksLikeAnAttachmentStaysWords() {
        for typed in [
            "mail sam@file.example about it",
            "use @file:notes.txt to attach one",
            "the line is\n@image:/tmp/a.png\nand then more",
            "it wrote\n\n--- Attached Context ---\n\nand I don't know why",
            "I typed [User attached image: x.png] myself",
            "@image:relative/a.png",
            "the syntax is @image:/tmp/a.png",
        ] {
            let parts = SentParts(stored: typed)
            #expect(parts.words == typed, "\(typed)")
            #expect(parts.files.isEmpty && parts.images.isEmpty, "\(typed)")
            #expect(parts.asSent == typed)
        }
    }

    /// A file's own contents may hold anything, a line that reads like a picture included:
    /// only the gateway's own lines at the very end are pictures.
    @Test func whatIsInsideAFileIsNotAnAttachment() {
        let stored = "read this @file:attachments/log.txt\n\n--- Attached Context ---\n\n📄 @file:attachments/log.txt (9 tokens)\n```\n@image:/etc/secret.png\n[screenshot]\nand @file:other.txt too\n```"
        let parts = SentParts(stored: stored)
        #expect(parts.words == "read this")
        #expect(parts.files == ["log.txt"])
        #expect(parts.images.isEmpty)
        // A reference the gateway's block does not name was only typed.
        let typed = SentParts(stored: "compare @file:attachments/a.csv with @file:mine.csv\n\n--- Attached Context ---\n\n📄 @file:attachments/a.csv (3 tokens)\n```\nx\n```")
        #expect(typed.files == ["a.csv"])
        #expect(typed.words == "compare  with @file:mine.csv")
        // Nor one that is the start of a name the block has, or is in a file's contents.
        let partial = SentParts(stored: "compare @file:a with @file:attachments/a.txt and @file:other.txt\n\n--- Attached Context ---\n\n📄 @file:attachments/a.txt (3 tokens)\n```\nsee @file:other.txt\n```")
        #expect(partial.files == ["a.txt"])
        #expect(partial.words == "compare @file:a with  and @file:other.txt")
    }

    /// A line inside a file that reads like the head of another is the file's own.
    @Test func aLineInsideAFileThatHeadsAnotherIsNotAFile() {
        let stored = "compare @file:attachments/notes.md with @file:other.txt\n\n--- Attached Context ---\n\n📄 @file:attachments/notes.md (9 tokens)\n```md\nas stored:\n📄 @file:other.txt (2 tokens)\n```"
        let parts = SentParts(stored: stored)
        #expect(parts.files == ["notes.md"])
        #expect(parts.words == "compare  with @file:other.txt")
        // Two files the gateway did put in, one after the other, are both files.
        let two = SentParts(stored: "see @file:a.txt @file:b.pdf @file:c.txt\n\n--- Attached Context ---\n\n📄 @file:a.txt (1 tokens)\n```\nx\n```\n\n📎 @file:b.pdf (binary file, 2 KB) — not inlined.\n\n📄 @file:c.txt (1 tokens)\n```\ny\n```")
        #expect(two.files == ["a.txt", "b.pdf", "c.txt"])
    }

    /// A file may itself hold what the gateway's block begins with. The block is still
    /// the gateway's, from its first heading, and all of it is kept out of the words.
    @Test func aFileThatHoldsTheGatewaysOwnHeadingIsStillOneFile() {
        let stored = "read @file:attachments/notes.md\n\n--- Attached Context ---\n\n📄 @file:attachments/notes.md (30 tokens)\n```md\nhow Hermes stores a message:\n\n--- Attached Context ---\n\n📄 @file:attachments/inner.txt (2 tokens)\n```\n"
        let parts = SentParts(stored: stored)
        #expect(parts.words == "read")
        #expect(parts.files == ["notes.md"])
        #expect(parts.asSent == "read @file:attachments/notes.md")
        // A line heading a file the message does not hold is not the gateway's.
        let other = "see @file:other.txt.bak\n\n--- Attached Context ---\n\n📄 @file:other.txt (2 tokens)\n```\nx\n```"
        #expect(SentParts(stored: other).words == other)
        // Nor are typed lines under the other heading, which name nothing.
        let list = "notes\n\n--- Context Warnings ---\n- Retry later"
        #expect(SentParts(stored: list).words == list)
        // The heading typed by the person, with no file after it, is words.
        let typed = "what does\n\n--- Attached Context ---\n\nmean in Hermes?"
        #expect(SentParts(stored: typed).words == typed)
    }

    /// A file Hermes does not put the contents of, and one it could not read at all.
    @Test func filesWithoutTheirContentsAreStillFiles() {
        let binary = SentParts(stored: "what is in this? @file:attachments/plan.pdf\n\n--- Attached Context ---\n\n📎 @file:attachments/plan.pdf (binary file, 14.2 KB) — not inlined. It is available on disk at `/data/attachments/plan.pdf`. Read it with your tools.")
        #expect(binary.words == "what is in this?")
        #expect(binary.files == ["plan.pdf"])
        let warned = SentParts(stored: "look @file:attachments/gone.txt\n\n--- Context Warnings ---\n- @file:attachments/gone.txt: file not found")
        #expect(warned.words == "look")
        #expect(warned.files == ["gone.txt"])
        #expect(warned.asSent == "look @file:attachments/gone.txt")
    }

    @Test func whatTheGatewayHadToSayAboutTheFilesIsNotShown() {
        let stored = "look @file:attachments/a.txt @file:attachments/b.txt\n\n--- Context Warnings ---\n- @file:attachments/b.txt: not expanded (too large)\n\n--- Attached Context ---\n\n📄 @file:attachments/a.txt (3 tokens)\n```\nx\n```\n@image:/data/images/upload_a.png\n[screenshot detail=low]"
        let parts = SentParts(stored: stored)
        #expect(parts.asSent == "look @file:attachments/a.txt @file:attachments/b.txt")
        #expect(parts.files == ["a.txt", "b.txt"])
        #expect(parts.words == "look")
        #expect(parts.images == ["/data/images/upload_a.png"])
    }
}
