import Foundation
@testable import Pinfold
import Testing

/// D6: the background refresh never downloads (or waits for) an iCloud original.
@Suite(.serialized) @MainActor
struct RefreshSkipsNotDownloadedTests {
    private func seed(probe: FakeUbiquityProbe) throws -> (CatalogScanner, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        storage.isUbiquitous = true
        storage.probe = probe
        let data = try AppFixture.data("Rome.kml")
        let dir = storage.root.appendingPathComponent("entry", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent("Rome.kml"))
        let meta = EntryMetadata(
            id: UUID(), displayName: "Rome", sourceFilename: "Rome.kml", importDate: .now,
            pointCount: 1, contentSHA256: ImportService.sha256Hex(data), trashedAt: nil
        )
        try meta.encoded().write(to: dir.appendingPathComponent("metadata.json"))
        let scanner = CatalogScanner(storage: storage, cache: ResourceCache { _ in Data() })
        return (scanner, storage.resourcesDirectory(forFolderNamed: "entry"))
    }

    @Test func notDownloadedOriginal_isLeftForALaterPass() async throws {
        let probe = FakeUbiquityProbe(status: .notDownloaded)
        let (scanner, resources) = try seed(probe: probe)
        let didWork = await scanner.materializeMissingResources()
        #expect(!didWork)
        #expect(!FileManager.default.fileExists(atPath: resources.path))
        #expect(probe.downloadRequests.isEmpty)
    }

    @Test func downloadedOriginal_isRefreshedAsBefore() async throws {
        let (scanner, resources) = try seed(probe: FakeUbiquityProbe(status: .current))
        let didWork = await scanner.materializeMissingResources()
        #expect(didWork)
        #expect(FileManager.default.fileExists(atPath: resources.path))
    }
}
