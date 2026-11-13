import Foundation
@testable import Pinfold
import Testing

/// `writeSnapshot`: ordering and failure behaviour of the file work behind a network-link
/// snapshot. A failure at any step must leave the old original and old sidecar intact.
@Suite(.serialized) @MainActor
struct SnapshotWriteTests {
    private func kml(_ name: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>\(name)</name>
        <Placemark><name>\(name)</name><Point><coordinates>1,2,0</coordinates></Point></Placemark>
        </Document></kml>
        """.utf8)
    }

    private func makeEntry(filename: String) async throws -> (StorageLocations, CatalogEntry) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base.appendingPathComponent("synced", isDirectory: true),
                                       cacheRoot: base.appendingPathComponent("cache", isDirectory: true))
        let cache = ResourceCache { _ in Data() }
        let catalog = Catalog(storage: storage, cache: cache)
        let prepared = try ImportService.prepare(data: kml("Old"), sourceFilename: filename)
        try ImportService.commit(prepared, storage: storage, cache: cache)
        await catalog.reload()
        return try (storage, #require(catalog.entries.first))
    }

    private func prepared(_ name: String, filename: String) throws -> ImportResult {
        try ImportService.prepare(data: kml(name), sourceFilename: filename)
    }

    private func names(in storage: StorageLocations, _ entry: CatalogEntry) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: storage.folder(for: entry).path).sorted()
    }

    @Test func caseOnlyRename_keepsNewContent() async throws {
        let (storage, entry) = try await makeEntry(filename: "Trails.kml")
        let new = try prepared("New", filename: "trails.kml")
        let updated = try writeSnapshot(new, to: entry, storage: storage)
        #expect(try Data(contentsOf: storage.originalFile(for: updated)) == new.originalData)
        #expect(try !names(in: storage, entry).contains { $0.hasSuffix(".tmp") })
        // Exactly one original survives (the new content is never deleted with the "old" file).
        #expect(try names(in: storage, entry).filter { $0.lowercased() == "trails.kml" }.count == 1)
    }

    @Test func sameName_replacesInPlace() async throws {
        let (storage, entry) = try await makeEntry(filename: "same.kml")
        let new = try prepared("New", filename: "same.kml")
        let updated = try writeSnapshot(new, to: entry, storage: storage)
        #expect(try Data(contentsOf: storage.originalFile(for: updated)) == new.originalData)
        #expect(try names(in: storage, entry) == ["metadata.json", "same.kml"])
    }

    @Test func differentName_replacesAndRemovesOld() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        let new = try prepared("New", filename: "new.kml")
        let updated = try writeSnapshot(new, to: entry, storage: storage)
        #expect(try Data(contentsOf: storage.originalFile(for: updated)) == new.originalData)
        #expect(!FileManager.default.fileExists(atPath: storage.originalFile(for: entry).path))
    }

    @Test func missingSidecar_changesNothing() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        let before = try Data(contentsOf: storage.originalFile(for: entry))
        try FileManager.default.removeItem(at: storage.metadataFile(for: entry))
        let new = try prepared("New", filename: "new.kml")
        #expect(throws: (any Error).self) {
            try writeSnapshot(new, to: entry, storage: storage)
        }
        #expect(try Data(contentsOf: storage.originalFile(for: entry)) == before)
        #expect(try names(in: storage, entry) == ["old.kml"])
    }

    @Test func updateExistingMetadata_throwsWhenAbsent() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        try FileManager.default.removeItem(at: storage.metadataFile(for: entry))
        #expect(throws: (any Error).self) {
            try storage.updateExistingMetadata(forFolderNamed: entry.storageFolderName) { $0.pointCount = 9 }
        }
    }

    @Test func moveFailure_rollsBackSidecarAndKeepsOldOriginal() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        let before = try Data(contentsOf: storage.originalFile(for: entry))
        let sidecarBefore = try storage.readMetadata(forFolderNamed: entry.storageFolderName)
        // A non-empty directory squatting on the new name makes the final move fail.
        let blocker = storage.folder(for: entry).appendingPathComponent("new.kml", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("f"))
        let new = try prepared("New", filename: "new.kml")

        #expect(throws: (any Error).self) {
            try writeSnapshot(new, to: entry, storage: storage)
        }
        #expect(try Data(contentsOf: storage.originalFile(for: entry)) == before)
        #expect(try storage.readMetadata(forFolderNamed: entry.storageFolderName) == sidecarBefore)
        #expect(try !names(in: storage, entry).contains { $0.hasSuffix(".tmp") })
    }

    // MARK: - Resource reset

    @Test func all_isUnchangedBehaviour() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        let resourcesDir = storage.resourcesDirectory(for: entry)
        ResourceManifestStore.shared.updateState(in: resourcesDir) { $0.consent = true }
        SubscriptionStateStore.write(SubscriptionState(etag: "\"v1\""), in: resourcesDir)

        _ = try writeSnapshot(prepared("New", filename: "old.kml"), to: entry, storage: storage)

        // The default drops all of resources/; it rebuilds on the next reload.
        #expect(!FileManager.default.fileExists(atPath: resourcesDir.path))
    }

    @Test func derivedOnly_prunesDerivedButKeepsChoices() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        let resourcesDir = storage.resourcesDirectory(for: entry)
        ResourceManifestStore.shared.updateState(in: resourcesDir) { $0.consent = true }
        let state = SubscriptionState(etag: "\"v1\"")
        SubscriptionStateStore.write(state, in: resourcesDir)
        #expect(PlacemarkIndex.exists(in: resourcesDir))

        _ = try writeSnapshot(prepared("New", filename: "old.kml"), to: entry, storage: storage,
                              resetResources: .derivedOnly)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: resourcesDir.path).sorted()
        #expect(remaining == ["download-state.json", SubscriptionStateStore.filename].sorted())
        #expect(ResourceManifestStore.shared.state(in: resourcesDir).consent)
        #expect(SubscriptionStateStore.read(in: resourcesDir) == state)
    }
}
