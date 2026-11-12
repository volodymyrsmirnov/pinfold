import Foundation
@testable import PinfoldCore
import Testing

struct XMLPreflightTests {
    private static let body = """
    <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Doc é</name>\
    <Placemark><name>Spot</name><Point><coordinates>1,2,0</coordinates></Point></Placemark>\
    </Document></kml>
    """

    private static func declaration(_ encoding: String) -> String {
        "<?xml version=\"1.0\" encoding=\"\(encoding)\"?>\n"
    }

    private static func utf16(_ text: String, bigEndian: Bool, bom: Bool) -> Data {
        var data = Data()
        var units = Array(text.utf16)
        if bom {
            units.insert(0xFEFF, at: 0)
        }
        for unit in units {
            let hi = UInt8(unit >> 8), lo = UInt8(unit & 0xFF)
            data.append(contentsOf: bigEndian ? [hi, lo] : [lo, hi])
        }
        return data
    }

    private static func utf32(_ text: String, bigEndian: Bool) -> Data {
        var data = Data()
        for scalar in [UnicodeScalar(0xFEFF)!] + Array(text.unicodeScalars) {
            let value = scalar.value
            let bytes = (0 ..< 4).map { UInt8((value >> UInt32(24 - 8 * $0)) & 0xFF) }
            data.append(contentsOf: bigEndian ? bytes : bytes.reversed())
        }
        return data
    }

    private func expectParses(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let doc = try KMLParser.parse(data: data)
        #expect(doc.root.name == "Doc é", sourceLocation: sourceLocation)
        #expect(doc.root.allPlacemarks.count == 1, sourceLocation: sourceLocation)
    }

    @Test func leadingWhitespaceBeforeDeclaration_parses() throws {
        try expectParses(Data(("\n  \t" + Self.declaration("UTF-8") + Self.body).utf8))
    }

