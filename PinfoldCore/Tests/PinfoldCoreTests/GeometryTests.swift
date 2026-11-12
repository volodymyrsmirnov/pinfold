import Foundation
@testable import PinfoldCore
import Testing

struct GeometryTests {
    private func parse(_ fixture: String) throws -> KMLDocument {
        try KMLParser.parse(data: Fixture.data(fixture))
    }

    private func placemark(_ name: String, in doc: KMLDocument) -> KMLPlacemark? {
        doc.root.allPlacemarks.first { $0.name == name }
    }

    @Test func parse_lineStringCaptured() throws {
        let doc = try parse("geometry.kml")
        let pm = placemark("Route", in: doc)
        #expect(pm != nil)
        guard case let .lineString(coords)? = pm?.geometries.first else {
            Issue.record("expected a lineString geometry")
            return
        }
        #expect(coords.count == 3)
        #expect(coords.map(\.longitude) == [10.0, 11.0, 12.0])
        #expect(coords.map(\.latitude) == [20.0, 21.0, 22.0])
        // Representative coordinate is the first vertex.
        #expect(pm?.coordinate == coords.first)
        #expect(pm?.hasPoint == false)
    }

    @Test func parse_polygonOuterAndInnerRings() throws {
        let doc = try parse("geometry.kml")
        let pm = placemark("Area", in: doc)
        guard case let .polygon(outer, inners)? = pm?.geometries.first else {
            Issue.record("expected a polygon geometry")
            return
        }
        #expect(outer.count == 4)
        #expect(inners.count == 1)
        #expect(inners.first?.count == 3)
    }

    @Test func parse_gxTrackCoordsCaptured() throws {
        let doc = try parse("geometry.kml")
        let pm = placemark("Hike", in: doc)
        #expect(pm != nil)
        guard case let .track(coords)? = pm?.geometries.first else {
            Issue.record("expected a track geometry")
            return
        }
        #expect(coords.count == 3)
        // gx:coord is "lon lat alt" — verify lon/lat mapped correctly (not swapped).
        #expect(coords.map(\.longitude) == [30.0, 31.0, 32.0])
        #expect(coords.map(\.latitude) == [40.0, 41.0, 42.0])
        #expect(pm?.coordinate == coords.first)
        #expect(pm?.hasPoint == false)
    }

    @Test func parse_multiGeometryPointPlusLine() throws {
        let doc = try parse("geometry.kml")
        let pm = placemark("Mixed", in: doc)
        #expect(pm != nil)
        #expect(pm?.hasPoint == true)
        // Point coordinate preserved, not clobbered by line vertices.
        #expect(pm?.coordinate?.longitude == 55.5)
        #expect(pm?.coordinate?.latitude == 33.3)
        // Line still captured, with its vertices in document order.
        guard case let .lineString(coords)? = pm?.geometries.first else {
            Issue.record("expected a lineString geometry")
            return
        }
        #expect(coords.map(\.longitude) == [10.0, 11.0])
        #expect(coords.map(\.latitude) == [20.0, 21.0])
    }

    @Test func parse_multiPolygonBuffersResetBetweenGeometries() throws {
        // Two consecutive Polygons inside one MultiGeometry: pins the buffer-reset path —
        // the second polygon must not inherit the first one's outer ring or inner rings.
        let doc = try parse("geometry.kml")
        let pm = placemark("TwoPolys", in: doc)
        #expect(pm?.geometries.count == 2)
        guard case let .polygon(outer1, inners1)? = pm?.geometries.first,
              case let .polygon(outer2, inners2)? = pm?.geometries.last
        else {
            Issue.record("expected two polygon geometries")
            return
        }
        // Distinct outer rings, each with its own coordinates.
        #expect(outer1.map(\.longitude) == [100.0, 101.0, 101.0, 100.0])
        #expect(outer1.map(\.latitude) == [10.0, 10.0, 11.0, 11.0])
        #expect(outer2.map(\.longitude) == [120.0, 121.0, 121.0, 120.0])
        #expect(outer2.map(\.latitude) == [20.0, 20.0, 21.0, 21.0])
        // The inner ring belongs to the FIRST polygon only.
        #expect(inners1.count == 1)
        #expect(inners1.first?.map(\.longitude) == [100.4, 100.6, 100.5])
        #expect(inners2.isEmpty)
    }

    @Test func counts_matchAllPlacemarksDerivation() throws {
        // The recursive placemarkCount/pointCount must equal the array-materializing
        // allPlacemarks derivation they replace.
        let doc = try parse("geometry.kml")
        let all = doc.root.allPlacemarks
        #expect(doc.placemarkCount == all.count)
        #expect(doc.pointCount == all.filter(\.hasPoint).count)
    }

