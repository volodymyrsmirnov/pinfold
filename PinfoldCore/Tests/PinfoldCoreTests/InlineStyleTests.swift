import Foundation
@testable import PinfoldCore
import Testing

/// CB-5 (A11): inline `<Style>` / `<StyleMap>` inside a placemark resolve through `styleUrl`.
struct InlineStyleTests {
    private func parse(_ xml: String) throws -> KMLDocument {
        try KMLParser.parse(data: Data(xml.utf8))
    }

    private func placemark(_ name: String, in doc: KMLDocument) throws -> KMLPlacemark {
        try #require(doc.root.allPlacemarks.first { $0.name == name })
    }

    @Test func inlinePlacemarkStyle_resolvesThroughStyleUrl() throws {
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Placemark><name>Styled</name>
            <Style><IconStyle><scale>2</scale><Icon><href>inline.png</href></Icon></IconStyle></Style>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        let pm = try placemark("Styled", in: doc)
        #expect(pm.coordinate?.longitude == 1)
        let style = doc.resolvedStyle(forStyleUrl: pm.styleUrl)
        #expect(style?.iconHref == "inline.png")
        #expect(style?.iconScale == 2)
    }

    @Test func inlineStyleOverridesSharedStyleFieldwise() throws {
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Style id="shared"><IconStyle><color>ff0000ff</color><Icon><href>shared.png</href></Icon></IconStyle>
            <LineStyle><width>4</width></LineStyle></Style>
          <Placemark><name>P</name><styleUrl>#shared</styleUrl>
            <Style><IconStyle><color>ff00ff00</color></IconStyle></Style>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        let pm = try placemark("P", in: doc)
        let style = try #require(doc.resolvedStyle(forStyleUrl: pm.styleUrl))
        #expect(style.iconColor == "ff00ff00") // inline wins
        #expect(style.iconHref == "shared.png") // falls back to shared
        #expect(style.lineWidth == 4)
        #expect(doc.styles["shared"]?.iconColor == "ff0000ff") // shared style untouched
    }

    @Test func inlineStyleWithSharedStyleDefinedLater_stillMerges() throws {
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Placemark><name>P</name><styleUrl>#late</styleUrl>
            <Style><LineStyle><color>ff112233</color></LineStyle></Style>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
          <Style id="late"><IconStyle><Icon><href>late.png</href></Icon></IconStyle></Style>
        </Document></kml>
        """)
        let style = try #require(doc.resolvedStyle(forStyleUrl: placemark("P", in: doc).styleUrl))
        #expect(style.iconHref == "late.png")
        #expect(style.lineColor == "ff112233")
    }

    @Test func identicalInlineStylesShareOneSynthesizedId() throws {
        let inline = "<Style><IconStyle><Icon><href>same.png</href></Icon></IconStyle></Style>"
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Placemark><name>A</name>\(inline)<Point><coordinates>1,2</coordinates></Point></Placemark>
          <Placemark><name>B</name>\(inline)<Point><coordinates>3,4</coordinates></Point></Placemark>
          <Placemark><name>C</name>
            <Style><IconStyle><Icon><href>other.png</href></Icon></IconStyle></Style>
            <Point><coordinates>5,6</coordinates></Point></Placemark>
        </Document></kml>
        """)
        let a = try placemark("A", in: doc).styleUrl
        let b = try placemark("B", in: doc).styleUrl
        let c = try placemark("C", in: doc).styleUrl
        #expect(a != nil)
        #expect(a == b)
        #expect(a != c)
        #expect(doc.styles.count == 2)
    }

    @Test func inlineStyleMapNormalPairIsApplied() throws {
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Placemark><name>P</name>
            <StyleMap>
              <Pair><key>highlight</key><Style><IconStyle><Icon><href>hi.png</href></Icon></IconStyle></Style></Pair>
              <Pair><key>normal</key><Style><IconStyle><Icon><href>norm.png</href></Icon></IconStyle></Style></Pair>
            </StyleMap>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        let style = try doc.resolvedStyle(forStyleUrl: placemark("P", in: doc).styleUrl)
        #expect(style?.iconHref == "norm.png")
    }

    @Test func inlineStyleMapWithStyleUrlPairIsApplied() throws {
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Style id="n"><IconStyle><Icon><href>n.png</href></Icon></IconStyle></Style>
          <Placemark><name>P</name>
            <StyleMap><Pair><key>normal</key><styleUrl>#n</styleUrl></Pair></StyleMap>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        let pm = try placemark("P", in: doc)
        #expect(pm.styleUrl == "#n")
        #expect(doc.resolvedStyle(forStyleUrl: pm.styleUrl)?.iconHref == "n.png")
    }

    @Test func inlineLineAndPolyStyleAreApplied() throws {
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Placemark><name>L</name>
            <Style><LineStyle><color>ff0000ff</color><width>5</width></LineStyle>
              <PolyStyle><color>7f00ff00</color><fill>0</fill></PolyStyle></Style>
            <LineString><coordinates>1,2 3,4</coordinates></LineString>
          </Placemark>
        </Document></kml>
        """)
        let style = try #require(doc.resolvedStyle(forStyleUrl: placemark("L", in: doc).styleUrl))
        #expect(style.lineColor == "ff0000ff")
        #expect(style.lineWidth == 5)
        #expect(style.polyColor == "7f00ff00")
        #expect(style.polyFill == false)
    }

    @Test func synthesizedIdDoesNotCollideWithAuthorId() throws {
        // Author ids shaped like the synthesized ones must survive untouched.
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Style id="_inline1"><IconStyle><Icon><href>author1.png</href></Icon></IconStyle></Style>
          <StyleMap id="_inline2"><Pair><key>normal</key><styleUrl>#_inline1</styleUrl></Pair></StyleMap>
          <Placemark><name>P</name>
            <Style><IconStyle><Icon><href>mine.png</href></Icon></IconStyle></Style>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        #expect(doc.styles["_inline1"]?.iconHref == "author1.png")
        let pm = try placemark("P", in: doc)
        #expect(pm.styleUrl != "#_inline1")
        #expect(pm.styleUrl != "#_inline2")
        #expect(doc.resolvedStyle(forStyleUrl: pm.styleUrl)?.iconHref == "mine.png")
    }

    @Test func styleWithoutRelevantFieldsKeepsSharedStyleUrl() throws {
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Style id="s"><IconStyle><Icon><href>s.png</href></Icon></IconStyle></Style>
          <Placemark><name>P</name><styleUrl>#s</styleUrl>
            <Style><BalloonStyle><text>hi</text></BalloonStyle></Style>
            <Point><coordinates>1,2</coordinates></Point>
          </Placemark>
        </Document></kml>
        """)
        #expect(try placemark("P", in: doc).styleUrl == "#s")
        #expect(doc.styles.count == 1)
    }

    @Test func documentLevelStylesAreUnchanged() throws {
        let doc = try parse("""
        <kml><Document><name>T</name>
          <Style id="a"><IconStyle><Icon><href>a.png</href></Icon></IconStyle></Style>
          <Placemark><name>P</name><styleUrl>#a</styleUrl><Point><coordinates>1,2</coordinates></Point></Placemark>
        </Document></kml>
        """)
        #expect(Array(doc.styles.keys) == ["a"])
        #expect(try placemark("P", in: doc).styleUrl == "#a")
    }
}
