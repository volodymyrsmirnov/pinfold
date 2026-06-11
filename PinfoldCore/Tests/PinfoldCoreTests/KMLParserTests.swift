import Foundation
@testable import PinfoldCore
import Testing

struct KMLParserTests {
    private func parse(_ fixture: String) throws -> KMLDocument {
        try KMLParser.parse(data: Fixture.data(fixture))
    }

    @Test func parsesDocumentName() throws {
        #expect(try parse("KML_Samples.kml").name == "KML Samples")
        #expect(try parse("Rome.kml").name == "Rome")
    }

    @Test func findsSimplePlacemarkWithCoordinate() throws {
        let doc = try parse("KML_Samples.kml")
        let simple = doc.root.allPlacemarks.first { $0.name == "Simple placemark" }
        #expect(simple != nil)
        #expect(simple?.coordinate?.longitude == -122.0822035425683)
        #expect(simple?.coordinate?.latitude == 37.42228990140251)
    }

    @Test func buildsNestedFolderHierarchy() throws {
        let doc = try parse("KML_Samples.kml")
        let names = doc.root.children.map(\.name)
        #expect(names.contains("Placemarks"))
        #expect(names.contains("Styles and Markup"))
    }

    @Test func nestedDocumentBecomesContainer() throws {
        let doc = try parse("KML_Samples.kml")
        let styles = doc.root.children.first { $0.name == "Styles and Markup" }
        let highlighted = styles?.children.first { $0.name == "Highlighted Icon" }
        #expect(highlighted != nil)
        #expect(highlighted?.placemarks.contains { $0.name == "Roll over this icon" } == true)
    }

    @Test func rootDocumentNameDoesNotLeakToChildren() throws {
        let doc = try parse("Rome.kml")
        #expect(doc.root.children.allSatisfy { $0.name != "Rome" })
    }

    @Test func parsesIconStyleFields() throws {
        let style = try parse("Munich Sole.kml").styles["icon-1502-0288D1-nodesc-normal"]
        #expect(style?.iconHref == "https://www.gstatic.com/mapspro/images/stock/503-wht-blank_maps.png")
        #expect(style?.iconColor == "ffd18802")
        #expect(style?.iconScale == 1)
    }

