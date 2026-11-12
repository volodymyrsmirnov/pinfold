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

    // MARK: Gate G1 bypasses (A5, A7)

    private static let entityDecl = "<!ENTITY a \"x\">"

    @Test func processingInstructionContainingGreaterThan_cannotHideDoctype() {
        let input = "<?foo ><a ?><!DOCTYPE kml [\(Self.entityDecl)]>\n" + Self.body
        #expect(throws: KMLParseError.dtdProhibited) {
            try KMLParser.parse(data: Data(input.utf8))
        }
    }

    @Test func commentContainingMarkup_cannotHideDoctype() {
        let input = "<!-- <a> --><!DOCTYPE kml [\(Self.entityDecl)]>\n" + Self.body
        #expect(throws: KMLParseError.dtdProhibited) {
            try KMLParser.parse(data: Data(input.utf8))
        }
    }

    @Test func utf7Declaration_isRejectedAsUnsupportedEncoding() {
        let input = "<?xml version=\"1.0\" encoding=\"UTF-7\"?>+ADw-!DOCTYPE r +AFsAPA-!ENTITY a \"x\"+AD4-+AF0APg-"
            + Self.body
        #expect(throws: KMLParseError.unsupportedEncoding) {
            try KMLParser.parse(data: Data(input.utf8))
        }
    }

    /// Minimal IBM037 encoder for the ASCII characters the tests use (unknown -> space).
    private static func ebcdic037(_ text: String) -> Data {
        let punctuation: [Character: UInt8] = [
            " ": 0x40, ".": 0x4B, "<": 0x4C, "(": 0x4D, "+": 0x4E, "!": 0x5A, "*": 0x5C, ")": 0x5D,
            "-": 0x60, "/": 0x61, ",": 0x6B, "_": 0x6D, ">": 0x6E, "?": 0x6F, ":": 0x7A, "'": 0x7D,
            "=": 0x7E, "\"": 0x7F, "[": 0xBA, "]": 0xBB, "\n": 0x25,
        ]
        let rows: [(String, UInt8)] = [("abcdefghi", 0x81), ("jklmnopqr", 0x91), ("stuvwxyz", 0xA2),
                                       ("ABCDEFGHI", 0xC1), ("JKLMNOPQR", 0xD1), ("STUVWXYZ", 0xE2),
                                       ("0123456789", 0xF0)]
        var table = punctuation
        for (chars, base) in rows {
            for (offset, char) in chars.enumerated() {
                table[char] = base + UInt8(offset)
            }
        }
        return Data(text.map { table[$0] ?? 0x40 })
    }

    @Test func ebcdicInput_isRejectedAsUnsupportedEncoding() throws {
        let text = "<?xml version=\"1.0\" encoding=\"IBM037\"?><!DOCTYPE r [\(Self.entityDecl)]>" + Self.body
        let data = Self.ebcdic037(text)
        #expect(!data.contains(0x3C))
        #expect(throws: KMLParseError.unsupportedEncoding) {
            try KMLParser.parse(data: data)
        }
    }

    @Test(arguments: ["UTF-8", "utf-8", "US-ASCII", "ISO-8859-1", "iso-8859-15", "windows-1252", "Latin1"])
    func commonDeclaredEncodings_pass(_ name: String) throws {
        let doc = try KMLParser.parse(data: Data(("<?xml version=\"1.0\" encoding='\(name)'?>\n" + Self.body).utf8))
        #expect(doc.root.allPlacemarks.count == 1)
    }

    // MARK: Delegate defence in depth (below the byte guard)

    @Test(arguments: [
        "<!DOCTYPE kml [<!ENTITY a \"x\">]>",
        "<!DOCTYPE kml [<!ENTITY a SYSTEM \"x.bin\" NDATA gif>]>",
        "<!DOCTYPE kml [<!ELEMENT kml ANY>]>",
        "<!DOCTYPE kml [<!ATTLIST kml foo CDATA #IMPLIED>]>",
        "<!DOCTYPE kml [<!NOTATION gif SYSTEM \"x\">]>",
    ])
    func delegateAbortsOnAnyDeclaration(_ doctype: String) {
        // `parseUnguarded` skips the byte scan, so only the delegate callbacks can stop this.
        #expect(throws: KMLParseError.dtdProhibited) {
            try KMLParser.parseUnguarded(data: Data((doctype + "\n" + Self.body).utf8))
        }
    }

    @Test func externalEntityDeclaration_isRejectedByGuard() {
        // XMLParser does not report external entity declarations (shouldResolveExternalEntities
        // is false), so the byte guard is what stops these.
        #expect(throws: KMLParseError.dtdProhibited) {
            try parse("<!DOCTYPE kml [<!ENTITY a SYSTEM \"file:///etc/hosts\">]>")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func largeEntityReferenceDocument_isRejectedFast() {
        var input = "<!DOCTYPE kml [<!ENTITY a \"0123456789012345678901234567890123456789\">]>\n<kml><Document><name>"
        input += String(repeating: "&a;", count: 150_000)
        input += "</name></Document></kml>"
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            #expect(throws: KMLParseError.dtdProhibited) {
                try KMLParser.parse(data: Data(input.utf8))
            }
        }
        #expect(elapsed < .seconds(1))
    }
}
