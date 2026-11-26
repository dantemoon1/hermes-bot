import Foundation

/// Fetches one response, taking it in as it arrives and stopping as soon as it is larger
/// than allowed. It follows no redirect: the request carries a credential.
final class LimitedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: Sendable {
        let status: Int
        let data: Data
        /// The kind the server says it is, without any parameters, in lower case.
        let type: String
        let name: String?
    }

    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var tooLarge = false
    private var continuation: CheckedContinuation<Result, any Error>?
    /// How it ended, when that came before anyone was waiting to hear: a task cancelled
    /// as it starts is over before the wait for it has begun.
    private var finished: Swift.Result<Result, any Error>?

    private init(limit: Int) {
        self.limit = limit
    }

    static func run(_ request: URLRequest, limit: Int) async throws -> Result {
        let download = LimitedDownload(limit: limit)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Told at once if it is already over; otherwise left waiting to be told.
                let already = download.lock.withLock { () -> Swift.Result<Result, any Error>? in
                    if download.finished == nil { download.continuation = continuation }
                    return download.finished
                }
                if let already { return continuation.resume(with: already) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        lock.withLock {
            self.response = http
            // Said to be too large before any of it has come.
            if http?.statusCode == 200, response.expectedContentLength > Int64(limit) { tooLarge = true }
        }
        completionHandler(lock.withLock { tooLarge } ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive more: Data) {
        let over = lock.withLock { () -> Bool in
            // Only a file is kept. What a refusal says is not needed: its number is enough.
            guard response?.statusCode == 200, !tooLarge else { return tooLarge }
            data.append(more)
            if data.count > limit {
                tooLarge = true
                // None of it is wanted, and no more is kept while the stop takes effect.
                data = Data()
            }
            return tooLarge
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (waiting, result): (CheckedContinuation<Result, any Error>?, Swift.Result<Result, any Error>) = lock.withLock {
            let outcome = ending(with: error)
            // Kept for whoever comes to wait, if nobody is waiting yet.
            if continuation == nil { finished = outcome.1 }
            defer { continuation = nil }
            return outcome
        }
        waiting?.resume(with: result)
    }

    /// How it ended. Called with the lock held.
    private func ending(with error: (any Error)?) -> (CheckedContinuation<Result, any Error>?, Swift.Result<Result, any Error>) {
        do {
            if tooLarge { return (continuation, .failure(GatewayError.rejected(code: 413, message: GatewayClient.tooLarge))) }
            if let error {
                let cancelled = (error as? URLError)?.code == .cancelled
                return (continuation, .failure(cancelled ? CancellationError() : GatewayError.connectionLost("File not fetched")))
            }
            guard let response else { return (continuation, .failure(GatewayError.connectionLost("File not fetched"))) }
            let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            let named = response.value(forHTTPHeaderField: "Content-Disposition") != nil ? response.suggestedFilename : nil
            return (continuation, .success(Result(status: response.statusCode, data: data, type: type, name: named)))
        }
    }
}
