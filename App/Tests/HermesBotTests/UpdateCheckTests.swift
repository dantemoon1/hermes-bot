import Foundation
import Network
import Testing
@testable import HermesBot

/// Saying when a newer version has been released.
@MainActor
@Suite(.serialized)
struct UpdateCheckTests {
    private func answer(_ json: String) -> @Sendable (URLRequest) async throws -> UpdateCheck.Answer? {
        { request in
            #expect(request.url?.absoluteString == "https://api.github.com/repos/\(UpdateCheck.repository)/releases/latest")
            return .release(Data(json.utf8))
        }
    }

    private func release(_ tag: String) -> String {
        #"{"id": 1, "tag_name": "\#(tag)", "draft": false, "prerelease": false, "html_url": "https://evil.example/download"}"#
    }

    @Test func aNewerReleaseIsOfferedWithItsOwnPage() async {
        let check = UpdateCheck(current: "0.1.0")
        await check.check(fetch: answer(release("v0.2.0")))
        #expect(check.available?.version == "0.2.0")
        // The page is made from the tag, never taken from the answer.
        #expect(check.available?.page.absoluteString == "https://github.com/\(UpdateCheck.repository)/releases/tag/v0.2.0")
        // A release taken back: the latest is no longer newer, and nothing is offered.
        await check.check(fetch: answer(release("v0.1.0")))
        #expect(check.available == nil)
        // A failure meanwhile leaves what is known alone.
        await check.check(fetch: answer(release("v0.3.0")))
        await check.check { _ in throw URLError(.notConnectedToInternet) }
        await check.check(fetch: answer("not json"))
        await check.check { _ in nil }
        #expect(check.available?.version == "0.3.0")
        // GitHub saying there is no published release at all takes the offer away.
        await check.check { _ in UpdateCheck.Answer.none }
        #expect(check.available == nil)
    }

    @Test func nothingIsOfferedThatIsNotNewer() async {
        for (running, tag) in [("0.2.0", "v0.2.0"), ("0.2.0", "0.1.9"), ("1.0", "v1.0.0"), ("0.10.0", "v0.9.9")] {
            let check = UpdateCheck(current: running)
            await check.check(fetch: answer(release(tag)))
            #expect(check.available == nil, "\(running) vs \(tag)")
        }
        let check = UpdateCheck(current: "0.9.9")
        await check.check(fetch: answer(release("v0.10.0")))
        #expect(check.available?.version == "0.10.0")
    }

    @Test func anAnswerThatIsNotAPublishedReleaseChangesNothing() async {
        let answers = [
            #"{"tag_name": "v9.0.0"}"#,
            #"{"id": 1, "tag_name": "v9.0.0", "draft": "false", "prerelease": null}"#,
            #"{"id": 1, "tag_name": "v9.0.0", "draft": 0, "prerelease": 0}"#,
            #"{"id": "1", "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": 1.5, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": 1.0000000000000001, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": 2.0, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": 1e3, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": 18446744073709551617, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": 0, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": -3, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": true, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"tag_name": "v9.0.0", "draft": false, "prerelease": false}"#,
            #"{"id": 1, "tag_name": "v9.0.0", "draft": true, "prerelease": false}"#,
            #"{"id": 1, "tag_name": "v9.0.0", "draft": false, "prerelease": true}"#,
            release("v9.0.0/../../evil"), release("v9.0.0?x=1"), release("latest"), release("v9.0.0.0.0"),
            #"{"message": "Not Found"}"#, "not json", "[]",
        ]
        for json in answers {
            let check = UpdateCheck(current: "0.1.0")
            await check.check(fetch: answer(json))
            #expect(check.available == nil, "\(json)")
        }
    }

    @Test func aCopyRunFromSourceDoesNotAsk() async {
        let check = UpdateCheck(current: nil)
        await check.check { _ in
            Issue.record("asked")
            return Optional<UpdateCheck.Answer>.none
        }
        #expect(check.available == nil)
    }

    /// A server on this Mac that answers each request with what `reply` says for its
    /// path, and notes the requests' headers.
    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private let listener: NWListener
        var port: UInt16 { listener.port?.rawValue ?? 0 }
        var requests: [String] { lock.withLock { seen } }

        init(reply: @escaping @Sendable (String) -> Data) async throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_000) { data, _, _, _ in
                    let head = String(decoding: data ?? Data(), as: UTF8.self)
                    self.lock.withLock { self.seen.append(head) }
                    let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    connection.send(content: reply(path), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            await withCheckedContinuation { ready in
                listener.stateUpdateHandler = { [listener] state in
                    guard case .ready = state else { return }
                    listener.stateUpdateHandler = nil
                    ready.resume()
                }
                listener.start(queue: .global())
            }
        }

        deinit { listener.cancel() }
    }

    nonisolated private static func http(_ status: String, _ headers: [String] = [], _ body: String = "") -> Data {
        Data((["HTTP/1.1 \(status)", "Content-Length: \(body.utf8.count)", "Connection: close"] + headers + ["", body]).joined(separator: "\r\n").utf8)
    }

    /// The real way of asking: a redirect is not followed, a cookie is neither kept nor
    /// sent, only a 200 is read, and an answer too large is not taken.
    @Test func theRealRequestFollowsNoRedirectAndKeepsNoCookie() async throws {
        let body = #"{"id": 1, "tag_name": "v9.0.0", "draft": false, "prerelease": false}"#
        let server = try await Server { path in
            switch path {
            case "/moved": Self.http("302 Found", ["Location: /release", "Set-Cookie: who=you; Path=/"])
            case "/cookie": Self.http("200 OK", ["Set-Cookie: who=you; Path=/", "Content-Type: application/json"], body)
            case "/missing": Self.http("404 Not Found", [], body)
            case "/gone": Self.http("410 Gone", [], body)
            case "/packed": Self.http("200 OK", ["Content-Encoding: gzip"], body)
            case "/said-huge": Self.http("200 OK", ["Content-Type: application/json"], body).replacingContentLength(with: UpdateCheck.limit + 1)
            case "/huge": Self.http("200 OK", [], String(repeating: " ", count: UpdateCheck.limit + 10) + body)
            default: Self.http("200 OK", ["Content-Type: application/json"], body)
            }
        }
        func ask(_ path: String) async -> UpdateCheck.Answer? {
            try? await UpdateCheck.fetch(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!))
        }
        #expect(await ask("/release") == .release(Data(body.utf8)))
        #expect(await ask("/moved") == nil)
        #expect(await ask("/missing") == UpdateCheck.Answer.none)
        #expect(await ask("/gone") == nil)
        #expect(await ask("/huge") == nil)
        // Packed, it is not read at all: unpacked it could be far larger than it came.
        #expect(await ask("/packed") == nil)
        #expect(await ask("/said-huge") == nil)
        #expect(await ask("/cookie") == .release(Data(body.utf8)))
        // Asked for unpacked.
        #expect(server.requests.allSatisfy { $0.lowercased().contains("\r\naccept-encoding: identity") })
        _ = await ask("/release")
        // The redirect's destination was never asked for, and no request carried a cookie.
        #expect(server.requests.filter { $0.hasPrefix("GET /release ") }.count == 2)
        #expect(!server.requests.contains { $0.lowercased().contains("\r\ncookie:") })
    }
}

private extension Data {
    /// The same answer saying it is `length` bytes long.
    func replacingContentLength(with length: Int) -> Data {
        let text = String(decoding: self, as: UTF8.self)
        return Data(text.replacing(/Content-Length: [0-9]+/, with: "Content-Length: \(length)").utf8)
    }
}
