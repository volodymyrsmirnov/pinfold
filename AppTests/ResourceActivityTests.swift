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
}
