import Foundation
import os
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `ResourceCache`. Pure disk I/O against a temporary directory — no shared
/// mutable state, so no `.serialized` requirement.
struct ResourceCacheTests {
    // MARK: - Helpers

    /// Creates a fresh temporary directory on disk for use as a `resources/` directory.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - cachedFilename

    @Test func cachedFilename_isDeterministic() {
        let cache = ResourceCache()
        let href = "https://example.com/images/icon.png"
        let first = cache.cachedFilename(for: href)
        let second = cache.cachedFilename(for: href)
        #expect(first == second)
    }

    @Test func cachedFilename_differsForDifferentHrefs() {
        let cache = ResourceCache()
        let a = cache.cachedFilename(for: "https://example.com/a.png")
        let b = cache.cachedFilename(for: "https://example.com/b.png")
        #expect(a != b)
    }

    @Test func cachedFilename_preservesPngExtension() {
        let cache = ResourceCache()
        let name = cache.cachedFilename(for: "https://example.com/icon.png")
        #expect(name.hasSuffix(".png"))
    }

    @Test func cachedFilename_preservesJpgExtension() {
        let cache = ResourceCache()
        let name = cache.cachedFilename(for: "https://example.com/photo.jpg")
        #expect(name.hasSuffix(".jpg"))
    }

    @Test func cachedFilename_usesImgForExtensionlessURL() {
        let cache = ResourceCache()
        let name = cache.cachedFilename(for: "https://example.com/resource")
        #expect(name.hasSuffix(".img"))
    }

    @Test func cachedFilename_stripsQueryStringFromExtension() {
        let cache = ResourceCache()
        // URL like "https://cdn.example.com/icon.png?v=2" should yield .png not .png?v=2
        let name = cache.cachedFilename(for: "https://cdn.example.com/icon.png?v=2")
        #expect(name.hasSuffix(".png"), "expected .png but got \(name)")
        #expect(!name.contains("?"))
    }

    @Test func cachedFilename_archivePath_preservesExtension() {
        let cache = ResourceCache()
        let name = cache.cachedFilename(for: "images/icon-1.png")
        #expect(name.hasSuffix(".png"))
    }

    // MARK: - writeEmbedded + localURL

