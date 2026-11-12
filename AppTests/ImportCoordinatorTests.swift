import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `ImportCoordinator` — the import-queue state machine extracted from `HomeView`.
///
/// The production entry point is URL-based (`enqueue(_ urls:…)`); these tests drive the same
/// pipeline through a test-only `enqueuePrepared(_:…)` that takes `(Data, filename)` pairs, so
/// no security-scoped file URLs are needed. State is injected (temp `StorageLocations`,
/// `Catalog`, and a stub-downloader `ResourceCache`) mirroring `CatalogTests`.
///
/// `@MainActor` + `.serialized` because the coordinator and its `Catalog` are mutable
/// `@MainActor` state shared across the (sequential) cases.
@Suite(.serialized) @MainActor struct ImportCoordinatorTests {
    // MARK: - Fixtures

    /// Minimal valid single-point KML with a caller-controlled point so distinct calls produce
    /// distinct content hashes. Two calls with the same `lon`/`lat` produce byte-identical KML
    /// (and therefore the same SHA-256 → duplicate).
    private func kml(lon: Double, lat: Double) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <Placemark>
              <Point><coordinates>\(lon),\(lat),0</coordinates></Point>
            </Placemark>
          </Document>
        </kml>
        """.utf8)
    }

    private func makeEnvironment() -> (ImportCoordinator, Catalog, StorageLocations, ResourceCache) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        let cache = ResourceCache { _ in Data() }
        let catalog = Catalog(storage: storage, cache: cache)
        return (ImportCoordinator(), catalog, storage, cache)
    }

    // MARK: - Sequential processing

    @Test func import_queueProcessesSequentially() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        coordinator.enqueuePrepared(
            [(kml(lon: 1, lat: 1), "a.kml"), (kml(lon: 2, lat: 2), "b.kml")],
            catalog: catalog, cache: cache
        )
        await coordinator.drainForTesting()

        #expect(catalog.entries.count == 2)
    }

    // MARK: - Duplicate handling

    @Test func import_duplicateStallsUntilDecision_skip() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 3, lat: 3)
        coordinator.enqueuePrepared([(content, "first.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 1)

        // Same content again → coordinator exposes the pending-duplicate state and stalls.
        coordinator.enqueuePrepared([(content, "again.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate != nil)
        // Stall semantics: nothing is being imported while we wait on the user's decision —
        // `isImporting` is false and the progress filename is cleared, so the coordinator's
        // published state is self-consistent for the UI.
        #expect(coordinator.isImporting == false)
        #expect(coordinator.currentFilename == nil)

        // Skip → still 1 entry; queue continues (drains cleanly).
        coordinator.skipDuplicate(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate == nil)
        #expect(catalog.entries.count == 1)
    }

    @Test func import_duplicateImportAnyway_addsSecondCopy() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 4, lat: 4)
        coordinator.enqueuePrepared([(content, "first.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        coordinator.enqueuePrepared([(content, "again.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate != nil)

        coordinator.importAnyway(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 2)
    }

    // MARK: - isImporting flag

    @Test func import_isImportingTrueWhileProcessing() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        #expect(coordinator.isImporting == false)

        coordinator.enqueuePrepared([(kml(lon: 5, lat: 5), "x.kml")], catalog: catalog, cache: cache)
        // Synchronously after enqueue, before the queue has drained, importing is in flight.
        #expect(coordinator.isImporting == true)

        await coordinator.drainForTesting()
        #expect(coordinator.isImporting == false)
        #expect(coordinator.currentFilename == nil)
    }

    // MARK: - Race regression: importAnyway awaits reload before processing next

    /// Regression for the fire-and-forget commit in `importAnyway`: the coordinator must
    /// commit AND await `catalog.reload()` BEFORE pulling the next queued item, so the next
    /// item's duplicate check runs against the post-reload catalogue, never a stale one.
    ///
    /// The deterministic stressor: queue TWO items byte-identical to an already-seeded entry.
    /// With the awaited reload, every dedup check sees all earlier commits, so each copy stalls
    /// individually: Import Anyway on the first stall commits exactly one copy and the second
    /// item immediately stalls again (`pendingDuplicate` non-nil, catalogue already showing
    /// 2 entries when the drain settles). With the old fire-and-forget reload, the drain
    /// resumes against a stale catalogue — the stall/count sequence diverges (verified red
    /// against a temporarily-reintroduced fire-and-forget commit) — so the exact asserts below
    /// pin the awaited behaviour.
    @Test func importAnyway_awaitsReloadBeforeNext() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 6, lat: 6)

        // Seed an existing entry with this content.
        coordinator.enqueuePrepared([(content, "original.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 1)

        // Enqueue TWO more byte-identical copies. The first stalls as a duplicate.
        coordinator.enqueuePrepared(
            [(content, "dup.kml"), (content, "dup2.kml")],
            catalog: catalog, cache: cache
        )
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate != nil)
        #expect(catalog.entries.count == 1)

        // Import Anyway commits the first copy; the awaited reload means the catalogue shows
        // 2 entries by the time the second copy's dedup check runs — which therefore stalls
        // again rather than slipping through against a stale snapshot.
        coordinator.importAnyway(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate != nil, "second byte-identical copy must stall too")
        #expect(catalog.entries.count == 2, "the reload must have been awaited before the next item ran")

        // Skip the second stall → final state: exactly original + one anyway-copy, no error.
        coordinator.skipDuplicate(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate == nil)
        #expect(coordinator.importError == nil)
        #expect(catalog.entries.count == 2)
    }

    // MARK: - One queue for every arrival path (B11, B16)

    private func makeInbox(_ name: String = "Inbox") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test func sameBytesFromOpenedFileAndInboxScan_importOnce() async throws {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let inboxURL = try makeInbox()
        let bytes = kml(lon: 10, lat: 10)
        let opened = inboxURL.appendingPathComponent("opened.kml")
        let sameBytes = inboxURL.appendingPathComponent("other-name.kml")
        try bytes.write(to: opened)
        try bytes.write(to: sameBytes)

        // "Open in" enqueues the file, then the inbox scan lists it again plus a copy of the
        // same bytes under another name.
        coordinator.enqueueOwned([.init(url: opened)], catalog: catalog, cache: cache)
        let inbox = PendingImportInbox(
            inboxURL: inboxURL, coordinator: coordinator, catalog: catalog, cache: cache
        )
        #expect(inbox.drain() == 1, "the already-queued path must not be enqueued a second time")
        await coordinator.drainForTesting()

        #expect(catalog.entries.count == 1)
        #expect(coordinator.pendingDuplicate == nil)
        #expect(!exists(opened) && !exists(sameBytes), "both copies are cleaned up")
    }

    @Test func sameFileEnqueuedTwice_importsOnce() async throws {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let file = try makeInbox().appendingPathComponent("a.kml")
        try kml(lon: 11, lat: 11).write(to: file)

        coordinator.enqueue([file, file], catalog: catalog, cache: cache)
        coordinator.enqueue([file], catalog: catalog, cache: cache)
        #expect(coordinator.totalCount == 1)
        await coordinator.drainForTesting()

        #expect(catalog.entries.count == 1)
        #expect(coordinator.pendingDuplicate == nil)
        #expect(coordinator.importError == nil)
        #expect(exists(file), "a picker file is never deleted")
    }

    @Test func inboxCopy_isDeletedOnSuccess_keptOnTransientFailure_deletedOnParseFailure() async throws {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let log = ImportFailureLog()
        coordinator.failureLog = log
        let dir = try makeInbox()
        let good = dir.appendingPathComponent("good.kml")
        let bad = dir.appendingPathComponent("bad.kml")
        try kml(lon: 12, lat: 12).write(to: good)
        try Data("garbage".utf8).write(to: bad)

        coordinator.enqueueOwned([.init(url: good), .init(url: bad)], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(!exists(good), "deleted on success")
        #expect(!exists(bad), "deleted on a permanent (parse) failure")
        #expect(log.failures.count == 1)
        #expect(catalog.entries.count == 1)

        // A transient failure: the storage root becomes read-only, so the commit fails.
        let transient = dir.appendingPathComponent("later.kml")
        try kml(lon: 13, lat: 13).write(to: transient)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storage.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storage.root.path) }

        coordinator.enqueueOwned([.init(url: transient)], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(exists(transient), "kept on a transient failure so a later drain retries it")
        #expect(log.failures.count == 2)
        #expect(coordinator.importError == nil, "non-interactive sources use the failure log, not the alert")
    }

    @Test func nonInteractiveActiveDuplicate_isSkippedSilently() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let log = ImportFailureLog()
        coordinator.failureLog = log
        let content = kml(lon: 14, lat: 14)
        coordinator.enqueuePrepared([(content, "a.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        coordinator.enqueuePrepared(
            [(content, "again.kml")], interactive: false, catalog: catalog, cache: cache
        )
        await coordinator.drainForTesting()

        #expect(coordinator.pendingDuplicate == nil)
        #expect(coordinator.importError == nil)
        #expect(log.failures.isEmpty)
        #expect(catalog.entries.count == 1)
    }

    // MARK: - Trashed duplicates (B9)

    private func seedTrashed(
        _ coordinator: ImportCoordinator, _ catalog: Catalog, _: StorageLocations, _ cache: ResourceCache,
        content: Data
    ) async {
        coordinator.enqueuePrepared([(content, "orig.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        if let entry = catalog.entries.first {
            await catalog.moveToTrash(entry)
        }
    }

    @Test func trashedDuplicate_stallsWithTrashedKind() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 20, lat: 20)
        await seedTrashed(coordinator, catalog, storage, cache, content: content)
        #expect(catalog.active.isEmpty)

        coordinator.enqueuePrepared([(content, "again.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        #expect(coordinator.pendingDuplicate?.kind == .trashed)
        #expect(coordinator.pendingDuplicate?.existingEntry.isTrashed == true)
    }

    @Test func restoreTrashedDuplicate_restoresAndCreatesNoSecondEntry() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 21, lat: 21)
        await seedTrashed(coordinator, catalog, storage, cache, content: content)
        coordinator.enqueuePrepared([(content, "again.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        coordinator.restoreTrashedDuplicate(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        #expect(catalog.entries.count == 1)
        #expect(catalog.active.count == 1)
        #expect(coordinator.pendingDuplicate == nil)
    }

    @Test func importAsNew_createsSecondEntry() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 22, lat: 22)
        await seedTrashed(coordinator, catalog, storage, cache, content: content)
        coordinator.enqueuePrepared([(content, "again.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        coordinator.importAnyway(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        #expect(catalog.entries.count == 2)
        #expect(catalog.active.count == 1)
        #expect(catalog.trashed.count == 1)
    }

    @Test func trashedDuplicateFromInbox_isNotDroppedSilently() async throws {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 23, lat: 23)
        await seedTrashed(coordinator, catalog, storage, cache, content: content)
        let file = try makeInbox().appendingPathComponent("shared.kml")
        try content.write(to: file)

        coordinator.enqueueOwned([.init(url: file)], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        #expect(coordinator.pendingDuplicate?.kind == .trashed, "a trashed duplicate prompts from every source")
        #expect(exists(file), "the copy stays until the user decides")

        coordinator.skipDuplicate(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(!exists(file), "skipping deletes the app-owned copy")
    }

    // MARK: - Progress and cancel (C4a)

    /// Waits until the drain has dequeued its first item (it is then in flight).
    private func waitUntilFirstItemStarts(_ coordinator: ImportCoordinator) async {
        while coordinator.currentFilename == nil {
            await Task.yield()
        }
    }

    @Test func progressCountsAdvance() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let first = kml(lon: 30, lat: 30)
        coordinator.enqueuePrepared(
            [(first, "a.kml"), (first, "dup.kml"), (kml(lon: 31, lat: 31), "b.kml")],
            catalog: catalog, cache: cache
        )
        #expect(coordinator.totalCount == 3)
        #expect(coordinator.completedCount == 0)
        #expect(coordinator.currentPosition == 1)

        await coordinator.drainForTesting()
        // Stalled on the duplicate after one finished item.
        #expect(coordinator.completedCount == 1)
        #expect(coordinator.currentPosition == 2)

        coordinator.skipDuplicate(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.completedCount == 3)
        #expect(coordinator.totalCount == 3)

        // A new batch restarts the counters.
        coordinator.enqueuePrepared([(kml(lon: 32, lat: 32), "c.kml")], catalog: catalog, cache: cache)
        #expect(coordinator.totalCount == 1)
        #expect(coordinator.completedCount == 0)
        await coordinator.drainForTesting()
    }

    @Test func cancel_dropsRemainingItems_currentItemCompletes() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        coordinator.enqueuePrepared(
            [(kml(lon: 40, lat: 40), "a.kml"), (kml(lon: 41, lat: 41), "b.kml"), (kml(lon: 42, lat: 42), "c.kml")],
            catalog: catalog, cache: cache
        )
        await waitUntilFirstItemStarts(coordinator)

        coordinator.cancel()
        #expect(coordinator.totalCount == 1)
        await coordinator.drainForTesting()

        #expect(catalog.entries.count == 1, "only the in-flight item completes")
        #expect(coordinator.completedCount == 1)
        #expect(coordinator.isImporting == false)
    }

    @Test func cancelDuringPrepare_abortsCurrentItemAndCommitsNothing() async throws {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let log = ImportFailureLog()
        coordinator.failureLog = log
        let dir = try makeInbox()
        let big = dir.appendingPathComponent("big.kml")
        try LargeKML.data(placemarks: 150_000).write(to: big)
        coordinator.enqueueOwned([.init(url: big)], catalog: catalog, cache: cache)
        await waitUntilFirstItemStarts(coordinator)

        coordinator.cancel()
        await coordinator.drainForTesting()

        #expect(catalog.entries.isEmpty, "nothing is committed for a cancelled item")
        #expect((try? storage.entryFolderNames()) ?? [] == [])
        #expect(!exists(big), "the app-owned copy is dropped like a cancelled queued item")
        #expect(log.failures.isEmpty && coordinator.importError == nil, "a cancel is not a failure")
        #expect(coordinator.isImporting == false)
        #expect(coordinator.completedCount == 1)
    }

    @Test func permanentFailureReason_isNotARawParserError() async throws {
        let (coordinator, catalog, _, cache) = makeEnvironment()
        let log = ImportFailureLog()
        coordinator.failureLog = log
        let dir = try makeInbox()
        let bad = dir.appendingPathComponent("bad.kml")
        try Data("<kml><Document>".utf8).write(to: bad)
        coordinator.enqueueOwned([.init(url: bad)], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        let reason = try #require(log.failures.first?.reason)
        #expect(!reason.contains("NSXMLParserErrorDomain"))
        #expect(!reason.isEmpty)
    }

    @Test func cancel_deletesPendingInboxCopies() async throws {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let dir = try makeInbox()
        var files: [URL] = []
        for index in 0 ..< 3 {
            let file = dir.appendingPathComponent("f\(index).kml")
            try kml(lon: Double(50 + index), lat: 50).write(to: file)
            files.append(file)
        }
        coordinator.enqueueOwned(files.map { .init(url: $0) }, catalog: catalog, cache: cache)
        await waitUntilFirstItemStarts(coordinator)

        coordinator.cancel()
        await coordinator.drainForTesting()

        #expect(catalog.entries.count == 1)
        #expect(files.allSatisfy { !exists($0) }, "the in-flight copy is deleted on success, the pending ones on cancel")
    }

    // MARK: - G1 fixes

    @Test func heldQueue_commitsIntoTheStorageResolvedAtCommitTime() async throws {
        let (coordinator, catalog, storageA, cache) = makeEnvironment()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storageB = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        coordinator.hold()
        coordinator.enqueuePrepared([(kml(lon: 60, lat: 60), "a.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.isEmpty, "nothing is imported while held")

        await catalog.setStorage(storageB)
        coordinator.release(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        #expect(try storageB.entryFolderNames().count == 1)
        #expect(try storageA.entryFolderNames().isEmpty)
        #expect(catalog.entries.count == 1)
    }

    @Test func recentlyCommittedHash_isTreatedAsDuplicateEvenIfCatalogIsStale() async {
        let (coordinator, catalog, _, cache) = makeEnvironment()
        let content = kml(lon: 61, lat: 61)
        coordinator.recentlyCommittedHashes = [ImportService.sha256Hex(content)]
        coordinator.enqueuePrepared([(content, "again.kml")], interactive: false, catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.isEmpty, "the item is skipped, not committed a second time")
        #expect(coordinator.pendingDuplicate == nil)
    }

    @Test func commit_clearsRecentlyCommittedOnceCatalogShowsIt() async {
        let (coordinator, catalog, _, cache) = makeEnvironment()
        coordinator.enqueuePrepared([(kml(lon: 62, lat: 62), "a.kml")], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 1)
        #expect(coordinator.recentlyCommittedHashes.isEmpty)
    }

    @Test func restoreFailure_keepsTheInboxCopy() async throws {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 63, lat: 63)
        await seedTrashed(coordinator, catalog, storage, cache, content: content)
        let file = try makeInbox().appendingPathComponent("shared.kml")
        try content.write(to: file)
        coordinator.enqueueOwned([.init(url: file)], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate?.kind == .trashed)

        // The trashed entry's sidecar becomes unreadable before the user taps Restore.
        let folder = try #require(catalog.entries.first?.storageFolderName)
        try Data("garbage".utf8).write(to: storage.metadataFile(forFolderNamed: folder))
        await catalog.reload()

        coordinator.restoreTrashedDuplicate(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        #expect(exists(file), "a failed restore must not delete the user's file")
        #expect(catalog.actionError != nil)
    }
}
