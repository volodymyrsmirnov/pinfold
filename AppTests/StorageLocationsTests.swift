import Foundation
@testable import Pinfold
import Testing

/// Tests for `StorageLocations` — pure on-disk path construction and
/// folder create/remove operations under a temporary root.
struct StorageLocationsTests {
    // MARK: - Helpers

    /// Returns a fresh temp root that does NOT yet exist on disk, so each test
    /// starts with a clean directory.
    private func makeTempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeEntry(
        storageFolderName: String = UUID().uuidString,
        sourceFilename: String = "test.kml"
    ) -> CatalogEntry {
        CatalogEntry(
            id: UUID(),
            displayName: "Test",
            sourceFilename: sourceFilename,
            importDate: .now,
            pointCount: 0,
            contentSHA256: "abc",
            storageFolderName: storageFolderName,
            trashedAt: nil
        )
    }

    // MARK: - Path construction

    @Test func folderURL_isRootPlusStorageFolderName() {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let entry = makeEntry(storageFolderName: "my-folder")

        let folder = locations.folder(for: entry)

        #expect(folder == root.appendingPathComponent("my-folder", isDirectory: true))
    }

    @Test func originalFileURL_isInsideFolder() {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let entry = makeEntry(storageFolderName: "my-folder", sourceFilename: "data.kml")

        let file = locations.originalFile(for: entry)

        #expect(file == root.appendingPathComponent("my-folder/data.kml"))
    }

    @Test func originalFileURL_ignoresReservedSidecarName() throws {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let folder = root.appendingPathComponent("my-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("metadata.json"))
        try Data("<kml/>".utf8).write(to: folder.appendingPathComponent("a.kml"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        #expect(locations.originalFileURL(inFolderNamed: "my-folder")?.lastPathComponent == "a.kml")

        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.kml"))
        #expect(locations.originalFileURL(inFolderNamed: "my-folder") == nil)
    }

    @Test func originalFileURL_findsGPXAndGeoJSON_neverTheSidecar() throws {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let folder = root.appendingPathComponent("fmt", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("metadata.json"))
        #expect(locations.originalFileURL(inFolderNamed: "fmt") == nil)

        try Data("<gpx/>".utf8).write(to: folder.appendingPathComponent("a.GPX"))
        #expect(locations.originalFileURL(inFolderNamed: "fmt")?.lastPathComponent == "a.GPX")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("a.GPX"))

        try Data("{}".utf8).write(to: folder.appendingPathComponent("b.geojson"))
        #expect(locations.originalFileURL(inFolderNamed: "fmt")?.lastPathComponent == "b.geojson")
    }

    @Test func resourcesDirectoryURL_isInsideFolder() {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let entry = makeEntry(storageFolderName: "my-folder")

        let resources = locations.resourcesDirectory(for: entry)

        #expect(resources == root.appendingPathComponent("my-folder/resources", isDirectory: true))
    }

    // MARK: - createFolders

    @Test func createFolders_createsFolderAndResourcesSubdir() throws {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let entry = makeEntry(storageFolderName: "entry-abc")

        try locations.createFolders(for: entry)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let folderExists = fm.fileExists(
            atPath: locations.folder(for: entry).path,
            isDirectory: &isDir
        )
        #expect(folderExists && isDir.boolValue, "entry folder should exist as a directory")

        var isDirRes: ObjCBool = false
        let resourcesExists = fm.fileExists(
            atPath: locations.resourcesDirectory(for: entry).path,
            isDirectory: &isDirRes
        )
        #expect(resourcesExists && isDirRes.boolValue, "resources/ subdir should exist as a directory")
    }

    @Test func createFolders_isIdempotent() throws {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let entry = makeEntry(storageFolderName: "entry-idem")

        try locations.createFolders(for: entry)
        // Second call must not throw
        try locations.createFolders(for: entry)

        let folderExists = FileManager.default.fileExists(atPath: locations.folder(for: entry).path)
        #expect(folderExists)
    }

    // MARK: - removeFolder

    @Test func removeFolder_deletesEntryFolder() throws {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let entry = makeEntry(storageFolderName: "entry-del")

        try locations.createFolders(for: entry)
        #expect(FileManager.default.fileExists(atPath: locations.folder(for: entry).path),
                "folder should exist before removal")

        try locations.removeFolder(for: entry)

        #expect(!FileManager.default.fileExists(atPath: locations.folder(for: entry).path),
                "folder should be gone after removal")
    }

    @Test func removeFolder_noThrow_whenFolderAbsent() throws {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let entry = makeEntry(storageFolderName: "nonexistent-folder")

        // Should not throw even though the folder was never created
        try locations.removeFolder(for: entry)
    }

    // MARK: - Two-root + sidecar (iCloud sync)

    @Test func resourcesDirectory_usesCacheRoot_whenProvided() {
        let synced = makeTempRoot()
        let cache = makeTempRoot()
        let locations = StorageLocations(root: synced, cacheRoot: cache)
        let entry = makeEntry(storageFolderName: "abc")

        let resources = locations.resourcesDirectory(for: entry)

        #expect(resources == cache.appendingPathComponent("abc/resources", isDirectory: true))
    }

    @Test func metadataFile_isInsideSyncedFolder() {
        let synced = makeTempRoot()
        let locations = StorageLocations(root: synced, cacheRoot: makeTempRoot())
        let entry = makeEntry(storageFolderName: "abc")

        #expect(locations.metadataFile(for: entry)
            == synced.appendingPathComponent("abc/metadata.json"))
    }

