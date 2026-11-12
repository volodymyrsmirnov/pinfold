import Foundation
@testable import Pinfold
import Testing

/// Tests for `LaunchReconciler`: the Spotlight ledger diff and the conservative cache prune.
/// A recording sink stands in for Core Spotlight; temp roots stand in for the real ones.
@Suite(.serialized) @MainActor
struct LaunchReconcilerTests {
    private final class RecordingSink: SpotlightSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _indexed: [String] = []
        private var _deindexed: [String] = []
        private var _clearedLegacy = 0

        var indexed: [String] {
            lock.withLock { _indexed }
        }

        var deindexed: [String] {
            lock.withLock { _deindexed }
        }

        var clearedLegacy: Int {
            lock.withLock { _clearedLegacy }
        }

        func index(entry: CatalogEntry, indexEntries _: [PlacemarkIndex.Entry]) {
            lock.withLock { _indexed.append(entry.storageFolderName) }
        }

        func deindex(folderName: String) {
            lock.withLock { _deindexed.append(folderName) }
        }

        func clearLegacyDomains() {
            lock.withLock { _clearedLegacy += 1 }
        }
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "LaunchReconcilerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func entry(_ folder: String, name: String = "N", trashed: Bool = false) -> CatalogEntry {
        CatalogEntry(
            id: UUID(), displayName: name, sourceFilename: "f.kml", importDate: .now, pointCount: 1,
            contentSHA256: "x", storageFolderName: folder, trashedAt: trashed ? .now : nil
        )
    }

    private func makeReconciler(_ sink: RecordingSink, _ defaults: UserDefaults) -> LaunchReconciler {
        LaunchReconciler(defaults: defaults, sink: sink)
    }

    private let storage = StorageLocations(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("unused-\(UUID().uuidString)"))

    // MARK: - Spotlight

    @Test func firstRunWithoutLedgerReindexesEverything() async {
        let sink = RecordingSink()
        let defaults = freshDefaults()
        let all = [entry("A"), entry("B"), entry("T", trashed: true)]
        await makeReconciler(sink, defaults).reconcileSpotlight(entries: all, storage: storage)
        #expect(sink.clearedLegacy == 1)
        #expect(Set(sink.indexed) == ["A", "B"])
        #expect(sink.deindexed.isEmpty)

        // A second launch with the same catalogue does nothing.
        let second = RecordingSink()
        await makeReconciler(second, defaults).reconcileSpotlight(entries: all, storage: storage)
        #expect(second.clearedLegacy == 0)
        #expect(second.indexed.isEmpty && second.deindexed.isEmpty)
    }

    @Test func vanishedEntryIsDeindexed() async {
        let defaults = freshDefaults()
        await makeReconciler(RecordingSink(), defaults)
            .reconcileSpotlight(entries: [entry("A"), entry("B")], storage: storage)
        let sink = RecordingSink()
        await makeReconciler(sink, defaults).reconcileSpotlight(entries: [entry("A")], storage: storage)
        #expect(sink.deindexed == ["B"])
        #expect(sink.indexed.isEmpty)
    }

    @Test func renamedEntryIsReindexed() async {
        let defaults = freshDefaults()
        await makeReconciler(RecordingSink(), defaults)
            .reconcileSpotlight(entries: [entry("A", name: "Old")], storage: storage)
        let sink = RecordingSink()
        await makeReconciler(sink, defaults)
            .reconcileSpotlight(entries: [entry("A", name: "New")], storage: storage)
        #expect(sink.indexed == ["A"])
        #expect(sink.deindexed.isEmpty)
    }

    @Test func trashedElsewhereIsDeindexed() async {
        let defaults = freshDefaults()
        await makeReconciler(RecordingSink(), defaults)
            .reconcileSpotlight(entries: [entry("A")], storage: storage)
        let sink = RecordingSink()
        await makeReconciler(sink, defaults)
            .reconcileSpotlight(entries: [entry("A", trashed: true)], storage: storage)
        #expect(sink.deindexed == ["A"])
        #expect(sink.indexed.isEmpty)
    }

    @Test func emptyCatalogueNeverDeindexesTheLedger() async {
        let defaults = freshDefaults()
        await makeReconciler(RecordingSink(), defaults)
            .reconcileSpotlight(entries: [entry("A")], storage: storage)
        let sink = RecordingSink()
        await makeReconciler(sink, defaults).reconcileSpotlight(entries: [], storage: storage)
        #expect(sink.deindexed.isEmpty)
        // The ledger survived, so the entry coming back is not treated as new.
        let back = RecordingSink()
        await makeReconciler(back, defaults).reconcileSpotlight(entries: [entry("A")], storage: storage)
        #expect(back.indexed.isEmpty && back.deindexed.isEmpty)
    }

    // MARK: - Cache pruning

    private func seedFolder(_ root: URL, _ name: String, inner: String = "resources") throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name).appendingPathComponent(inner), withIntermediateDirectories: true
        )
    }

    private func splitStorage() throws -> (StorageLocations, URL) {
        let root = tempRoot()
        let cache = tempRoot()
        try seedFolder(root, "Live", inner: "x")
        try seedFolder(cache, "Live")
        try seedFolder(cache, "Orphan")
        return (StorageLocations(root: root, cacheRoot: cache), cache)
    }

    @Test func orphanedCacheFolderIsPruned() throws {
        let (storage, cache) = try splitStorage()
        let removed = LaunchReconciler.pruneCache(storage: storage, status: .active)
        #expect(removed == ["Orphan"])
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Live").path))
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("Orphan").path))
    }

    @Test func nothingIsPrunedWhileICloudIsUnavailable() throws {
        let (storage, cache) = try splitStorage()
        #expect(LaunchReconciler.pruneCache(storage: storage, status: .unavailable).isEmpty)
        #expect(LaunchReconciler.pruneCache(storage: storage, status: .off).isEmpty)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Orphan").path))
    }

    @Test func nonSplitLayoutIsNeverPruned() throws {
        let root = tempRoot()
        try seedFolder(root, "Live", inner: "x")
        try seedFolder(root, "Orphan")
        let storage = StorageLocations(root: root)
        #expect(LaunchReconciler.pruneCache(storage: storage, status: .active).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Orphan").path))
    }

    @Test func unreadableOrEmptyRootPrunesNothing() throws {
        let cache = tempRoot()
        try seedFolder(cache, "Orphan")
        let missingRoot = StorageLocations(root: tempRoot(), cacheRoot: cache)
        #expect(LaunchReconciler.pruneCache(storage: missingRoot, status: .active).isEmpty)
        let emptyRoot = tempRoot()
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let empty = StorageLocations(root: emptyRoot, cacheRoot: cache)
        #expect(LaunchReconciler.pruneCache(storage: empty, status: .active).isEmpty)
    }

    @Test func foldersWithForeignContentAreLeftAlone() throws {
        let (storage, cache) = try splitStorage()
        try seedFolder(cache, "Odd", inner: "notes")
        let removed = LaunchReconciler.pruneCache(storage: storage, status: .active)
        #expect(removed == ["Orphan"])
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("Odd").path))
    }
}
