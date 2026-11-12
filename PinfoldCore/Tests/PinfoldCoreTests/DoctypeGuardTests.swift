import Foundation
@testable import PinfoldCore
import Testing

struct DoctypeGuardTests {
    private static let body = """
    <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Doc</name>\
    <Placemark><name>Spot</name><Point><coordinates>1,2,0</coordinates></Point></Placemark>\
    </Document></kml>
    """

    private func parse(_ prolog: String, body: String = DoctypeGuardTests.body) throws -> KMLDocument {
        try KMLParser.parse(data: Data((prolog + "\n" + body).utf8))
    }

    @Test func doctypeWithoutSubset_isAccepted() throws {
        let doc = try parse("<?xml version=\"1.0\"?>\n<!DOCTYPE kml>")
        #expect(doc.root.allPlacemarks.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func doctypeWithPublicIdAndNoSubset_isAcceptedWithoutFetching() throws {
        // Port 9 (discard) on loopback: a fetch attempt would fail or hang, never succeed.
        let doctype = "<!DOCTYPE kml PUBLIC \"-//x//DTD KML//EN\" \"http://127.0.0.1:9/kml.dtd\">"
        let clock = ContinuousClock()
        var doc: KMLDocument?
        let elapsed = try clock.measure { doc = try parse(doctype) }
        #expect(doc?.root.allPlacemarks.count == 1)
        #expect(elapsed < .seconds(5))
        let system = "<!DOCTYPE kml SYSTEM \"http://127.0.0.1:9/kml.dtd\">"
        #expect(try parse(system).root.allPlacemarks.count == 1)
    }

    @Test func doctypeWithSubset_isRejected() {
        #expect(throws: KMLParseError.dtdProhibited) {
            try parse("<!DOCTYPE kml [<!ENTITY a \"x\">]>")
        }
    }

    @Test func subsetAfterQuotedGreaterThan_isRejected() {
        #expect(throws: KMLParseError.dtdProhibited) {
            try parse("<!DOCTYPE kml SYSTEM \"a>b\" [<!ENTITY a \"x\">]>")
        }
    }

    @Test func bracketInsideQuotedLiteral_isRejected() {
        #expect(throws: KMLParseError.dtdProhibited) {
            try parse("<!DOCTYPE kml SYSTEM \"a[b\">")
        }
    }

    @Test func subsetOnLaterLine_isRejected() {
        #expect(throws: KMLParseError.dtdProhibited) {
            try parse("<!DOCTYPE kml\n  PUBLIC \"-//x//EN\"\n  \"kml.dtd\"\n\n  [\n<!ENTITY a \"x\">\n]>")
        }
    }

    @Test func unterminatedDoctype_isRejected() {
        #expect(throws: KMLParseError.dtdProhibited) {
            try KMLParser.parse(data: Data("<!DOCTYPE kml".utf8))
        }
        #expect(throws: KMLParseError.dtdProhibited) {
            try KMLParser.parse(data: Data("<!DOCTYPE kml SYSTEM \"unclosed>".utf8))
        }
    }

    @Test func secondDoctypeWithSubset_isRejected() {
        #expect(throws: KMLParseError.dtdProhibited) {
            try parse("<!DOCTYPE kml>\n<!DOCTYPE kml [<!ENTITY a \"x\">]>")
        }
    }

    @Test func lowercaseDoctypeWithSubset_isRejected() {
        #expect(throws: KMLParseError.dtdProhibited) {
            try parse("<!doctype kml [<!ENTITY a \"x\">]>")
        }
    }

    @Test func undefinedEntityWithHarmlessDoctype_failsAsMalformedNotExpanded() {
        let body = "<kml><Document><name>&a;</name></Document></kml>"
        do {
            _ = try parse("<!DOCTYPE kml>", body: body)
            Issue.record("expected a parse error")
        } catch KMLParseError.malformedXML {
            // expected: the entity is undefined, so it is an error rather than expanded
        } catch {
            Issue.record("expected malformedXML, got \(error)")
        }
    }
}
