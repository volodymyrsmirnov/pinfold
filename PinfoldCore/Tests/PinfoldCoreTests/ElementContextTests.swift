import Foundation
@testable import PinfoldCore
import Testing

/// CB-1 (A1): `<name>`, `<description>` and `<styleUrl>` only count under the right parent.
struct ElementContextTests {
    private func parse(_ xml: String) throws -> KMLDocument {
        try KMLParser.parse(data: Data(xml.utf8))
    }

    /// Document names of the ten corpus fixtures, captured before CB-1 changed behaviour.
    static let expectedNames: [(String, String)] = [
        ("KML_Samples.kml", "KML Samples"),
        ("Munich Sole.kml", "Munich Sole"),
        ("Munich Sole.kmz", "Munich Sole"),
        ("Rome.kml", "Rome"),
        ("Rome.kmz", "Rome"),
        ("Iceland.kml", "Iceland"),
        ("Iceland.kmz", "Iceland"),
        ("iceland-trip-2026.kml", "Iceland Trip 2026"),
        ("schemadata.kml", "SchemaData Sample"),
        ("geometry.kml", "Geometry Samples"),
    ]

    @Test(arguments: expectedNames)
    func fixtureDocumentNamesUnchanged(fixture: String, name: String) throws {
        let parsed = try KMLReader.read(data: Fixture.data(fixture))
        #expect(parsed.document.name == name)
    }

    @Test func atomAuthorNameDoesNotRenameDocument() throws {
        let doc = try parse("""
        <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:atom="http://www.w3.org/2005/Atom">
          <Document>
            <name>Real Name</name>
            <atom:author><atom:name>Some Author</atom:name></atom:author>
            <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
          </Document>
        </kml>
        """)
        #expect(doc.name == "Real Name")
    }

    @Test func networkLinkNameDoesNotRenameFolder() throws {
        let doc = try parse("""
        <kml><Document><name>Doc</name>
          <Folder><name>Folder</name>
            <NetworkLink><name>Remote</name><Link><href>http://example.com/a.kml</href></Link></NetworkLink>
            <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
          </Folder>
        </Document></kml>
        """)
        #expect(doc.name == "Doc")
        #expect(doc.root.children.first?.name == "Folder")
    }

    @Test func groundOverlayNameAndDescriptionAreIgnored() throws {
        let doc = try parse("""
        <kml><Document><name>Doc</name><description>Doc description</description>
          <GroundOverlay><name>Overlay</name><description><![CDATA[<b>x</b>]]></description></GroundOverlay>
          <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
        </Document></kml>
        """)
        #expect(doc.name == "Doc")
        #expect(doc.descriptionHTML == "Doc description")
        #expect(doc.root.allPlacemarks.map(\.name) == ["P"])
    }

    @Test func nestedNameInsidePlacemarkChildIsIgnored() throws {
        let doc = try parse("""
        <kml><Document><name>Doc</name>
          <Placemark><name>Real</name>
            <atom:author xmlns:atom="http://www.w3.org/2005/Atom"><atom:name>Nope</atom:name></atom:author>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        #expect(doc.root.allPlacemarks.first?.name == "Real")
    }

    @Test func nestedNameBeforePlacemarkNameDoesNotLeak() throws {
        let doc = try parse("""
        <kml><Document>
          <Placemark>
            <atom:author xmlns:atom="http://www.w3.org/2005/Atom"><atom:name>Nope</atom:name></atom:author>
            <name>Real</name>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        #expect(doc.root.allPlacemarks.first?.name == "Real")
    }

    @Test func overlayDescriptionDoesNotOverwriteFolderDescription() throws {
        let doc = try parse("""
        <kml><Document><name>Doc</name>
          <Folder><name>F</name><description>Folder text</description>
            <ScreenOverlay><name>S</name><description>Overlay text <b>bold</b></description></ScreenOverlay>
            <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
          </Folder>
        </Document></kml>
        """)
        // The folder description is not in the model until CB-6; the overlay text must at
        // least not land on the placemark, and swallowed markup must not break parsing.
        #expect(doc.root.allPlacemarks.first?.descriptionHTML == nil)
    }

    @Test func overlayDescriptionAfterDocumentDescriptionKeepsDocumentDescription() throws {
        let doc = try parse("""
        <kml><Document><name>Doc</name><description>Doc text</description>
          <ScreenOverlay><description>Overlay text <i>x</i></description></ScreenOverlay>
          <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
        </Document></kml>
        """)
        #expect(doc.descriptionHTML == "Doc text")
    }

    @Test func styleUrlOutsidePlacemarkDoesNotStyleIt() throws {
        let doc = try parse("""
        <kml><Document>
          <Placemark><name>P</name>
            <LookAt><styleUrl>#bogus</styleUrl></LookAt>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        #expect(doc.root.allPlacemarks.first?.styleUrl == nil)
    }
}
