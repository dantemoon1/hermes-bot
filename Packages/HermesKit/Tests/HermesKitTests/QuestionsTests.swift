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
        // The window request was answered with nothing, without the owner seeing it.
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

    @Test func aFailedTellingIsTriedAgainBeforeAChatIsOpened() async throws {
        let refusals = Calls()
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            if method == "client.capabilities", refusals.next() == 1 {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":5000,"message":"busy"}}"#]
            }
            if method == "session.resume" { return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-7"}}"#] }
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.answerQuestions()
        await client.connect()
        let chat = try json(#"{"id":"c7","preview":"","message_count":0}"#).decode(BotChat.self)
        _ = try await client.openChat(chat, profile: "default")
        // Refused once, said again, and only then the chat opened.
        let order = gateway.methods.filter { $0 == "client.capabilities" || $0 == "session.resume" }
        #expect(order == ["client.capabilities", "client.capabilities", "session.resume"])
        _ = try await client.openChat(chat, profile: "default")
        #expect(gateway.params(of: "client.capabilities").count == 2)
    }

    @Test func aGatewayThatDoesNotKnowTheTellingIsNotAskedAgain() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            method == "client.capabilities"
                ? [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"unknown method"}}"#]
                : [#"{"jsonrpc":"2.0","id":\#(id),"result":{"session_id":"live-7"}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.answerQuestions()
        await client.connect()
        let chat = try json(#"{"id":"c7","preview":"","message_count":0}"#).decode(BotChat.self)
        _ = try await client.openChat(chat, profile: "default")
        #expect(gateway.params(of: "client.capabilities").count == 1)
        // Said again by the owner, as the roster does for every connection it uses: still not asked.
        await client.answerQuestions()
        _ = try await client.openChat(chat, profile: "default")
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

    @Test func theApprovalModeIsReadAndSetOnlyWhereSettingsArePerBot() async throws {
        // Scoped gateway: first config.get probes the nonexistent bot, later ones return the mode.
        let asked = Counter()
        let (scoped, scopedEndpoint) = try await FakeGateway.start { id, method in
            if method == "config.get", asked.next() == 1 {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4064,"message":"Profile 'hermes-bot-no-such-bot' does not exist."}}"#]
            }
            return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"key":"approvals.mode","value":"smart"}}"#]
        }
        defer { scoped.stop() }
        let client = GatewayClient(endpoint: scopedEndpoint, token: "t")
        await client.connect()
        #expect(try await client.approvalMode(of: "garden") == .smart)
        #expect(try await client.setApprovalMode(.smart, of: "garden") == .smart)
        let gets = scoped.params(of: "config.get")
        #expect(gets.count == 2)
        #expect(gets.first?["profile"] as? String == "hermes-bot-no-such-bot")
        #expect(gets.last?["key"] as? String == "approvals.mode")
        #expect(gets.last?["profile"] as? String == "garden")
        let set = try #require(scoped.params(of: "config.set").first)
        #expect(set["key"] as? String == "approvals.mode")
        #expect(set["value"] as? String == "smart")
        #expect(set["profile"] as? String == "garden")

        // Unscoped gateway (Hermes before 0.21.6): answers for the nonexistent bot, so neither
        // reading nor writing approvals.mode is allowed.
        let (unscoped, unscopedEndpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"key":"reasoning","value":"medium"}}"#]
        }
        defer { unscoped.stop() }
        let old = GatewayClient(endpoint: unscopedEndpoint, token: "t")
        await old.connect()
        await #expect(throws: GatewayError.unsupported(method: "config.get")) { try await old.approvalMode(of: "garden") }
        await #expect(throws: GatewayError.unsupported(method: "config.set")) { try await old.setApprovalMode(.off, of: "garden") }
        #expect(unscoped.params(of: "config.set").isEmpty)
        #expect(unscoped.params(of: "config.get").count == 1)

        // Session authority: config.set requires a session_id, so approvals.mode is not offered.
        let greeting = #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"session_authority":true}}}"#
        let (authority, authorityEndpoint) = try await FakeGateway.start(greeting: greeting) { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"key":"approvals.mode","value":"manual"}}"#]
        }
        defer { authority.stop() }
        let authClient = GatewayClient(endpoint: authorityEndpoint, token: "t")
        await authClient.connect()
        await #expect(throws: GatewayError.unsupported(method: "config.get")) { try await authClient.approvalMode(of: "default") }
        await #expect(throws: GatewayError.unsupported(method: "config.set")) { try await authClient.setApprovalMode(.smart, of: "default") }
        #expect(authority.params(of: "config.get").isEmpty)
        #expect(authority.params(of: "config.set").isEmpty)
    }

    @Test func unknownApprovalKeyAndOutOfSyncAreUnsupportedWhileWriteRefusalStaysRejected() async throws {
        // 4002 unknown config key -> unsupported.
        let probe1 = Counter()
        let (noKey, noKeyEndpoint) = try await FakeGateway.start { id, method in
            if method == "config.get", probe1.next() == 1 {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4064,"message":"Profile 'hermes-bot-no-such-bot' does not exist."}}"#]
            }
            return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4002,"message":"unknown config key: approvals.mode"}}"#]
        }
        defer { noKey.stop() }
        let c1 = GatewayClient(endpoint: noKeyEndpoint, token: "t")
        await c1.connect()
        await #expect(throws: GatewayError.unsupported(method: "config.get")) { try await c1.approvalMode(of: "default") }
        await #expect(throws: GatewayError.unsupported(method: "config.set")) { try await c1.setApprovalMode(.smart, of: "default") }

        // 4002 ConfigWriteError (not unknown config key) -> rejected, not unsupported.
        let probe2 = Counter()
        let (locked, lockedEndpoint) = try await FakeGateway.start { id, method in
            if method == "config.get", probe2.next() == 1 {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4064,"message":"Profile 'hermes-bot-no-such-bot' does not exist."}}"#]
            }
            return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4002,"message":"approvals.mode is locked by policy"}}"#]
        }
        defer { locked.stop() }
        let c2 = GatewayClient(endpoint: lockedEndpoint, token: "t")
        await c2.connect()
        await #expect(throws: GatewayError.rejected(code: 4002, message: "approvals.mode is locked by policy")) {
            try await c2.setApprovalMode(.smart, of: "default")
        }

        // 4000 invalid params -> outOfSync -> unsupported.
        let probe3 = Counter()
        let (outOfSync, outOfSyncEndpoint) = try await FakeGateway.start { id, method in
            if method == "config.get", probe3.next() == 1 {
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4064,"message":"Profile 'hermes-bot-no-such-bot' does not exist."}}"#]
            }
            return [#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":4000,"message":"invalid params for config.get: profile"}}"#]
        }
        defer { outOfSync.stop() }
        let c3 = GatewayClient(endpoint: outOfSyncEndpoint, token: "t")
        await c3.connect()
        await #expect(throws: GatewayError.unsupported(method: "config.get")) { try await c3.approvalMode(of: "default") }
    }

    @Test func allBotsFailsRatherThanSkippingAnUnreadableProfile() async throws {
        let (gateway, endpoint) = try await FakeGateway.start { id, _ in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":{"profiles":[{"name":"default","is_default":true},{"not_a_name":1}]}}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        await #expect(throws: GatewayError.unexpectedReply(method: "profiles.list")) { try await client.allBots() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
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

    // MARK: Connection cards

    @Test func aConnectionCardIsRead() throws {
        let event = GatewayEvent(type: "connection.request", payload: try json(#"""
        {"op_id":"op-1","seq":2,"deadline_at":2000000000,"timeout_seconds":300,"targets":[
          {"name":"notion","kind":"connector","action":"connect","state":"pending","display":"Notion","alias":"work","connect_url":"https://auth.example.com/x","tools":["a","b"]},
          {"name":"fs","kind":"mcp","action":"install","state":"failed","detail":"bad key","tier":"community",
           "launch":{"kind":"stdio","target":"npx fs"},"scan":{"status":"warnings","summary":"network use"},
           "required_env":[{"name":"ROOT","required":true,"secret":false,"default":"/d"},{"name":"KEY","required":true,"secret":true,"default":""}]},
          {"name":"odd","kind":"spaceship","action":"connect","state":"pending"}]}
        """#), sessionID: "live-1")
        let question = try #require(BotQuestion(event))
        #expect(question.route == .connection)
        #expect(question.id == "op-1")
        guard case .connection(let card) = question.kind else { Issue.record("not a card"); return }
        #expect(card.seq == 2)
        #expect(card.deadline == Date(timeIntervalSince1970: 2_000_000_000))
        // A row of a kind this app does not know is left out rather than guessed at.
        #expect(card.targets.map(\.name) == ["notion", "fs"])
        #expect(card.targets[0].connectURL?.host == "auth.example.com")
        #expect(card.targets[0].alias == "work")
        #expect(card.targets[1].alias == nil)
        #expect(card.targets[1].fields.map(\.isSecret) == [false, true])
        #expect(card.targets[1].launch == ConnectionTarget.Launch(isRemote: false, target: "npx fs"))
        #expect(card.targets[1].scan == "warnings: network use")
        #expect(!card.targets[1].isResolved)
        // No chat named: not put up.
        #expect(BotQuestion(GatewayEvent(type: "connection.request", payload: event.payload)) == nil)
    }

    @Test func onlyASafeSignInAddressIsOffered() {
        #expect(ConnectionTarget.openable("https://auth.example.com/oauth?x=1") != nil)
        #expect(ConnectionTarget.openable("http://127.0.0.1:8123/callback") != nil)
        for unsafe in ["http://auth.example.com/", "file:///etc/passwd", "javascript:alert(1)", "hermes-bot://x",
                       "https://user:pass@auth.example.com/", "https:///nohost", "not a url"] {
            #expect(ConnectionTarget.openable(unsafe) == nil, "\(unsafe)")
        }
    }

    @Test func movesOnACardAreShapedAsTheGatewayReadsThem() throws {
        let answer = ConnectionAnswer(moves: ["notion": .skip, "fs": .approve(values: ["KEY": "s3cret"])], isContinue: true)
        let wire = answer.wire
        #expect(wire["settled_by"] == .string("continue"))
        guard case .array(let rows)? = wire["targets"] else { Issue.record("no rows"); return }
        #expect(rows.contains(.object(["name": .string("notion"), "status": .string("skipped")])))
        #expect(rows.contains(.object(["name": .string("fs"), "status": .string("approved"), "env": .object(["KEY": .string("s3cret")])])))
        // Never the values typed.
        var dumped = ""
        dump(answer, to: &dumped)
        #expect(!dumped.contains("s3cret") && !String(describing: answer).contains("s3cret"))
    }

    @Test func aSnapshotGivesBackAnOpenConnectionCard() async throws {
        let snapshot = try json(#"{"pending_connection":{"op_id":"op-9","seq":1,"targets":[]}}"#)
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let waiting = await client.takeWaiting(in: snapshot, sessionID: "live-3")
        #expect(waiting.map(\.id) == ["op-9"])
        #expect(waiting.first?.route == .connection)
    }

    private func card(_ text: String) throws -> ConnectionRequest {
        try #require(ConnectionRequest(payload: try json(text)))
    }

    @Test func aRowNamedTwiceIsTakenOnceAndAFieldNamedTwiceIsSecret() throws {
        let card = try card(#"""
        {"op_id":"op-2","seq":1,"targets":[
          {"name":"fs","kind":"mcp","action":"install","state":"pending","launch":{"kind":"stdio","target":"npx fs"},
           "required_env":[{"name":"KEY","required":false,"secret":false,"default":"shown"},{"name":"KEY","required":true,"secret":true,"default":"hidden"}]},
          {"name":"fs","kind":"connector","action":"connect","state":"pending"}]}
        """#)
        #expect(card.targets.map(\.kind) == [.mcp])
        let field = try #require(card.targets.first?.fields.first)
        #expect(card.targets.first?.fields.count == 1)
        // Secret and required if either says so; a secret keeps no default, so nothing unseen is sent.
        #expect(field.isSecret && field.isRequired)
        #expect(field.defaultValue == "")
        #expect(field.value(typed: nil) == "")
        #expect(!field.isFilled(typed: nil))
    }

    @Test func aSecretFieldNeverKeepsItsDefault() throws {
        let card = try card(#"""
        {"op_id":"op-3","seq":1,"targets":[{"name":"fs","kind":"mcp","action":"install","state":"pending",
          "required_env":[{"name":"ROOT","required":true,"secret":false,"default":"/d"},{"name":"KEY","required":true,"secret":true,"default":"sk-live-x"}]}]}
        """#)
        let fields = try #require(card.targets.first?.fields)
        #expect(fields[0].value(typed: nil) == "/d" && fields[0].isFilled(typed: nil))
        #expect(!fields[0].isFilled(typed: "   "))
        #expect(fields[1].value(typed: nil) == "" && !fields[1].isFilled(typed: nil))
        #expect(fields[1].value(typed: "typed") == "typed")
    }

    @Test func whatIsResolvedIsTheGatewaysWord() throws {
        let card = try card(#"""
        {"op_id":"op-4","seq":3,"targets":[
          {"name":"a","kind":"connector","action":"connect","state":"expired"},
          {"name":"b","kind":"plugin","action":"install","state":"failed"},
          {"name":"c","kind":"mcp","action":"install","state":"failed"},
          {"name":"d","kind":"connector","action":"connect","state":"initiated","resolved":true}]}
        """#)
        // An expired sign-in waits on the person; a failed catalog row is done; the gateway's flag wins.
        #expect(card.targets.map(\.isResolved) == [false, true, false, true])
    }

    @Test func eachRowOffersOnlyWhatHermesWouldTake() throws {
        let card = try card(#"""
        {"op_id":"op-5","seq":1,"targets":[
          {"name":"hosted","kind":"connector","action":"connect","state":"initiated","connect_url":"https://auth.example.com/1"},
          {"name":"installing","kind":"mcp","action":"install","state":"initiated","launch":{"kind":"stdio","target":"npx x"}},
          {"name":"minting","kind":"mcp","action":"authorize","state":"pending"},
          {"name":"dead","kind":"connector","action":"connect","state":"failed","connect_url":"https://auth.example.com/old"},
          {"name":"late","kind":"connector","action":"connect","state":"expired"},
          {"name":"fresh","kind":"mcp","action":"install","state":"pending","launch":{"kind":"stdio","target":"npx y","cwd":"/w","env":["A","B"]}},
          {"name":"blind","kind":"mcp","action":"install","state":"pending"},
          {"name":"unpinned","kind":"plugin","action":"install","state":"pending","repo":"github.com/x/y"},
          {"name":"pinned","kind":"plugin","action":"install","state":"pending","repo":"github.com/x/y","sha":"0123456789abcdef0123456789abcdef01234567","subdir":"p","target_profile":"default","platforms":["macos"],"tier":"made-up"}]}
        """#)
        let row = { (name: String) in card.targets.first { $0.name == name }! }
        #expect(row("hosted").move == .open(URL(string: "https://auth.example.com/1")!))
        // Installing: the gateway is at work, and there is nothing to press.
        #expect(row("installing").move == .none)
        // An authorize still minting its link has nothing to approve.
        #expect(row("minting").move == .none)
        // A failed sign-in's old link is dead: it is tried again, not reopened.
        #expect(row("dead").move == .retry)
        #expect(row("late").move == .retry)
        #expect(row("fresh").move == .approve && row("fresh").canBeApproved)
        #expect(row("fresh").launch == ConnectionTarget.Launch(isRemote: false, target: "npx y", cwd: "/w", env: ["A", "B"]))
        // What would run cannot be shown: not offered.
        #expect(!row("blind").canBeApproved)
        #expect(!row("unpinned").canBeApproved)
        #expect(row("pinned").canBeApproved)
        #expect(row("pinned").source == ConnectionTarget.Source(repo: "github.com/x/y", sha: "0123456789abcdef0123456789abcdef01234567", subdir: "p", targetProfile: "default", platforms: ["macos"]))
        // A tier the contract does not name is not shown.
        #expect(row("pinned").tier == nil)
    }

    @Test func aDeadlineThatMakesNoSenseIsNone() throws {
        for value in ["1e300", "-5", "\"soon\"", "99999999999999"] {
            let read = try card(#"{"op_id":"op-6","seq":1,"deadline_at":"# + value + "}")
            #expect(read.deadline == nil, "\(value)")
        }
        #expect(try card(#"{"op_id":"op-6","seq":1e300,"targets":[]}"#).seq == 0)
    }

    @Test func anUpdateKeepsWhatOnlyTheRequestSaid() throws {
        let request = try card(#"{"op_id":"op-7","seq":1,"targets":[],"display":{"suggested":["notion"]}}"#)
        let settled = try card(#"{"op_id":"op-7","seq":2,"settled":true,"settled_by":"continue","targets":[]}"#)
        let now = try #require(request.updated(by: settled))
        #expect(now.suggested == ["notion"] && now.isSettled)
        // Not newer: moves nothing.
        #expect(now.updated(by: request) == nil)
        #expect(request.updated(by: try card(#"{"op_id":"op-7","seq":1,"targets":[]}"#)) == nil)
    }

    @Test func aMoveNeverShowsTheValuesTyped() {
        let move = ConnectionAnswer.Move.approve(values: ["KEY": "s3cret"])
        var dumped = ""
        dump(move, to: &dumped)
        #expect(!dumped.contains("s3cret") && !String(describing: move).contains("s3cret") && !String(reflecting: move).contains("s3cret"))
    }

    @Test func whatIsNotUnderstoodIsTakenTheSaferWay() throws {
        let card = try card(#"""
        {"op_id":"op-8","seq":2.6,"targets":[
          {"name":"fs","kind":"mcp","action":"install","state":"pending","launch":{"kind":"spaceship","target":"npx fs"},
           "scan":{"status":"  "},
           "required_env":[{"name":"A","required":true,"secret":"true","default":"leak"},{"name":"B","required":true,"default":"x"},
                           {"name":"C","required":false,"secret":false,"default":"/d","prompt":"  "}]},
          {"name":"short","kind":"plugin","action":"install","state":"pending","repo":"github.com/x/y","sha":"0123abc"}]}
        """#)
        // A seq that is not a whole number is no seq at all, rather than one rounded up.
        #expect(card.seq == 0)
        let fs = card.targets[0]
        // A launch of a kind the contract does not name is not described, so not approved.
        #expect(fs.launch == nil && !fs.canBeApproved)
        #expect(fs.scan == nil)
        // A field is plain only where it plainly says so; a secret keeps no default.
        #expect(fs.fields.map(\.isSecret) == [true, true, false])
        #expect(fs.fields[0].defaultValue == "" && fs.fields[1].defaultValue == "")
        #expect(fs.fields[2].prompt == nil)
        // A commit that is not a full one cannot pin the install.
        #expect(card.targets[1].source?.pinnedCommit == nil && !card.targets[1].canBeApproved)
    }

    @Test func aRowConnectedWithSomethingAmissSaysSo() throws {
        let card = try card(#"""
        {"op_id":"op-9","seq":4,"targets":[
          {"name":"cal","kind":"mcp","action":"authorize","state":"connected","discovery_error":"tools/list failed"},
          {"name":"charts","kind":"plugin","action":"install","state":"connected","missing_env":["CHARTS_TOKEN"],"enabled":false},
          {"name":"fine","kind":"mcp","action":"install","state":"connected","tools":["a"]}]}
        """#)
        #expect(card.targets[0].caveat == "its tools couldn't be listed")
        #expect(card.targets[1].caveat == "it still needs CHARTS_TOKEN; it isn't turned on")
        #expect(card.targets[2].caveat == nil)
    }

    @Test func fieldsAskedForAtDifferentTimesAreOneList() {
        let first = [ConnectionTarget.Field(name: "A", isRequired: true, isSecret: true), ConnectionTarget.Field(name: "B", isRequired: true, isSecret: true)]
        let later = [ConnectionTarget.Field(name: "B", isRequired: true, isSecret: false, defaultValue: "shown")]
        let all = ConnectionTarget.merged(first, with: later)
        #expect(all.map(\.name) == ["A", "B"])
        #expect(all[1].isSecret && all[1].defaultValue == "")
    }

    @Test func retryGoesOnlyWhenTheGatewaySaysThatVeryCardIsOpen() async throws {
        let card = ConnectionRequest(opID: "op-r", seq: 1, deadline: nil, targets: [])
        for status in [#"{}"#, #"{"op_id":"op-other","settled":false}"#, #"{"op_id":"op-r"}"#] {
            let (gateway, endpoint) = try await FakeGateway.start { id, method in
                [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(method == "connectors.operation.status" ? status : #"{"op_id":"op-r","seq":2,"targets":[]}"#)}"#]
            }
            defer { gateway.stop() }
            let client = GatewayClient(endpoint: endpoint, token: "t")
            await client.connect()
            await #expect(throws: GatewayError.self, "\(status)") { _ = try await client.retry("notion", of: card, inSession: "live-1", profile: "default") }
            #expect(gateway.params(of: "connectors.connect").isEmpty, "\(status)")
        }
        let (gateway, endpoint) = try await FakeGateway.start { id, method in
            [#"{"jsonrpc":"2.0","id":\#(id),"result":\#(method == "connectors.operation.status" ? #"{"op_id":"op-r","settled":false}"# : #"{"op_id":"op-r","seq":2,"targets":[]}"#)}"#]
        }
        defer { gateway.stop() }
        let client = GatewayClient(endpoint: endpoint, token: "t")
        await client.connect()
        #expect(try await client.retry("notion", of: card, inSession: "live-1", profile: "default")?.seq == 2)
    }

    @Test func a4004RefusalUsesStructuredReasonBeforeMessage() async throws {
        let card = ConnectionRequest(opID: "op-r", seq: 1, deadline: nil, targets: [])
        func client(connectError: String) async throws -> (FakeGateway, GatewayClient) {
            let (gateway, endpoint) = try await FakeGateway.start { id, method in
                if method == "connectors.operation.status" {
                    return [#"{"jsonrpc":"2.0","id":\#(id),"result":{"op_id":"op-r","seq":1,"settled":false,"targets":[]}}"#]
                }
                return [#"{"jsonrpc":"2.0","id":\#(id),"error":\#(connectError)}"#]
            }
            let client = GatewayClient(endpoint: endpoint, token: "t")
            await client.connect()
            return (gateway, client)
        }

        // `data.reason` == UNKNOWN_OPERATION wins even when message text mentions "target".
        let (g1, c1) = try await client(connectError: #"{"code":4004,"message":"target gone","data":{"reason":"UNKNOWN_OPERATION"}}"#)
        defer { g1.stop() }
        await #expect(throws: GatewayClient.ConnectionOver.self) {
            _ = try await c1.retry("notion", of: card, inSession: "live-1", profile: "default")
        }

        // `data.reason` == UNKNOWN_TARGET keeps the card open even when message text omits "target".
        let (g2, c2) = try await client(connectError: #"{"code":4004,"message":"Missing row","data":{"reason":"UNKNOWN_TARGET"}}"#)
        defer { g2.stop() }
        await #expect(throws: GatewayClient.ConnectionRefusal(code: 4004, reason: "UNKNOWN_TARGET", message: "Missing row")) {
            _ = try await c2.retry("notion", of: card, inSession: "live-1", profile: "default")
        }

        // Without `data.reason`, falls back to checking message text for "target".
        let (g3, c3) = try await client(connectError: #"{"code":4004,"message":"No such target on the open operation."}"#)
        defer { g3.stop() }
        await #expect(throws: GatewayClient.ConnectionRefusal(code: 4004, reason: nil, message: "No such target on the open operation.")) {
            _ = try await c3.retry("notion", of: card, inSession: "live-1", profile: "default")
        }

        let (g4, c4) = try await client(connectError: #"{"code":4004,"message":"No open operation with that op_id."}"#)
        defer { g4.stop() }
        await #expect(throws: GatewayClient.ConnectionOver.self) {
            _ = try await c4.retry("notion", of: card, inSession: "live-1", profile: "default")
        }
    }

    /// Every `profiles.list` answer a client hears is noted by the names it gave, and a mark
    /// whose answers are no longer all kept says so rather than passing some over.
    @Test func everyBotListHeardIsNotedUntilTooManyHaveCome() async throws {
        let client = GatewayClient(endpoint: try #require(GatewayEndpoint("127.0.0.1:1")), token: "t")
        let mark = await client.listingMark()
        await client.noteListing([try json(#"{"name": "default"}"#), try json(#"{"title": "no name"}"#)])
        await client.noteListing([try json(#"{"name": "default"}"#)])
        let listed = try #require(await client.listings(since: mark))
        let heard = listed.heard
        #expect(listed.through == mark + 2)
        #expect(heard.count == 2)
        #expect(heard[0].contains("default") && heard[0].count == 2)
        #expect(heard[1] == ["default"])
        for _ in 0..<GatewayClient.listingsKept { await client.noteListing([]) }
        #expect(await client.listings(since: mark) == nil)
        #expect(await client.listings(since: await client.listingMark())?.heard == [])
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
