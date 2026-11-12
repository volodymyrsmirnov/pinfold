import Foundation

/// Why a `BoundedDownloader` fetch failed.
enum DownloadError: Error {
    /// The server answered with a non-2xx status. Always retryable.
    case httpStatus(Int)
    /// The body is (or would be) larger than the allowed cap. Not retryable.
    case tooLarge
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
/// - Applies `timeout` to each request (and three times that to the whole transfer).
enum BoundedDownloader {
    /// Fetches `url` and returns its body.
    ///
    /// - Parameters:
    ///   - url: An `http` or `https` URL. Other schemes fail with `.transport`.
    ///   - maxBytes: Largest accepted body size in bytes.
    ///   - timeout: Per-request timeout in seconds.
    ///   - configuration: Session configuration; defaults to `.ephemeral`. Tests inject a
    ///     configuration carrying a `URLProtocol` stub.
    /// - Throws: `DownloadError`, or `CancellationError` when the calling task is cancelled.
    static func fetch(
        _ url: URL,
        maxBytes: Int,
        timeout: TimeInterval,
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

        do {
            let (bytes, response) = try await session.bytes(for: request)
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
            throw CancellationError()
        } catch {
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
