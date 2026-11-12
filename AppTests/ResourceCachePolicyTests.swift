import Foundation
import os
@testable import Pinfold
import Testing

/// D7: policy is re-checked before every request, and transport/HTTP failures never count toward
/// the non-image give-up limit.
struct ResourceCachePolicyTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    private static let html = Data("<html>sign in</html>".utf8)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func switchingToNever_midBatch_stopsQueuedRequests() async throws {
        let dir = try makeTempDir()
        let policy = OSAllocatedUnfairLock<RemoteImagePolicy>(initialState: .always)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = ResourceCache(downloader: { _ in
            calls.withLock { $0 += 1 }
            policy.withLock { $0 = .never }
            try await Task.sleep(for: .milliseconds(20))
            return Self.png
        }, policy: { policy.withLock { $0 } })
        await cache.downloadRemote((0 ..< 20).map { "https://example.com/\($0).png" }, to: dir)
        #expect(calls.withLock { $0 } <= 4, "only the already-running requests may finish")
    }

    @Test func httpFailures_doNotCountTowardNonImageLimit() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = ResourceCache(downloader: { _ in
            let call = calls.withLock { value -> Int in value += 1; return value }
            switch call {
            case 1 ... 4: throw DownloadError.httpStatus(503)
            case 5: return Self.html
            default: return Self.png
            }
        }, now: { clock.withLock { $0 } })
        for _ in 0 ..< 6 {
            await cache.downloadRemote([href], to: dir)
            clock.withLock { $0 = $0.addingTimeInterval(86400 * 2) }
        }
        #expect(cache.localURL(forHref: href, in: dir) != nil, "the good image must still be fetched")
    }
}
