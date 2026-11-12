import Foundation
@testable import Pinfold
import Testing

/// `CatalogScanner.materializeMissingResources`: when derived data is rebuilt (stale source
/// stamp, unparseable originals) and `Catalog.reload` pruning the shared index store.
@Suite(.serialized) @MainActor struct DerivedDataRefreshTests {
    private struct Seeded {
        let scanner: CatalogScanner
        let storage: StorageLocations
        let dir: URL
        let resourcesDir: URL
        let sha: String
    }

    /// An entry with Rome.kml as original, a sidecar claiming `sidecarSHA` (default: the real
    /// one), and a materialized resources dir holding an *empty* index (so a refresh is visible).
    private func seed(
        sidecarSHA: String? = nil, original: Data? = nil, currentVersion: Bool = true
    ) throws -> Seeded {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        let scanner = CatalogScanner(storage: storage, cache: ResourceCache { _ in Data() })
        let data = try original ?? AppFixture.data("Rome.kml")
        let sha = ImportService.sha256Hex(data)
        let dir = storage.root.appendingPathComponent("entry", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("Rome.kml"))
        let meta = EntryMetadata(
            id: UUID(), displayName: "Rome", sourceFilename: "Rome.kml",
            importDate: .now, pointCount: 1, contentSHA256: sidecarSHA ?? sha, trashedAt: nil
        )
        try meta.encoded().write(to: dir.appendingPathComponent("metadata.json"))
        let resourcesDir = storage.resourcesDirectory(forFolderNamed: "entry")
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try PlacemarkIndex.write([], to: resourcesDir)
        if currentVersion {
            PlacemarkIndex.writeDerivedDataVersion(to: resourcesDir)
        }
        return Seeded(scanner: scanner, storage: storage, dir: dir, resourcesDir: resourcesDir, sha: sha)
    }

    // MARK: - Stale index (snapshot replaced the original on another device)

    @Test func staleStamp_triggersRefresh() async throws {
        let seeded = try seed()
        PlacemarkIndex.writeSourceStamp("older-content", to: seeded.resourcesDir)

        _ = await seeded.scanner.materializeMissingResources()

        #expect(try #require(PlacemarkIndex.read(from: seeded.resourcesDir)).isEmpty == false)
        #expect(PlacemarkIndex.sourceStamp(in: seeded.resourcesDir) == seeded.sha)
    }

    @Test func matchingStamp_doesNotRefresh() async throws {
        let seeded = try seed()
        PlacemarkIndex.writeSourceStamp(seeded.sha, to: seeded.resourcesDir)

        _ = await seeded.scanner.materializeMissingResources()

        #expect(PlacemarkIndex.read(from: seeded.resourcesDir) == [])
    }

    @Test func unstampedIndex_countsAsCurrentAndGetsStamped() async throws {
        let seeded = try seed()
        #expect(PlacemarkIndex.sourceStamp(in: seeded.resourcesDir) == nil)

        _ = await seeded.scanner.materializeMissingResources()

        #expect(PlacemarkIndex.read(from: seeded.resourcesDir) == [], "no second full refresh")
        #expect(PlacemarkIndex.sourceStamp(in: seeded.resourcesDir) == seeded.sha)
    }

    // MARK: - Derived-data version (entries refreshed by an older build)

    @Test func entryWithoutCurrentDerivedVersion_isRefreshedExactlyOnce() async throws {
        let seeded = try seed(currentVersion: false)
        PlacemarkIndex.writeSourceStamp(seeded.sha, to: seeded.resourcesDir)

        _ = await seeded.scanner.materializeMissingResources()
        #expect(try #require(PlacemarkIndex.read(from: seeded.resourcesDir)).isEmpty == false, "refreshed")
        #expect(PlacemarkIndex.derivedDataIsCurrent(in: seeded.resourcesDir))

        // Empty the index again: a second pass must not refresh it.
        try PlacemarkIndex.write([], to: seeded.resourcesDir)
        _ = await seeded.scanner.materializeMissingResources()
        #expect(PlacemarkIndex.read(from: seeded.resourcesDir) == [], "refreshed once only")
    }

