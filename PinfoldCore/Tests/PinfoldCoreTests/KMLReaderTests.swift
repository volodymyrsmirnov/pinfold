import Foundation
@testable import PinfoldCore
import Testing
import ZIPFoundation

struct KMLReaderTests {
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

    @Test func read_kmzWithMalformedRootKMLMentionsEntry() throws {
        // doc.kml truncated mid-element so XMLParser fails; the wrapping error must name the
        // archive entry that failed.
        let truncated = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document><name>Bad
        """.utf8)
        let zip = try makeZip([("doc.kml", truncated)])
        do {
            _ = try KMLReader.read(data: zip)
            Issue.record("expected a read error")
        } catch {
            #expect(String(describing: error).contains("doc.kml"))
        }
    }

    @Test func readsPlainKML() throws {
        let parsed = try KMLReader.read(data: Fixture.data("Rome.kml"))
        #expect(parsed.document.name == "Rome")
        #expect(parsed.embeddedResources.isEmpty)
        #expect(parsed.document.pointCount > 0)
    }

    @Test func readsKMZWithResources() throws {
        let parsed = try KMLReader.read(data: Fixture.data("Rome.kmz"))
        #expect(parsed.document.name == "Rome")
        #expect(parsed.embeddedResources.keys.contains("images/icon-1.png"))
    }

    @Test func kmlAndKmzProduceSamePlacemarkCount() throws {
        let fromKML = try KMLReader.read(data: Fixture.data("Rome.kml"))
        let fromKMZ = try KMLReader.read(data: Fixture.data("Rome.kmz"))
        #expect(fromKML.document.placemarkCount == fromKMZ.document.placemarkCount)
    }

    @Test func kmzReadExposesRootKMLPath() throws {
        let parsed = try KMLReader.read(data: Fixture.data("Rome.kmz"))
        #expect(parsed.rootKMLPath == "doc.kml")
    }

    @Test func plainKMLReadHasNilRootKMLPath() throws {
        let parsed = try KMLReader.read(data: Fixture.data("Rome.kml"))
        #expect(parsed.rootKMLPath == nil)
    }
}
