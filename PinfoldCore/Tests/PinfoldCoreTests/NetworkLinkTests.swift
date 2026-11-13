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

    // MARK: Refresh hints and NetworkLinkControl

    @Test func refreshModeAndInterval_underLink() throws {
        let doc = try parse("""
        <kml><NetworkLink><Link><href>https://a/x.kml</href>\
        <refreshMode>onInterval</refreshMode><refreshInterval>600</refreshInterval></Link></NetworkLink></kml>
        """)
        #expect(doc.networkLinks.first?.refreshMode == .onInterval)
        #expect(doc.networkLinks.first?.refreshInterval == 600)
    }

    @Test func refreshHints_underLegacyUrl() throws {
        let doc = try parse("""
        <kml><NetworkLink><Url><href>https://a/x.kml</href>\
        <refreshMode>onInterval</refreshMode><refreshInterval>600</refreshInterval></Url></NetworkLink></kml>
        """)
        #expect(doc.networkLinks.first?.refreshMode == .onInterval)
        #expect(doc.networkLinks.first?.refreshInterval == 600)
    }

    @Test func unknownRefreshMode_isNil() throws {
        let doc = try parse("""
        <kml><NetworkLink><Link><href>https://a/x.kml</href>\
        <refreshMode>sometimes</refreshMode><refreshInterval>soon</refreshInterval></Link></NetworkLink></kml>
        """)
        #expect(doc.networkLinks.count == 1)
        #expect(doc.networkLinks.first?.refreshMode == nil)
        #expect(doc.networkLinks.first?.refreshInterval == nil)
    }

    @Test func refreshHints_doNotLeakBetweenLinks() throws {
        let doc = try parse("""
        <kml><Document>
        <NetworkLink><Link><href>https://a/1.kml</href><refreshMode>onExpire</refreshMode></Link></NetworkLink>
        <NetworkLink><Link><href>https://a/2.kml</href></Link></NetworkLink>
        </Document></kml>
        """)
        #expect(doc.networkLinks.map(\.refreshMode) == [.onExpire, nil])
    }

    @Test func networkLinkControl_minRefreshAndExpires() throws {
        let doc = try parse("""
        <kml><NetworkLinkControl><minRefreshPeriod>120</minRefreshPeriod>\
        <expires>2026-12-01T10:00:00Z</expires></NetworkLinkControl>\
        <Document><name>D</name></Document></kml>
        """)
        let expected = ISO8601DateFormatter().date(from: "2026-12-01T10:00:00Z")
        #expect(doc.networkLinkControl?.minRefreshPeriod == 120)
        #expect(doc.networkLinkControl?.expires == expected)
        #expect(expected != nil)
    }

    @Test func networkLinkControl_updateBlockIgnored() throws {
        let doc = try parse("""
        <kml><NetworkLinkControl><Update><targetHref>x.kml</targetHref><Change>\
        <Placemark targetId="a"><name>x</name><Point><coordinates>9,9</coordinates></Point></Placemark>\
        </Change></Update></NetworkLinkControl>
        <Document><Placemark><name>real</name><Point><coordinates>1,2</coordinates></Point></Placemark></Document></kml>
        """)
        #expect(doc.placemarkCount == 1)
        #expect(doc.root.placemarks.first?.name == "real")
    }

    @Test func noNetworkLinkControl_isNil() throws {
        let doc = try parse("<kml><Document><name>D</name></Document></kml>")
        #expect(doc.networkLinkControl == nil)
    }

    @Test func refreshInterval_nonFiniteOrNonPositive_isDropped_andHugeIsCapped() throws {
        let values = ["inf", "nan", "-5", "0", "1e30"]
        let links = values.map {
            "<NetworkLink><Link><href>https://a/\($0).kml</href><refreshInterval>\($0)</refreshInterval></Link></NetworkLink>"
        }.joined()
        let doc = try parse("<kml><Document>\(links)</Document></kml>")
        #expect(doc.networkLinks.map(\.refreshInterval) == [nil, nil, nil, nil, KMLRefreshHint.maxSeconds])
    }

    @Test func minRefreshPeriod_nonFiniteIsDropped_andHugeIsCapped() throws {
        let infinite = try parse("""
        <kml><NetworkLinkControl><minRefreshPeriod>inf</minRefreshPeriod></NetworkLinkControl>\
        <Document><name>D</name></Document></kml>
        """)
        #expect(infinite.networkLinkControl?.minRefreshPeriod == nil)
        let huge = try parse("""
        <kml><NetworkLinkControl><minRefreshPeriod>1e21</minRefreshPeriod></NetworkLinkControl>\
        <Document><name>D</name></Document></kml>
        """)
        #expect(huge.networkLinkControl?.minRefreshPeriod == KMLRefreshHint.maxSeconds)
    }

    @Test func modelInitialisersSanitiseHints() {
        #expect(KMLNetworkLink(name: nil, href: "https://a", refreshInterval: .infinity).refreshInterval == nil)
        #expect(KMLNetworkLink(name: nil, href: "https://a", refreshInterval: 60).refreshInterval == 60)
        #expect(KMLNetworkLinkControl(minRefreshPeriod: .nan, expires: nil).minRefreshPeriod == nil)
        #expect(KMLRefreshHint.maxSeconds == 30 * 24 * 3600)
    }
}
