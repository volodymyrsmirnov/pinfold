import Foundation
@testable import Pinfold
import Testing

@Suite(.serialized) @MainActor struct SearchDataRevisionTests {
    @Test func reloadBumpsSearchDataRevision() async {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        let catalog = Catalog(storage: storage, cache: ResourceCache { _ in Data() })
        let before = catalog.searchDataRevision
        await catalog.reload()
        #expect(catalog.searchDataRevision != before)
    }
}