    @Test func unparseableEntryWithoutVersion_doesNotLoop() async throws {
        let seeded = try seed(original: Data("not xml".utf8), currentVersion: false)
        PlacemarkIndex.writeSourceStamp(seeded.sha, to: seeded.resourcesDir)
        _ = await seeded.scanner.materializeMissingResources()
        #expect(PlacemarkIndex.parseFailureMarker(in: seeded.resourcesDir) == seeded.sha)
        try AppFixture.data("Rome.kml").write(to: seeded.dir.appendingPathComponent("Rome.kml"))
        _ = await seeded.scanner.materializeMissingResources()
        #expect(!PlacemarkIndex.derivedDataIsCurrent(in: seeded.resourcesDir), "marker prevents a re-read")
    }

    // MARK: - Unparseable originals are not retried

    @Test func unparseableOriginal_isNotRetriedUntilContentChanges() async throws {
        let garbage = Data("this is not xml at all".utf8)
        let seeded = try seed(original: garbage)
        try FileManager.default.removeItem(at: PlacemarkIndex.indexFile(in: seeded.resourcesDir))

        _ = await seeded.scanner.materializeMissingResources()
        #expect(PlacemarkIndex.parseFailureMarker(in: seeded.resourcesDir) == seeded.sha)
        #expect(!PlacemarkIndex.exists(in: seeded.resourcesDir))

        // Make the file parseable but keep the sidecar SHA: the marker means it is not read.
        try AppFixture.data("Rome.kml").write(to: seeded.dir.appendingPathComponent("Rome.kml"))
        _ = await seeded.scanner.materializeMissingResources()
        #expect(!PlacemarkIndex.exists(in: seeded.resourcesDir), "not retried for the same content")

        // New content (new sidecar SHA): retried, parses, marker cleared.
        let meta = EntryMetadata(
            id: UUID(), displayName: "Rome", sourceFilename: "Rome.kml",
            importDate: .now, pointCount: 1, contentSHA256: "new-sha", trashedAt: nil
        )
        try meta.encoded().write(to: seeded.dir.appendingPathComponent("metadata.json"))
        _ = await seeded.scanner.materializeMissingResources()
        #expect(PlacemarkIndex.exists(in: seeded.resourcesDir))
        #expect(PlacemarkIndex.parseFailureMarker(in: seeded.resourcesDir) == nil)
    }

    @Test func unreadableOriginal_isStillRetried() async throws {
        let seeded = try seed()
        try FileManager.default.removeItem(at: PlacemarkIndex.indexFile(in: seeded.resourcesDir))
        try FileManager.default.removeItem(at: seeded.dir.appendingPathComponent("Rome.kml"))

        _ = await seeded.scanner.materializeMissingResources()
        #expect(PlacemarkIndex.parseFailureMarker(in: seeded.resourcesDir) == nil)

        try AppFixture.data("Rome.kml").write(to: seeded.dir.appendingPathComponent("Rome.kml"))
        _ = await seeded.scanner.materializeMissingResources()
        #expect(PlacemarkIndex.exists(in: seeded.resourcesDir))
    }

    // MARK: - Store pruning

    @Test func reload_prunesIndexesOfEntriesThatAreGone() async throws {
        let seeded = try seed()
        let catalog = Catalog(storage: seeded.storage, cache: ResourceCache { _ in Data() })
        let stray = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try PlacemarkIndex.write([], to: stray)
        let store = PlacemarkIndexStore.shared
        _ = store.snapshot(for: stray)
        let before = store.decodeCount

        await catalog.reload()
        _ = store.snapshot(for: stray)

        #expect(store.decodeCount > before, "the stray entry's cached index was dropped and re-decoded")
    }
}
