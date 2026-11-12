import Foundation
import os

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
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw DownloadError.transport(URLError(.unsupportedURL))
        }
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let delegate = SameHostRedirectGuard(enabled: !followCrossHostRedirects)

        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            if delegate.refusedRedirect {
                throw DownloadError.redirectedToOtherHost
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
            return data
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