    @Test func parse_lineAndPolyStyleParsed() throws {
        let doc = try parse("geometry.kml")
        let style = doc.styles["ls"]
        #expect(style?.lineColor == "ff0000ff")
        #expect(style?.lineWidth == 3)
        #expect(style?.polyColor == "7f00ff00")
    }

    @Test func parse_pointOnlyFilesUnchanged() throws {
        // Rome.kml is point-only; pin its current placemark count and coordinates so the
        // geometry-capture change is proven not to disturb point-only files.
        let doc = try parse("Rome.kml")
        let placemarks = doc.root.allPlacemarks
        let allPoints = placemarks.allSatisfy(\.hasPoint)
        let noGeometries = placemarks.allSatisfy(\.geometries.isEmpty)
        let allHaveCoordinate = placemarks.allSatisfy { $0.coordinate != nil }
        #expect(allPoints)
        #expect(noGeometries)
        #expect(doc.pointCount == placemarks.count)
        // Every point-only placemark keeps a coordinate.
        #expect(allHaveCoordinate)
    }

    // MARK: - CB-3 (A9): invalid and degenerate geometry

    private func onlyPlacemark(_ body: String) throws -> KMLPlacemark {
        let xml = "<kml><Document><name>D</name><Placemark><name>P</name>\(body)</Placemark></Document></kml>"
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        return try #require(doc.root.allPlacemarks.first)
    }

    @Test func pointWithUnparseableCoordinates_fallsBackToLineGeometry() throws {
        let pm = try onlyPlacemark("""
        <MultiGeometry>
          <Point><coordinates>abc,def</coordinates></Point>
          <LineString><coordinates>1,2 3,4</coordinates></LineString>
        </MultiGeometry>
        """)
        #expect(pm.hasPoint == false)
        #expect(pm.geometries.count == 1)
        #expect(pm.coordinate == Coordinate(longitude: 1, latitude: 2))
    }

    @Test func pointWithUnparseableCoordinates_isNotCountedAsPoint() throws {
        let xml = """
        <kml><Document><name>D</name>
          <Placemark><name>Bad</name><Point><coordinates>abc</coordinates></Point></Placemark>
          <Placemark><name>Good</name><Point><coordinates>1,2</coordinates></Point></Placemark>
        </Document></kml>
        """
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        #expect(doc.placemarkCount == 2) // the bad one is kept as placeless
        #expect(doc.pointCount == 1)
        let bad = doc.root.allPlacemarks.first { $0.name == "Bad" }
        #expect(bad?.hasPoint == false)
        #expect(bad?.coordinate == nil)
    }

    @Test func emptyLineStringIsDropped() throws {
        let pm = try onlyPlacemark("<LineString><coordinates> </coordinates></LineString>")
        #expect(pm.geometries.isEmpty)
        #expect(pm.coordinate == nil)
        #expect(pm.hasPoint == false)
    }

    @Test func singleVertexLineIsDropped_butLocatesThePlacemark() throws {
        let pm = try onlyPlacemark("<LineString><coordinates>5,6</coordinates></LineString>")
        #expect(pm.geometries.isEmpty)
        #expect(pm.hasPoint == false)
        #expect(pm.coordinate == Coordinate(longitude: 5, latitude: 6))
    }

    @Test func singleVertexTrackIsDropped_butLocatesThePlacemark() throws {
        let pm = try onlyPlacemark("<gx:Track><gx:coord>7 8 0</gx:coord></gx:Track>")
        #expect(pm.geometries.isEmpty)
        #expect(pm.hasPoint == false)
        #expect(pm.coordinate == Coordinate(longitude: 7, latitude: 8, altitude: 0))
    }

    @Test func polygonWithFewerThanThreeOuterVerticesIsDropped() throws {
        let pm = try onlyPlacemark("""
        <Polygon><outerBoundaryIs><LinearRing><coordinates>1,1 2,2</coordinates></LinearRing></outerBoundaryIs></Polygon>
        """)
        #expect(pm.geometries.isEmpty)
        #expect(pm.coordinate == nil)
    }

    @Test func degenerateInnerRingIsDropped() throws {
        let pm = try onlyPlacemark("""
        <Polygon>
          <outerBoundaryIs><LinearRing><coordinates>0,0 4,0 4,4 0,4 0,0</coordinates></LinearRing></outerBoundaryIs>
          <innerBoundaryIs><LinearRing><coordinates>1,1 2,2</coordinates></LinearRing></innerBoundaryIs>
          <innerBoundaryIs><LinearRing><coordinates>1,1 2,1 2,2 1,1</coordinates></LinearRing></innerBoundaryIs>
        </Polygon>
        """)
        guard case let .polygon(outer, inners)? = pm.geometries.first else {
            Issue.record("expected the polygon to be kept")
            return
        }
        #expect(outer.count == 5)
        #expect(inners.count == 1) // only the good inner ring survives
        #expect(inners.first?.count == 4)
    }

