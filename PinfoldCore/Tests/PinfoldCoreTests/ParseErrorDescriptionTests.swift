import Foundation
@testable import PinfoldCore
import Testing

struct ParseErrorDescriptionTests {
    private func describe(_ error: KMLParseError) -> String {
        error.errorDescription ?? ""
    }

    @Test func malformedXML_withLine_prefixesLineAndMapsCode() {
        let code = XMLParser.ErrorCode.tagNameMismatchError.rawValue
        let error = KMLParseError.malformedXML(line: 12, column: 3, detail: "x", code: code)
        #expect(describe(error) == "Line 12: a tag is not closed.")
        #expect(error.localizedDescription == "Line 12: a tag is not closed.")
    }

    @Test func malformedXML_withoutLine_hasNoPrefix() {
        let code = XMLParser.ErrorCode.emptyDocumentError.rawValue
        let error = KMLParseError.malformedXML(line: 0, column: 0, detail: "x", code: code)
        #expect(describe(error) == "The file is empty.")
    }

    @Test func malformedXML_unknownCode_usesGenericReason() {
        let error = KMLParseError.malformedXML(line: 4, column: 1, detail: "x", code: 9999)
        #expect(describe(error) == "Line 4: the file is not valid XML.")
    }

    @Test func dtdProhibited() {
        #expect(describe(.dtdProhibited)
            == "This file declares entities in a DTD, which Pinfold does not open.")
    }

    @Test func unsupportedRootElement() {
        #expect(describe(.unsupportedRootElement("gpx"))
            == "This is not a KML file (it starts with <gpx>).")
    }

    @Test func unsupportedEncoding() {
        #expect(describe(.unsupportedEncoding)
            == "This file uses a text encoding Pinfold cannot read.")
    }

    @Test func noDescriptionMentionsNSXMLParserErrorDomain() {
        let cases: [KMLParseError] = [
            .malformedXML(line: 1, column: 1, detail: "NSXMLParserErrorDomain code 111", code: 111),
            .dtdProhibited, .unsupportedRootElement("html"), .unsupportedEncoding,
        ]
        for error in cases {
            #expect(!describe(error).contains("NSXMLParserErrorDomain"))
            #expect(!describe(error).contains("code 111"))
        }
    }

    @Test func truncatedDocument_descriptionCarriesLineNumber() {
        let xml = "<?xml version=\"1.0\"?>\n<kml>\n<Document>\n<name>Cut</name>\n<Placemark><name>P"
        do {
            _ = try KMLParser.parse(data: Data(xml.utf8))
            Issue.record("expected a parse error")
        } catch {
            let text = error.localizedDescription
            #expect(text.hasPrefix("Line "), "got: \(text)")
            #expect(!text.contains("NSXMLParserErrorDomain"))
        }
    }
}
