import Foundation
@testable import PinfoldCore
import Testing

/// CB-9 (D3a): NetworkLink capture.
struct NetworkLinkTests {
    private func parse(_ xml: String) throws -> KMLDocument {
        try KMLParser.parse(data: Data(xml.utf8))
    }

    @Test func networkLinkOnlyFile_hasZeroPlacemarksAndOneLink() throws {
        let doc = try KMLParser.parse(data: Fixture.data("networklink.kml"))
        #expect(doc.placemarkCount == 0)
        #expect(doc.networkLinks == [
            KMLNetworkLink(name: "Example Map",
                           href: "https://www.google.com/maps/d/kml?forcekml=1&mid=EXAMPLE_MAP_ID"),
        ])
        #expect(doc.name == nil)
    }

    @Test func legacyUrlElementIsSupported() throws {
        let doc = try parse("""
        <kml><NetworkLink><name>Old</name><Url><href>http://example.com/old.kml</href></Url></NetworkLink></kml>
        """)
        #expect(doc.networkLinks == [KMLNetworkLink(name: "Old", href: "http://example.com/old.kml")])
    }

    @Test func hrefInCDATAIsTrimmed() throws {
        let doc = try parse("""
        <kml><NetworkLink><Link><href><![CDATA[
            http://example.com/a.kml
        ]]></href></Link></NetworkLink></kml>
        """)
        #expect(doc.networkLinks == [KMLNetworkLink(name: nil, href: "http://example.com/a.kml")])
    }

    @Test func networkLinkAlongsidePlacemarks() throws {
        let doc = try parse("""
        <kml><Document><name>Doc</name>
          <Placemark><name>P</name><Point><coordinates>1,2</coordinates></Point></Placemark>
          <NetworkLink><name>First</name><Link><href>http://example.com/1.kml</href></Link></NetworkLink>
          <Folder><name>F</name>
            <NetworkLink><name>Second</name><Link><href>http://example.com/2.kml</href></Link></NetworkLink>
            <Placemark><name>Q</name><Point><coordinates>3,4</coordinates></Point></Placemark>
          </Folder>
          <NetworkLink><Link><href>http://example.com/3.kml</href></Link></NetworkLink>
        </Document></kml>
        """)
        #expect(doc.name == "Doc")
        #expect(doc.placemarkCount == 2)
        #expect(doc.networkLinks.map(\.href) == [
            "http://example.com/1.kml", "http://example.com/2.kml", "http://example.com/3.kml",
        ])
        #expect(doc.networkLinks.map(\.name) == ["First", "Second", nil])
        #expect(doc.root.children.first?.name == "F")
    }

    @Test func emptyHrefIsSkipped() throws {
        let doc = try parse("""
        <kml><NetworkLink><name>Empty</name><Link><href>  </href></Link></NetworkLink>
        <NetworkLink><name>None</name></NetworkLink></kml>
        """)
        #expect(doc.networkLinks.isEmpty)
    }

    @Test func iconHrefIsNotANetworkLink() throws {
        let doc = try parse("""
        <kml><Document><name>Doc</name>
          <Style id="s"><IconStyle><Icon><href>http://example.com/icon.png</href></Icon></IconStyle></Style>
          <GroundOverlay><name>O</name><Icon><href>http://example.com/overlay.png</href></Icon></GroundOverlay>
          <Placemark><name>P</name><styleUrl>#s</styleUrl><Point><coordinates>1,2</coordinates></Point></Placemark>
        </Document></kml>
        """)
        #expect(doc.networkLinks.isEmpty)
        #expect(doc.styles["s"]?.iconHref == "http://example.com/icon.png")
    }

    @Test func documentsWithoutNetworkLinksHaveNone() throws {
        let doc = try KMLParser.parse(data: Fixture.data("Rome.kml"))
        #expect(doc.networkLinks.isEmpty)
    }
}
