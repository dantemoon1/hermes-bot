import Foundation
import Testing
@testable import HermesKit

@Suite(.timeLimit(.minutes(1)))
struct QuestionsTests {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func ask(_ method: String, _ params: String, id: JSONValue = .string("srq-1")) throws -> IncomingRequest {
        IncomingRequest.read(method: method, id: id, params: try json(params))
    }

    // MARK: Reading what the gateway asks

    @Test func aCommandApprovalIsPutToThePerson() throws {
        let read = try ask("approval", #"{"session_id":"live-1","request_id":"a1","command":"rm -rf /tmp/x","description":"tidy up","allow_permanent":false}"#)
        guard case .ask(let question) = read, case .approval(let approval) = question.kind else { Issue.record("not asked: \(read)"); return }
        #expect(question.id == "srq-1")
        #expect(question.sessionID == "live-1")
        #expect(question.route == .request(.string("srq-1")))
        #expect(approval.subject == .command("rm -rf /tmp/x"))
        #expect(approval.description == "tidy up")
        // Not allowed for good, so "always" is not offered; deny always is.
        #expect(approval.choices == [.once, .session, .deny])
        #expect(!approval.takesReason)
    }

    @Test func choicesFollowWhatTheGatewayListsAndSmartDenialTakesAwayTheLasting() throws {
        #expect(Approval.choices(try json(#"{"choices":["once","deny","session"]}"#)) == [.once, .session, .deny])
        // A listed set without deny still gets it: the person can always say no.
        #expect(Approval.choices(try json(#"{"choices":["once"]}"#)) == [.once, .deny])
        #expect(Approval.choices(try json(#"{"smart_denied":true}"#)) == [.once, .deny])
        #expect(Approval.choices(try json(#"{}"#)) == [.once, .session, .always, .deny])
        // Words the app does not know are not offered.
        #expect(Approval.choices(try json(#"{"choices":["once","yolo"]}"#)) == [.once, .deny])
    }

    @Test func aFolderOrSiteRequestThatNamesNoneIsRefusedWithNoCard() throws {
        #expect(try ask("approval", #"{"session_id":"s","request_id":"a","kind":"access","path":"  "}"#)
            == .reply(.error(code: -32602, message: "an access request needs a path and a network request needs a host")))
        #expect(try ask("approval", #"{"session_id":"s","request_id":"a","kind":"network"}"#)
            == .reply(.error(code: -32602, message: "an access request needs a path and a network request needs a host")))
        guard case .ask(let folder) = try ask("approval", #"{"session_id":"s","kind":"access","path":"~/Docs","access":"read","risk":"Reads it"}"#),
              case .approval(let approval) = folder.kind else { Issue.record("no folder"); return }
        #expect(approval.subject == .folder(path: "~/Docs", canWrite: false))
        #expect(approval.risk == "Reads it")
        #expect(approval.takesReason)
    }