    @Test func leadingBOMThenNewlines_parses() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(("\r\n\n" + Self.declaration("UTF-8") + Self.body).utf8))
        try expectParses(data)
    }

    @Test func controlCharactersInTextAndCDATA_areStripped() throws {
        let xml = "<kml><Document><name>A\u{1}B</name><Placemark><name>P</name>"
            + "<description><![CDATA[x\u{8}y\u{0}z\u{1F}]]></description></Placemark></Document></kml>"
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        #expect(doc.root.name == "AB")
        #expect(doc.root.allPlacemarks.first?.descriptionHTML == "xyz")
    }

    @Test func tabNewlineCarriageReturn_arePreserved() throws {
        let input = Data("<a>x\ty\nz\rw</a>".utf8)
        #expect(try XMLPreflight.normalize(input) == input)
    }

    @Test func utf16LEWithBOM_parsesToSameDocumentAsUTF8() throws {
        let text = Self.declaration("UTF-16") + Self.body
        let wide = try KMLParser.parse(data: Self.utf16(text, bigEndian: false, bom: true))
        let narrow = try KMLParser.parse(data: Data((Self.declaration("UTF-8") + Self.body).utf8))
        #expect(wide.root.name == narrow.root.name)
        #expect(wide.root.allPlacemarks.map(\.name) == narrow.root.allPlacemarks.map(\.name))
        #expect(wide.root.allPlacemarks.first?.coordinate == narrow.root.allPlacemarks.first?.coordinate)
    }

    @Test func utf16BEWithBOM_parses() throws {
        try expectParses(Self.utf16(Self.declaration("UTF-16") + Self.body, bigEndian: true, bom: true))
    }

    @Test func utf16WithoutBOM_parses() throws {
        let text = Self.declaration("UTF-16") + Self.body
        try expectParses(Self.utf16(text, bigEndian: false, bom: false))
        try expectParses(Self.utf16(text, bigEndian: true, bom: false))
        try expectParses(Self.utf16("\n" + text, bigEndian: false, bom: false))
    }

    @Test func utf32WithBOM_parses() throws {
        let text = Self.declaration("UTF-32") + Self.body
        try expectParses(Self.utf32(text, bigEndian: false))
        try expectParses(Self.utf32(text, bigEndian: true))
    }

    @Test func utf16WithInternalSubsetDoctype_isRejected() {
        let text = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<!DOCTYPE kml [<!ENTITY a \"x\">]>\n" + Self.body
        for bigEndian in [false, true] {
            #expect(throws: KMLParseError.dtdProhibited) {
                try KMLParser.parse(data: Self.utf16(text, bigEndian: bigEndian, bom: true))
            }
        }
        #expect(throws: KMLParseError.dtdProhibited) {
            try KMLParser.parse(data: Self.utf16(text, bigEndian: false, bom: false))
        }
        #expect(throws: KMLParseError.dtdProhibited) {
            try KMLParser.parse(data: Self.utf32(text, bigEndian: false))
        }
    }

    @Test func undecodableUTF16_throwsUnsupportedEncoding() {
        // BOM, then a lone high surrogate.
        let data = Data([0xFF, 0xFE, 0x00, 0xD8, 0x3C, 0x00])
        #expect(throws: KMLParseError.unsupportedEncoding) {
            try XMLPreflight.normalize(data)
        }
    }

    @Test func cleanInput_isReturnedByteIdentical() throws {
        let input = Data((Self.declaration("UTF-8") + Self.body).utf8)
        #expect(try XMLPreflight.normalize(input) == input)
    }

    @Test func strayLeadingNULInUTF8_isStrippedNotMisdetectedAsUTF16() throws {
        try expectParses(Data(("\u{0}" + Self.declaration("UTF-8") + Self.body).utf8))
    }

    @Test func deniedDeclaredEncoding_isUnsupported() {
        let names = ["UTF-7", "IBM037", "ibm-037", "EBCDIC-US", "cp500", "cp1140", "IBM1047", "ISO-2022-JP", "HZ-GB-2312",
                     "UCS-2", "UCS-4", "UTF-16", "UTF-16LE", "UTF-32", "UTF-32BE", "BOCU-1", "SCSU", "x-EBCDIC-KoreanExtended"]
        for name in names {
            let input = Data((Self.declaration(name) + Self.body).utf8)
            #expect(throws: KMLParseError.unsupportedEncoding) { try XMLPreflight.normalize(input) }
        }
    }

    @Test func firstNonWhitespaceByteMustBeLessThan() {
        #expect(throws: KMLParseError.unsupportedEncoding) {
            try XMLPreflight.normalize(Data([0x4C, 0x6F, 0xA7, 0x94]))
        }
    }

    @Test func declaredEncoding_acceptsEveryAsciiCompatibleName() throws {
        let names = ["utf-8", "ISO-8859-2", "windows-1251", "latin1", "US-ASCII", "ASCII", "Shift_JIS", "x-sjis",
                     "EUC-JP", "EUC-KR", "GB2312", "GBK", "Big5", "KOI8-R", "cp1252", "cp437", "cp850", "macintosh",
                     "ISO_8859-1", "ISO-8859-15", "IBM850"]
        for name in names {
            let input = Data((Self.declaration(name) + Self.body).utf8)
            #expect(try XMLPreflight.normalize(input) == input, "\(name)")
        }
    }

    private static func cfEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    @Test func legacyEncodingDeclarationsWithMatchingBytes_parse() throws {
        let cases: [(String, String.Encoding, String)] = [
            ("Shift_JIS", .shiftJIS, "日本語"), ("x-sjis", .shiftJIS, "日本語"), ("EUC-JP", .japaneseEUC, "日本語"),
            ("GBK", Self.cfEncoding(.GBK_95), "中文"), ("Big5", Self.cfEncoding(.big5), "中文"),
            ("KOI8-R", Self.cfEncoding(.KOI8_R), "Привет"), ("EUC-KR", Self.cfEncoding(.EUC_KR), "한국"),
            ("macintosh", .macOSRoman, "Café"), ("ISO_8859-1", .isoLatin1, "Café"),
            ("cp1252", .windowsCP1252, "Café €"),
        ]
        for (name, encoding, title) in cases {
            let xml = Self.declaration(name) + "<kml><Document><name>\(title)</name></Document></kml>"
            let data = try #require(xml.data(using: encoding), "\(name)")
            let doc = try KMLParser.parse(data: data)
            #expect(doc.root.name == title, "\(name)")
        }
    }
}
