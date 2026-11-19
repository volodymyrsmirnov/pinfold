import Foundation
import os
import PinfoldCore

/// Why a `BoundedDownloader` fetch failed.
enum DownloadError: Error {
    /// The server answered with a non-2xx status. Retried at once only when transient
    /// (`RetryPolicy.retryableStatuses`); `ResourceCache` still backs off and retries any status.
    case httpStatus(Int)
    /// The body is (or would be) larger than the allowed cap. Not retryable.
    case tooLarge
    /// The server redirected to a different host and the caller asked not to follow that.
    case redirectedToOtherHost
    /// Any transport-level failure (offline, timeout, TLS, bad URL). Retried at once only for
    /// connectivity, DNS, connect and timeout failures (`RetryPolicy`).
    case transport(Error)
}

/// Outcome of a conditional GET.
struct ConditionalResponse: Sendable {
    enum Body: Sendable { case notModified, data(Data) }
    let body: Body
    let etag: String?
    let lastModified: String?
    /// From `Cache-Control: max-age` (relative to now) or the `Expires` header.
    let httpExpires: Date?
}

/// A small, hardened HTTP GET for untrusted remote resources.
///
/// - Uses ephemeral sessions with no cookies, credentials or cache. Requests that don't inject
///   a configuration share one session per timeout, so downloads from the same host reuse its
///   connections (no new DNS lookup and TLS handshake per image).
/// - Rejects non-2xx responses with `DownloadError.httpStatus`.
/// - Rejects a declared `Content-Length` over the cap *before* reading the body.
/// - Collects the body as it arrives with a running limit and stops as soon as the cap is
///   passed, so an oversized or unbounded response never sits fully in memory.
/// - Optionally refuses redirects to a different host (`followCrossHostRedirects: false`), so a
///   confirmed download cannot silently contact a host the person was never shown.
/// - Applies `timeout` to each request (and three times that to the whole transfer).
/// - Retries transient failures (`RetryPolicy`): connectivity, DNS, timeouts, 5xx and 429.
enum BoundedDownloader {
    /// Fetches `url` and returns its body.
    ///
    /// - Parameters:
    ///   - url: An `http` or `https` URL. Other schemes fail with `.transport`.
    ///   - maxBytes: Largest accepted body size in bytes.
    ///   - timeout: Per-request timeout in seconds.
    ///   - followCrossHostRedirects: When `false`, a redirect to another host fails with
    ///     `.redirectedToOtherHost`. Defaults to `true` (image downloads).
    ///   - configuration: A session configuration for this request alone; `nil` (the default)
    ///     uses the shared session. Tests inject one carrying a `URLProtocol` stub.
    ///   - retry: How transient failures are retried.
    /// - Throws: `DownloadError`, or `CancellationError` when the calling task is cancelled.
    static func fetch(
        _ url: URL,
        maxBytes: Int,
        timeout: TimeInterval,
        followCrossHostRedirects: Bool = true,
        configuration: URLSessionConfiguration? = nil,
        retry: RetryPolicy = .standard
    ) async throws -> Data {
        let result = try await retry.run {
            try await download(
                url, request: URLRequest(url: url), maxBytes: maxBytes, timeout: timeout,
                followCrossHostRedirects: followCrossHostRedirects, configuration: configuration,
                allowNotModified: false
            )
        }
        return result.data ?? Data()
    }

    /// Conditional GET: sends `If-None-Match` / `If-Modified-Since` when given, treats `304` as
    /// `.notModified`, and reports the validators and freshness hints of a `200`.
    ///
    /// - Parameters:
    ///   - etag: The previously stored `ETag`, sent as `If-None-Match`.
    ///   - lastModified: The previously stored `Last-Modified`, sent as `If-Modified-Since`.
    ///   - now: The reference time for `Cache-Control: max-age` (injectable for tests).
    /// - Throws: `DownloadError`, or `CancellationError` when the calling task is cancelled.
    static func fetchConditional(
        _ url: URL,
        etag: String?,
        lastModified: String?,
        maxBytes: Int,
        timeout: TimeInterval,
        followCrossHostRedirects: Bool = false,
        configuration: URLSessionConfiguration? = nil,
        retry: RetryPolicy = .standard,
        now: Date = .now
    ) async throws -> ConditionalResponse {
        var request = URLRequest(url: url)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let result = try await retry.run {
            try await download(
                url, request: request, maxBytes: maxBytes, timeout: timeout,
                followCrossHostRedirects: followCrossHostRedirects, configuration: configuration,
                allowNotModified: true
            )
        }
        let http = result.response
        return ConditionalResponse(
            body: result.data.map { .data($0) } ?? .notModified,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            httpExpires: httpExpiry(http, now: now)
        )
    }

