import Foundation
@testable import Pinfold
import Testing

/// Tests for `PlacemarkIndexStore` — the in-memory cache of decoded indexes keyed by folder and
/// file modification date (B17).
struct PlacemarkIndexStoreTests {
    private func makeResourcesDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func setModificationDate(_ date: Date, of dir: URL) throws {
        let file = dir.appendingPathComponent(PlacemarkIndex.filename)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    @Test func store_reusesDecodedIndexUntilFileChanges() throws {
        let dir = try makeResourcesDir()
        let store = PlacemarkIndexStore()
        try PlacemarkIndex.write([PlacemarkIndex.Entry(key: "k1", name: "One", lat: nil, lon: nil)], to: dir)
        try setModificationDate(Date(timeIntervalSince1970: 1_000_000), of: dir)

        #expect(store.snapshot(for: dir)?.entries.count == 1)
        #expect(store.snapshot(for: dir)?.entries.count == 1)
        #expect(store.decodeCount == 1)

        try PlacemarkIndex.write([
            PlacemarkIndex.Entry(key: "k1", name: "One", lat: nil, lon: nil),
            PlacemarkIndex.Entry(key: "k2", name: "Two", lat: nil, lon: nil),
        ], to: dir)
        try setModificationDate(Date(timeIntervalSince1970: 2_000_000), of: dir)

        #expect(store.snapshot(for: dir)?.entries.count == 2)
        #expect(store.decodeCount == 2)
    }

    @Test func store_dropsEntriesForRemovedFolders() throws {
        let dirA = try makeResourcesDir()
        let dirB = try makeResourcesDir()
        let store = PlacemarkIndexStore()
        for dir in [dirA, dirB] {
            try PlacemarkIndex.write([PlacemarkIndex.Entry(key: "k", name: "N", lat: nil, lon: nil)], to: dir)
            _ = store.snapshot(for: dir)
        }
        #expect(store.cachedIndexCount == 2)

        try FileManager.default.removeItem(at: dirA)
        #expect(store.snapshot(for: dirA) == nil)
        #expect(store.cachedIndexCount == 1)

        store.prune(keeping: [])
        #expect(store.cachedIndexCount == 0)
    }

    @Test func store_missingIndexIsNil() throws {
        #expect(PlacemarkIndexStore().snapshot(for: try makeResourcesDir()) == nil)
    }

    @Test func store_fallsBackToV1() throws {
        let dir = try makeResourcesDir()
        try Data(#"[{"key":"k1","name":"Old"}]"#.utf8)
            .write(to: dir.appendingPathComponent("placemarks-index.json"))
        let snapshot = PlacemarkIndexStore().snapshot(for: dir)
        #expect(snapshot?.entries.first?.name == "Old")
    }
}
