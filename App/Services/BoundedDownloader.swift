import Foundation
import os
import PinfoldCore

/// Why a `BoundedDownloader` fetch failed.
enum DownloadError: Error {
    /// The server answered with a non-2xx status. Always retryable.
    case httpStatus(Int)
    /// The body is (or would be) larger than the allowed cap. Not retryable.
    case tooLarge
    /// The server redirected to a different host and the caller asked not to follow that.
    case redirectedToOtherHost
    /// Any transport-level failure (offline, timeout, TLS, bad URL). Retryable.
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
/// - Uses an ephemeral session (no cookies, credentials or disk cache).
/// - Rejects non-2xx responses with `DownloadError.httpStatus`.
/// - Rejects a declared `Content-Length` over the cap *before* reading the body.
/// - Streams the body with a running limit and stops as soon as the cap is passed, so an
///   oversized or unbounded response never sits fully in memory.
/// - Optionally refuses redirects to a different host (`followCrossHostRedirects: false`), so a
///   confirmed download cannot silently contact a host the person was never shown.
/// - Applies `timeout` to each request (and three times that to the whole transfer).
enum BoundedDownloader {
    /// Fetches `url` and returns its body.
    ///
    /// - Parameters:
    ///   - url: An `http` or `https` URL. Other schemes fail with `.transport`.
    ///   - maxBytes: Largest accepted body size in bytes.
    ///   - timeout: Per-request timeout in seconds.
    ///   - followCrossHostRedirects: When `false`, a redirect to another host fails with
    ///     `.redirectedToOtherHost`. Defaults to `true` (image downloads).
    ///   - configuration: Session configuration; defaults to `.ephemeral`. Tests inject a
    ///     configuration carrying a `URLProtocol` stub.
    /// - Throws: `DownloadError`, or `CancellationError` when the calling task is cancelled.
    static func fetch(
        _ url: URL,
        maxBytes: Int,
        timeout: TimeInterval,
        followCrossHostRedirects: Bool = true,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Data {
        let result = try await download(
            url, request: URLRequest(url: url), maxBytes: maxBytes, timeout: timeout,
            followCrossHostRedirects: followCrossHostRedirects, configuration: configuration,
            allowNotModified: false
        )
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
        configuration: URLSessionConfiguration = .ephemeral,
        now: Date = .now
    ) async throws -> ConditionalResponse {
        var request = URLRequest(url: url)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        let result = try await download(
            url, request: request, maxBytes: maxBytes, timeout: timeout,
            followCrossHostRedirects: followCrossHostRedirects, configuration: configuration,
            allowNotModified: true
        )
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
        configuration: URLSessionConfiguration,
        allowNotModified: Bool
    ) async throws -> (response: HTTPURLResponse, data: Data?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw DownloadError.transport(URLError(.unsupportedURL))
        }
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = baseRequest
        request.timeoutInterval = timeout
        let delegate = SameHostRedirectGuard(enabled: !followCrossHostRedirects)

        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            if delegate.refusedRedirect {
                throw DownloadError.redirectedToOtherHost
            }
            if allowNotModified, let http = response as? HTTPURLResponse, http.statusCode == 304 {
                return (http, nil)
            }
            try validate(response, maxBytes: maxBytes)
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                // Leaving the loop cancels the underlying task.
                if data.count > maxBytes {
                    throw DownloadError.tooLarge
                }
            }
            return try (httpResponse(response), data)
        } catch let error as DownloadError {
            throw error
        } catch is CancellationError {
            if delegate.refusedRedirect {
                throw DownloadError.redirectedToOtherHost
            }
            throw CancellationError()
        } catch {
            // A refused redirect cancels the task, which surfaces as a cancellation error.
            if delegate.refusedRedirect {
                throw DownloadError.redirectedToOtherHost
            }
            throw DownloadError.transport(error)
        }
    }

    private static func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.transport(URLError(.badServerResponse))
        }
        return http
    }

    private static func validate(_ response: URLResponse, maxBytes: Int) throws {
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.transport(URLError(.badServerResponse))
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(maxBytes) {
            throw DownloadError.tooLarge
        }
    }
}

/// Per-task delegate that declines redirects to a different host when `enabled`.
private final class SameHostRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let enabled: Bool
    private let refused = OSAllocatedUnfairLock(initialState: false)

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var refusedRedirect: Bool {
        refused.withLock { $0 }
    }

    func urlSession(
        _: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard enabled else { return request }
        let original = task.originalRequest?.url?.host()?.lowercased()
        if request.url?.host()?.lowercased() == original {
            return request
        }
        refused.withLock { $0 = true }
        task.cancel()
        return nil
    }
}
