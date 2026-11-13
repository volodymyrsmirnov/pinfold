import Foundation
@testable import Pinfold
import Testing

/// `SubscriptionContentWriter.apply`: a refresh replaces a list's original but keeps everything
/// the person made (sidecar annotations, remote-image consent, refresh state) and rebuilds the
/// data derived from the new original.
@Suite(.serialized) @MainActor
struct SubscriptionContentWriterTests {
    // MARK: - Fixtures

    private func kml(_ names: [String]) -> Data {
        let placemarks = names.enumerated().map { index, name in
            "<Placemark><name>\(name)</name><Point><coordinates>\(index + 1),2,0</coordinates></Point></Placemark>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Feed</name>\(placemarks)</Document></kml>
        """.utf8)
    }

    private struct Environment {
        let storage: StorageLocations
        let cache: ResourceCache
        let entry: CatalogEntry

        var resourcesDir: URL {
            storage.resourcesDirectory(for: entry)
        }
    }

    /// A committed one-placemark list. The cache never fetches (`.never`), so nothing touches
    /// the network and no background download races the assertions.
    private func makeEnvironment() async throws -> Environment {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base.appendingPathComponent("synced", isDirectory: true),
                                       cacheRoot: base.appendingPathComponent("cache", isDirectory: true))
        let cache = ResourceCache(downloader: { _ in Data() }, policy: { .never })
        let catalog = Catalog(storage: storage, cache: cache)
        let prepared = try ImportService.prepare(data: kml(["Old"]), sourceFilename: "feed.kml")
        try ImportService.commit(prepared, storage: storage, cache: cache)
        await catalog.reload()
        return try Environment(storage: storage, cache: cache, entry: #require(catalog.entries.first))
    }

    // MARK: - Choices in resources/ survive, derived data is rebuilt

    @Test func derivedOnly_keepsConsentAndState() async throws {
        let env = try await makeEnvironment()
        ResourceManifestStore.shared.updateState(in: env.resourcesDir) { $0.consent = true }
        let state = SubscriptionState(
            lastAttemptAt: Date(timeIntervalSince1970: 1000),
            lastSuccessAt: Date(timeIntervalSince1970: 1000),
            etag: "\"v1\"",
            lastModified: "Wed, 21 Oct 2026 07:28:00 GMT"
        )
        SubscriptionStateStore.write(state, in: env.resourcesDir)
        // A derived file left over from the old original must not survive the refresh.
        let stale = env.resourcesDir.appendingPathComponent("stale-icon.png")
        try Data("old".utf8).write(to: stale)

        let new = try ImportService.prepare(data: kml(["Alpha", "Beta"]), sourceFilename: "feed.kml")
        let updated = try await SubscriptionContentWriter.apply(new, to: env.entry, storage: env.storage, cache: env.cache)

        #expect(ResourceManifestStore.shared.state(in: env.resourcesDir).consent)
        #expect(SubscriptionStateStore.read(in: env.resourcesDir) == state)
        let index = try #require(PlacemarkIndex.read(from: env.resourcesDir))
        #expect(index.map(\.name).sorted() == ["Alpha", "Beta"])
        #expect(PlacemarkIndex.sourceStamp(in: env.resourcesDir) == new.contentSHA256)
        #expect(PlacemarkIndex.derivedDataIsCurrent(in: env.resourcesDir))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(try Data(contentsOf: env.storage.originalFile(for: updated)) == new.originalData)
    }

    @Test func derivedOnly_keepsNotesFavouritesTagsName() async throws {
        let env = try await makeEnvironment()
        let note = PlacemarkNote(text: "Bring water", modifiedAt: Date(timeIntervalSince1970: 2000), placemarkName: "Old")
        let subscription = try Subscription(
            url: #require(URL(string: "https://example.test/feed.kml")),
            origin: .url,
            subscribedAt: Date(timeIntervalSince1970: 500)
        )
        try env.storage.updateExistingMetadata(forFolderNamed: env.entry.storageFolderName) { metadata in
            metadata.displayName = "My Trail Feed"
            metadata.notes = ["key-1": note]
            metadata.favoriteKeys = ["key-1"]
            metadata.visitedKeys = ["key-2"]
            metadata.tags = ["hiking", "summer"]
            metadata.subscription = subscription
        }
        let before = try #require(try env.storage.readMetadata(forFolderNamed: env.entry.storageFolderName))

        let new = try ImportService.prepare(data: kml(["Alpha", "Beta"]), sourceFilename: "feed.kml")
        _ = try await SubscriptionContentWriter.apply(new, to: env.entry, storage: env.storage, cache: env.cache)

        let after = try #require(try env.storage.readMetadata(forFolderNamed: env.entry.storageFolderName))
        #expect(after.displayName == "My Trail Feed")
        #expect(after.notes == before.notes)
        #expect(after.favoriteKeys == before.favoriteKeys)
        #expect(after.visitedKeys == before.visitedKeys)
        #expect(after.tags == before.tags)
        #expect(after.trashedAt == before.trashedAt)
        #expect(after.subscription == subscription)
        #expect(after.contentSHA256 == new.contentSHA256)
        #expect(after.pointCount == 2)
        #expect(before.pointCount == 1)
    }

    @Test func kmz_derivedOnly_reextractsEmbedded() async throws {
        let env = try await makeEnvironment()
        let new = try ImportService.prepare(data: AppFixture.data("Rome.kmz"), sourceFilename: "feed.kmz")
        #expect(new.format == .kmz)

        let updated = try await SubscriptionContentWriter.apply(new, to: env.entry, storage: env.storage, cache: env.cache)

        let icon = env.cache.cachedFilename(for: "images/icon-1.png")
        #expect(FileManager.default.fileExists(atPath: env.resourcesDir.appendingPathComponent(icon).path))
        #expect(ResourceManifestStore.shared.manifest(in: env.resourcesDir)["images/icon-1.png"] == icon)
        #expect(PlacemarkIndex.sourceStamp(in: env.resourcesDir) == new.contentSHA256)
        #expect(updated.sourceFilename == "feed.kmz")
    }

    // MARK: - Remote image cache

    /// A KML whose icon styles reference `hrefs` (gathered by `prepare` as remote hrefs).
    private func kml(icons hrefs: [String]) -> Data {
        let styles = hrefs.enumerated().map { index, href in
            "<Style id=\"s\(index)\"><IconStyle><Icon><href>\(href)</href></Icon></IconStyle></Style>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Feed</name>\(styles)
        <Placemark><name>New</name><Point><coordinates>1,2,0</coordinates></Point></Placemark>
        </Document></kml>
        """.utf8)
    }

