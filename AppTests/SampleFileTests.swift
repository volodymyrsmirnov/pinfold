import Foundation
@testable import Pinfold
import Testing

/// The bundled sample behind "Try a Sample File": it must ship in the app bundle and import
/// through the picker's URL path into a non-empty file.
@Suite(.serialized) @MainActor struct SampleFileTests {
    @Test func sampleFile_isBundledAndImportsAsRome() async throws {
        let url = try #require(SampleFile.url)

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        let cache = ResourceCache { _ in Data() }
        let catalog = Catalog(storage: storage, cache: cache)
        let coordinator = ImportCoordinator()

        coordinator.enqueue([url], catalog: catalog, cache: cache)
        await coordinator.drainForTesting()

        let entry = try #require(catalog.entries.first)
        #expect(catalog.entries.count == 1)
        #expect(entry.displayName == "Rome")
        #expect(entry.pointCount > 0)
        #expect(coordinator.importError == nil)
    }
}
