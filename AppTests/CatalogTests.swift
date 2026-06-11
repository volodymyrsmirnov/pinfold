import Foundation
@testable import Pinfold
import Testing

/// Tests for `Catalog` — the in-memory catalogue sourced from the folders on disk, with
/// mutations (trash / restore / delete) writing through to the folder and reloading.
@Suite(.serialized) @MainActor struct CatalogTests {
    private func makeCatalog() -> (Catalog, StorageLocations) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        let catalog = Catalog(storage: storage, cache: ResourceCache { _ in Data() })
        return (catalog, storage)
    }

    @discardableResult
    private func seedFolder(
        _ storage: StorageLocations,
        folder: String,
        sha: String = "sha",
        importDate: Date = Date(timeIntervalSince1970: 1),
        trashedAt: Date? = nil
    ) throws -> EntryMetadata {
        let dir = storage.root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = EntryMetadata(
            id: UUID(), displayName: folder, sourceFilename: "\(folder).kml",
            importDate: importDate, pointCount: 1, contentSHA256: sha, trashedAt: trashedAt
        )
        try meta.encoded().write(to: dir.appendingPathComponent("metadata.json"))
        // The scanner now requires an original alongside a readable sidecar (a sidecar-only
        // folder is treated as mid-download / mid-commit and skipped), so write one. The
        // bytes are irrelevant for the `.ok` path — the entry comes from the sidecar.
        try Data("<kml/>".utf8).write(to: dir.appendingPathComponent("\(folder).kml"))
        return meta
    }

    @Test func reload_splitsActiveAndTrashed() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "live")
        try seedFolder(storage, folder: "dead", trashedAt: Date(timeIntervalSince1970: 9))

        await catalog.reload()

        #expect(catalog.active.map(\.storageFolderName) == ["live"])
        #expect(catalog.trashed.map(\.storageFolderName) == ["dead"])
    }

    @Test func moveToTrash_movesEntryAndPersistsToSidecar() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "f")
        await catalog.reload()
        let entry = try #require(catalog.active.first)

        await catalog.moveToTrash(entry)

        #expect(catalog.active.isEmpty)
        #expect(catalog.trashed.count == 1)
        // Persisted: a fresh scan from disk still sees it trashed.
        #expect(try storage.readMetadata(forFolderNamed: "f")?.trashedAt != nil)
    }

    @Test func restore_clearsTrashState() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "f", trashedAt: Date(timeIntervalSince1970: 9))
        await catalog.reload()
        let entry = try #require(catalog.trashed.first)

        await catalog.restore(entry)

        #expect(catalog.trashed.isEmpty)
        #expect(catalog.active.count == 1)
        #expect(try storage.readMetadata(forFolderNamed: "f")?.trashedAt == nil)
    }

    @Test func deleteForever_removesFolderAndEntry() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "gone", trashedAt: Date(timeIntervalSince1970: 9))
        await catalog.reload()
        let entry = try #require(catalog.trashed.first)

        await catalog.deleteForever(entry)

        #expect(catalog.entries.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: storage.root.appendingPathComponent("gone").path
        ))
    }

    @Test func entryWithSHA256_findsByContentHash() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "f", sha: "needle")
        await catalog.reload()

        #expect(catalog.entry(withSHA256: "needle")?.storageFolderName == "f")
        #expect(catalog.entry(withSHA256: "missing") == nil)
    }

    @Test func setStorage_repointsRootAndReloads() async throws {
        let (catalog, oldStorage) = makeCatalog()
        try seedFolder(oldStorage, folder: "old")
        await catalog.reload()
        #expect(catalog.entries.map(\.storageFolderName) == ["old"])

        // A different root with its own content — setStorage repoints and reloads from it
        // (it does not migrate; migration is the caller's job, see StorageMigrationTests).
        let newRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let newStorage = StorageLocations(root: newRoot, cacheRoot: oldStorage.cacheRoot)
        try seedFolder(newStorage, folder: "new")

        await catalog.setStorage(newStorage)

        #expect(catalog.entries.map(\.storageFolderName) == ["new"])
        #expect(catalog.storage.root == newRoot)
    }
}
