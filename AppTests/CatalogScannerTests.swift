import Foundation
@testable import Pinfold
import Testing

/// Tests for `CatalogScanner` — building the catalogue from the folders on disk, with
/// the folders as the single source of truth (no parallel index, no de-duplication).
@Suite(.serialized) @MainActor struct CatalogScannerTests {
    private func makeScanner() -> (CatalogScanner, StorageLocations) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        // Stub cache so rebuild-from-original never hits the network.
        let scanner = CatalogScanner(storage: storage, cache: ResourceCache { _ in Data() })
        return (scanner, storage)
    }

    private func seedFolder(
        _ storage: StorageLocations,
        folder: String,
        sha: String,
        importDate: Date,
        trashedAt: Date? = nil
    ) throws {
        let dir = storage.root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = EntryMetadata(
            id: UUID(), displayName: folder, sourceFilename: "\(folder).kml",
            importDate: importDate, pointCount: 1, contentSHA256: sha, trashedAt: trashedAt
        )
        try meta.encoded().write(to: dir.appendingPathComponent("metadata.json"))
    }

    @Test func scan_emptyWhenRootAbsent() {
        let (scanner, _) = makeScanner()
        #expect(scanner.scan().isEmpty)
    }

    @Test func scan_readsSidecars_sortedByImportDateDescending() throws {
        let (scanner, storage) = makeScanner()
        try seedFolder(storage, folder: "older", sha: "a", importDate: Date(timeIntervalSince1970: 1))
        try seedFolder(storage, folder: "newer", sha: "b", importDate: Date(timeIntervalSince1970: 2))

        let entries = scanner.scan()

        #expect(entries.count == 2)
        #expect(entries.map(\.storageFolderName) == ["newer", "older"])
    }

    @Test func scan_includesTrashedEntries() throws {
        let (scanner, storage) = makeScanner()
        try seedFolder(storage, folder: "t", sha: "a",
                       importDate: Date(timeIntervalSince1970: 1),
                       trashedAt: Date(timeIntervalSince1970: 100))

        let entries = scanner.scan()

        #expect(entries.count == 1)
        #expect(entries.first?.isTrashed == true)
    }

    /// Folders are the source of truth: two folders with the same content hash are TWO
    /// entries. No reconcile-time de-duplication (decision: block duplicates at import only).
    @Test func scan_doesNotDeduplicateByContentHash() throws {
        let (scanner, storage) = makeScanner()
        try seedFolder(storage, folder: "one", sha: "dup", importDate: Date(timeIntervalSince1970: 1))
        try seedFolder(storage, folder: "two", sha: "dup", importDate: Date(timeIntervalSince1970: 2))

        #expect(scanner.scan().count == 2)
    }

    /// Self-healing: a folder with only a bare original (no sidecar) is parsed into an
    /// entry, and a sidecar is written so subsequent scans are cheap reads.
    @Test func scan_rebuildsFromBareOriginal_andWritesSidecar() throws {
        let (scanner, storage) = makeScanner()
        let dir = storage.root.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AppFixture.data("Rome.kml").write(to: dir.appendingPathComponent("Rome.kml"))

        let entries = scanner.scan()

        #expect(entries.count == 1)
        #expect(entries.first?.storageFolderName == "bare")
        #expect(entries.first?.sourceFilename == "Rome.kml")
        #expect(try storage.readMetadata(forFolderNamed: "bare") != nil)
    }

    /// A folder with neither a sidecar nor a parseable original is skipped (e.g. an
    /// iCloud placeholder that has not downloaded yet).
    @Test func scan_skipsEmptyFolders() throws {
        let (scanner, storage) = makeScanner()
        let dir = storage.root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(scanner.scan().isEmpty)
    }

    // MARK: - Corrupt / unreadable sidecars

    /// An existing sidecar that fails to decode (an iCloud conflict placeholder, a partial
    /// sync, or a future-schema file) must NEVER be overwritten — doing so would destroy
    /// trash state, favorites, and visited keys. The garbage bytes stay on disk untouched.
    @Test func scan_corruptSidecarWithOriginal_doesNotOverwriteSidecar() throws {
        let (scanner, storage) = makeScanner()
        let dir = storage.root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AppFixture.data("Rome.kml").write(to: dir.appendingPathComponent("Rome.kml"))
        let sidecarURL = dir.appendingPathComponent("metadata.json")
        let garbage = Data("this is not valid json {{{".utf8)
        try garbage.write(to: sidecarURL)

        _ = scanner.scan()

        let after = try Data(contentsOf: sidecarURL)
        #expect(after == garbage, "unreadable sidecar must be left byte-for-byte unchanged")
    }

    /// A folder with a corrupt sidecar but a valid original still appears in the catalogue,
    /// derived in-memory from the original (display name + point count), so the entry is not
    /// lost while its sidecar is unreadable.
    @Test func scan_corruptSidecarWithOriginal_entryStillListed() throws {
        let (scanner, storage) = makeScanner()
        let dir = storage.root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AppFixture.data("Rome.kml").write(to: dir.appendingPathComponent("Rome.kml"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("metadata.json"))

        let entries = scanner.scan()

        #expect(entries.count == 1)
        #expect(entries.first?.storageFolderName == "corrupt")
        #expect(entries.first?.sourceFilename == "Rome.kml")
        #expect(entries.first?.displayName == "Rome")
        #expect((entries.first?.pointCount ?? 0) > 0)
    }

    /// A genuinely *absent* sidecar (not just unreadable) is still backfilled — the existing
    /// self-heal behavior for pre-sync entries is preserved.
    @Test func scan_missingSidecarWithOriginal_backfillsSidecar() throws {
        let (scanner, storage) = makeScanner()
        let dir = storage.root.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AppFixture.data("Rome.kml").write(to: dir.appendingPathComponent("Rome.kml"))

        _ = scanner.scan()

        #expect(try storage.readMetadata(forFolderNamed: "bare") != nil,
                "a missing sidecar must be backfilled on scan")
    }

    /// A corrupt sidecar with NO original file: nothing to derive an entry from, so the folder
    /// is skipped and left entirely untouched (no writes, no deletes).
    @Test func scan_corruptSidecarNoOriginal_folderUntouchedAndSkipped() throws {
        let (scanner, storage) = makeScanner()
        let dir = storage.root.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sidecarURL = dir.appendingPathComponent("metadata.json")
        let garbage = Data("garbage".utf8)
        try garbage.write(to: sidecarURL)

        let entries = scanner.scan()

        #expect(entries.isEmpty)
        // Folder contents are exactly the one garbage sidecar — nothing added or removed.
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        #expect(contents.map(\.lastPathComponent) == ["metadata.json"])
        #expect(try Data(contentsOf: sidecarURL) == garbage)
    }

    // MARK: - Per-device resource materialization

    /// Simulates a second device: the synced folder has the original + sidecar, but the
    /// local resources cache (kept out of iCloud) does not exist yet. Materializing must
    /// build the cache from the original so icons resolve on this device too.
    @Test func materialize_buildsResourcesForSyncedKmz() async throws {
        let (scanner, storage) = makeScanner()
        let folder = "kmz"
        let dir = storage.root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AppFixture.data("Rome.kmz").write(to: dir.appendingPathComponent("Rome.kmz"))
        // Sidecar present (as it would be after syncing from the other device).
        let meta = EntryMetadata(
            id: UUID(), displayName: "Rome", sourceFilename: "Rome.kmz",
            importDate: .now, pointCount: 1, contentSHA256: "x", trashedAt: nil
        )
        try meta.encoded().write(to: dir.appendingPathComponent("metadata.json"))

        let resourcesDir = storage.resourcesDirectory(forFolderNamed: folder)
        #expect(!FileManager.default.fileExists(atPath: resourcesDir.path),
                "precondition: no local resource cache yet")

        let changed = await scanner.materializeMissingResources()

        #expect(changed)
        #expect(FileManager.default.fileExists(atPath: resourcesDir.path))
        #expect(scanner.cache.localURL(forHref: "images/icon-1.png", in: resourcesDir) != nil,
                "embedded KMZ icon must be extracted into the local cache")
    }

    /// Idempotent: once the resources directory exists it is treated as the done-marker and
    /// the original is not re-parsed (no duplicate work, no clobbering).
    @Test func materialize_skipsFolderWithExistingResourcesDir() async throws {
        let (scanner, storage) = makeScanner()
        let folder = "done"
        let dir = storage.root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AppFixture.data("Rome.kmz").write(to: dir.appendingPathComponent("Rome.kmz"))

        // Pre-existing resources dir with a sentinel file = "already materialized".
        let resourcesDir = storage.resourcesDirectory(forFolderNamed: folder)
        try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        let sentinel = resourcesDir.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)

        let changed = await scanner.materializeMissingResources()

        #expect(!changed)
        #expect(FileManager.default.fileExists(atPath: sentinel.path), "must not clobber the cache")
    }
}
