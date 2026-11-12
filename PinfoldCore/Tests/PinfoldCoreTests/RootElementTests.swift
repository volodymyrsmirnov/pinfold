import Foundation
@testable import PinfoldCore
import Testing

/// CB-2 (A6): only KML roots are accepted.
struct RootElementTests {
    private func parse(_ xml: String) throws -> KMLDocument {
        try KMLParser.parse(data: Data(xml.utf8))
    }

    @Test func gpxRootIsRejected() {
        let xml = #"<?xml version="1.0"?><gpx version="1.1"><wpt lat="1" lon="2"><name>x</name></wpt></gpx>"#
        #expect(throws: KMLParseError.unsupportedRootElement("gpx")) { try parse(xml) }
    }

    @Test func htmlRootIsRejected() {
        let xml = "<html><body><p>hello</p></body></html>"
        #expect(throws: KMLParseError.unsupportedRootElement("html")) { try parse(xml) }
    }

    @Test func bareDocumentRootIsAccepted() throws {
        let doc = try parse("<Document><name>Bare</name><Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark></Document>")
        #expect(doc.name == "Bare")
        #expect(doc.placemarkCount == 1)
    }

    @Test func bareFolderRootIsAccepted() throws {
        let doc = try parse("<Folder><name>F</name><Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark></Folder>")
        #expect(doc.name == "F")
        #expect(doc.placemarkCount == 1)
    }

    @Test func barePlacemarkRootIsAccepted() throws {
        let doc = try parse("<Placemark><name>Solo</name><Point><coordinates>1,2</coordinates></Point></Placemark>")
        #expect(doc.placemarkCount == 1)
        #expect(doc.root.allPlacemarks.first?.name == "Solo")
    }

    @Test func prefixedKmlRootIsAccepted() throws {
        let doc = try parse("""
        <k:kml xmlns:k="http://www.opengis.net/kml/2.2"><k:Document><k:name>Pre</k:name>
        <k:Placemark><k:name>P</k:name><k:Point><k:coordinates>1,2</k:coordinates></k:Point></k:Placemark>
        </k:Document></k:kml>
        """)
        #expect(doc.name == "Pre")
        #expect(doc.placemarkCount == 1)
    }
}
