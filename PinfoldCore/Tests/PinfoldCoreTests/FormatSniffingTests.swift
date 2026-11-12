import Foundation
@testable import PinfoldCore
import Testing

struct FormatSniffingTests {
    private static let kml = """
    <kml xmlns="http://www.opengis.net/kml/2.2"><Document><Placemark><name>A</name>\
    <Point><coordinates>1,2,0</coordinates></Point></Placemark></Document></kml>
    """
    private static let gpx = """
    <?xml version="1.0"?><gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1">\
    <wpt lat="2" lon="1"><name>A</name></wpt></gpx>
    """
    private static let geoJSON = """
    {"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":{"name":"A"}}
    """

    @Test func kmlKmzGpxGeoJSONAreDetected() throws {
        #expect(try KMLReader.read(data: Data(Self.kml.utf8)).format == .kml)
        #expect(try KMLReader.read(data: Fixture.data("Rome.kmz")).format == .kmz)
        #expect(try KMLReader.detectFormat(of: Data(Self.gpx.utf8)) == .gpx)
        #expect(try KMLReader.detectFormat(of: Fixture.data("Rome.kmz")) == .kmz)
    }

    @Test func kmlRootVariantsAreKML() throws {
        for root in ["Document", "Folder", "Placemark"] {
            let xml = "<\(root)><name>x</name></\(root)>"
            #expect(try KMLReader.detectFormat(of: Data(xml.utf8)) == .kml)
        }
        let prefixed = "<?xml version=\"1.0\"?><!-- c --><!DOCTYPE kml><k:kml xmlns:k=\"x\"/>"
        #expect(try KMLReader.detectFormat(of: Data(prefixed.utf8)) == .kml)
    }

    @Test func geoJSONWithLeadingWhitespaceAndBOM() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("\n  \t".utf8) + Data(Self.geoJSON.utf8)
        #expect(try KMLReader.detectFormat(of: bom) == .geoJSON)
        #expect(try KMLReader.detectFormat(of: Data("  [ ]".utf8)) == .geoJSON)
    }

    @Test func unknownXMLRootIsUnsupported() {
        expectReadError(.unsupportedFormat) { try KMLReader.read(data: Data("<html/>".utf8)) }
        expectReadError(.unsupportedFormat) { try KMLReader.readDocument(data: Data("<html/>".utf8)) }
        expectReadError(.unsupportedFormat) { try KMLReader.read(data: Data("hello".utf8)) }
    }

    @Test func emptyInputIsUnsupported() {
        expectReadError(.unsupportedFormat) { try KMLReader.read(data: Data()) }
        expectReadError(.unsupportedFormat) { try KMLReader.readDocument(data: Data("  \n".utf8)) }
    }

    @Test func unsupportedFormatHasReadableMessage() {
        #expect(KMLReadError.unsupportedFormat.errorDescription?.contains("KML") == true)
    }

    @Test func sizeCapAppliesToEveryPlainFormat() {
        for text in [Self.gpx, Self.geoJSON, Self.kml] {
            expectReadError(.fileTooLarge) {
                try KMLReader.read(data: Data(text.utf8), maxPlainBytes: 10, maxArchiveBytes: 10)
            }
        }
    }
}

/// `KMLReadError` carries an arbitrary underlying `Error` in one case, so it is not Equatable;
/// compare the simple cases by their message.
func expectReadError(_ expected: KMLReadError, sourceLocation: SourceLocation = #_sourceLocation,
                     _ body: () throws -> some Any)
{
    do {
        _ = try body()
        Issue.record("expected \(expected) but nothing was thrown", sourceLocation: sourceLocation)
    } catch let error as KMLReadError {
        #expect(error.errorDescription == expected.errorDescription, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected \(expected) but got \(error)", sourceLocation: sourceLocation)
    }
}