    @Test func writeThenReadMetadata_roundTrips() throws {
        let locations = StorageLocations(root: makeTempRoot(), cacheRoot: makeTempRoot())
        let entry = makeEntry(storageFolderName: "round-trip")
        try locations.createFolders(for: entry)

        let meta = entry.metadata
        try locations.writeMetadata(meta, for: entry)

        let read = try locations.readMetadata(forFolderNamed: "round-trip")
        #expect(read == meta)
    }

    @Test func readMetadata_returnsNil_whenAbsent() throws {
        let locations = StorageLocations(root: makeTempRoot(), cacheRoot: makeTempRoot())
        #expect(try locations.readMetadata(forFolderNamed: "missing") == nil)
    }

    @Test func entryFolderNames_listsOnlyDirectories() throws {
        let synced = makeTempRoot()
        let locations = StorageLocations(root: synced, cacheRoot: makeTempRoot())
        let fm = FileManager.default
        try fm.createDirectory(at: synced.appendingPathComponent("folder-a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: synced.appendingPathComponent("folder-b"), withIntermediateDirectories: true)
        try Data().write(to: synced.appendingPathComponent("loose-file.txt"))

        let names = try locations.entryFolderNames().sorted()
        #expect(names == ["folder-a", "folder-b"])
    }

    @Test func createFolders_createsBothSyncedAndCacheFolders() throws {
        let synced = makeTempRoot()
        let cache = makeTempRoot()
        let locations = StorageLocations(root: synced, cacheRoot: cache)
        let entry = makeEntry(storageFolderName: "both")

        try locations.createFolders(for: entry)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: synced.appendingPathComponent("both").path))
        #expect(fm.fileExists(atPath: cache.appendingPathComponent("both/resources").path))
    }