    /// `Cache-Control: max-age` (relative to `now`) wins over the `Expires` header.
    private static func httpExpiry(_ http: HTTPURLResponse, now: Date) -> Date? {
        if let control = http.value(forHTTPHeaderField: "Cache-Control") {
            for directive in control.split(separator: ",") {
                let parts = directive.split(separator: "=", maxSplits: 1)
                // A non-finite, non-positive or absurd `max-age` is ignored or capped
                // (`KMLRefreshHint`): it is stored and scheduled with.
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "max-age",
                      let seconds = KMLRefreshHint.sanitised(TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)
                              .trimmingCharacters(in: CharacterSet(charactersIn: "\""))))
                else { continue }
                return now.addingTimeInterval(seconds)
            }
        }
        guard let expires = http.value(forHTTPHeaderField: "Expires") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: expires)
    }

    // swiftlint:disable:next function_parameter_count
    private static func download(
        _ url: URL,
        request baseRequest: URLRequest,
        maxBytes: Int,
        timeout: TimeInterval,
        followCrossHostRedirects: Bool,
        configuration: URLSessionConfiguration?,
        allowNotModified: Bool
    ) async throws -> (response: HTTPURLResponse, data: Data?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw DownloadError.transport(URLError(.unsupportedURL))
        }
        let session: URLSession = if let configuration {
            TransferRouter.makeSession(configuration, timeout: timeout)
        } else {
            TransferRouter.sharedSession(timeout: timeout)
        }
        defer {
            if configuration != nil {
                session.finishTasksAndInvalidate()
            }
        }
        var request = baseRequest
        request.timeoutInterval = timeout
        let transfer = BoundedTransfer(
            maxBytes: maxBytes, allowNotModified: allowNotModified,
            refuseCrossHostRedirects: !followCrossHostRedirects
        )
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.begin(task, router: session.delegate as? TransferRouter, continuation: continuation)
            }
        } onCancel: {
            transfer.cancelByCaller(task)
        }
    }
}

// MARK: - Transfer state

/// One request's state: the response, the body collected so far, and how it ended. Every
/// callback arrives on the session's serial delegate queue; the lock covers the caller's
/// cancellation, which arrives from anywhere.
private final class BoundedTransfer: @unchecked Sendable {
    typealias Outcome = (response: HTTPURLResponse, data: Data?)

    private struct State {
        var continuation: CheckedContinuation<Outcome, Error>?
        var response: HTTPURLResponse?
        var data = Data()
        /// The first reason this transfer must fail; later errors (the cancel it triggers) lose.
        var failure: Error?
        var cancelledByCaller = false
        var finished = false
    }

    let maxBytes: Int
    let allowNotModified: Bool
    let refuseCrossHostRedirects: Bool
    private let lock = NSLock()
    private var current = State()

    init(maxBytes: Int, allowNotModified: Bool, refuseCrossHostRedirects: Bool) {
        self.maxBytes = maxBytes
        self.allowNotModified = allowNotModified
        self.refuseCrossHostRedirects = refuseCrossHostRedirects
    }

    /// Registers with the router, then starts the task unless the caller was cancelled.
    ///
    /// Registration comes first, so the task's completion always finds this transfer and
    /// removes the route. A caller cancelled before that is caught by the flag check after it:
    /// the route is taken back and the task never starts (a task cancelled before `resume` may
    /// already have completed, unseen, and would never report again).
    func begin(_ task: URLSessionDataTask, router: TransferRouter?, continuation: CheckedContinuation<Outcome, Error>) {
        locked { $0.continuation = continuation }
        guard let router else {
            finish(.failure(DownloadError.transport(URLError(.unknown))))
            return
        }
        router.register(self, for: task)
        if locked({ $0.cancelledByCaller }) {
            router.unregister(task)
            finish(.failure(CancellationError()))
            return
        }
        task.resume()
    }

    /// The calling task was cancelled: cancels the request and resumes the caller at once with
    /// `CancellationError`, without waiting for the task's completion callback. That callback
    /// can't be relied on here: cancelled between `begin`'s check and `register`, the task can
    /// complete before it is registered, and the router would drop its completion. (`finish`
    /// resumes at most once; before `begin` stores the continuation it does nothing, and `begin`
    /// then sees the flag.)
    func cancelByCaller(_ task: URLSessionDataTask) {
        locked { $0.cancelledByCaller = true }
        task.cancel()
        finish(.failure(CancellationError()))
    }

