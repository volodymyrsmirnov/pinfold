import Foundation
@testable import Pinfold
import Testing

/// D1/D2: sidecar updates are single coordinated read-modify-writes, and a snapshot touches only
/// the fields it owns and never leaves a sidecar naming a missing file.
@Suite(.serialized) @MainActor
struct SidecarUpdateTests {
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
        try ImportService.commit(ImportService.prepare(data: kml("Old"), sourceFilename: filename),
                                 storage: storage, cache: cache)
        await catalog.reload()
        return try (storage, #require(catalog.entries.first))
    }

    @Test func concurrentUpdatesOfDifferentFields_areBothKept() async throws {
        let (storage, entry) = try await makeEntry(filename: "a.kml")
        let name = entry.storageFolderName
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 40 {
                group.addTask {
                    try? storage.updateMetadata(forFolderNamed: name) { $0.favoriteKeys.insert("k\(index)") }
                }
                group.addTask {
                    try? storage.updateMetadata(forFolderNamed: name) { $0.visitedKeys.insert("v\(index)") }
                }
            }
        }
        let meta = try #require(try storage.readMetadata(forFolderNamed: name))
        #expect(meta.favoriteKeys.count == 40)
        #expect(meta.visitedKeys.count == 40)
    }

    @Test func snapshot_keepsConcurrentTagEdit_onFailureRollback() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        // Block the final move so the snapshot fails after updating the sidecar (same-slot path
        // would not fail, so use a differing name with a directory squatting on it).
        let blocker = storage.folder(for: entry).appendingPathComponent("new.kml", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try storage.updateMetadata(forFolderNamed: entry.storageFolderName) { $0.tags = ["mine"] }
        let live = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        let new = try ImportService.prepare(data: kml("New"), sourceFilename: "new.kml")
        #expect(throws: (any Error).self) { try writeSnapshot(new, to: entry, storage: storage) }
        let after = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(after == live)
    }

    @Test func snapshot_changesOnlyOwnedFields() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        try storage.updateMetadata(forFolderNamed: entry.storageFolderName) {
            $0.tags = ["t"]
            $0.favoriteKeys = ["f"]
        }
        let new = try ImportService.prepare(data: kml("New"), sourceFilename: "new.kml")
        _ = try writeSnapshot(new, to: entry, storage: storage)
        let meta = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(meta.tags == ["t"])
        #expect(meta.favoriteKeys == ["f"])
        #expect(meta.sourceFilename == "new.kml")
        #expect(meta.contentSHA256 == new.contentSHA256)
    }

    @Test func differentName_neverLeavesSidecarNamingMissingFile() async throws {
        let (storage, entry) = try await makeEntry(filename: "old.kml")
        let new = try ImportService.prepare(data: kml("New"), sourceFilename: "new.kml")
        _ = try writeSnapshot(new, to: entry, storage: storage)
        let meta = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        let named = storage.folder(for: entry).appendingPathComponent(meta.sourceFilename)
        #expect(FileManager.default.fileExists(atPath: named.path))
    }
}
