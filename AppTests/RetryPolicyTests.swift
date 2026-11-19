import Foundation
import os
@testable import Pinfold
import Testing

/// `RetryPolicy`: which failures are retried, how long it waits, and that `BoundedDownloader`
/// applies it to real requests.
struct RetryPolicyTests {
    /// Records the waits instead of sleeping.
    private final class Waits: Sendable {
        private let recorded = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        var values: [Duration] {
            recorded.withLock { $0 }
        }

        var policy: RetryPolicy {
            RetryPolicy(maxRetries: 3, baseDelay: .seconds(1), jitter: 0) { [recorded] delay in
                recorded.withLock { $0.append(delay) }
            }
        }
    }

    // MARK: - Classification

    @Test(arguments: [408, 429, 500, 502, 503, 504])
    func transientStatuses_areRetryable(status: Int) {
        #expect(RetryPolicy.isRetryable(DownloadError.httpStatus(status)))
    }

    @Test(arguments: [400, 401, 403, 404, 410, 451, 501])
    func definitiveStatuses_areNotRetryable(status: Int) {
        #expect(!RetryPolicy.isRetryable(DownloadError.httpStatus(status)))
    }

    @Test(arguments: [
        URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .networkConnectionLost, .notConnectedToInternet,
    ])
    func connectivityFailures_areRetryable(code: URLError.Code) {
        #expect(RetryPolicy.isRetryable(DownloadError.transport(URLError(code))))
        #expect(RetryPolicy.isRetryable(URLError(code)))
    }

    @Test(arguments: [
        URLError.Code.badURL, .unsupportedURL, .cancelled, .secureConnectionFailed,
        .serverCertificateUntrusted, .userAuthenticationRequired,
    ])
    func definitiveTransportFailures_areNotRetryable(code: URLError.Code) {
        #expect(!RetryPolicy.isRetryable(DownloadError.transport(URLError(code))))
    }

    @Test func boundsAndCancellation_areNotRetryable() {
        #expect(!RetryPolicy.isRetryable(DownloadError.tooLarge))
        #expect(!RetryPolicy.isRetryable(DownloadError.redirectedToOtherHost))
        #expect(!RetryPolicy.isRetryable(CancellationError()))
    }

    // MARK: - Schedule

    @Test func delays_double() {
        let policy = RetryPolicy.standard
        #expect(policy.delay(beforeRetry: 1) == .seconds(1))
        #expect(policy.delay(beforeRetry: 2) == .seconds(2))
        #expect(policy.delay(beforeRetry: 3) == .seconds(4))
    }

    @Test func run_stopsAfterThreeRetries() async {
        let waits = Waits()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await #expect(throws: DownloadError.self) {
            try await waits.policy.run { () async throws -> Int in
                calls.withLock { $0 += 1 }
                throw DownloadError.httpStatus(503)
            }
        }
        #expect(calls.withLock { $0 } == 4)
        #expect(waits.values == [.seconds(1), .seconds(2), .seconds(4)])
    }

    @Test func run_doesNotRetryDefinitiveFailure() async {
        let waits = Waits()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await #expect(throws: DownloadError.self) {
            try await waits.policy.run { () async throws -> Int in
                calls.withLock { $0 += 1 }
                throw DownloadError.httpStatus(404)
            }
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(waits.values.isEmpty)
    }

    @Test func run_jitterOnlyAddsToTheDelay() async throws {
        let recorded = OSAllocatedUnfairLock<[Duration]>(initialState: [])
        let policy = RetryPolicy(maxRetries: 1, baseDelay: .seconds(1), jitter: 0.25) { delay in
            recorded.withLock { $0.append(delay) }
        }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let value = try await policy.run { () async throws -> Int in
            let call = calls.withLock { count -> Int in
                count += 1
                return count
            }
            if call == 1 {
                throw URLError(.timedOut)
            }
            return 7
        }
        #expect(value == 7)
        let delay = try #require(recorded.withLock { $0.first })
        #expect(delay >= .seconds(1) && delay <= .milliseconds(1250))
    }

    // MARK: - Through the downloader

    private func fetch(host: String, retry: RetryPolicy) async throws -> Data {
        try await BoundedDownloader.fetch(
            #require(URL(string: "https://\(host)/a.png")), maxBytes: 1000, timeout: 5,
            configuration: StubURLProtocol.configuration(), retry: retry
        )
    }

    @Test func downloader_retriesServerErrorThenSucceeds() async throws {
        let host = "retry-503.test"
        StubURLProtocol.register(
            .init(chunks: [Data([1, 2])], transientFailures: 2, transientStatus: 503), host: host
        )
        let waits = Waits()
        let data = try await fetch(host: host, retry: waits.policy)
        #expect(data == Data([1, 2]))
        #expect(StubURLProtocol.requestCount(host: host) == 3)
        #expect(waits.values == [.seconds(1), .seconds(2)])
    }

    @Test func downloader_retriesTimeoutThenSucceeds() async throws {
        let host = "retry-timeout.test"
        StubURLProtocol.register(.init(chunks: [Data([9])], transientFailures: 1), host: host)
        let data = try await fetch(host: host, retry: Waits().policy)
        #expect(data == Data([9]))
        #expect(StubURLProtocol.requestCount(host: host) == 2)
    }

    @Test func downloader_givesUpAfterThreeRetries() async throws {
        let host = "retry-dns.test"
        StubURLProtocol.register(
            .init(chunks: [Data([1])], transientFailures: 10, transientError: .cannotFindHost), host: host
        )
        do {
            _ = try await fetch(host: host, retry: Waits().policy)
            Issue.record("expected failure")
        } catch DownloadError.transport {
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(StubURLProtocol.requestCount(host: host) == 4)
    }

    @Test func downloader_neverRetries404() async throws {
        let host = "retry-404.test"
        StubURLProtocol.register(.init(status: 404, chunks: [Data([1])]), host: host)
        let waits = Waits()
        do {
            _ = try await fetch(host: host, retry: waits.policy)
            Issue.record("expected failure")
        } catch let DownloadError.httpStatus(code) {
            #expect(code == 404)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(StubURLProtocol.requestCount(host: host) == 1)
        #expect(waits.values.isEmpty)
    }

    @Test func downloader_neverRetriesOversizeBody() async throws {
        let host = "retry-big.test"
        StubURLProtocol.register(.init(chunks: [Data(count: 1500)]), host: host)
        do {
            _ = try await fetch(host: host, retry: Waits().policy)
            Issue.record("expected tooLarge")
        } catch DownloadError.tooLarge {
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(StubURLProtocol.requestCount(host: host) == 1)
    }

    @Test func conditionalFetch_retriesToo() async throws {
        let host = "retry-cond.test"
        StubURLProtocol.register(
            .init(chunks: [Data([4])], transientFailures: 1, transientStatus: 502), host: host
        )
        let response = try await BoundedDownloader.fetchConditional(
            #require(URL(string: "https://\(host)/feed.kml")), etag: nil, lastModified: nil,
            maxBytes: 1000, timeout: 5, configuration: StubURLProtocol.configuration(), retry: Waits().policy
        )
        guard case let .data(data) = response.body else {
            Issue.record("expected data")
            return
        }
        #expect(data == Data([4]))
        #expect(StubURLProtocol.requestCount(host: host) == 2)
    }
}
