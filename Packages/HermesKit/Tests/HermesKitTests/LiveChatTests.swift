import Foundation
import Testing
@testable import HermesKit

@Suite(.timeLimit(.minutes(1)))
struct LiveChatTests {
    private func event(_ type: String, _ payload: String, session: String = "live-1") -> String {
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"\#(type)","session_id":"\#(session)","payload":\#(payload)}}"#
    }

    private func chat(_ json: String = #"{"id":"stored-1"}"#) throws -> BotChat {
        try JSONDecoder().decode(BotChat.self, from: Data(json.utf8))
    }

    @Test func aCompactedChatIsOpenedWhereItContinues() throws {
        #expect(try chat().liveID == "stored-1")
        #expect(try chat(#"{"id":"stored-1","resolved_id":"tip-9"}"#).liveID == "tip-9")
        #expect(try chat(#"{"id":"stored-1","resolved_id":""}"#).liveID == "stored-1")
    }

    @Test func eventsBecomeTurnSteps() {
        func step(_ type: String, _ payload: JSONValue) -> TurnEvent? {
            TurnEvent(GatewayEvent(type: type, payload: payload, sessionID: "s"))
        }
        #expect(step("message.start", .object([:])) == .started)
        #expect(step("message.delta", .object(["text": .string("Hi")])) == .text("Hi"))
        #expect(step("message.delta", .object(["text": .null])) == nil)
        #expect(step("message.interim", .object(["text": .string("One sec."), "already_streamed": .bool(false)])) == .text("One sec.\n\n"))
        #expect(step("message.interim", .object(["text": .string("One sec."), "already_streamed": .bool(true)])) == .pause)
        #expect(step("tool.start", .object(["tool_id": .string("1"), "name": .string(" calendar ")])) == .tool("calendar"))
        #expect(step("tool.start", .object(["tool_id": .string("1"), "name": .string("  ")])) == nil)
        #expect(step("message.complete", .object(["text": .string("Done"), "status": .string("complete")])) == .finished(reply: "Done", outcome: .complete))
        #expect(step("message.complete", .object([:])) == .finished(reply: nil, outcome: .complete))
        #expect(step("message.complete", .object(["status": .string("interrupted")])) == .finished(reply: nil, outcome: .stopped))
        // A failed turn's text is the error, not a reply, unless marked as a partial reply.
        #expect(step("message.complete", .object(["status": .string("error"), "error": .string("No credit"), "text": .string("No credit")])) == .finished(reply: nil, outcome: .failed("No credit")))
        #expect(step("message.complete", .object(["status": .string("error"), "text": .string("Out of credit")])) == .finished(reply: nil, outcome: .failed("Out of credit")))
        #expect(step("message.complete", .object(["status": .string("error"), "error": .string("Cut off"), "text": .string("Half an ans"), "partial": .bool(true)])) == .finished(reply: "Half an ans", outcome: .failed("Cut off")))
        #expect(step("error", .object(["message": .string("Agent failed to start")])) == .trouble("Agent failed to start"))
        #expect(step("session.usage", .object([:])) == nil)
    }

    @Test func aTurnCollectsItsReplyAndStaysFinished() {
        var turn = LiveTurn()
        #expect(turn.isWorking)
        turn.apply(.started)
        turn.apply(.tool("calendar"))
        turn.apply(.text("Mon"))
        turn.apply(.text("day"))
        #expect(turn.reply == "Monday")
        #expect(turn.tools == ["calendar"])
        turn.apply(.finished(reply: "Monday.", outcome: .complete))
        #expect(turn.reply == "Monday.")
        #expect(!turn.isWorking)
        turn.apply(.text(" late"))
        turn.apply(.finished(reply: "x", outcome: .stopped))
        #expect(turn.reply == "Monday.")
        #expect(turn.outcome == .complete)

        var stopped = LiveTurn()
        stopped.apply(.started)
        stopped.apply(.text("Half"))
        stopped.apply(.finished(reply: nil, outcome: .stopped))
        #expect(stopped.reply == "Half")
    }

