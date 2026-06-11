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
}
