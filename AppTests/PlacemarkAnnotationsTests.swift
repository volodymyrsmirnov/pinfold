import Testing
import Foundation
import PinfoldCore
@testable import Pinfold

@Suite(.serialized) @MainActor struct PlacemarkAnnotationsTests {

    private func makeEntryAndStorage() throws -> (CatalogEntry, StorageLocations) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base)
        let folder = "entry-1"
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
        )
        let meta = EntryMetadata(
            id: UUID(), displayName: "T", sourceFilename: "t.kml",
            importDate: Date(timeIntervalSince1970: 0), pointCount: 1,
            contentSHA256: "x", trashedAt: nil
        )
        try storage.writeMetadata(meta, forFolderNamed: folder)
        return (CatalogEntry(metadata: meta, storageFolderName: folder), storage)
    }

    private func point(_ source: String) -> KMLPlacemark {
        KMLPlacemark(id: "p1", name: "N", descriptionHTML: nil, styleUrl: nil,
                     coordinate: nil, extendedData: [], photoLinks: [], sourceID: source)
    }

    @Test func toggleFavoriteUpdatesStateAndPersists() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        let p = point("a")

        #expect(store.isFavorite(p) == false)
        store.toggleFavorite(p)
        #expect(store.isFavorite(p) == true)

        let reopened = PlacemarkAnnotations(entry: entry, storage: storage)
        #expect(reopened.isFavorite(p) == true)
    }

    @Test func toggleVisitedIsIndependentOfFavorite() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        let p = point("b")
        store.toggleFavorite(p)
        store.toggleVisited(p)
        #expect(store.isFavorite(p) == true)
        #expect(store.isVisited(p) == true)
        store.toggleFavorite(p)
        #expect(store.isFavorite(p) == false)
        #expect(store.isVisited(p) == true)
    }

    @Test func writeThroughPreservesTrashedAt() throws {
        let (entry, storage) = try makeEntryAndStorage()
        try storage.updateMetadata(forFolderNamed: entry.storageFolderName) {
            $0.trashedAt = Date(timeIntervalSince1970: 42)
        }
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        store.toggleVisited(point("c"))
        let reloaded = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(reloaded.trashedAt == Date(timeIntervalSince1970: 42))
        #expect(reloaded.visitedKeys.contains("id:c"))
    }
}
