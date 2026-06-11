import Foundation
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

        // Permanently skipped — retry must not re-attempt.
        actor CallCounter { var count = 0; func increment() {
            count += 1
        } }
        let counter = CallCounter()
        let retry = ResourceCache { _ in
            await counter.increment()
            return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
        await retry.retryPending(in: dir)
        #expect(await counter.count == 0,
                "A non-image href must be permanently skipped, not retried")
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
        let failing = ResourceCache { _ in
            struct FakeNetworkError: Error {}
            throw FakeNetworkError()
        }
        await failing.downloadRemote([href], to: dir)
        #expect(failing.localURL(forHref: href, in: dir) == nil, "Initial download must fail")

        // Connectivity restored: a retry that is NOT handed the href list reads the recorded
        // one (no re-parse) and succeeds.
        let succeeding = ResourceCache { _ in Self.pngBytes }
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
