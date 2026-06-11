import Foundation
@testable import PinfoldCore
import Testing
import ZIPFoundation

struct KMZArchiveTests {
    /// Builds an in-memory zip archive containing the given entries.
    private func makeZip(_ entries: [(path: String, data: Data)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file,
                                 uncompressedSize: Int64(data.count))
            { position, size in
                data.subdata(in: Int(position) ..< (Int(position) + size))
            }
        }
        return archive.data!
    }

    private var minimalKML: Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document><name>Zipped</name></Document>
        </kml>
        """.utf8)
    }

    @Test func extract_skipsPathTraversalEntries() throws {
        let zip = try makeZip([
            ("../evil.png", Data([0x01, 0x02])),
            ("/abs.png", Data([0x03, 0x04])),
            ("doc.kml", minimalKML),
        ])
        let contents = try KMZArchive.extract(zip)
        #expect(contents.resources["../evil.png"] == nil)
        #expect(contents.resources["/abs.png"] == nil)
        // Parsing the root KML still succeeds despite the skipped entries.
        let doc = try KMLParser.parse(data: contents.rootKML)
        #expect(doc.name == "Zipped")
    }

    @Test func extract_normalizesDotSegments() throws {
        let zip = try makeZip([
            ("images/./icon.png", Data([0x05, 0x06])),
            ("doc.kml", minimalKML),
        ])
        let contents = try KMZArchive.extract(zip)
        #expect(contents.resources.keys.contains("images/icon.png"))
        #expect(contents.resources.keys.allSatisfy { key in
            !key.split(separator: "/").contains("..")
        })
    }

    @Test func detectsKMZMagic() throws {
        #expect(try KMZArchive.isKMZ(Fixture.data("Rome.kmz")) == true)
        #expect(try KMZArchive.isKMZ(Fixture.data("Rome.kml")) == false)
    }

    @Test func extractsRootKMLAndResources() throws {
        let contents = try KMZArchive.extract(Fixture.data("Rome.kmz"))
        let doc = try KMLParser.parse(data: contents.rootKML)
        #expect(doc.name == "Rome")
        #expect(contents.resources.keys.contains("images/icon-1.png"))
        #expect(contents.resources["images/icon-1.png"]?.isEmpty == false)
    }

    @Test func munichKMZHasFiveIconResources() throws {
        let contents = try KMZArchive.extract(Fixture.data("Munich Sole.kmz"))
        let icons = contents.resources.keys.filter { $0.hasPrefix("images/") }
        #expect(icons.count == 5)
    }

    @Test func rootKMLPathIsExposedOnContents() throws {
        let contents = try KMZArchive.extract(Fixture.data("Rome.kmz"))
        #expect(contents.rootKMLPath == "doc.kml")
    }

    @Test func extractThrowsNotAZipArchiveForPlainKML() throws {
        #expect(throws: KMZArchiveError.notAZipArchive) {
            try KMZArchive.extract(Fixture.data("Rome.kml"))
        }
    }

    @Test func isKMZReturnsFalseForEmptyData() {
        #expect(KMZArchive.isKMZ(Data()) == false)
    }

    @Test func extractRejectsArchiveExceedingByteCap() throws {
        #expect(throws: KMZArchiveError.archiveTooLarge) {
            try KMZArchive.extract(Fixture.data("Rome.kmz"), maxUncompressedBytes: 8)
        }
    }

    @Test func extractRejectsArchiveExceedingEntryCap() throws {
        #expect(throws: KMZArchiveError.archiveTooLarge) {
            try KMZArchive.extract(Fixture.data("Rome.kmz"), maxEntryCount: 0)
        }
    }

    @Test func extractSucceedsWithinDefaultCaps() throws {
        // The generous defaults must never reject a normal archive.
        let contents = try KMZArchive.extract(Fixture.data("Rome.kmz"))
        #expect(contents.resources.isEmpty == false)
    }

    @Test func read_nestedRootKML_resourceKeysAreRootRelative() throws {
        // Root KML lives in `folder/`; its Style references `icons/pin.png`, which in the
        // archive is `folder/icons/pin.png`. Consumers look the resource up by the href as
        // written in the KML (root-relative), so the embeddedResources key must be
        // `icons/pin.png`, not the raw `folder/icons/pin.png`.
        let nestedKML = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>Nested</name>
            <Style id="s"><IconStyle><Icon><href>icons/pin.png</href></Icon></IconStyle></Style>
          </Document>
        </kml>
        """.utf8)
        let zip = try makeZip([
            ("folder/doc.kml", nestedKML),
            ("folder/icons/pin.png", Data([0xAA, 0xBB])),
            ("other/x.png", Data([0xCC, 0xDD])),
        ])
        let parsed = try KMLReader.read(data: zip)
        #expect(parsed.rootKMLPath == "folder/doc.kml")
        // Key under the root KML's directory is remapped to root-relative.
        #expect(parsed.embeddedResources["icons/pin.png"] == Data([0xAA, 0xBB]))
        #expect(parsed.embeddedResources["folder/icons/pin.png"] == nil)
        // Sibling entry outside the root dir keeps its raw archive path.
        #expect(parsed.embeddedResources["other/x.png"] == Data([0xCC, 0xDD]))
        // No remapped key introduces a traversal component.
        #expect(parsed.embeddedResources.keys.allSatisfy { key in
            !key.split(separator: "/").contains("..")
        })
    }

    @Test func read_topLevelRootKML_resourceKeysUnchanged() throws {
        // The common case: a top-level root KML is a no-op — keys stay raw.
        let zip = try makeZip([
            ("doc.kml", minimalKML),
            ("images/icon.png", Data([0x01, 0x02])),
        ])
        let parsed = try KMLReader.read(data: zip)
        #expect(parsed.rootKMLPath == "doc.kml")
        #expect(parsed.embeddedResources["images/icon.png"] == Data([0x01, 0x02]))
    }
}