    @Test func updateMetadataPreservesUntouchedFields() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base)
        let folder = "entry-1"
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
        )
        let meta = EntryMetadata(
            id: UUID(), displayName: "T", sourceFilename: "t.kml",
            importDate: Date(timeIntervalSince1970: 0), pointCount: 1,
            contentSHA256: "x", trashedAt: nil,
            favoriteKeys: ["id:keep"], visitedKeys: ["id:seen"]
        )
        try storage.writeMetadata(meta, forFolderNamed: folder)

        let stamp = Date(timeIntervalSince1970: 555)
        try storage.updateMetadata(forFolderNamed: folder) { $0.trashedAt = stamp }

        let reloaded = try #require(try storage.readMetadata(forFolderNamed: folder))
        #expect(reloaded.trashedAt == stamp)
        #expect(reloaded.favoriteKeys == ["id:keep"])
        #expect(reloaded.visitedKeys == ["id:seen"])
        #expect(reloaded.pointCount == 1)
        #expect(reloaded.contentSHA256 == "x")
    }

    @Test func coordinatedIO_metadataRoundTripUnchanged() throws {
        // NSFileCoordinator-routed write/read must be transparent for plain (non-ubiquitous)
        // files on a local temp root: the round-tripped metadata is byte-for-byte equal.
        let locations = StorageLocations(root: makeTempRoot(), cacheRoot: makeTempRoot())
        let entry = makeEntry(storageFolderName: "coordinated")
        try locations.createFolders(for: entry)

        let meta = EntryMetadata(
            id: UUID(), displayName: "Coord", sourceFilename: "c.kml",
            importDate: Date(timeIntervalSince1970: 42), pointCount: 7,
            contentSHA256: "sha", trashedAt: nil,
            favoriteKeys: ["id:a", "id:b"], visitedKeys: ["id:c"]
        )
        try locations.writeMetadata(meta, for: entry)

        let viaForName = try #require(try locations.readMetadata(forFolderNamed: "coordinated"))
        #expect(viaForName == meta)

        guard case let .ok(viaSidecar) = locations.readSidecar(forFolderNamed: "coordinated") else {
            Issue.record("expected .ok from readSidecar")
            return
        }
        #expect(viaSidecar == meta)
    }

    @Test func updateMetadata_isNoOp_whenSidecarAbsent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(root: base)
        let folder = "ghost"
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true
        )
        // Must not throw, and must not create a sidecar.
        try storage.updateMetadata(forFolderNamed: folder) { $0.trashedAt = .now }
        #expect(try storage.readMetadata(forFolderNamed: folder) == nil)
    }

    // MARK: - Coordinated writes and deletes (B14)

    @Test func writeOriginal_roundTrips() throws {
        let root = makeTempRoot()
        let locations = StorageLocations(root: root)
        let entry = makeEntry(storageFolderName: "w", sourceFilename: "a.kml")
        try locations.createFolders(for: entry)

        try locations.writeOriginal(Data("one".utf8), for: entry)
        try locations.writeOriginal(Data("two".utf8), for: entry)

        #expect(try Data(contentsOf: locations.originalFile(for: entry)) == Data("two".utf8))
    }

    @Test func removeFolder_removesSyncedFolderAndCache() throws {
        let base = makeTempRoot()
        let locations = StorageLocations(
            root: base.appendingPathComponent("synced"), cacheRoot: base.appendingPathComponent("cache")
        )
        let entry = makeEntry(storageFolderName: "both")
        try locations.createFolders(for: entry)
        try locations.writeOriginal(Data("x".utf8), for: entry)

        try locations.removeFolder(for: entry)

        #expect(!FileManager.default.fileExists(atPath: locations.folder(for: entry).path))
        #expect(!FileManager.default.fileExists(atPath: locations.resourcesDirectory(for: entry).path))
        #expect(!FileManager.default.fileExists(
            atPath: locations.cacheRoot.appendingPathComponent("both").path
        ))
    }

    @Test func removeFolder_missingFolderIsANoOp() throws {
        let locations = StorageLocations(root: makeTempRoot())
        try locations.removeFolder(named: "never-existed")
    }

    // MARK: - Sidecar not downloaded (B2)

    private func ubiquitousLocations(probe: FakeUbiquityProbe) -> StorageLocations {
        var locations = StorageLocations(root: makeTempRoot())
        locations.isUbiquitous = true
        locations.probe = probe
        return locations
    }

    @Test func readSidecar_missingInUbiquitousRoot_uuidFolder_isNotDownloaded() {
        let locations = ubiquitousLocations(probe: FakeUbiquityProbe())
        #expect(locations.readSidecar(forFolderNamed: UUID().uuidString) == .notDownloaded)
    }

    @Test func readSidecar_missingInUbiquitousRoot_placeholderOrStatus_isNotDownloaded() {
        let placeholder = ubiquitousLocations(probe: FakeUbiquityProbe(placeholder: true))
        #expect(placeholder.readSidecar(forFolderNamed: "Dropped") == .notDownloaded)
        let stale = ubiquitousLocations(probe: FakeUbiquityProbe(status: .notDownloaded))
        #expect(stale.readSidecar(forFolderNamed: "Dropped") == .notDownloaded)
    }

    @Test func readSidecar_missingInUbiquitousRoot_nonUUIDFolder_isMissing() {
        let locations = ubiquitousLocations(probe: FakeUbiquityProbe())
        #expect(locations.readSidecar(forFolderNamed: "Dropped") == .missing)
    }

    @Test func readSidecar_missingInLocalRoot_isMissingEvenForUUIDFolder() {
        var locations = StorageLocations(root: makeTempRoot())
        locations.probe = FakeUbiquityProbe(placeholder: true)
        #expect(locations.readSidecar(forFolderNamed: UUID().uuidString) == .missing)
    }

    // MARK: - Tolerant sidecar (B12)

    @Test func tolerantSidecar_recoversTrashStateFromUndecodableJSON() throws {
        let locations = StorageLocations(root: makeTempRoot())
        let id = UUID()
        let folder = locations.root.appendingPathComponent("t", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
        {"id":"\(id.uuidString)","displayName":"Kept","trashedAt":1234.5,"pointCount":"many"}
        """
        try Data(json.utf8).write(to: folder.appendingPathComponent("metadata.json"))

        let tolerant = locations.tolerantSidecar(forFolderNamed: "t")

        #expect(tolerant == TolerantSidecar(
            id: id, displayName: "Kept", trashedAt: Date(timeIntervalSinceReferenceDate: 1234.5)
        ))
    }

    @Test func tolerantSidecar_isNilForNonJSON() throws {
        let locations = StorageLocations(root: makeTempRoot())
        let folder = locations.root.appendingPathComponent("t", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: folder.appendingPathComponent("metadata.json"))
        #expect(locations.tolerantSidecar(forFolderNamed: "t") == nil)
    }
}
