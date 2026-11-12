import Foundation
@testable import Pinfold
import Testing

/// D3: one resolver picks an entry's original (sidecar name first, then kml/kmz, then the rest),
/// and the scanner clears stale snapshot temp files.
@Suite(.serialized) @MainActor
struct OriginalResolverTests {
    private func makeRoot() throws -> (StorageLocations, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("f", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (StorageLocations(root: root), folder)
    }

    private func touch(_ name: String, in folder: URL) throws {
        try Data("x".utf8).write(to: folder.appendingPathComponent(name))
    }

    @Test func sidecarlessFolder_prefersKMLOverJSON() throws {
        let (storage, folder) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try touch("data.json", in: folder)
        try touch("trip.kml", in: folder)
        #expect(storage.originalFileURL(inFolderNamed: "f")?.lastPathComponent == "trip.kml")
    }

    @Test func sidecarSourceFilename_winsOverSiblings() throws {
        let (storage, folder) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try touch("a.kml", in: folder)
        try touch("route.geojson", in: folder)
        let meta = EntryMetadata(
            id: UUID(), displayName: "R", sourceFilename: "route.geojson", importDate: .now,
            pointCount: 0, contentSHA256: "abc", trashedAt: nil
        )
        try storage.writeMetadata(meta, forFolderNamed: "f")
        #expect(storage.originalFileURL(inFolderNamed: "f")?.lastPathComponent == "route.geojson")
    }

    @Test func sidecarNamingMissingFile_fallsBackToRanking() throws {
        let (storage, folder) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try touch("notes.json", in: folder)
        try touch("z.kmz", in: folder)
        let meta = EntryMetadata(
            id: UUID(), displayName: "R", sourceFilename: "gone.kml", importDate: .now,
            pointCount: 0, contentSHA256: "abc", trashedAt: nil
        )
        try storage.writeMetadata(meta, forFolderNamed: "f")
        #expect(storage.originalFileURL(inFolderNamed: "f")?.lastPathComponent == "z.kmz")
    }

    @Test func sidecarFilenameWithPathComponents_isIgnored() throws {
        let (storage, folder) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        try touch("a.kml", in: folder)
        let meta = EntryMetadata(
            id: UUID(), displayName: "R", sourceFilename: "../f/a.kml", importDate: .now,
            pointCount: 0, contentSHA256: "abc", trashedAt: nil
        )
        try storage.writeMetadata(meta, forFolderNamed: "f")
        #expect(storage.originalFileURL(inFolderNamed: "f")?.lastPathComponent == "a.kml")
    }

    @Test func scanRemovesStaleSnapshotTempFiles_butKeepsFreshOnes() throws {
        let (storage, folder) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let kml = Data("""
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>T</name>
        <Placemark><name>P</name><Point><coordinates>1,2,0</coordinates></Point></Placemark></Document></kml>
        """.utf8)
        let prepared = try ImportService.prepare(data: kml, sourceFilename: "t.kml")
        try ImportService.commit(prepared, storage: storage, cache: ResourceCache { _ in Data() })
        let entryFolder = try #require(storage.entryFolderNames().first)
        _ = folder
        let dir = storage.root.appendingPathComponent(entryFolder)
        let stale = dir.appendingPathComponent(".snapshot-STALE.tmp")
        let fresh = dir.appendingPathComponent(".snapshot-FRESH.tmp")
        try Data("x".utf8).write(to: stale)
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3 * 3600)], ofItemAtPath: stale.path
        )
        _ = CatalogScanner(storage: storage).scan()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }
}