    @Test func parsesStyleMapNormalPair() throws {
        #expect(try parse("Munich Sole.kml").styleMaps["icon-1502-0288D1-nodesc"]
            == "#icon-1502-0288D1-nodesc-normal")
    }

    @Test func placemarkStyleUrlResolvesThroughStyleMap() throws {
        let doc = try parse("Munich Sole.kml")
        let pm = doc.root.allPlacemarks.first { $0.styleUrl == "#icon-1502-0288D1-nodesc" }
        #expect(pm != nil)
        #expect(doc.resolvedStyle(forStyleUrl: pm?.styleUrl)?.iconHref
            == "https://www.gstatic.com/mapspro/images/stock/503-wht-blank_maps.png")
    }

    @Test func parsesExtendedDataExcludingMediaLinks() throws {
        let doc = try parse("iceland-trip-2026.kml")
        let pm = doc.root.allPlacemarks.first { $0.name == "Hallgrímskirkja" }
        #expect(pm?.extendedData.first { $0.name == "day" }?.value == "1")
        #expect(pm?.extendedData.first { $0.name == "category" }?.value == "culture")
        #expect(pm?.extendedData.contains { $0.name == "gx_media_links" } == false)
    }

    @Test func gathersPhotoLinksFromMediaLinks() throws {
        let doc = try parse("Iceland.kml")
        let withPhotos = doc.root.allPlacemarks.first { !$0.photoLinks.isEmpty }
        #expect(withPhotos != nil)
        #expect(withPhotos?.photoLinks.first?.hasPrefix("https://") == true)
    }

    @Test func preservesCDATAHTMLDescription() throws {
        let doc = try parse("KML_Samples.kml")
        let pm = doc.root.allPlacemarks.first { $0.name == "Descriptive HTML" }
        #expect(pm?.descriptionHTML?.contains("<b>Bold</b>") == true)
    }

    @Test func keepsPlacelessPlacemarkWithoutCoordinate() throws {
        let doc = try parse("KML_Samples.kml")
        let pm = doc.root.allPlacemarks.first { $0.name == "Descriptive HTML" }
        #expect(pm != nil)
        #expect(pm?.coordinate == nil)
    }

    @Test func dropsNonPointGeometryPlacemarks() throws {
        let doc = try parse("KML_Samples.kml")
        #expect(doc.root.allPlacemarks.contains { $0.name == "Tessellated" } == false) // LineString
        #expect(doc.root.allPlacemarks.contains { $0.name == "Building 40" } == false) // Polygon
    }

    @Test func inlinePlacemarkStyleDoesNotLeakIntoDocumentStyles() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>Test</name>
            <Placemark>
              <name>Styled</name>
              <Style>
                <IconStyle>
                  <Icon><href>inline.png</href></Icon>
                </IconStyle>
              </Style>
              <Point><coordinates>1.0,2.0,0</coordinates></Point>
            </Placemark>
          </Document>
        </kml>
        """
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        let pm = doc.root.allPlacemarks.first { $0.name == "Styled" }
        #expect(pm != nil) // placemark is kept
        #expect(pm?.coordinate?.longitude == 1.0)
        #expect(doc.styles.isEmpty) // inline style must NOT leak into document table
    }

    @Test func parseMalformedXMLThrows() {
        #expect(throws: KMLParseError.self) {
            try KMLParser.parse(data: Data("not xml".utf8))
        }
    }

    @Test func capturesPlacemarkIDAttribute() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>Test</name>
            <Placemark id="marker-42">
              <name>Tagged</name>
              <Point><coordinates>1.0,2.0,0</coordinates></Point>
            </Placemark>
          </Document>
        </kml>
        """
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        let pm = doc.root.allPlacemarks.first { $0.name == "Tagged" }
        #expect(pm != nil)
        #expect(pm?.sourceID == "marker-42")
        #expect(pm?.stableKey == "id:marker-42")
    }

    @Test func parse_rejectsDOCTYPE() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE kml [<!ENTITY a "x">]>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>&a;</name>
          </Document>
        </kml>
        """
        #expect(throws: KMLParseError.self) {
            try KMLParser.parse(data: Data(xml.utf8))
        }
    }

    @Test func parse_rejectsBillionLaughs() {
        // Nested-entity expansion payload (5 levels suffices to prove the point).
        // Rejection must happen before XML parsing, so this completes fast regardless
        // of the theoretical expansion size.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE kml [
          <!ENTITY a "ha">
          <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
          <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
          <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">
          <!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;">
        ]>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>&e;</name>
          </Document>
        </kml>
        """
        #expect(throws: KMLParseError.self) {
            try KMLParser.parse(data: Data(xml.utf8))
        }
    }

    @Test func multiGeometryUsesPointCoordinateNotLineStringVertex() throws {
        // Point appears BEFORE the LineString — without the inPoint guard the later LineString
        // coordinates overwrite the already-captured Point coordinate.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>Test</name>
            <Placemark>
              <name>Mixed</name>
              <MultiGeometry>
                <Point>
                  <coordinates>55.5,33.3,0</coordinates>
                </Point>
                <LineString>
                  <coordinates>10.0,20.0,0 11.0,21.0,0</coordinates>
                </LineString>
              </MultiGeometry>
            </Placemark>
          </Document>
        </kml>
        """
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        let pm = doc.root.allPlacemarks.first { $0.name == "Mixed" }
        #expect(pm != nil) // placemark is kept (has a Point)
        #expect(pm?.coordinate?.longitude == 55.5) // Point's coordinate, not LineString vertex
        #expect(pm?.coordinate?.latitude == 33.3)
    }
}
