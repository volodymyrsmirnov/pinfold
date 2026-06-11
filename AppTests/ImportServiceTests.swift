import Foundation
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `ImportService` — prepare, commit-to-disk, and sha256Hex. Duplicate detection
/// lives on `Catalog` and is covered by `CatalogTests`.
@Suite(.serialized) @MainActor struct ImportServiceTests {
    // MARK: - Helpers

    private func makeStorage() -> StorageLocations {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return StorageLocations(root: tempRoot)
    }

    /// A no-op `ResourceCache` whose downloader always returns empty data.
    private func stubCache() -> ResourceCache {
        ResourceCache { _ in Data() }
    }

    // MARK: - sha256Hex

    @Test func sha256Hex_isStableForSameInput() {
        let data = Data("hello world".utf8)
        let first = ImportService.sha256Hex(data)
        let second = ImportService.sha256Hex(data)
        #expect(first == second)
    }

    @Test func sha256Hex_differsForDifferentInput() {
        let a = ImportService.sha256Hex(Data("apple".utf8))
        let b = ImportService.sha256Hex(Data("orange".utf8))
        #expect(a != b)
    }

    @Test func sha256Hex_isLowercaseHex() {
        let hex = ImportService.sha256Hex(Data("test".utf8))
        // 64 hex chars (SHA-256 = 32 bytes)
        #expect(hex.count == 64)
        let allowedChars = CharacterSet(charactersIn: "0123456789abcdef")
        #expect(hex.unicodeScalars.allSatisfy { allowedChars.contains($0) })
    }

    @Test func sha256Hex_knownValue() {
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let hex = ImportService.sha256Hex(Data())
        #expect(hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    // MARK: - prepare — Rome.kml

    @Test func prepare_romeKml_hasExpectedDisplayName() throws {
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        #expect(result.displayName == "Rome")
    }

    @Test func prepare_romeKml_pointCountMatchesKMLReader() throws {
        let data = try AppFixture.data("Rome.kml")
        let parsed = try KMLReader.read(data: data)
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        #expect(result.pointCount == parsed.document.pointCount)
    }

    @Test func prepare_romeKml_contentSHA256IsCorrect() throws {
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        let expected = ImportService.sha256Hex(data)
        #expect(result.contentSHA256 == expected)
    }

    @Test func prepare_romeKml_gatherRemoteHrefs() throws {
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        // Rome.kml has https:// style icon hrefs
        #expect(!result.remoteResourceHrefs.isEmpty, "Rome.kml should have remote icon hrefs")
        for href in result.remoteResourceHrefs {
            #expect(href.hasPrefix("http://") || href.hasPrefix("https://"),
                    "All remote hrefs must be http(s) — got \(href)")
        }
    }

    @Test func prepare_romeKml_embeddedResourcesEmpty() throws {
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        #expect(result.embeddedResources.isEmpty, "Plain KML has no embedded resources")
    }

    @Test func prepare_romeKml_storageFolderNameIsUUID() throws {
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        // Should be a parseable UUID
        #expect(UUID(uuidString: result.storageFolderName) != nil)
    }

    // MARK: - prepare — Rome.kmz

    @Test func prepare_romeKmz_hasExpectedDisplayName() throws {
        let data = try AppFixture.data("Rome.kmz")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kmz")
        #expect(result.displayName == "Rome")
    }

    @Test func prepare_romeKmz_pointCountMatchesKMLReader() throws {
        let data = try AppFixture.data("Rome.kmz")
        let parsed = try KMLReader.read(data: data)
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kmz")
        #expect(result.pointCount == parsed.document.pointCount)
    }

