import Foundation

/// Retries a network request after a transient failure, waiting longer before each attempt.
///
/// Only failures that a later attempt can plausibly fix are retried: lost or missing
/// connectivity, DNS and connect failures, timeouts, and the HTTP statuses that mean "try
/// again" (408, 429, 500, 502, 503, 504). A definitive answer is never retried: 404 and every
/// other 4xx, an over-cap body, a refused redirect, an unsupported URL, a TLS failure, or a
/// cancellation.
///
/// This is the short, in-request retry. `ResourceCache` and `SubscriptionRefresher` keep their
/// own longer-term schedules on top of it for whatever still fails.
struct RetryPolicy {
    /// Retries after the first attempt (so up to `maxRetries + 1` attempts in all).
    var maxRetries: Int
    /// Wait before the first retry; each later retry waits twice as long as the one before.
    var baseDelay: Duration
    /// Random extra wait, as a fraction of the delay (0.25 adds up to 25 %), so parallel
    /// downloads that failed together don't all retry at the same instant.
    var jitter: Double
    /// Waits between attempts; throws `CancellationError` when the calling task is cancelled.
    /// Tests inject one that records the delays instead of sleeping.
    var sleep: @Sendable (Duration) async throws -> Void

    /// Up to 3 retries, after about 1 s, 2 s and 4 s.
    static let standard = RetryPolicy(
        maxRetries: 3, baseDelay: .seconds(1), jitter: 0.25,
        sleep: { try await Task.sleep(for: $0) }
    )

    /// A single attempt.
    static let none = RetryPolicy(maxRetries: 0, baseDelay: .zero, jitter: 0, sleep: { _ in })

    /// The wait before retry number `retry` (1-based), without jitter: `baseDelay`, doubling.
    func delay(beforeRetry retry: Int) -> Duration {
        baseDelay * (1 << min(max(retry - 1, 0), 16))
    }

    /// Runs `operation`, retrying it while it fails with a retryable error and retries remain.
    /// The last error (or the first non-retryable one) is rethrown. `operation` runs in the
    /// caller's isolation, so it can check actor state (is this still wanted?) before each
    /// attempt and throw `CancellationError` to stop.
    func run<T>(
        isolation _: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async throws -> T {
        var retry = 0
        while true {
            do {
                return try await operation()
            } catch {
                guard retry < maxRetries, Self.isRetryable(error) else { throw error }
                retry += 1
                let base = delay(beforeRetry: retry)
                try await sleep(base + base * Double.random(in: 0 ... max(jitter, 0)))
            }
        }
    }

    // MARK: - Classification

    /// HTTP statuses a server uses to say "try again later".
    static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504]

    /// Whether a failed request may succeed if it is simply tried again.
    static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case let DownloadError.httpStatus(status):
            retryableStatuses.contains(status)
        case let DownloadError.transport(underlying):
            isRetryableTransport(underlying)
        case DownloadError.tooLarge, DownloadError.redirectedToOtherHost, DownloadError.stalled,
             is CancellationError:
            false
        default:
            isRetryableTransport(error)
        }
    }

    /// Connectivity, DNS, connect and timeout failures. Not: bad or unsupported URLs, TLS and
    /// certificate failures, cancellations, or anything outside `NSURLErrorDomain`.
    private static func isRetryableTransport(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}