    /// The end of a turn that was already running when ours was sent is not our answer.
    @Test func anEarlierTurnsTailIsNotTakenForOurs() {
        var turn = LiveTurn()
        turn.apply(.text("someone else's words"))
        turn.apply(.tool("browser"))
        turn.apply(.finished(reply: "someone else's answer", outcome: .complete))
        turn.apply(.finished(reply: "someone else's half", outcome: .stopped))
        #expect(turn.isWorking)
        #expect(turn.reply.isEmpty && turn.tools.isEmpty)
        turn.apply(.started)
        turn.apply(.text("Ours"))
        turn.apply(.finished(reply: nil, outcome: .complete))
        #expect(turn.reply == "Ours")
        #expect(turn.outcome == .complete)
    }

    @Test func troubleEndsATurnOnlyBeforeItBegins() {
        var never = LiveTurn()
        never.apply(.trouble("Agent failed to start"))
        #expect(never.outcome == .failed("Agent failed to start"))

        var running = LiveTurn()
        running.apply(.started)
        running.apply(.text("So far"))
        running.apply(.trouble("Couldn't switch model"))
        #expect(running.isWorking)
        #expect(running.reply == "So far")
    }

    /// The gateway ends a turn with a failure, and no start, when the bot's agent can't start.
    @Test func aFailureBeforeTheTurnBeginsEndsIt() {
        var turn = LiveTurn()
        turn.apply(.finished(reply: nil, outcome: .failed("No model")))
        #expect(turn.outcome == .failed("No model"))
        #expect(turn.reply.isEmpty)
    }

