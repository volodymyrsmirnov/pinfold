import Foundation
import os
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

    @Test func prepare_romeKml_formatIsKML() throws {
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        #expect(result.format == .kml)
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

    @Test func prepare_romeKmz_formatIsKMZ() throws {
        let data = try AppFixture.data("Rome.kmz")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kmz")
        #expect(result.format == .kmz)
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

    // MARK: - prepare — filename sanitization

    @Test func prepare_sanitizesSourceFilename() throws {
        let minimalKML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <Placemark>
              <Point><coordinates>12.5,41.9,0</coordinates></Point>
            </Placemark>
          </Document>
        </kml>
        """
        let result = try ImportService.prepare(data: Data(minimalKML.utf8), sourceFilename: "a/b.kml")
        #expect(result.sourceFilename == "b.kml",
                "prepare must sanitize attacker-controlled filenames to a final path component")
    }

    // MARK: - prepare — description images (D1)

    private func kml(descriptions: [String]) -> Data {
        let placemarks = descriptions.map {
            "<Placemark><description><![CDATA[\($0)]]></description>"
                + "<Point><coordinates>1,2,0</coordinates></Point></Placemark>"
        }.joined()
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document>\(placemarks)</Document></kml>
        """.utf8)
    }

    @Test func descriptionImagesAreGatheredAsRemoteHrefs() throws {
        let data = kml(descriptions: [
            #"<p>a</p><img src=" https://x.test/a.jpg "/><img src="http://y.test/b.png">"#,
            #"<img src="https://x.test/a.jpg"><img src="https://z.test/c.jpg">"#,
        ])
        let result = try ImportService.prepare(data: data, sourceFilename: "d.kml")
        // Recorded under the exact (trimmed) string DescriptionView looks up in the manifest.
        #expect(result.remoteResourceHrefs == ["http://y.test/b.png", "https://x.test/a.jpg", "https://z.test/c.jpg"])
    }

    @Test func upperCaseSchemesAreGatheredUnderTheirOriginalString() throws {
        let data = kml(descriptions: [#"<img src="HTTP://X.test/a.jpg"><img src="Https://y.test/b.png">"#])
        let result = try ImportService.prepare(data: data, sourceFilename: "d.kml")
        #expect(result.remoteResourceHrefs == ["HTTP://X.test/a.jpg", "Https://y.test/b.png"])
    }

    @Test func nonHTTPImageSourcesAreIgnored() throws {
        let data = kml(descriptions: [
            #"<img src="photo.jpg"><img src="data:image/png;base64,AAAA"><img src="javascript:alert(1)">"#
                + #"<img src="file:///etc/passwd">"#,
        ])
        let result = try ImportService.prepare(data: data, sourceFilename: "d.kml")
        #expect(result.remoteResourceHrefs.isEmpty)
    }

    @Test func descriptionImageHrefsRespectTheCap() throws {
        let imgs = (0 ..< 600).map { "<img src=\"https://x.test/\($0).jpg\">" }.joined()
        let result = try ImportService.prepare(data: kml(descriptions: [imgs]), sourceFilename: "d.kml")
        #expect(result.remoteResourceHrefs.count == 500)
    }

    @Test func commit_stampsTheIndexWithSourceAndCurrentVersion() throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        let entry = try ImportService.commit(result, storage: storage, cache: stubCache())
        let resourcesDir = storage.resourcesDirectory(for: entry)
        #expect(PlacemarkIndex.sourceStamp(in: resourcesDir) == result.contentSHA256)
        #expect(PlacemarkIndex.derivedDataIsCurrent(in: resourcesDir))
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

    @Test func commit_writesPlacemarkIndex() throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        #expect(!result.indexEntries.isEmpty, "prepare must build the index entries")

        let entry = try ImportService.commit(result, storage: storage, cache: stubCache())

        let resourcesDir = storage.resourcesDirectory(for: entry)
        let onDisk = PlacemarkIndex.read(from: resourcesDir)
        #expect(onDisk != nil, "placemarks-index.json must exist after commit")
        #expect(onDisk?.count == result.indexEntries.count)
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

    // MARK: - Failure cleanup (B8, E3)

    /// Plants a non-empty directory at `path`, so a file write to that path fails.
    private func blockPath(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: path.appendingPathComponent("blocker"))
    }

    private func folderNames(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
    }

    @Test func commit_originalWriteFails_removesFolderAndCache() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storage = StorageLocations(
            root: base.appendingPathComponent("synced", isDirectory: true),
            cacheRoot: base.appendingPathComponent("cache", isDirectory: true)
        )
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        let folder = storage.root.appendingPathComponent(result.storageFolderName, isDirectory: true)
        try blockPath(folder.appendingPathComponent(result.sourceFilename))

        #expect(throws: (any Error).self) {
            try ImportService.commit(result, storage: storage, cache: stubCache())
        }

        #expect(folderNames(in: storage.root).isEmpty, "the half-written entry folder must be removed")
        #expect(folderNames(in: storage.cacheRoot).isEmpty, "the entry's cache folder must be removed")
    }

    @Test func commit_cacheWriteFails_importSucceedsAndMarkerIsRemoved() throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        // Block the search-index file so the cache write fails.
        let resources = storage.root
            .appendingPathComponent(result.storageFolderName, isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)
        // Block both the v1 and v2 index names so this works whichever the writer uses.
        for name in ["placemarks-index.json", "placemarks-index.v2.json"] {
            try blockPath(resources.appendingPathComponent(name))
        }

        let entry = try ImportService.commit(result, storage: storage, cache: stubCache())

        #expect(FileManager.default.fileExists(atPath: storage.originalFile(for: entry).path))
        #expect(try storage.readMetadata(forFolderNamed: entry.storageFolderName) != nil)
        // `resources/` is the "materialized" marker: removing it lets the scanner rebuild it.
        #expect(!FileManager.default.fileExists(atPath: storage.resourcesDirectory(for: entry).path))
    }

    @Test func retryAfterFailedCommit_createsExactlyOneEntry() throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        let blocker = storage.root
            .appendingPathComponent(result.storageFolderName, isDirectory: true)
            .appendingPathComponent(result.sourceFilename)
        try blockPath(blocker)

        #expect(throws: (any Error).self) {
            try ImportService.commit(result, storage: storage, cache: stubCache())
        }
        #expect(folderNames(in: storage.root).isEmpty)

        // The retry (same result) now succeeds and leaves exactly one folder.
        let entry = try ImportService.commit(result, storage: storage, cache: stubCache())
        #expect(folderNames(in: storage.root) == [entry.storageFolderName])
    }

    // MARK: - Off the main actor (B11)

    @Test func commit_runsOffTheMainActor() async throws {
        let storage = makeStorage()
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kml")
        let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)

        let entry = try await ImportService.commitOffMain(result, storage: storage, cache: stubCache()) {
            ranOnMain.withLock { $0 = Thread.isMainThread }
        }

        #expect(ranOnMain.withLock { $0 } == false)
        #expect(FileManager.default.fileExists(atPath: storage.originalFile(for: entry).path))
    }

    // MARK: - Stored filename (G1)

    @Test func storedFilename_keepsSupportedExtensions() {
        #expect(ImportFormats.storedFilename(for: "a.kml", data: Data()) == "a.kml")
        #expect(ImportFormats.storedFilename(for: "A.KMZ", data: Data()) == "A.KMZ")
    }

    @Test func storedFilename_appendsExtensionByContent() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x00])
        #expect(ImportFormats.storedFilename(for: "trip", data: zip) == "trip.kmz")
        #expect(ImportFormats.storedFilename(for: "trip.txt", data: Data("<kml/>".utf8)) == "trip.txt.kml")
    }

    @Test func storedFilename_renamesReservedSidecarName() {
        #expect(ImportFormats.storedFilename(for: "metadata.json", data: Data("<kml/>".utf8)) == "metadata.kml")
        #expect(ImportFormats.storedFilename(for: "Metadata.JSON", data: Data("x".utf8)) == "Metadata.kml")
    }

    @Test func prepare_fileWithoutExtension_isStoredWithSupportedExtension() throws {
        let data = try AppFixture.data("Rome.kml")
        let result = try ImportService.prepare(data: data, sourceFilename: "shared-file")
        #expect(result.sourceFilename == "shared-file.kml")
        let sidecarNamed = try ImportService.prepare(data: data, sourceFilename: "metadata.json")
        #expect(sidecarNamed.sourceFilename == "metadata.kml")
    }

    // MARK: - Streamed extraction (A10b)

    /// The manifest must map each archive key to `cachedFilename(for:)`, the scheme
    /// `localURL(forHref:in:)` and existing entries rely on, with the bytes of the archive entry.
    @Test func commit_romeKmz_manifestUsesCachedFilenameScheme() throws {
        let storage = makeStorage()
        let cache = stubCache()
        let data = try AppFixture.data("Rome.kmz")
        let expected = try KMLReader.read(data: data).embeddedResources
        let result = try ImportService.prepare(data: data, sourceFilename: "Rome.kmz")

        let entry = try ImportService.commit(result, storage: storage, cache: cache)

        let resourcesDir = storage.resourcesDirectory(for: entry)
        let manifest = ResourceManifestStore.shared.manifest(in: resourcesDir)
        #expect(Set(manifest.keys) == Set(expected.keys))
        for (key, bytes) in expected {
            #expect(manifest[key] == cache.cachedFilename(for: key))
            let written = try Data(contentsOf: resourcesDir.appendingPathComponent(cache.cachedFilename(for: key)))
            #expect(written == bytes)
        }
        #expect(cache.localURL(forHref: "images/icon-1.png", in: resourcesDir) != nil)
    }

    // MARK: - Readable errors (A8c)

    @Test func importError_passesUnderlyingDescriptionThrough() {
        let underlying = KMLReadError.fileTooLarge
        let error = ImportError.parseFailure(underlying: underlying)
        #expect(error.localizedDescription == underlying.localizedDescription)
    }

    @Test func importError_withoutReadableUnderlyingFallsBackToGenericReason() {
        let raw = NSError(domain: "NSXMLParserErrorDomain", code: 4)
        let error = ImportError.parseFailure(underlying: raw)
        #expect(error.localizedDescription == ImportFormats.invalidFileReason)
        #expect(!error.localizedDescription.contains("NSXMLParserErrorDomain"))
    }

    @Test func prepare_garbage_throwsReadableError() {
        do {
            _ = try ImportService.prepare(data: Data("garbage not kml".utf8), sourceFilename: "bad.kml")
            Issue.record("expected a parse failure")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
            #expect(!error.localizedDescription.contains("NSXMLParserErrorDomain"))
        }
    }

    // MARK: - Formats (FM-1)

    @Test func gpxImports() throws {
        let data = try FormatFixture.gpx()
        let result = try ImportService.prepare(data: data, sourceFilename: "sample.gpx")
        #expect(result.format == .gpx)
        #expect(result.sourceFilename == "sample.gpx")
        #expect(result.displayName == "Sample Hike")
        #expect(result.pointCount > 0)
        let bare = try ImportService.prepare(data: data, sourceFilename: "hike")
        #expect(bare.sourceFilename == "hike.gpx")
    }

    @Test func geoJSONImports() throws {
        let data = try AppFixture.data("sample.geojson")
        let result = try ImportService.prepare(data: data, sourceFilename: "sample.geojson")
        #expect(result.format == .geoJSON)
        #expect(result.sourceFilename == "sample.geojson")
        #expect(result.pointCount > 0)
        #expect(try ImportService.prepare(data: data, sourceFilename: "places.json").sourceFilename == "places.json")
        #expect(try ImportService.prepare(data: data, sourceFilename: "places").sourceFilename == "places.geojson")
        let txt = try ImportService.prepare(data: data, sourceFilename: "places.txt")
        #expect(txt.sourceFilename == "places.txt.geojson")
    }

    @Test func jsonNamedMetadataIsRenamed() throws {
        let data = try AppFixture.data("sample.geojson")
        let result = try ImportService.prepare(data: data, sourceFilename: "metadata.json")
        #expect(result.sourceFilename == "metadata.geojson")
        let upper = try ImportService.prepare(data: data, sourceFilename: "Metadata.JSON")
        #expect(upper.sourceFilename.lowercased() != "metadata.json")
        #expect(ImportFormats.originalExtensions.isSuperset(of: ["gpx", "geojson", "json"]))
    }
}
