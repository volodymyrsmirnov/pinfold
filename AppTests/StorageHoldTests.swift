import Foundation
@testable import Pinfold
import Testing

/// D4/D5: imports are held (and an in-flight commit finishes) across a storage application, and
/// the catalogue's background work can be suspended for a migration.
@Suite(.serialized) @MainActor
struct StorageHoldTests {
    private func kml(_ lon: Double) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
        <Placemark><Point><coordinates>\(lon),1,0</coordinates></Point></Placemark>
        </Document></kml>
        """.utf8)
    }

    private func makeEnvironment() -> (ImportCoordinator, Catalog, StorageLocations, ResourceCache) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        let cache = ResourceCache { _ in Data() }
        return (ImportCoordinator(), Catalog(storage: storage, cache: cache), storage, cache)
    }

    @Test func holdsNest_drainResumesOnlyWhenAllReleased() async {
        let (coordinator, catalog, _, cache) = makeEnvironment()
        coordinator.hold()
        coordinator.hold()
        coordinator.enqueuePrepared([(kml(5), "a.kml")], catalog: catalog, cache: cache)
        coordinator.release(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.isEmpty)
        coordinator.release(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 1)
    }

    @Test func holdAndWait_letsTheInFlightItemFinish_butNotTheRest() async {
        let (coordinator, catalog, _, cache) = makeEnvironment()
        coordinator.enqueuePrepared(
            [(kml(1), "a.kml"), (kml(2), "b.kml"), (kml(3), "c.kml")], catalog: catalog, cache: cache
        )
        // Wait until the first item is in flight.
        for _ in 0 ..< 200 where coordinator.currentFilename == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await coordinator.holdAndWaitUntilIdle()
        #expect(!coordinator.isImporting)
        #expect(coordinator.inFlightHashes.isEmpty)
        let committed = catalog.entries.count
        #expect(committed >= 1 && committed < 3)
        coordinator.release(catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 3)
    }

    @Test func storageDidChange_forgetsRecentlyCommittedHashes() async {
        let (coordinator, catalog, _, cache) = makeEnvironment()
        let content = kml(9)
        coordinator.recentlyCommittedHashes = [ImportService.sha256Hex(content)]
        coordinator.storageDidChange()
        coordinator.enqueuePrepared([(content, "again.kml")], interactive: false, catalog: catalog, cache: cache)
        await coordinator.drainForTesting()
        #expect(catalog.entries.count == 1)
    }

    @Test func suspendBackgroundWork_returnsPromptly_andResumeIsSafe() async {
        let (_, catalog, _, _) = makeEnvironment()
        await catalog.suspendBackgroundWork()
        await catalog.reload()
        catalog.resumeBackgroundWork()
        await catalog.suspendBackgroundWork()
        catalog.resumeBackgroundWork()
        #expect(catalog.backgroundWorkSuspended == false)
    }
}