    @Test func prepare_romeKmz_embeddedResourcesContainIcons() throws {
        let data = try AppFixture.data("Rome.kmz")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kmz")
        #expect(!result.embeddedResources.isEmpty, "Rome.kmz should have embedded resources")
        // Rome.kmz is confirmed to contain "images/icon-1.png"
        #expect(result.embeddedResources["images/icon-1.png"] != nil,
                "Rome.kmz embedded resources should include images/icon-1.png")
    }

    @Test func prepare_romeKmz_noRemoteHrefs() throws {
        // Rome.kmz uses relative hrefs pointing to embedded images, not remote URLs
        let data = try AppFixture.data("Rome.kmz")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kmz")
        #expect(result.remoteResourceHrefs.isEmpty,
                "Rome.kmz icon hrefs are relative (archive paths), not remote http(s)")
    }

    @Test func prepare_romeKmz_sourceFilenamePreserved() throws {
        let data = try AppFixture.data("Rome.kmz")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kmz")
        #expect(result.sourceFilename == "Rome.kmz")
    }

    // MARK: - prepare — fallback displayName

    @Test func prepare_fallbackDisplayName_usesFilenameStem() throws {
        // A KML with no <Document><name> would fall back to the filename stem.
        // We test this by using a KML that does have a name, then verify the
        // stem fallback logic directly via a synthetic minimal KML.
        let minimalKML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <Placemark>
              <Point><coordinates>12.5,41.9,0</coordinates></Point>
            </Placemark>
          </Document>
        </kml>
        """.data(using: .utf8)!
        let result = try ImportService.prepare(data: minimalKML, sourceFilename: "my-trip.kml")
        #expect(result.displayName == "my-trip",
                "When document name is nil, display name should be the filename stem")
    }

    // MARK: - commit

    @Test func commit_createsOnDiskFolderAndOriginalFile() throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")

        let entry = try ImportService.commit(result, storage: storage, cache: stubCache())

        #expect(FileManager.default.fileExists(atPath: storage.folder(for: entry).path),
                "Entry folder must exist after commit")
        #expect(FileManager.default.fileExists(atPath: storage.originalFile(for: entry).path),
                "Original file must exist after commit")
    }

    @Test func commit_writesEmbeddedResourcesToDisk() throws {
        let storage = makeStorage()
        let cache = stubCache()
        let data = try AppFixture.data("Rome.kmz")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kmz")
        #expect(!result.embeddedResources.isEmpty)

        let entry = try ImportService.commit(result, storage: storage, cache: cache)

        let resourcesDir = storage.resourcesDirectory(for: entry)
        let manifestURL = resourcesDir.appendingPathComponent("manifest.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path),
                "manifest.json must exist after writing embedded resources")
        #expect(cache.localURL(forHref: "images/icon-1.png", in: resourcesDir) != nil,
                "images/icon-1.png should be resolvable from cache after commit")
    }

    @Test func commit_entryHasCorrectMetadata() throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")

        let entry = try ImportService.commit(result, storage: storage, cache: stubCache())

        #expect(entry.displayName == result.displayName)
        #expect(entry.sourceFilename == result.sourceFilename)
        #expect(entry.pointCount == result.pointCount)
        #expect(entry.contentSHA256 == result.contentSHA256)
        #expect(entry.storageFolderName == result.storageFolderName)
        #expect(!entry.isTrashed)
    }

    @Test func commit_entryIDEqualsFolderUUID() throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")

        let entry = try ImportService.commit(result, storage: storage, cache: stubCache())

        // UUID().uuidString is uppercase; compare case-insensitively.
        #expect(entry.id.uuidString.caseInsensitiveCompare(result.storageFolderName) == .orderedSame,
                "entry identity must equal its folder UUID")
    }

    @Test func commit_writesSidecarMatchingEntry() throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")

        let entry = try ImportService.commit(result, storage: storage, cache: stubCache())

        let sidecar = try storage.readMetadata(forFolderNamed: entry.storageFolderName)
        #expect(sidecar?.id == entry.id)
        #expect(sidecar?.contentSHA256 == entry.contentSHA256)
        #expect(sidecar?.displayName == entry.displayName)
        #expect(sidecar?.trashedAt == nil)
    }
}