    @Test func aPauseSeparatesWhatWasSaidBeforeWorkFromWhatFollows() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.pause)
        #expect(turn.reply.isEmpty)
        turn.apply(.text("Checking."))
        turn.apply(.pause)
        turn.apply(.pause)
        turn.apply(.text("Done."))
        #expect(turn.reply == "Checking.\n\nDone.")
        #expect(turn.contents == [.said("Checking.\n\nDone.")])
    }

    @Test func whatTheBotSaysAndDoesIsKeptInOrder() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.tool("calendar"))
        turn.apply(.tool("weather"))
        turn.apply(.text("Rain at "))
        turn.apply(.text("two."))
        turn.apply(.tool("notes"))
        turn.apply(.text("Noted."))
        #expect(turn.contents == [.used(["calendar", "weather"]), .said("Rain at two."), .used(["notes"]), .said("Noted.")])
        #expect(turn.tools == ["calendar", "weather", "notes"])
        #expect(turn.reply == "Rain at two.\n\nNoted.")
        // Said in more than one stretch: the whole reply at the end can't be placed, so the pieces stay.
        turn.apply(.finished(reply: "Rain at two. Noted.", outcome: .complete))
        #expect(turn.parts.count == 4)
    }

    @Test func somethingAddedMidAnswerSitsBetweenWhatWasSaidBeforeAndAfter() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.text("Booking the 9am"))
        turn.add("make it 10")
        turn.apply(.text("Booking 10am instead."))
        #expect(turn.contents == [.said("Booking the 9am"), .added("make it 10"), .said("Booking 10am instead.")])
        // Said in two stretches within one turn: the whole reply can't be placed, so the pieces stay.
        turn.apply(.finished(reply: "Booking 10am instead.", outcome: .complete))
        #expect(turn.contents.first == .said("Booking the 9am"))
        #expect(turn.contents.count == 3)
        #expect(!turn.isWorking)
    }

    @Test func aReplyThatOnlyArrivesWholeIsShown() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.tool("notes"))
        turn.apply(.finished(reply: "Done.", outcome: .complete))
        #expect(turn.contents == [.used(["notes"]), .said("Done.")])
    }

    @Test func aMessageCanJoinWorkAlreadyUnderWayOrCarryOnIntoAFurtherTurn() {
        var joined = LiveTurn()
        joined.joinRunningTurn()
        joined.apply(.text("On it."))
        joined.apply(.finished(reply: nil, outcome: .complete))
        #expect(joined.reply == "On it.")
        #expect(joined.outcome == .complete)

        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.text("First half"))
        turn.add("actually, stop and do this")
        turn.apply(.finished(reply: nil, outcome: .stopped))
        turn.carryOn()
        #expect(turn.isWorking)
        turn.apply(.text("Doing that."))
        turn.apply(.finished(reply: nil, outcome: .complete))
        #expect(turn.contents == [.said("First half"), .added("actually, stop and do this"), .said("Doing that.")])
    }

    /// The turn that was under way when a message was added ends with what it had said so
    /// far, as the gateway sends it. That is shown once, before the message, not again after.
    @Test func aTurnCutShortByAnAdditionShowsWhatItSaidOnce() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.text("Booking the 9am"))
        turn.add("make it 10")
        turn.apply(.finished(reply: "Booking the 9am", outcome: .stopped))
        #expect(turn.contents == [.said("Booking the 9am"), .added("make it 10")])

        // The same when the added message is then taken back.
        var takenBack = LiveTurn()
        takenBack.apply(.started)
        takenBack.apply(.text("So far"))
        let id = takenBack.add("never arrived")
        takenBack.takeBack(id)
        takenBack.apply(.finished(reply: "So far.", outcome: .complete))
        #expect(takenBack.contents == [.said("So far.")])
    }

    /// After a further turn begins, a reply that arrives whole belongs to that turn: it must
    /// not replace what the earlier turn said.
    @Test func aWholeReplyInAFurtherTurnDoesNotReplaceWhatWasSaidBefore() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.text("First half"))
        turn.add("actually, do this")
        turn.apply(.finished(reply: "First half", outcome: .stopped))
        turn.carryOn()
        turn.apply(.finished(reply: "\n\nNew answer", outcome: .complete))
        #expect(turn.contents == [.said("First half"), .added("actually, do this"), .said("New answer")])

        // Streamed in one stretch, the further turn's reply is replaced by its own whole form only.
        var streamed = LiveTurn()
        streamed.apply(.started)
        streamed.apply(.text("First half"))
        streamed.add("actually, do this")
        streamed.apply(.finished(reply: "First half", outcome: .stopped))
        streamed.carryOn()
        streamed.apply(.text("New ans"))
        streamed.apply(.finished(reply: "New answer.", outcome: .complete))
        #expect(streamed.contents == [.said("First half"), .added("actually, do this"), .said("New answer.")])
    }

    /// Two messages added mid-answer, each answered by a turn of its own: the second
    /// answer is its own bubble, not run on from the first, and is not shown twice.
    @Test func successiveTurnsEachKeepTheirOwnWords() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.text("First"))
        turn.add("B")
        turn.add("C")
        turn.apply(.finished(reply: "First", outcome: .stopped))
        turn.carryOn()
        turn.apply(.text("Second answer"))
        turn.apply(.finished(reply: "Second answer", outcome: .stopped))
        turn.carryOn()
        turn.apply(.text("Third answer"))
        turn.apply(.pause)
        turn.apply(.finished(reply: "Third answer", outcome: .complete))
        #expect(turn.contents == [.said("First"), .added("B"), .added("C"), .said("Second answer"), .said("Third answer")])

        // Tools likewise: a new turn's tools are their own line.
        var tools = LiveTurn()
        tools.apply(.started)
        tools.apply(.tool("calendar"))
        tools.add("B")
        tools.takeBack(tools.parts.last!.id)
        tools.apply(.finished(reply: nil, outcome: .stopped))
        tools.carryOn()
        tools.apply(.tool("notes"))
        #expect(tools.contents == [.used(["calendar"]), .used(["notes"])])
    }

    @Test func partsKeepTheirIdsWhenOneIsTakenBack() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.text("So far"))
        let first = turn.add("reject me")
        let second = turn.add("keep me")
        let kept = turn.parts.map(\.id)
        turn.takeBack(first)
        #expect(turn.contents == [.said("So far"), .added("keep me")])
        #expect(turn.parts.map(\.id) == [kept[0], second])
        // An id is not handed out again.
        #expect(turn.add("another") != first)
        #expect(turn.hasAdditions)
        turn.takeBack(999)
        #expect(turn.parts.count == 3)
    }

    @Test func aFreshStretchDoesNotOpenOnBlankLines() {
        var turn = LiveTurn()
        turn.apply(.started)
        turn.apply(.text("\n\n"))
        #expect(turn.parts.isEmpty)
        turn.apply(.text("\n\nRight, 10am."))
        turn.apply(.text("\n\nDone."))
        #expect(turn.contents == [.said("Right, 10am.\n\nDone.")])
    }

    @Test func aStoppedTurnCanBeEndedHere() {
        var turn = LiveTurn()
        turn.endStopped()
        #expect(turn.outcome == .stopped)
        var done = LiveTurn()
        done.apply(.started)
        done.apply(.finished(reply: "Hi", outcome: .complete))
        done.endStopped()
        #expect(done.outcome == .complete)
    }

    @Test func sendingOpensTheChatAndFollowsOnlyItsOwnReply() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { [self] id, method in
            switch method {
            case "session.resume":
                [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-1","running":false}}"#]
            case "prompt.submit":
                [
                    #"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"streaming"}}"#,
                    event("message.start", "{}"),
                    event("message.delta", #"{"text":"other bot"}"#, session: "live-2"),
                    event("tool.start", #"{"tool_id":"a","name":"weather"}"#),
                    event("message.delta", #"{"text":"Rain"}"#),
                    event("session.usage", "{}"),
                    event("message.complete", #"{"text":"Rain at 2.","status":"complete"}"#),
                ]
            default:
                [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown method"}}"#]
            }
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()

        let live = try await client.openChat(try chat(), profile: "default")
        #expect(live == LiveChat(sessionID: "live-1"))
        let steps = await client.turnEvents(in: live)
        #expect(try await client.send("weather?", in: live, profile: "default") == .started)

        var turn = LiveTurn()
        var seen: [TurnEvent] = []
        for await step in steps {
            seen.append(step)
            turn.apply(step)
            if !turn.isWorking { break }
        }
        #expect(seen == [.started, .tool("weather"), .text("Rain"), .finished(reply: "Rain at 2.", outcome: .complete)])
        #expect(turn.reply == "Rain at 2.")
    }

    /// A message a page sends is stored as one no one sees; one the person typed says nothing of it.
    @Test func aHiddenMessageSaysSoAndATypedOneDoesNot() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            switch method {
            case "session.resume": [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-1","running":false}}"#]
            case "prompt.submit": [#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"streaming"}}"#]
            default: [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown method"}}"#]
            }
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        let live = try await client.openChat(try chat(), profile: "default")
        _ = try await client.send("typed", in: live, profile: "default")
        _ = try await client.send("Show last 12 weeks", in: live, profile: "default", hidden: true)
        let sent = gateway.params(of: "prompt.submit")
        #expect(sent.count == 2)
        #expect(sent.first?["display_kind"] == nil)
        #expect(sent.first?["queued"] == nil)
        #expect(sent.last?["display_kind"] as? String == "hidden")
        #expect(sent.last?["queued"] as? Bool == true)
        #expect(sent.last?["text"] as? String == "Show last 12 weeks")
    }

    /// A chat opened straight after connecting waits for the gateway to say which route
    /// chats take, so it is opened under the name that route knows.
    @Test func aChatOpenedAtOnceGoesByTheNameTheGatewaysRouteTakes() async throws {
        for (authority, expected) in [("true", "gui"), ("false", "desktop")] {
            let greeting = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"session_authority":\#(authority)}}}"#
            let (gateway, endpoint) = try await FakeGateway.start(greeting: greeting) { id, _ in
                [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-1"}}"#]
            }
            defer { gateway.stop() }
            let client = GatewayClient(endpoint: endpoint, token: "t")
            await client.connect()
            _ = try await client.openChat(try chat(), profile: "default")
            #expect(gateway.params(of: "session.resume").first?["source"] as? String == expected)
        }
    }

    /// A gateway that says its session authority handles chats wants an id on every message;
    /// one that does not say so is sent none, since its older route does not know the field.
    @Test func aMessageCarriesItsOwnIdOnlyWhereTheGatewayWantsOne() async throws {
        for (authority, expected) in [("true", true), ("false", false), ("null", false)] {
            let greeting = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"session_authority":\#(authority)}}}"#
            let (gateway, endpoint) = try await FakeGateway.start(greeting: greeting)
            defer { gateway.stop() }
            let client = GatewayClient(endpoint: endpoint, token: "t")
            let events = await client.events()
            await client.connect()
            for await event in events where event.type == "gateway.ready" { break }
            #expect(await client.usesSessionAuthority == expected)
            try await client.send("one", in: LiveChat(sessionID: "live-1"), profile: "default")
            try await client.send("two", in: LiveChat(sessionID: "live-1"), profile: "default")
            let ids = gateway.params(of: "prompt.submit").map { $0["submission_id"] as? String }
            #expect(ids.count == 2)
            if expected {
                #expect(ids[0] != nil && ids[1] != nil && ids[0] != ids[1])
            } else {
                #expect(ids == [nil, nil])
            }
        }
    }

    /// Where the session authority handles chats, a picture is only held on the gateway and
    /// named on the message it goes with; on the older route it is queued in the chat and
    /// the message names nothing.
    @Test func aPictureIsNamedOnTheMessageOnlyWhereTheSessionAuthorityHoldsIt() async throws {
        for authority in [true, false] {
            let greeting = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"session_authority":\#(authority)}}}"#
            let (gateway, endpoint) = try await FakeGateway.start(greeting: greeting) { id, method in
                switch method {
                case "image.attach_bytes":
                    [#"{"jsonrpc":"2.0","id":\#(id),"result":{"attached":true,"path":"/h/cache/images/upload_1.png","name":"upload_1.png","mime":"image/png","count":1}}"#]
                default:
                    [#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"queued"}}"#]
                }
            }
            defer { gateway.stop() }
            let client = GatewayClient(endpoint: endpoint, token: "t")
            let events = await client.events()
            await client.connect()
            for await event in events where event.type == "gateway.ready" { break }
            let chat = LiveChat(sessionID: "live-1")
            let picture = try await client.attachImage(Data([1, 2, 3]), named: "sketch.png", in: chat, profile: "default")
            if authority {
                let held = StagedPicture(path: "/h/cache/images/upload_1.png", mime: "image/png", name: "upload_1.png")
                #expect(picture == .staged(held))
                try await client.send("what is this?", in: chat, profile: "default", pictures: [held])
                let named = gateway.params(of: "prompt.submit").first?["attachments"] as? [[String: String]]
                #expect(named == [["path": "/h/cache/images/upload_1.png", "mime": "image/png"]])
            } else {
                #expect(picture == .image(path: "/h/cache/images/upload_1.png", name: "upload_1.png"))
                try await client.send("what is this?", in: chat, profile: "default")
                #expect(gateway.params(of: "prompt.submit").first?["attachments"] == nil)
            }
        }
    }

    @Test func aReplyWithoutASessionIdIsAnError() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"running":true}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.unexpectedReply(method: "session.resume")) {
            try await client.openChat(try chat(), profile: "default")
        }
    }
}
