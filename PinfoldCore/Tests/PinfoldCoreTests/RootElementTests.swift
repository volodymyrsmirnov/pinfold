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

    @Test func upperCaseRootNamesAreAcceptedLikeVersion1_7() throws {
        let doc = try parse("<KML><Document><Placemark><name>U</name><Point><coordinates>1,2</coordinates></Point></Placemark></Document></KML>")
        #expect(doc.placemarkCount == 1)
        for root in ["DOCUMENT", "folder", "PLACEMARK", "Kml"] {
            _ = try parse("<\(root)><name>x</name></\(root)>")
        }
        let xml = "<KML><Document><Placemark><name>U</name></Placemark></Document></KML>"
        #expect(try KMLReader.detectFormat(of: Data(xml.utf8)) == .kml)
        #expect(try KMLReader.read(data: Data(xml.utf8)).document.placemarkCount == 1)
    }

    @Test func longLeadingCommentStillSniffsAsKML() throws {
        let comment = "<!--" + String(repeating: "x", count: 70 * 1024) + "-->"
        let xml = "<?xml version=\"1.0\"?>" + comment + "<kml><Document><Placemark><name>L</name>"
            + "<Point><coordinates>1,2</coordinates></Point></Placemark></Document></kml>"
        #expect(try KMLReader.detectFormat(of: Data(xml.utf8)) == .kml)
        #expect(try KMLReader.read(data: Data(xml.utf8)).document.placemarkCount == 1)
    }

    @Test func multiMegabytePrologStillSniffs() throws {
        let comment = "<!--" + String(repeating: "x", count: 3 * 1024 * 1024) + "-->"
        let xml = comment + "<gpx version=\"1.1\"><wpt lat=\"1\" lon=\"2\"/></gpx>"
        #expect(try KMLReader.detectFormat(of: Data(xml.utf8)) == .gpx)
    }

    @Test func prologOnlyInputIsUnsupported() {
        let xml = "<?xml version=\"1.0\"?><!--" + String(repeating: "x", count: 100_000) + "-->"
        #expect(throws: KMLReadError.self) { try KMLReader.detectFormat(of: Data(xml.utf8)) }
    }
}