    @Test func clarifyKeepsFiveQuestionsAndAnswersAlreadyLocked() throws {
        let rows = (1...7).map { #"{"qid":"q\#($0)","question":"Q\#($0)?","choices":["a","b"],"multi_select":\#($0 == 2)}"# }.joined(separator: ",")
        let read = try ask("clarify", #"{"session_id":"s","questions":[\#(rows),{"qid":"","question":"no id"}],"answers":{"q1":"a","q3":null,"zz":"x"}}"#)
        guard case .ask(let question) = read, case .clarify(let clarify) = question.kind else { Issue.record("not asked"); return }
        #expect(clarify.questions.map(\.id) == ["q1", "q2", "q3", "q4", "q5"])
        #expect(clarify.questions[1].multiSelect)
        #expect(clarify.locked["q1"] == .some("a"))
        #expect(clarify.locked["q3"] == .some(nil))
        #expect(clarify.locked["zz"] == nil)
        // Nothing that can be shown: passed on at once with no answers.
        #expect(try ask("clarify", #"{"session_id":"s","questions":[]}"#) == .reply(.result(.object([:]))))
    }

    @Test func everyWindowRequestIsAnsweredAtOnce() throws {
        let empty = IncomingRequest.reply(.result(.object(["value": .string("")])))
        for method in ["preview.read", "terminal.read", "display.install.sudo", "vault.code", "vault.save_login", "vault.unlock_prompt"] {
            #expect(try ask(method, #"{"session_id":"s"}"#) == empty, "\(method)")
        }
        #expect(try ask("theme.pick", #"{"session_id":"s","picker":"accent"}"#) == .reply(.result(.object(["cancelled": .bool(true)]))))
        #expect(try ask("setup_beat", #"{"session_id":"s","beat":"name","card":{}}"#) == .reply(.result(.object([:]))))
        for method in ["preview.act", "tour", "theme.apply", "window.read"] {
            guard case .reply(.result(let result)) = try ask(method, #"{"session_id":"s","action":"x"}"#),
                  let value = result["value"]?.stringValue, let said = try? json(value) else { Issue.record("\(method) not refused"); return }
            #expect(said["error"]?.stringValue?.isEmpty == false, "\(method)")
        }
        guard case .reply(.error(let code, _)) = try ask("something.new", "{}") else { Issue.record("not refused"); return }
        #expect(code == -32601)
    }

    @Test func theSessionAuthoritysPromptsAreRead() throws {
        let approval = GatewayEvent(type: "approval.request", payload: try json(
            #"{"kind":"approval","prompt_id":"p1","execution_generation":3,"command":"ls","description":"","choices":["once","deny"],"timeout_s":45}"#), sessionID: "live-2")
        let question = try #require(BotQuestion(approval))
        #expect(question.route == .prompt(generation: 3))
        #expect(question.waits == .seconds(45))
        guard case .approval(let read) = question.kind else { Issue.record("not approval"); return }
        #expect(read.choices == [.once, .deny])
        #expect(read.description == nil)

        let clarify = GatewayEvent(type: "clarify.request", payload: try json(
            #"{"kind":"clarify","prompt_id":"p2","execution_generation":3,"question":"Which?","choices":["x","y"],"multi_select":true}"#), sessionID: "live-2")
        guard case .clarify(let one)? = BotQuestion(clarify)?.kind else { Issue.record("not clarify"); return }
        #expect(one.questions == [Clarify.Question(id: "p2", text: "Which?", choices: ["x", "y"], multiSelect: true)])

        // Not a question: an ordinary event, or a prompt with no generation to answer it by.
        #expect(BotQuestion(GatewayEvent(type: "message.delta", payload: .object([:]))) == nil)
        #expect(BotQuestion(GatewayEvent(type: "approval.request", payload: try json(#"{"kind":"approval","prompt_id":"p"}"#))) == nil)
        // And a request is never a step of the answer.
        #expect(TurnEvent(GatewayEvent(type: "message.complete", payload: .object([:]), requestID: .string("x"))) == nil)
    }

    @Test func endingsAreReadFromCancelsAndSettlements() throws {
        let cancel = GatewayEvent(type: "request.cancel", payload: try json(#"{"id":"srq-1","method":"approval","reason":"timeout"}"#))
        #expect(BotQuestion.ended(by: cancel)?.id == "srq-1")
        #expect(BotQuestion.ended(by: cancel)?.reason == "timeout")
        let settled = GatewayEvent(type: "approval.settled", payload: try json(#"{"prompt_id":"p1","execution_generation":1}"#))
        #expect(BotQuestion.ended(by: settled)?.id == "p1")
        #expect(BotQuestion.ended(by: GatewayEvent(type: "sessions.changed", payload: .object([:]))) == nil)
    }

    @Test func aSnapshotGivesBackWhatIsStillWaiting() async throws {
        let snapshot = try json(#"""
        {"session_id":"live-9","open_requests":[
            {"id":"srq-a","method":"secret","params":{"session_id":"live-9","env_var":"KEY","prompt":"p"}},
            {"id":"srq-b","method":"preview.read","params":{"session_id":"live-9"}},
            {"id":"srq-c","method":"sudo","params":{"command":"sudo ls"}}],
         "prompts":[{"kind":"approval","prompt_id":"p1","execution_generation":2,"command":"ls","choices":["once","deny"]}]}
        """#)
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let waiting = await client.takeWaiting(in: snapshot, sessionID: "live-9")
        // A window request in a snapshot is not put to the person; one naming no chat is this one's.
        #expect(waiting.map(\.id) == ["srq-a", "srq-c", "p1"])
        #expect(waiting.first?.kind == .secret(name: "KEY", prompt: "p"))
        #expect(waiting[1].sessionID == "live-9")
    }

    // MARK: Answering

    @Test func answersAreShapedAsTheGatewayReadsThem() throws {
        let folder = BotQuestion(id: "q", sessionID: "s", route: .request(.string("q")),
                                 kind: .approval(Approval(subject: .folder(path: "/x", canWrite: true), choices: [.once, .deny])))
        #expect(GatewayClient.result(for: folder, .approval(.deny, reason: "  not that one ")) == .object(["choice": .string("deny"), "reason": .string("not that one")]))
        #expect(GatewayClient.result(for: folder, .approval(.once, reason: "ignored")) == .object(["choice": .string("once")]))
        // A command's refusal carries no reason: the gateway ignores it there.
        let command = BotQuestion(id: "q", sessionID: "s", route: .request(.string("q")), kind: .approval(Approval(subject: .command("ls"), choices: [.once, .deny])))
        #expect(GatewayClient.result(for: command, .approval(.deny, reason: "no")) == .object(["choice": .string("deny")]))

        let clarify = BotQuestion(id: "c", sessionID: "s", route: .request(.string("c")), kind: .clarify(Clarify(questions: [
            .init(id: "q1", text: "One?", choices: ["a"]), .init(id: "q2", text: "Two?", choices: ["x", "y"], multiSelect: true), .init(id: "q3", text: "Three?"),
        ])))
        let result = GatewayClient.result(for: clarify, .clarify(["q1": .one("a"), "q2": .several(["x", "y"]), "q3": ClarifyAnswer?.none]))
        #expect(result["answers"]?["q1"] == .string("a"))
        #expect(result["answers"]?["q2"] == .string(#"["x","y"]"#))
        #expect(result["answers"]?["q3"] == .null)
        #expect(result["outcome"] == .string("submitted"))
        #expect(GatewayClient.result(for: clarify, .skipped) == .object([:]))

        let secret = BotQuestion(id: "k", sessionID: "s", route: .request(.string("k")), kind: .secret(name: "KEY", prompt: ""))
        #expect(GatewayClient.result(for: secret, .value("abc")) == .object(["value": .string("abc")]))
        #expect(GatewayClient.result(for: secret, .skipped) == .object(["value": .string("")]))
    }

    @Test func anAnswerNeverDescribesWhatWasTyped() {
        let answer = QuestionAnswer.value("hunter2-very-secret")
        #expect(!String(describing: answer).contains("hunter2"))
        #expect(!String(reflecting: answer).contains("hunter2"))
        #expect(!"\(answer)".contains("hunter2"))
        var dumped = ""
        dump(answer, to: &dumped)
        #expect(!dumped.contains("hunter2"))
        #expect(!String(describing: QuestionAnswer.approval(.deny, reason: "my secret reason")).contains("my secret"))
    }

    // MARK: Over a connection

    @Test func theClientSaysItAnswersAndAnswersWindowRequestsItself() async throws {
        let (gateway, endpoint) = try await FakeGateway.start()
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        let events = await client.events()
        await client.answerQuestions()
        await client.connect()
        await client.questionsAdvertised()
        #expect(gateway.params(of: "client.capabilities").first?["server_requests"] as? Bool == true)

        gateway.push(#"{"jsonrpc":"2.0","id":"srq-w","method":"preview.read","params":{"session_id":"live-1"}}"#)
        gateway.push(#"{"jsonrpc":"2.0","id":"srq-a","method":"approval","params":{"session_id":"live-1","request_id":"a1","command":"ls"}}"#)
        var asked: BotQuestion?
        for await event in events {
            if let question = BotQuestion(event) {
                asked = question
                break
            }
        }
        let question = try #require(asked)
        #expect(question.id == "srq-a")
        // The window request was answered with nothing, without the person seeing it.
        let deadline = Date.now.addingTimeInterval(3)
        while gateway.responses.isEmpty, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(gateway.responses.first?["id"] as? String == "srq-w")
        #expect((gateway.responses.first?["result"] as? [String: Any])?["value"] as? String == "")

        try await client.answer(question, with: .approval(.session), profile: "default")
        while gateway.responses.count < 2, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let answered = try #require(gateway.responses.last)
        #expect(answered["id"] as? String == "srq-a")
        #expect((answered["result"] as? [String: Any])?["choice"] as? String == "session")
    }

    @Test func aClientNotAskedToAnswerSaysNothing() async throws {
        let (gateway, endpoint) = try await FakeGateway.start()
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        _ = try await client.request("ping")
        #expect(gateway.params(of: "client.capabilities").isEmpty)
    }

    @Test func aPromptIsAnsweredByMethodForItsTurn() async throws {
        let (gateway, endpoint) = try await FakeGateway.start()
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        let prompt = BotQuestion(id: "p1", sessionID: "live-3", route: .prompt(generation: 4),
                                 kind: .approval(Approval(subject: .command("ls"), choices: [.once, .deny])))
        try await client.answer(prompt, with: .approval(.once), profile: "garden")
        let sent = try #require(gateway.params(of: "approval.respond").first)
        #expect(sent["prompt_id"] as? String == "p1")
        #expect(sent["execution_generation"] as? Int == 4)
        #expect(sent["choice"] as? String == "once")
        #expect(sent["session_id"] as? String == "live-3")
        #expect(sent["profile"] as? String == "garden")

        let one = BotQuestion(id: "p2", sessionID: "live-3", route: .prompt(generation: 4),
                              kind: .clarify(Clarify(questions: [.init(id: "p2", text: "?", choices: ["a", "b"], multiSelect: true)])))
        try await client.answer(one, with: .clarify(["p2": .several(["a", "b"])]), profile: "garden")
        #expect(gateway.params(of: "clarify.respond").first?["answer"] as? String == #"["a","b"]"#)
        try await client.answer(one, with: .skipped, profile: "garden")
        #expect(gateway.params(of: "clarify.respond").last?["answer"] as? String == "")
    }

    @Test func openingAChatHandsBackItsWaitingQuestions() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            guard method == "session.resume" else { return [#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#] }
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-7","open_requests":[{"id":"srq-z","method":"sudo","params":{"session_id":"live-7","command":"sudo ls"}}]}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.answerQuestions()
        await client.connect()
        let chat = try json(#"{"id":"c7","preview":"","message_count":0}"#).decode(BotChat.self)
        let open = try await client.openChat(chat, profile: "default")
        #expect(open.waiting.map(\.kind) == [BotQuestion.Kind.sudo(command: "sudo ls")])
        // Told before the chat was opened, so its questions come here.
        #expect(gateway.params(of: "client.capabilities").count == 1)
    }

    @Test func clarifyAsOneSetIsAskedForOnlyWhereTheAuthoritySaysItCan() async throws {
        let greeting = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"session_authority":true}}}"#
        let (gateway, endpoint) = try await FakeGateway.start(greeting: greeting) { id, method in
            method == "client.capabilities"
                ? [#"{"jsonrpc":"2.0","id":\#(id),"result":{"server_requests":[],"canonical_clarify_batch":true}}"#]
                : [#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"queued"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.answerQuestions()
        await client.connect()
        await client.questionsAdvertised()
        try await client.send("hi", in: LiveChat(sessionID: "live-1"), profile: "default")
        #expect(gateway.params(of: "prompt.submit").first?["clarify_batch"] as? Bool == true)

        // The older route never sees the field.
        let (older, olderEndpoint) = try await FakeGateway.start()
        defer { older.stop() }
        let other = GatewayClient(endpoint: olderEndpoint, token: "t")
        await other.answerQuestions()
        await other.connect()
        await other.questionsAdvertised()
        _ = try? await other.send("hi", in: LiveChat(sessionID: "live-1"), profile: "default")
        #expect(older.params(of: "prompt.submit").first?["clarify_batch"] == nil)
    }

    @Test func windowRequestsAreDeclinedWhereTheGatewayCountsDeclines() throws {
        for method in ["preview.read", "preview.act", "terminal.read", "window.read", "tour", "theme.apply"] {
            #expect(IncomingRequest.read(method: method, id: .string("s"), params: try json(#"{"session_id":"x"}"#), declinesNotShown: true)
                == .reply(.error(code: 4404, message: "This window is not showing the session.")), "\(method)")
        }
        // Not a window's request: answered as ever.
        #expect(IncomingRequest.read(method: "theme.pick", id: .string("s"), params: try json(#"{"session_id":"x","picker":"accent"}"#), declinesNotShown: true)
            == .reply(.result(.object(["cancelled": .bool(true)]))))
    }

    @Test func aQuestionThatNamesNoChatIsRefused() throws {
        for method in ["approval", "clarify", "secret", "sudo"] {
            guard case .reply(.error(let code, _)) = try ask(method, #"{"command":"ls","env_var":"K","prompt":"p","questions":[{"qid":"q","question":"?"}]}"#) else {
                Issue.record("\(method) not refused"); continue
            }
            #expect(code == -32602)
        }
    }

    @Test func aQuestionNobodyListensForIsRefusedAtOnce() async throws {
        let (gateway, endpoint) = try await FakeGateway.start()
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.answerQuestions()
        await client.connect()
        await client.questionsAdvertised()
        gateway.push(#"{"jsonrpc":"2.0","id":"srq-n","method":"sudo","params":{"session_id":"live-1","command":"sudo ls"}}"#)
        let deadline = Date.now.addingTimeInterval(3)
        while gateway.responses.isEmpty, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(gateway.responses.first?["id"] as? String == "srq-n")
        #expect((gateway.responses.first?["error"] as? [String: Any])?["code"] as? Int == -32603)
    }

    @Test func requestsWaitingInASnapshotThatAreNotQuestionsAreAnsweredOnOpening() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            guard method == "session.resume" else { return [#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#] }
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-7","open_requests":[{"id":"srq-t","method":"theme.pick","params":{"session_id":"live-7","picker":"accent"}}]}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.answerQuestions()
        await client.connect()
        let chat = try json(#"{"id":"c7","preview":"","message_count":0}"#).decode(BotChat.self)
        let open = try await client.openChat(chat, profile: "default")
        #expect(open.waiting.isEmpty)
        let deadline = Date.now.addingTimeInterval(3)
        while gateway.responses.isEmpty, Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(gateway.responses.first?["id"] as? String == "srq-t")
    }

    @Test func anAnswerTheGatewayAlreadyHadIsSaidToCountForNothing() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"status":"already_resolved","prompt_id":"p1"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        let prompt = BotQuestion(id: "p1", sessionID: "live-3", route: .prompt(generation: 4),
                                 kind: .approval(Approval(subject: .command("ls"), choices: [.once, .deny])))
        #expect(try await client.answer(prompt, with: .approval(.once), profile: "default") == false)
    }
}