    @Test func derivedOnly_keepsRemoteImageCacheForHrefsStillListed() async throws {
        let env = try await makeEnvironment()
        let dir = env.resourcesDir
        let store = ResourceManifestStore.shared
        let kept = "https://img.test/kept.png"
        let skipped = "https://img.test/skipped.png"
        let pending = "https://img.test/pending.png"
        let dropped = "https://img.test/dropped.png"
        let keptFile = env.cache.cachedFilename(for: kept)
        let droppedFile = env.cache.cachedFilename(for: dropped)
        try Data("kept".utf8).write(to: dir.appendingPathComponent(keptFile))
        try Data("dropped".utf8).write(to: dir.appendingPathComponent(droppedFile))
        try store.updateManifest(in: dir) { manifest in
            manifest[kept] = keptFile
            manifest[skipped] = "" // permanent skip marker
            manifest[dropped] = droppedFile
        }
        let backoff = DownloadState.HrefState(attempts: 2, nextAttemptAt: Date(timeIntervalSince1970: 4_000_000_000))
        store.updateState(in: dir) { state in
            state.consent = true
            state.hrefs[pending] = backoff
            state.hrefs[dropped] = backoff
        }

        let new = try ImportService.prepare(data: kml(icons: [kept, skipped, pending]), sourceFilename: "feed.kml")
        #expect(Set(new.remoteResourceHrefs) == [kept, skipped, pending])
        _ = try await SubscriptionContentWriter.apply(new, to: env.entry, storage: env.storage, cache: env.cache)

        let manifest = store.manifest(in: dir)
        #expect(manifest[kept] == keptFile)
        #expect(try Data(contentsOf: dir.appendingPathComponent(keptFile)) == Data("kept".utf8))
        #expect(manifest[skipped] == "")
        #expect(manifest[dropped] == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(droppedFile).path))
        let state = store.state(in: dir)
        #expect(state.consent)
        #expect(state.hrefs[pending] == backoff)
        #expect(state.hrefs[dropped] == nil)
    }

    // MARK: - Conflicts on the original

    @Test func resolveOriginalConflicts_withoutConflicts_leavesFileAlone() async throws {
        let env = try await makeEnvironment()
        let url = env.storage.originalFile(for: env.entry)
        let before = try Data(contentsOf: url)
        try resolveOriginalConflicts(at: url)
        #expect(try Data(contentsOf: url) == before)
    }
}