    @Test func writeEmbedded_writesFilesAndManifest() throws {
        let cache = ResourceCache()
        let dir = try makeTempDir()
        let resources: [String: Data] = [
            "images/icon-1.png": Data([0x89, 0x50, 0x4E, 0x47]), // PNG header
            "images/icon-2.png": Data([0xFF, 0xD8, 0xFF, 0xE0]), // JPEG header
        ]

        try cache.writeEmbedded(resources, to: dir)

        for (key, _) in resources {
            let resolved = cache.localURL(forHref: key, in: dir)
            #expect(resolved != nil, "localURL should resolve for key \(key)")
            if let url = resolved {
                #expect(FileManager.default.fileExists(atPath: url.path),
                        "cached file should exist on disk for \(key)")
            }
        }
    }

    @Test func writeEmbedded_manifestContainsAllKeys() throws {
        let cache = ResourceCache()
        let dir = try makeTempDir()
        let resources: [String: Data] = [
            "images/a.png": Data([1, 2, 3]),
            "images/b.png": Data([4, 5, 6]),
        ]

        try cache.writeEmbedded(resources, to: dir)

        // localURL returning non-nil is sufficient evidence the manifest was updated
        let resolvedA = cache.localURL(forHref: "images/a.png", in: dir)
        let resolvedB = cache.localURL(forHref: "images/b.png", in: dir)
        #expect(resolvedA != nil)
        #expect(resolvedB != nil)
    }

    @Test func writeEmbedded_withRealRomeKmz() throws {
        // Uses the real Rome.kmz fixture so we exercise actual KMZ embedded resources.
        let cache = ResourceCache()
        let dir = try makeTempDir()

        let data = try AppFixture.data("Rome.kmz")
        let parsed = try KMLReader.read(data: data)
        #expect(!parsed.embeddedResources.isEmpty, "Rome.kmz should have embedded resources")

        try cache.writeEmbedded(parsed.embeddedResources, to: dir)

        // "images/icon-1.png" is confirmed to be in Rome.kmz
        let resolved = cache.localURL(forHref: "images/icon-1.png", in: dir)
        #expect(resolved != nil, "images/icon-1.png should be resolved after writeEmbedded")
        if let url = resolved {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func localURL_returnsNilForUnknownHref() throws {
        let cache = ResourceCache()
        let dir = try makeTempDir()

        let result = cache.localURL(forHref: "https://example.com/unknown.png", in: dir)
        #expect(result == nil)
    }

    // MARK: - downloadRemote

    /// Minimal valid PNG header bytes — `downloadRemote` now image-sniffs payloads, so stub
    /// downloaders must return real image magic bytes (not arbitrary text) to be cached.
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test func downloadRemote_stubWritesFilesAndUpdatesManifest() async throws {
        let dir = try makeTempDir()
        let stubData = Self.pngBytes

        // Stub downloader always succeeds
        let cache = ResourceCache { _ in stubData }

        let hrefs = [
            "https://example.com/icon-a.png",
            "https://example.com/icon-b.png",
        ]

        await cache.downloadRemote(hrefs, to: dir)

        for href in hrefs {
            let url = cache.localURL(forHref: href, in: dir)
            #expect(url != nil, "Downloaded file should be resolvable for \(href)")
            if let url {
                let written = try Data(contentsOf: url)
                #expect(written == stubData)
            }
        }
    }

    @Test func downloadRemote_offlineFirst_failingURLDoesNotBlockOthers() async throws {
        let dir = try makeTempDir()
        let successData = Self.pngBytes
        let failHref = "https://example.com/fail.png"
        let successHref = "https://example.com/success.png"

        let cache = ResourceCache { url in
            if url.absoluteString == failHref {
                struct FakeNetworkError: Error {}
                throw FakeNetworkError()
            }
            return successData
        }

        let hrefs = [failHref, successHref]
        await cache.downloadRemote(hrefs, to: dir)

        // The failing URL should NOT be in the manifest
        let failedURL = cache.localURL(forHref: failHref, in: dir)
        #expect(failedURL == nil, "Failed href must not be recorded in manifest")

        // The successful URL MUST be in the manifest
        let successURL = cache.localURL(forHref: successHref, in: dir)
        #expect(successURL != nil, "Successful href must be cached despite the other failure")
        if let url = successURL {
            let written = try Data(contentsOf: url)
            #expect(written == successData)
        }
    }

    @Test func downloadRemote_skipsNonHTTPHrefs() async throws {
        let dir = try makeTempDir()
        // Use a counter actor to safely track calls from concurrent code.
        actor CallCounter { var count = 0; func increment() {
            count += 1
        } }
        let counter = CallCounter()

        let cache = ResourceCache { _ in
            await counter.increment()
            return Data()
        }

        await cache.downloadRemote(["images/local-path.png", "ftp://old.example.com/icon.png"], to: dir)
        let callCount = await counter.count
        #expect(callCount == 0, "Non-http(s) hrefs should be skipped entirely")
    }

    @Test func downloadRemote_httpHref_fetchedOverHTTPSButKeyedByOriginalHref() async throws {
        let dir = try makeTempDir()
        // Capture the URL the downloader is actually asked to fetch.
        actor URLBox { var url: URL?; func set(_ u: URL) {
            url = u
        } }
        let box = URLBox()

        let cache = ResourceCache { url in
            await box.set(url)
            return Self.pngBytes
        }

        let httpHref = "http://maps.google.com/mapfiles/kml/paddle/blu-5.png"
        await cache.downloadRemote([httpHref], to: dir)

        // The fetch must happen over https (ATS blocks plain http).
        let fetched = await box.url
        #expect(fetched?.scheme == "https")
        #expect(fetched?.absoluteString == "https://maps.google.com/mapfiles/kml/paddle/blu-5.png")

        // But the manifest/lookup key remains the original http href so UI lookups resolve.
        #expect(cache.localURL(forHref: httpHref, in: dir) != nil)
    }

    // MARK: - download limits (DoS bounds for untrusted input)

    @Test func download_skipsResponsesOverSizeCap() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/huge.png"
        // 21 MB of zeros — over the 20 MB cap.
        let oversized = Data(count: 21 * 1024 * 1024)
        let cache = ResourceCache { _ in oversized }

        await cache.downloadRemote([href], to: dir)

        // The file must NOT be written / resolvable.
        #expect(cache.localURL(forHref: href, in: dir) == nil,
                "Oversized response must not be written")

        // It must be permanently skipped: a subsequent retry (even with a now-valid,
        // small image) must NOT re-attempt it.
        actor CallCounter { var count = 0; func increment() {
            count += 1
        } }
        let counter = CallCounter()
        let retry = ResourceCache { _ in
            await counter.increment()
            return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG
        }
        await retry.retryPending(in: dir)
        #expect(await counter.count == 0,
                "A permanently-skipped href must not be re-attempted by retryPending")
        #expect(retry.localURL(forHref: href, in: dir) == nil)
    }

    @Test func download_skipsNonImageData() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/notimage.png"
        let html = Data("<!doctype html><html><body>nope</body></html>".utf8)
        let cache = ResourceCache { _ in html }

        await cache.downloadRemote([href], to: dir)

        #expect(cache.localURL(forHref: href, in: dir) == nil,
                "Non-image payload must not be written")
    }

    @Test func download_acceptsRealImageMagicBytes() async throws {
        let dir = try makeTempDir()
        let pngHref = "https://example.com/real.png"
        let jpegHref = "https://example.com/real.jpg"
        // Minimal valid magic-byte headers.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

        let cache = ResourceCache { url in
            url.absoluteString.hasSuffix(".png") ? png : jpeg
        }
        await cache.downloadRemote([pngHref, jpegHref], to: dir)

        #expect(cache.localURL(forHref: pngHref, in: dir) != nil, "Valid PNG must be cached")
        #expect(cache.localURL(forHref: jpegHref, in: dir) != nil, "Valid JPEG must be cached")
    }

    @Test func download_capsHrefCountPerEntry() async throws {
        let dir = try makeTempDir()
        actor CallCounter { var count = 0; func increment() {
            count += 1
        } }
        let counter = CallCounter()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let cache = ResourceCache { _ in
            await counter.increment()
            return png
        }

        // 600 distinct hrefs — over the 500 per-entry cap.
        let hrefs = (0 ..< 600).map { "https://example.com/icon-\($0).png" }
        await cache.downloadRemote(hrefs, to: dir)

        #expect(await counter.count == 500,
                "At most maxRemoteResourcesPerEntry (500) downloads should be attempted")
        // Deterministic: the first 500 in input order are the ones attempted.
        #expect(cache.localURL(forHref: hrefs[0], in: dir) != nil)
        #expect(cache.localURL(forHref: hrefs[499], in: dir) != nil)
        #expect(cache.localURL(forHref: hrefs[500], in: dir) == nil,
                "Hrefs beyond the cap must not be downloaded")
    }

    // MARK: - clearDownloaded / resumeDeferred (C9)

    private func countingCache(_ counter: OSAllocatedUnfairLock<Int>) -> ResourceCache {
        ResourceCache(downloader: { _ in
            counter.withLock { $0 += 1 }
            return Self.pngBytes
        })
    }

    @Test func clearDownloaded_removesRemoteFilesKeepsEmbeddedAndIndex() async throws {
        let dir = try makeTempDir()
        let remote = "https://example.com/photo.png"
        let embedded = "images/icon.png"
        let cache = ResourceCache(downloader: { _ in Self.pngBytes })
        try cache.writeEmbedded([embedded: Self.pngBytes], to: dir)
        let indexURL = dir.appendingPathComponent(PlacemarkIndex.filename)
        try Data("{}".utf8).write(to: indexURL)
        await cache.downloadRemote([remote], to: dir)
        let remoteFile = try #require(cache.localURL(forHref: remote, in: dir))

        cache.clearDownloaded(in: dir)

        #expect(!FileManager.default.fileExists(atPath: remoteFile.path))
        #expect(cache.localURL(forHref: remote, in: dir) == nil)
        #expect(ResourceManifestStore.shared.manifest(in: dir)[remote] == nil)
        #expect(cache.localURL(forHref: embedded, in: dir) != nil)
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        #expect(ResourceManifestStore.shared.state(in: dir).deferredUntilOpened)
    }

    @Test func clearedEntryIsNotRetriedByBackgroundPass() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/photo.png"
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cache = countingCache(calls)
        await cache.downloadRemote([href], to: dir)
        cache.clearDownloaded(in: dir)
        let before = calls.withLock { $0 }

        await cache.retryPending(in: dir)

        #expect(calls.withLock { $0 } == before)
        #expect(cache.localURL(forHref: href, in: dir) == nil)
    }

    @Test func resumeDeferredFetchesAgain() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/photo.png"
        let cache = ResourceCache(downloader: { _ in Self.pngBytes })
        await cache.downloadRemote([href], to: dir)
        cache.clearDownloaded(in: dir)

        await cache.resumeDeferred(in: dir)

        #expect(cache.localURL(forHref: href, in: dir) != nil)
        #expect(!ResourceManifestStore.shared.state(in: dir).deferredUntilOpened)
    }

    // MARK: - retryPending

    @Test func retryPending_downloadsOnlyMissingHrefs() async throws {
        let dir = try makeTempDir()
        actor CallCounter { var count = 0; func increment() {
            count += 1
        } }
        let counter = CallCounter()

        let alreadyCachedHref = "https://example.com/cached.png"
        let pendingHref = "https://example.com/pending.png"

        // Pre-write the "already cached" resource
        let preCache = ResourceCache { _ in Self.pngBytes }
        await preCache.downloadRemote([alreadyCachedHref], to: dir)

        let retryCache = ResourceCache { _ in
            await counter.increment()
            return Self.pngBytes
        }

        await retryCache.retryPending([alreadyCachedHref, pendingHref], to: dir)

        let callCount = await counter.count
        // Only the pending one should have been downloaded
        #expect(callCount == 1, "retryPending should only attempt hrefs absent from the manifest")
        let pending = retryCache.localURL(forHref: pendingHref, in: dir)
        #expect(pending != nil, "Pending href should be cached after retry")
    }

    @Test func retryInDir_retriesRecordedHrefsAfterFailure() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/icon.png"

        // First attempt fails (offline) but records the expected href list to disk.
        let clock = Mutable(Date(timeIntervalSince1970: 1_000_000))
        let failing = ResourceCache(downloader: { _ in
            struct FakeNetworkError: Error {}
            throw FakeNetworkError()
        }, now: { clock.value })
        await failing.downloadRemote([href], to: dir)
        #expect(failing.localURL(forHref: href, in: dir) == nil, "Initial download must fail")

        // Connectivity restored: a retry that is NOT handed the href list reads the recorded
        // one (no re-parse) and succeeds.
        clock.value = clock.value.addingTimeInterval(3600) // past the backoff window
        let succeeding = ResourceCache(downloader: { _ in Self.pngBytes }, now: { clock.value })
        await succeeding.retryPending(in: dir)
        #expect(succeeding.localURL(forHref: href, in: dir) != nil,
                "retryPending(in:) should fetch the recorded pending href without being given it")
    }

    @Test func retryInDir_noOpWhenNothingRecorded() async throws {
        let dir = try makeTempDir()
        actor CallCounter { var count = 0; func increment() {
            count += 1
        } }
        let counter = CallCounter()
        let cache = ResourceCache { _ in
            await counter.increment()
            return Data()
        }
        await cache.retryPending(in: dir)
        #expect(await counter.count == 0, "Retry with no recorded hrefs must not download")
    }
}