    @Test func validPointStillWinsOverDegenerateLine() throws {
        let pm = try onlyPlacemark("""
        <MultiGeometry><Point><coordinates>9,9</coordinates></Point>
        <LineString><coordinates>1,1</coordinates></LineString></MultiGeometry>
        """)
        #expect(pm.hasPoint)
        #expect(pm.coordinate == Coordinate(longitude: 9, latitude: 9))
        #expect(pm.geometries.isEmpty)
    }

    // MARK: - CB-4 (A2a): every point of a MultiGeometry

    @Test func multiGeometryThreePoints_firstIsRepresentativeRestAreGeometries() throws {
        let pm = try onlyPlacemark("""
        <MultiGeometry>
          <Point><coordinates>1,2</coordinates></Point>
          <Point><coordinates>3,4</coordinates></Point>
          <Point><coordinates>5,6</coordinates></Point>
        </MultiGeometry>
        """)
        #expect(pm.hasPoint)
        #expect(pm.coordinate == Coordinate(longitude: 1, latitude: 2))
        #expect(pm.geometries == [
            .point(Coordinate(longitude: 3, latitude: 4)),
            .point(Coordinate(longitude: 5, latitude: 6)),
        ])
    }

    @Test func multiGeometryPointsAndLine_documentOrderPreserved() throws {
        let pm = try onlyPlacemark("""
        <MultiGeometry>
          <Point><coordinates>1,2</coordinates></Point>
          <LineString><coordinates>10,10 11,11</coordinates></LineString>
          <Point><coordinates>3,4</coordinates></Point>
          <gx:Track><gx:coord>20 20</gx:coord><gx:coord>21 21</gx:coord></gx:Track>
        </MultiGeometry>
        """)
        #expect(pm.coordinate == Coordinate(longitude: 1, latitude: 2))
        #expect(pm.geometries == [
            .lineString([Coordinate(longitude: 10, latitude: 10), Coordinate(longitude: 11, latitude: 11)]),
            .point(Coordinate(longitude: 3, latitude: 4)),
            .track([Coordinate(longitude: 20, latitude: 20), Coordinate(longitude: 21, latitude: 21)]),
        ])
    }

    @Test func invalidSecondPointIsNotAGeometry() throws {
        let pm = try onlyPlacemark("""
        <MultiGeometry><Point><coordinates>1,2</coordinates></Point>
        <Point><coordinates>oops</coordinates></Point></MultiGeometry>
        """)
        #expect(pm.geometries.isEmpty)
    }

    // MARK: - CB-8 (A14): gx:MultiTrack

    @Test func gxMultiTrack_innerTracksAreCaptured() throws {
        let pm = try onlyPlacemark("""
        <gx:MultiTrack><gx:interpolate>0</gx:interpolate>
          <gx:Track><gx:coord>10 20 0</gx:coord><gx:coord>11 21 0</gx:coord></gx:Track>
          <gx:Track><gx:coord>30 40 0</gx:coord><gx:coord>31 41 0</gx:coord></gx:Track>
        </gx:MultiTrack>
        """)
        #expect(pm.geometries.count == 2)
        #expect(pm.geometries.allSatisfy {
            if case .track = $0 {
                true
            } else {
                false
            }
        })
        #expect(pm.hasPoint == false)
        #expect(pm.coordinate == Coordinate(longitude: 10, latitude: 20, altitude: 0))
    }

    @Test func gxMultiTrackOnlyPlacemarkIsKept() throws {
        let xml = """
        <kml><Document><name>D</name><Placemark><name>Run</name>
        <gx:MultiTrack><gx:Track><gx:coord>1 2</gx:coord><gx:coord>3 4</gx:coord></gx:Track></gx:MultiTrack>
        </Placemark></Document></kml>
        """
        let doc = try KMLParser.parse(data: Data(xml.utf8))
        #expect(doc.placemarkCount == 1)
    }

    @Test func modelOnlyPlacemarkIsStillDropped() throws {
        let xml = """
        <kml><Document><name>D</name><Placemark><name>3D</name>
        <Model><Location><longitude>1</longitude><latitude>2</latitude></Location></Model>
        </Placemark></Document></kml>
        """
        #expect(try KMLParser.parse(data: Data(xml.utf8)).placemarkCount == 0)
    }
}