    /// Records why the transfer fails (the first reason wins) and cancels the task.
    func fail(_ error: Error, task: URLSessionTask) {
        locked { state in
            if state.failure == nil {
                state.failure = error
            }
        }
        task.cancel()
    }

    /// The response arrived: decides whether to read the body.
    func receive(_ response: URLResponse) -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            return refuse(DownloadError.transport(URLError(.badServerResponse)))
        }
        if allowNotModified, http.statusCode == 304 {
            locked { $0.response = http }
            return .allow
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            return refuse(DownloadError.httpStatus(http.statusCode))
        }
        if response.expectedContentLength > Int64(maxBytes) {
            return refuse(DownloadError.tooLarge)
        }
        locked { state in
            state.response = http
            if response.expectedContentLength > 0 {
                state.data.reserveCapacity(Int(response.expectedContentLength))
            }
        }
        return .allow
    }

    private func refuse(_ error: Error) -> URLSession.ResponseDisposition {
        locked { state in
            if state.failure == nil {
                state.failure = error
            }
        }
        return .cancel
    }

    /// A body chunk arrived. Returns `false` once the body passed the cap.
    func append(_ chunk: Data) -> Bool {
        locked { state in
            guard state.failure == nil, state.response?.statusCode != 304 else { return true }
            // Checked before appending, so the buffer never grows past the cap.
            guard chunk.count <= maxBytes - state.data.count else {
                state.failure = DownloadError.tooLarge
                state.data = Data()
                return false
            }
            state.data.append(chunk)
            return true
        }
    }

    /// The task ended, with `error` when it didn't complete.
    func complete(_ error: Error?) {
        let result: Result<Outcome, Error> = locked { state in
            if let failure = state.failure {
                return .failure(failure)
            }
            if state.cancelledByCaller {
                return .failure(CancellationError())
            }
            if let error {
                return .failure(DownloadError.transport(error))
            }
            guard let response = state.response else {
                return .failure(DownloadError.transport(URLError(.badServerResponse)))
            }
            return .success((response, response.statusCode == 304 ? nil : state.data))
        }
        finish(result)
    }

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.withLock { body(&current) }
    }

    private func finish(_ result: Result<Outcome, Error>) {
        let continuation = locked { state -> CheckedContinuation<Outcome, Error>? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            state.finished = true
            state.data = Data()
            return continuation
        }
        continuation?.resume(with: result)
    }
}

// MARK: - Session delegate

/// The delegate of every `BoundedDownloader` session: hands each task's callbacks to its
/// `BoundedTransfer`. A session-level delegate (rather than a per-task one) because it is what
/// receives the body chunks.
private final class TransferRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let transfers = OSAllocatedUnfairLock<[Int: BoundedTransfer]>(initialState: [:])

    /// Shared sessions, one per timeout (images and online lists use different ones).
    private static let shared = OSAllocatedUnfairLock<[TimeInterval: URLSession]>(initialState: [:])

    static func sharedSession(timeout: TimeInterval) -> URLSession {
        shared.withLock { sessions in
            if let existing = sessions[timeout] {
                return existing
            }
            let session = makeSession(.ephemeral, timeout: timeout)
            sessions[timeout] = session
            return session
        }
    }

    /// A session with no cookies, credentials or cache, so nothing from one untrusted request
    /// reaches the next.
    static func makeSession(_ configuration: URLSessionConfiguration, timeout: TimeInterval) -> URLSession {
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: TransferRouter(), delegateQueue: nil)
    }

    func register(_ transfer: BoundedTransfer, for task: URLSessionTask) {
        transfers.withLock { $0[task.taskIdentifier] = transfer }
    }

    func unregister(_ task: URLSessionTask) {
        transfers.withLock { _ = $0.removeValue(forKey: task.taskIdentifier) }
    }

    private func transfer(for task: URLSessionTask) -> BoundedTransfer? {
        transfers.withLock { $0[task.taskIdentifier] }
    }

    func urlSession(
        _: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let transfer = transfer(for: task), transfer.refuseCrossHostRedirects else {
            completionHandler(request)
            return
        }
        let original = task.originalRequest?.url?.host()?.lowercased()
        if request.url?.host()?.lowercased() == original {
            completionHandler(request)
            return
        }
        transfer.fail(DownloadError.redirectedToOtherHost, task: task)
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(transfer(for: dataTask)?.receive(response) ?? .cancel)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask) else { return }
        if !transfer.append(data) {
            dataTask.cancel()
        }
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let transfer = transfers.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        transfer?.complete(error)
    }
}
