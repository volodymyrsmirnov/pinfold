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
            catalog: catalog, storage: storage, cache: cache
        )
        await coordinator.drainForTesting()

        #expect(catalog.entries.count == 2)
    }

    // MARK: - Duplicate handling

    @Test func import_duplicateStallsUntilDecision_skip() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 3, lat: 3)
        coordinator.enqueuePrepared([(content, "first.kml")], catalog: catalog, storage: storage, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 1)

        // Same content again → coordinator exposes the pending-duplicate state and stalls.
        coordinator.enqueuePrepared([(content, "again.kml")], catalog: catalog, storage: storage, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate != nil)

        // Skip → still 1 entry; queue continues (drains cleanly).
        coordinator.skipDuplicate(catalog: catalog, storage: storage, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate == nil)
        #expect(catalog.entries.count == 1)
    }

    @Test func import_duplicateImportAnyway_addsSecondCopy() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 4, lat: 4)
        coordinator.enqueuePrepared([(content, "first.kml")], catalog: catalog, storage: storage, cache: cache)
        await coordinator.drainForTesting()

        coordinator.enqueuePrepared([(content, "again.kml")], catalog: catalog, storage: storage, cache: cache)
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate != nil)

        coordinator.importAnyway(catalog: catalog, storage: storage, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 2)
    }

    // MARK: - isImporting flag

    @Test func import_isImportingTrueWhileProcessing() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        #expect(coordinator.isImporting == false)

        coordinator.enqueuePrepared([(kml(lon: 5, lat: 5), "x.kml")], catalog: catalog, storage: storage, cache: cache)
        // Synchronously after enqueue, before the queue has drained, importing is in flight.
        #expect(coordinator.isImporting == true)

        await coordinator.drainForTesting()
        #expect(coordinator.isImporting == false)
        #expect(coordinator.currentFilename == nil)
    }

    // MARK: - Race regression: importAnyway awaits reload before processing next

    /// Regression for the fire-and-forget commit in `importAnyway`. Queue:
    /// [duplicate-of-existing, fresh-file]. When the user taps Import Anyway on the stalled
    /// duplicate, the coordinator must commit AND await `catalog.reload()` BEFORE pulling the
    /// next queued item — otherwise the next item's duplicate check runs against a stale
    /// catalogue.
    ///
    /// The deterministic stressor: the queue carries the SAME content as the *next* item too.
    /// After Import Anyway commits the duplicate copy, the next item is byte-identical to it; a
    /// correct (await-before-next) implementation sees the just-committed copy and stalls again
    /// on a second duplicate, so exactly one copy is added per decision. The fire-and-forget
    /// code can let the next item's dedup check miss the in-flight commit. We assert the final,
    /// fully-settled entry count is exact.
    @Test func importAnyway_awaitsReloadBeforeNext() async {
        let (coordinator, catalog, storage, cache) = makeEnvironment()
        let content = kml(lon: 6, lat: 6)

        // Seed an existing entry with this content.
        coordinator.enqueuePrepared([(content, "original.kml")], catalog: catalog, storage: storage, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 1)

        // Now enqueue the SAME content again, plus a fresh distinct file. The first stalls as a
        // duplicate; Import Anyway must await the reload before the fresh file is dedup-checked.
        coordinator.enqueuePrepared(
            [(content, "dup.kml"), (kml(lon: 7, lat: 7), "fresh.kml")],
            catalog: catalog, storage: storage, cache: cache
        )
        await coordinator.drainForTesting()
        #expect(coordinator.pendingDuplicate != nil)

        coordinator.importAnyway(catalog: catalog, storage: storage, cache: cache)
        await coordinator.drainForTesting()

        // original + dup-copy + fresh = exactly 3, and no error surfaced.
        #expect(coordinator.importError == nil)
        #expect(catalog.entries.count == 3)
    }
}
