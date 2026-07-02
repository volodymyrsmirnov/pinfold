import Foundation
@testable import Pinfold
import Testing

/// Integration test for the restore guard's entry resolution: the saved folder name must
/// resolve only against ACTIVE entries (a trashed or deleted entry silently lands the user
/// on the catalogue). Uses the temporary-root pattern so no real storage is touched.
@Suite(.serialized) @MainActor struct RestoreResolutionTests {
    @Test func folderName_resolvesOnlyActiveEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreResolutionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageLocations(root: root)
        let catalog = Catalog(storage: storage, cache: ResourceCache())

        // Import one entry through the real pipeline, then reload the catalogue from disk.
        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
        <Placemark><name>Spot</name><Point><coordinates>2.0,48.0,0</coordinates></Point></Placemark>
        </Document></kml>
        """
        let result = try ImportService.prepare(data: Data(kml.utf8), sourceFilename: "restore.kml")
        try ImportService.commit(result, storage: storage, cache: ResourceCache())
        await catalog.reload()

        let entry = try #require(catalog.active.first)
        let folderName = entry.storageFolderName

        // Present + active → resolves.
        #expect(catalog.active.first { $0.storageFolderName == folderName } != nil)

        // Trashed → no longer resolves via `active`.
        await catalog.moveToTrash(entry)
        #expect(catalog.active.first { $0.storageFolderName == folderName } == nil)

        // Missing entirely → no longer resolves.
        #expect(catalog.active.first { $0.storageFolderName == "no-such-folder" } == nil)
    }
}