// MARK: - DL-1 / DL-2 / DL-3

private final class Counter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    func increment() {
        value.withLock { $0 += 1 }
    }

    var count: Int {
        value.withLock { $0 }
    }
}

private final class Mutable<T: Sendable>: Sendable {
    private let box: OSAllocatedUnfairLock<T>
    init(_ initial: T) {
        box = OSAllocatedUnfairLock(initialState: initial)
    }

    func mutate(_ body: @Sendable (inout T) -> Void) {
        box.withLock { body(&$0) }
    }

    var value: T {
        get { box.withLock { $0 } }
        set { box.withLock { $0 = newValue } }
    }
}

extension ResourceCacheTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let html = Data("<html>portal</html>".utf8)

    private func state(_ dir: URL) -> DownloadState {
        ResourceManifestStore.shared.state(in: dir)
    }

    // MARK: DL-1

    @Test func http404_isRetriedLater_notMarkedSkipped() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let clock = Mutable(Date(timeIntervalSince1970: 1_000_000))
        let failing = ResourceCache(downloader: { _ in throw DownloadError.httpStatus(404) }, now: { clock.value })
        await failing.downloadRemote([href], to: dir)
        #expect(failing.localURL(forHref: href, in: dir) == nil)
        #expect(ResourceManifestStore.shared.manifest(in: dir)[href] == nil, "must not be a permanent skip")

        clock.value = clock.value.addingTimeInterval(3600)
        let working = ResourceCache(downloader: { _ in Self.png }, now: { clock.value })
        await working.retryPending(in: dir)
        #expect(working.localURL(forHref: href, in: dir) != nil)
    }

    @Test func nonImage200_isNotSkippedOnFirstAttempt() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let clock = Mutable(Date(timeIntervalSince1970: 1_000_000))
        let portal = ResourceCache(downloader: { _ in Self.html }, now: { clock.value })
        await portal.downloadRemote([href], to: dir)
        #expect(ResourceManifestStore.shared.manifest(in: dir)[href] == nil)
        #expect(state(dir).hrefs[href]?.attempts == 1)

        clock.value = clock.value.addingTimeInterval(3600)
        let working = ResourceCache(downloader: { _ in Self.png }, now: { clock.value })
        await working.retryPending(in: dir)
        #expect(working.localURL(forHref: href, in: dir) != nil)
    }

    @Test func tooLargeError_isPermanentSkip() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/big.png"
        let cache = ResourceCache { _ in throw DownloadError.tooLarge }
        await cache.downloadRemote([href], to: dir)
        #expect(ResourceManifestStore.shared.manifest(in: dir)[href] == "")
    }

    // MARK: DL-2

    @Test func retryPending_skipsHrefsInsideBackoffWindow() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let clock = Mutable(Date(timeIntervalSince1970: 1_000_000))
        let calls = Counter()
        let cache = ResourceCache(downloader: { _ in
            calls.increment()
            throw DownloadError.httpStatus(503)
        }, now: { clock.value })

        await cache.downloadRemote([href], to: dir)
        #expect(calls.count == 1)
        await cache.retryPending(in: dir)
        #expect(calls.count == 1, "inside the backoff window nothing is requested")

        clock.value = clock.value.addingTimeInterval(61)
        await cache.retryPending(in: dir)
        #expect(calls.count == 2)
    }

    @Test func attemptCounterGrowsAndBackoffDoubles() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let start = Date(timeIntervalSince1970: 1_000_000)
        let clock = Mutable(start)
        let cache = ResourceCache(downloader: { _ in throw DownloadError.httpStatus(500) }, now: { clock.value })

        var expectedDelays: [TimeInterval] = [60, 120, 240, 480]
        for attempt in 1 ... 4 {
            await cache.retryOrDownload(href, in: dir)
            let entry = try #require(state(dir).hrefs[href])
            #expect(entry.attempts == attempt)
            #expect(entry.nextAttemptAt == clock.value.addingTimeInterval(expectedDelays.removeFirst()))
            clock.value = clock.value.addingTimeInterval(86400)
        }
        #expect(ResourceCache.backoff(afterAttempts: 30) == 24 * 60 * 60)
    }

    @Test func offlineErrors_doNotCountAsAttempts() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let clock = Mutable(Date(timeIntervalSince1970: 1_000_000))
        let offline = ResourceCache(downloader: { _ in throw URLError(.notConnectedToInternet) }, now: { clock.value })
        for _ in 0 ..< 5 {
            await offline.retryOrDownload(href, in: dir)
        }
        #expect(state(dir).hrefs[href] == nil, "offline failures leave no attempts or backoff")

        let online = ResourceCache(downloader: { _ in Self.png }, now: { clock.value })
        await online.retryOrDownload(href, in: dir)
        #expect(online.localURL(forHref: href, in: dir) != nil)
    }

    @Test func deadHostStillBacksOff() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let cache = ResourceCache(downloader: { _ in throw URLError(.cannotFindHost) })
        await cache.retryOrDownload(href, in: dir)
        #expect(state(dir).hrefs[href]?.attempts == 1)
    }

    @Test func successClearsDownloadState() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let clock = Mutable(Date(timeIntervalSince1970: 1_000_000))
        let works = Mutable(false)
        let cache = ResourceCache(downloader: { _ in
            if works.value {
                return Self.png
            }
            throw DownloadError.httpStatus(500)
        }, now: { clock.value })
        await cache.downloadRemote([href], to: dir)
        #expect(state(dir).hrefs[href] != nil)

        works.value = true
        clock.value = clock.value.addingTimeInterval(3600)
        await cache.retryPending(in: dir)
        #expect(state(dir).hrefs[href] == nil)
        #expect(cache.localURL(forHref: href, in: dir) != nil)
    }

    @Test func concurrentPassesDoNotLoseManifestEntries() async throws {
        let dir = try makeTempDir()
        let cache = ResourceCache { _ in Self.png }
        let groups = (0 ..< 8).map { g in (0 ..< 10).map { "https://example.com/\(g)-\($0).png" } }
        await withTaskGroup(of: Void.self) { group in
            for hrefs in groups {
                group.addTask { await cache.downloadRemote(hrefs, to: dir) }
            }
        }
        let manifest = ResourceManifestStore.shared.manifest(in: dir)
        #expect(manifest.count == 80)
        #expect(ResourceManifestStore.shared.recordedHrefs(in: dir).count == 80)
    }

    @Test func nonImageContent_isSkippedAfterMaxAttempts() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let clock = Mutable(Date(timeIntervalSince1970: 1_000_000))
        let calls = Counter()
        let cache = ResourceCache(downloader: { _ in
            calls.increment()
            return Self.html
        }, now: { clock.value })
        for _ in 0 ..< 8 {
            await cache.downloadRemote([href], to: dir)
            clock.value = clock.value.addingTimeInterval(86400)
        }
        #expect(calls.count == 5)
        #expect(ResourceManifestStore.shared.manifest(in: dir)[href] == "")
        #expect(state(dir).hrefs[href] == nil)
    }

    @Test func downloadsRunAtMostFourAtATime() async throws {
        let dir = try makeTempDir()
        let current = Mutable(0)
        let peak = Mutable(0)
        let cache = ResourceCache { _ in
            current.mutate { $0 += 1 }
            peak.mutate { $0 = max($0, current.value) }
            try await Task.sleep(for: .milliseconds(30))
            current.mutate { $0 -= 1 }
            return Self.png
        }
        await cache.downloadRemote((0 ..< 12).map { "https://example.com/\($0).png" }, to: dir)
        #expect(peak.value <= 4)
        #expect(ResourceManifestStore.shared.manifest(in: dir).count == 12)
    }

    // MARK: DL-3

    @Test func policyNever_recordsHrefsButFetchesNothing() async throws {
        let dir = try makeTempDir()
        let calls = Counter()
        let cache = ResourceCache(downloader: { _ in
            calls.increment()
            return Self.png
        }, policy: { .never })
        await cache.downloadRemote(["https://example.com/a.png"], to: dir)
        #expect(calls.count == 0)
        #expect(ResourceManifestStore.shared.recordedHrefs(in: dir) == ["https://example.com/a.png"])
    }

    @Test func policyAsk_fetchesOnlyAfterConsent() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let calls = Counter()
        let cache = ResourceCache(downloader: { _ in
            calls.increment()
            return Self.png
        }, policy: { .ask })
        await cache.downloadRemote([href], to: dir)
        await cache.retryPending(in: dir)
        #expect(calls.count == 0)
        #expect(cache.pendingConsent(in: dir).count == 1)

        await cache.grantConsent(in: dir)
        #expect(calls.count == 1)
        #expect(cache.localURL(forHref: href, in: dir) != nil)
        #expect(cache.pendingConsent(in: dir) == .none)
        #expect(state(dir).consent)
    }

    @Test func switchingToAlways_resumesPending() async throws {
        let dir = try makeTempDir()
        let href = "https://example.com/a.png"
        let policy = Mutable(RemoteImagePolicy.never)
        let cache = ResourceCache(downloader: { _ in Self.png }, policy: { policy.value })
        await cache.downloadRemote([href], to: dir)
        #expect(cache.localURL(forHref: href, in: dir) == nil)

        policy.value = .always
        await cache.retryPending(in: dir)
        #expect(cache.localURL(forHref: href, in: dir) != nil)
    }

    @Test func pendingConsent_listsDistinctHosts() async throws {
        let dir = try makeTempDir()
        let cache = ResourceCache(downloader: { _ in Self.png }, policy: { .ask })
        await cache.downloadRemote([
            "https://B.example.com/1.png", "https://b.example.com/2.png",
            "http://a.example.org/3.png",
        ], to: dir)
        let pending = cache.pendingConsent(in: dir)
        #expect(pending.count == 3)
        #expect(pending.hosts == ["a.example.org", "b.example.com"])
    }

    @Test func pendingConsent_isEmptyUnlessPolicyIsAsk() async throws {
        let dir = try makeTempDir()
        let cache = ResourceCache(downloader: { _ in Self.png }, policy: { .never })
        await cache.downloadRemote(["https://example.com/a.png"], to: dir)
        #expect(cache.pendingConsent(in: dir) == .none)
    }

    @Test func downloadStateDecodesWithMissingKeys() throws {
        let decoded = try JSONDecoder().decode(DownloadState.self, from: Data("{}".utf8))
        #expect(decoded == DownloadState())
    }
}

private extension ResourceCache {
    /// Test helper: one pass over a single href.
    func retryOrDownload(_ href: String, in dir: URL) async {
        await downloadRemote([href], to: dir)
    }
}
