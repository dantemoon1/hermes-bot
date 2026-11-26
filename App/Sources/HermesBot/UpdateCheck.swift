import Foundation
import Observation

/// Whether a newer version of the app has been released. It asks GitHub for the latest
/// release of the app's own repository when the app opens and once a day after, and
/// says so in Settings, with a way to the release page. Nothing is downloaded or
/// installed (issue 44 is for that), and nothing is sent but the request itself.
@MainActor
@Observable
final class UpdateCheck {
    static let shared = UpdateCheck()

    /// Where releases are published.
    nonisolated static let repository = "dantemoon1/hermes-bot"
    /// The most of an answer that is read. A release is a few kilobytes.
    nonisolated static let limit = 256 * 1024

    /// The version this copy of the app is, from its bundle; nil when it runs from source.
    let current: String?
    /// A newer version, and the page it is on. Nil until one is found, and again once
    /// the latest release is no longer newer (one taken back).
    private(set) var available: (version: String, page: URL)?

    private var watching: Task<Void, Never>?

    init(current: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.current = current
    }

    /// Asks now and then once a day, for as long as the app runs. Only a copy of the
    /// app that knows its own version asks: one run from source has nothing to compare.
    func start() {
        guard watching == nil, current != nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    /// What GitHub said: a release's answer, or that there is no published release.
    enum Answer: Equatable, Sendable {
        case release(Data)
        case none
    }

    /// Asks GitHub once. A failure or an answer that is not a release changes nothing
    /// and says nothing; GitHub saying there is no release takes any offer away.
    func check(fetch: @Sendable (URLRequest) async throws -> Answer? = UpdateCheck.fetch) async {
        guard let current, let running = Self.version(of: current) else { return }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        switch try? await fetch(request) {
        case .none?:
            available = nil
        case .release(let data)?:
            guard let tag = Self.tag(in: data), let latest = Self.version(of: tag) else { return }
            available = Self.isNewer(latest, than: running) ? (latest.map(String.init).joined(separator: "."), Self.page(for: tag)) : nil
        case nil:
            return
        }
    }

    /// The tag of a published release in GitHub's answer: an object with a release's
    /// number, and `draft` and `prerelease` both said and both false. Anything else is
    /// not a release.
    nonisolated static func tag(in data: Data) -> String? {
        guard let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = release["id"] as? NSNumber, CFGetTypeID(id) == CFNumberGetTypeID(), !CFNumberIsFloatType(id),
              id.stringValue.allSatisfy(\.isASCII), id.stringValue.allSatisfy(\.isNumber), let number = Int64(id.stringValue), number > 0,
              let draft = release["draft"] as? NSNumber, CFGetTypeID(draft) == CFBooleanGetTypeID(), !draft.boolValue,
              let prerelease = release["prerelease"] as? NSNumber, CFGetTypeID(prerelease) == CFBooleanGetTypeID(), !prerelease.boolValue
        else { return nil }
        return release["tag_name"] as? String
    }

    /// A version written as up to four numbers with dots between, a `v` before them
    /// allowed (`v1.2.0`); anything else is not a version this app compares.
    nonisolated static func version(of text: String) -> [Int]? {
        guard let match = text.wholeMatch(of: /v?([0-9]{1,6}(?:\.[0-9]{1,6}){0,3})/) else { return nil }
        return match.1.split(separator: ".").compactMap { Int($0) }
    }

    nonisolated static func isNewer(_ one: [Int], than other: [Int]) -> Bool {
        for index in 0..<max(one.count, other.count) {
            let a = index < one.count ? one[index] : 0, b = index < other.count ? other[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The release's page, made here from the tag (already checked to be a plain
    /// version), never taken from the answer: what opens is always this repository's.
    nonisolated static func page(for tag: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")!
    }

    /// The answer's body from a 200, `.none` from a 404 (GitHub's word for no published
    /// release), and nil for anything else. No cookies are kept or sent, nothing is
    /// cached, a redirect is not followed, the whole of it must come within 20 seconds,
    /// and it must come unpacked, no more than `limit` bytes of it, or it is not read.
    nonisolated static func fetch(_ request: URLRequest) async throws -> Answer? {
        var request = request
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return Answer.none }
        guard http.statusCode == 200, (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity",
              http.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { return nil }
        }
        return .release(data)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
