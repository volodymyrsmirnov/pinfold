import Foundation
@testable import Pinfold
import Testing

/// Tests for `StorageUsage`: the Settings storage breakdown. Sizes are allocated bytes, so
/// payloads are large and assertions allow some allocation rounding.
struct StorageUsageTests {
    private static let slack = 16384

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func bytes(_ count: Int) -> Data {
        Data(repeating: 0x41, count: count)
    }

    @Test func emptyCatalogueIsZero() throws {
        let storage = try StorageLocations(root: makeRoot())
        #expect(StorageUsage.measure(in: storage) == StorageUsage.zero)
        let missing = StorageLocations(root: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        #expect(StorageUsage.measure(in: missing) == StorageUsage.zero)
    }

    @Test func sizesAreSplitByCategory() async throws {
        let storage = try StorageLocations(root: makeRoot())
        let folder = storage.root.appendingPathComponent("entry-1", isDirectory: true)
        let resources = storage.resourcesDirectory(forFolderNamed: "entry-1")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try bytes(100_000).write(to: folder.appendingPathComponent("a.kml"))
        try bytes(1000).write(to: folder.appendingPathComponent("metadata.json"))

        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(count: 200_000)
        let cache = ResourceCache(downloader: { _ in png })
        try cache.writeEmbedded(["images/i.png": bytes(300_000)], to: resources)
        try bytes(50000).write(to: resources.appendingPathComponent(PlacemarkIndex.filename))
        let href = "https://example.com/p.png"
        await cache.downloadRemote([href], to: resources)
        #expect(cache.localURL(forHref: href, in: resources) != nil)

        let usage = StorageUsage.measure(in: storage)
        #expect(usage.files >= 101_000 && usage.files < 101_000 + Self.slack)
        #expect(usage.downloadedImages >= 200_004 && usage.downloadedImages < 200_004 + Self.slack)
        // Embedded image + index + the manifest/hrefs/state sidecars.
        #expect(usage.extractedData >= 350_000 && usage.extractedData < 350_000 + Self.slack)
        #expect(usage.total == usage.files + usage.downloadedImages + usage.extractedData)
    }
}
