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

    @Test func deleteForever_skipsAnEntryRestoredOnDiskSinceItWasListed() async throws {
        // The list still shows the entry in Trash, but its sidecar was restored meanwhile
        // (another device, or a restore that finished during the index read): keep the file.
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "back", trashedAt: Date(timeIntervalSince1970: 9))
        await catalog.reload()
        let stale = try #require(catalog.trashed.first)
        try storage.updateMetadata(forFolderNamed: "back") { $0.trashedAt = nil }

        await catalog.deleteForever(stale)

        #expect(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("back").path))
        #expect(catalog.active.map(\.storageFolderName) == ["back"])
    }

    @Test func deleteForever_twiceIsQuietNoOp() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "gone", trashedAt: Date(timeIntervalSince1970: 9))
        await catalog.reload()
        let entry = try #require(catalog.trashed.first)

        await catalog.deleteForever(entry)
        await catalog.deleteForever(entry)

        #expect(catalog.actionError == nil)
        #expect(catalog.entries.isEmpty)
    }

    @Test func deleteForever_neverDeletesAnActiveEntry() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "keep")
        await catalog.reload()
        let entry = try #require(catalog.active.first)

        await catalog.deleteForever(entry)

        #expect(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("keep").path))
    }

    @Test func entryWithSHA256_findsByContentHash() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "f", sha: "needle")
        await catalog.reload()

        #expect(catalog.entry(withSHA256: "needle")?.storageFolderName == "f")
        #expect(catalog.entry(withSHA256: "missing") == nil)
    }

    @Test func reload_concurrentCallsSettleToFinalState() async throws {
        let (catalog, storage) = makeCatalog()
        // Seed several folders so a scan has real work to do.
        for index in 0 ..< 5 {
            try seedFolder(storage, folder: "f\(index)")
        }

        // Fire many reloads concurrently. The generation guard must ensure no crash and that a
        // stale scan never clobbers a newer one. A final awaited reload settles the state.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await catalog.reload() }
            }
        }
        await catalog.reload()

        let onDisk = try FileManager.default.contentsOfDirectory(atPath: storage.root.path)
            .filter { !$0.hasPrefix(".") }
        #expect(
            catalog.entries.count == onDisk.count,
            "After concurrent reloads settle, entries must match the on-disk folder count"
        )
        #expect(catalog.entries.count == 5)
    }

    @Test func legacyTags_surviveTrashAndRestore() async throws {
        // Tagging is gone from the UI, but tags written by older versions must stay in the
        // sidecar untouched so a device still on that version doesn't lose them on sync.
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "f")
        try storage.updateMetadata(forFolderNamed: "f") { $0.tags = ["art", "food"] }
        await catalog.reload()
        let entry = try #require(catalog.active.first)

        await catalog.moveToTrash(entry)
        let trashedMeta = try #require(try storage.readMetadata(forFolderNamed: "f"))
        #expect(trashedMeta.trashedAt != nil)
        #expect(trashedMeta.tags == ["art", "food"])

        let trashed = try #require(catalog.trashed.first)
        _ = await catalog.restore(trashed)
        let meta = try #require(try storage.readMetadata(forFolderNamed: "f"))
        #expect(meta.trashedAt == nil)
        #expect(meta.tags == ["art", "food"])
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

    @Test func deleteForeverSelection_removesTrashedAndKeepsActive() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "keep")
        try seedFolder(storage, folder: "t1", sha: "a", trashedAt: Date(timeIntervalSince1970: 5))
        try seedFolder(storage, folder: "t2", sha: "b", trashedAt: Date(timeIntervalSince1970: 6))
        await catalog.reload()
        #expect(catalog.trashed.count == 2)

        // The active entry rides along in the selection but must never be deleted.
        await catalog.deleteForever(catalog.entries)

        #expect(catalog.trashed.isEmpty)
        #expect(catalog.entries.map(\.storageFolderName) == ["keep"])
        for gone in ["t1", "t2"] {
            #expect(!FileManager.default.fileExists(atPath: storage.root.appendingPathComponent(gone).path))
        }
        #expect(FileManager.default.fileExists(atPath: storage.root.appendingPathComponent("keep").path))
    }

    @Test func deleteForeverSelection_withNothingTrashedIsANoOp() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "keep")
        await catalog.reload()

        await catalog.deleteForever(catalog.active)

        #expect(catalog.entries.map(\.storageFolderName) == ["keep"])
    }

    // MARK: - Read-only entries and action errors (B12)

    private func seedUnreadable(_ storage: StorageLocations, folder: String) throws -> Data {
        let dir = storage.root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AppFixture.data("Rome.kml").write(to: dir.appendingPathComponent("Rome.kml"))
        let garbage = Data("not json".utf8)
        try garbage.write(to: dir.appendingPathComponent("metadata.json"))
        return garbage
    }

    @Test func moveToTrashOnReadOnlyEntry_setsActionError() async throws {
        let (catalog, storage) = makeCatalog()
        _ = try seedUnreadable(storage, folder: "bad")
        await catalog.reload()
        let entry = try #require(catalog.active.first)

        await catalog.moveToTrash(entry)

        #expect(catalog.actionError != nil)
        #expect(catalog.active.count == 1)
    }

    @Test func mutationOnHealthyEntry_leavesActionErrorNil() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "ok")
        await catalog.reload()
        let entry = try #require(catalog.active.first)

        await catalog.moveToTrash(entry)

        #expect(catalog.actionError == nil)
        #expect(catalog.trashed.map(\.storageFolderName) == ["ok"])
    }

    @Test func deleteForeverFailure_setsActionError() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "stuck", trashedAt: Date(timeIntervalSince1970: 3))
        await catalog.reload()
        let entry = try #require(catalog.trashed.first)
        // A read-only root: the folder itself cannot be unlinked.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storage.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.root.path) }

        await catalog.deleteForever(entry)

        // The folder's contents may be removed before the unlink of the folder itself fails,
        // so only the reported error is asserted.
        #expect(catalog.actionError != nil)
    }

    // MARK: - Bulk actions (C8)

    @Test func bulkTrash_trashesAllSelectedWithOneReload() async throws {
        let (catalog, storage) = makeCatalog()
        for name in ["a", "b", "c"] {
            try seedFolder(storage, folder: name)
        }
        await catalog.reload()
        let picked = catalog.active.filter { $0.storageFolderName != "c" }

        await catalog.moveToTrash(picked)

        #expect(catalog.active.map(\.storageFolderName) == ["c"])
        #expect(Set(catalog.trashed.map(\.storageFolderName)) == ["a", "b"])
        #expect(try storage.readMetadata(forFolderNamed: "a")?.trashedAt != nil)
        #expect(catalog.actionError == nil)
    }

    @Test func bulkActionsSkipReadOnlyEntries() async throws {
        let (catalog, storage) = makeCatalog()
        try seedFolder(storage, folder: "ok")
        let garbage = try seedUnreadable(storage, folder: "bad")
        await catalog.reload()
        let all = catalog.active

        await catalog.moveToTrash(all)

        #expect(catalog.actionError != nil)
        #expect(catalog.trashed.map(\.storageFolderName) == ["ok"])
        #expect(catalog.active.map(\.storageFolderName) == ["bad"])
        #expect(try Data(contentsOf: storage.metadataFile(forFolderNamed: "bad")) == garbage)
    }
}
