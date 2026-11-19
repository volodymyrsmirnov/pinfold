import Foundation
import os
@testable import Pinfold
import Testing

/// `ResourceActivity` and `ResourceCache.observedImageStatus`: what an image placeholder shows
/// while a download is queued, running, failed or done.
@MainActor
struct ResourceActivityTests {
    private nonisolated static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A downloader that holds every request until `release()`.
    private final class Gate: Sendable {
        private let waiters = OSAllocatedUnfairLock<[CheckedContinuation<Void, Never>]>(initialState: [])
        private let open = OSAllocatedUnfairLock(initialState: false)

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = open.withLock { isOpen in
                    if isOpen {
                        return true
                    }
                    waiters.withLock { $0.append(continuation) }
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }

        var waiting: Int {
            waiters.withLock { $0.count }
        }

        func release() {
            open.withLock { $0 = true }
            waiters.withLock { list in
                list.forEach { $0.resume() }
                list.removeAll()
            }
        }
    }

    @Test func statusIsLoadingWhileDownloadingThenCached() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/loading.png"
        let gate = Gate()
        let cache = ResourceCache(downloader: { _ in
            await gate.wait()
            return Self.png
        }, policy: { .always })
        #expect(cache.observedImageStatus(forHref: href, in: dir) == .idle)

        let pass = Task.detached { await cache.downloadRemote([href], to: dir) }
        while gate.waiting == 0 {
            await Task.yield()
        }
        #expect(cache.observedImageStatus(forHref: href, in: dir) == .loading)

        gate.release()
        await pass.value
        guard case .cached = cache.observedImageStatus(forHref: href, in: dir) else {
            Issue.record("expected cached")
            return
        }
    }

    @Test func queuedHrefsShowLoadingBeforeTheyStart() async throws {
        let dir = try makeTempDir()
        // More than the per-entry concurrency, so some wait for a slot.
        let hrefs = (0 ..< 10).map { "https://example.com/queued-\($0).png" }
        let gate = Gate()
        let cache = ResourceCache(downloader: { _ in
            await gate.wait()
            return Self.png
        }, policy: { .always })
        let pass = Task.detached { await cache.downloadRemote(hrefs, to: dir) }
        while gate.waiting == 0 {
            await Task.yield()
        }
        #expect(hrefs.allSatisfy { cache.observedImageStatus(forHref: $0, in: dir) == .loading })
        gate.release()
        await pass.value
        #expect(hrefs.allSatisfy { !ResourceActivity.isActive($0, in: dir) })
    }

    @Test func failedDownloadShowsFailedUntilItSucceeds() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/failed.png"
        let works = OSAllocatedUnfairLock(initialState: false)
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        let cache = ResourceCache(downloader: { _ in
            guard works.withLock({ $0 }) else { throw DownloadError.httpStatus(500) }
            return Self.png
        }, policy: { .always }, now: { clock.withLock { $0 } })

        await cache.downloadRemote([href], to: dir)
        #expect(cache.observedImageStatus(forHref: href, in: dir) == .failed)

        works.withLock { $0 = true }
        clock.withLock { $0 = $0.addingTimeInterval(3600) }
        await cache.retryPending(in: dir)
        guard case .cached = cache.observedImageStatus(forHref: href, in: dir) else {
            Issue.record("expected cached")
            return
        }
    }

    @Test func offlineStopsThePassAndUnmarksTheRest() async throws {
        let dir = try makeTempDir()
        let hrefs = (0 ..< 30).map { "https://example.com/offline-\($0).png" }
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let cache = ResourceCache(downloader: { _ in
            requests.withLock { $0 += 1 }
            throw DownloadError.transport(URLError(.notConnectedToInternet))
        }, policy: { .always })

        await cache.downloadRemote(hrefs, to: dir)
        // Only the first wave (at most the per-entry concurrency) went out.
        #expect(requests.withLock { $0 } < hrefs.count)
        #expect(hrefs.allSatisfy { !ResourceActivity.isActive($0, in: dir) })
    }

    @Test func clearingForgetsFailures() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/cleared.png"
        let cache = ResourceCache(downloader: { _ in throw DownloadError.httpStatus(500) }, policy: { .always })
        await cache.downloadRemote([href], to: dir)
        #expect(ResourceActivity.hasFailed(href, in: dir))
        cache.clearDownloaded(in: dir)
        #expect(!ResourceActivity.hasFailed(href, in: dir))
    }

    /// Switching remote images to Never while a retry waits stops the retry before it contacts
    /// the host again.
    @Test func policyChangeDuringRetry_stopsTheRetry() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/policy.png"
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let policy = OSAllocatedUnfairLock(initialState: RemoteImagePolicy.always)
        let retry = RetryPolicy(maxRetries: 3, baseDelay: .seconds(1), jitter: 0) { _ in
            policy.withLock { $0 = .never }
        }
        let cache = ResourceCache(downloader: { _ in
            requests.withLock { $0 += 1 }
            throw DownloadError.httpStatus(503)
        }, policy: { policy.withLock { $0 } }, retry: retry)

        await cache.downloadRemote([href], to: dir)
        #expect(requests.withLock { $0 } == 1)
        #expect(!ResourceActivity.isActive(href, in: dir))
        #expect(!ResourceActivity.hasFailed(href, in: dir), "a stopped retry is not a failure")
    }

    /// The live retry policy retries a transient failure within the pass.
    @Test func transientFailure_isRetriedWithinThePass() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/retry.png"
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let retry = RetryPolicy(maxRetries: 3, baseDelay: .zero, jitter: 0) { _ in }
        let cache = ResourceCache(downloader: { _ in
            let count = requests.withLock { value -> Int in
                value += 1
                return value
            }
            if count < 3 {
                throw DownloadError.httpStatus(503)
            }
            return Self.png
        }, policy: { .always }, retry: retry)

        await cache.downloadRemote([href], to: dir)
        #expect(requests.withLock { $0 } == 3)
        #expect(cache.localURL(forHref: href, in: dir) != nil)
    }

    /// A second pass over the same entry leaves hrefs the first is fetching alone (no duplicate
    /// request, and its outcome can't clear the first pass's progress).
    @Test func overlappingPasses_fetchEachHrefOnce() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/overlap.png"
        let gate = Gate()
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let cache = ResourceCache(downloader: { _ in
            requests.withLock { $0 += 1 }
            await gate.wait()
            return Self.png
        }, policy: { .always })

        let first = Task.detached { await cache.downloadRemote([href], to: dir) }
        while gate.waiting == 0 {
            await Task.yield()
        }
        await cache.downloadRemote([href], to: dir)
        #expect(ResourceActivity.isActive(href, in: dir), "the first pass still owns it")
        gate.release()
        await first.value
        #expect(requests.withLock { $0 } == 1)
    }

    @Test func failuresOfRemovedHrefs_areForgotten() async throws {
        let dir = try makeTempDir()
        let old = "https://example.com/old.png"
        let cache = ResourceCache(downloader: { _ in throw DownloadError.httpStatus(500) }, policy: { .always })
        await cache.downloadRemote([old], to: dir)
        #expect(ResourceActivity.hasFailed(old, in: dir))
        await cache.retryPending(["https://example.com/new.png"], to: dir)
        #expect(!ResourceActivity.hasFailed(old, in: dir))
    }
}
