import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

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
        #expect(store.favoriteKeys.contains("id:a"))

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

    @Test func corruptSidecarIsNotOverwritten() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base)
        let folder = "entry-1"
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
        )
        let corruptBytes = Data("not json".utf8)
        let metaURL = base.appendingPathComponent(folder).appendingPathComponent("metadata.json")
        try corruptBytes.write(to: metaURL)

        let entry = CatalogEntry(
            id: UUID(), displayName: "T", sourceFilename: "t.kml",
            importDate: Date(timeIntervalSince1970: 0), pointCount: 1,
            contentSHA256: "x", storageFolderName: folder, trashedAt: nil
        )
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        store.toggleFavorite(point("z"))

        let bytesAfter = try Data(contentsOf: metaURL)
        #expect(bytesAfter == corruptBytes)
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

    @Test func toggleAppliesDeltaOntoCurrentOnDiskSets() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        // Another device's sync lands while the file is open.
        try storage.updateMetadata(forFolderNamed: entry.storageFolderName) {
            $0.favoriteKeys = ["id:remote"]
            $0.visitedKeys = ["id:remoteV"]
        }
        store.toggleFavorite(point("local"))
        let reloaded = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(reloaded.favoriteKeys == ["id:remote", "id:local"])
        #expect(reloaded.visitedKeys == ["id:remoteV"])
        store.toggleFavorite(point("local"))
        let after = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(after.favoriteKeys == ["id:remote"])
    }

    @Test func readOnlyEntryNeverPersists() throws {
        let (entry, storage) = try makeEntryAndStorage()
        var readOnly = entry
        readOnly.sidecarState = .notDownloaded
        let store = PlacemarkAnnotations(entry: readOnly, storage: storage)
        store.toggleFavorite(point("x"))
        let reloaded = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(reloaded.favoriteKeys.isEmpty)
    }

    // MARK: - Notes

    @Test func setNote_persistsThroughUpdateMetadata() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        let p = point("n1")
        store.setNote("  Bring water  ", for: p)
        #expect(store.note(for: p)?.text == "Bring water")
        #expect(store.noteTextsByKey["id:n1"] == "Bring water")

        let reloaded = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(reloaded.notes["id:n1"]?.text == "Bring water")
        #expect(reloaded.notes["id:n1"]?.placemarkName == "N")
        let reopened = PlacemarkAnnotations(entry: entry, storage: storage)
        #expect(reopened.note(for: p)?.text == "Bring water")
    }

    @Test func notesRevisionBumpsOnlyWhenNotesChange() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        let before = store.notesRevision
        store.toggleFavorite(point("r"))
        #expect(store.notesRevision == before)
        store.setNote("x", for: point("r"))
        #expect(store.notesRevision != before)
    }

    @Test func clearingANoteWritesATombstone() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        let p = point("n2")
        store.setNote("x", for: p)
        store.setNote("   ", for: p)
        #expect(store.note(for: p) == nil)
        #expect(store.noteTextsByKey.isEmpty)
        let reloaded = try #require(try storage.readMetadata(forFolderNamed: entry.storageFolderName))
        #expect(reloaded.notes["id:n2"]?.text == "")
    }

    @Test func orphanedNotes_listsNotesWhoseKeyIsGone() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        store.setNote("keep", for: point("live"))
        store.setNote("lost", for: point("dead"))
        store.setNote("", for: point("tomb"))
        let orphans = store.orphanedNotes(validKeys: ["id:live"])
        #expect(orphans.map(\.key) == ["id:dead"])
        #expect(orphans.first?.note.text == "lost")
    }

    @Test func unreadableSidecar_neverPersistsNotes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base)
        let folder = "entry-1"
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
        )
        let corruptBytes = Data("not json".utf8)
        let metaURL = base.appendingPathComponent(folder).appendingPathComponent("metadata.json")
        try corruptBytes.write(to: metaURL)
        let entry = CatalogEntry(
            id: UUID(), displayName: "T", sourceFilename: "t.kml",
            importDate: Date(timeIntervalSince1970: 0), pointCount: 1,
            contentSHA256: "x", storageFolderName: folder, trashedAt: nil
        )
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        store.setNote("hi", for: point("q"))
        #expect(try Data(contentsOf: metaURL) == corruptBytes)
    }

    @Test func setNote_reportsSuccess() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        #expect(store.canEdit)
        #expect(store.setNote("ok", for: point("s")))
    }

    @Test func setNote_failsOnReadOnlyEntryAndKeepsMemoryClean() throws {
        let (entry, storage) = try makeEntryAndStorage()
        var readOnly = entry
        readOnly.sidecarState = .notDownloaded
        let store = PlacemarkAnnotations(entry: readOnly, storage: storage)
        #expect(!store.canEdit)
        #expect(!store.setNote("lost", for: point("ro")))
        #expect(store.note(for: point("ro")) == nil)
    }

    @Test func setNote_failsWhenSidecarCannotBeWritten() throws {
        let (entry, storage) = try makeEntryAndStorage()
        let store = PlacemarkAnnotations(entry: entry, storage: storage)
        // Removing the folder makes the write fail.
        try FileManager.default.removeItem(at: storage.root.appendingPathComponent(entry.storageFolderName))
        #expect(!store.setNote("lost", for: point("w")))
        #expect(store.note(for: point("w")) == nil)
    }
}
