import MapKit
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `MapRectBuilder.boundingRect(for:)`. Pure geometry — no shared state,
/// no MapKit view, so no `.serialized` requirement.
struct MapRectBuilderTests {
    @Test func boundingRect_emptyReturnsNil() {
        #expect(MapRectBuilder.boundingRect(for: []) == nil)
    }

    @Test func boundingRect_singleCoordinateZeroSize() throws {
        let coord = Coordinate(longitude: -122.0, latitude: 37.0)
        let rect = MapRectBuilder.boundingRect(for: [coord])
        let expectedOrigin = MKMapPoint(CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0))
        #expect(rect != nil)
        #expect(rect?.size.width == 0)
        #expect(rect?.size.height == 0)
        #expect(try abs(#require(rect?.origin.x) - expectedOrigin.x) < 1.0)
        #expect(try abs(#require(rect?.origin.y) - expectedOrigin.y) < 1.0)
    }

    @Test func multiplePoints_rectContainsAll() throws {
        let coords = [
            Coordinate(longitude: -122.0, latitude: 37.0),
            Coordinate(longitude: -121.0, latitude: 38.0),
            Coordinate(longitude: -123.0, latitude: 36.0),
        ]
        let rect = MapRectBuilder.boundingRect(for: coords)
        #expect(rect != nil)
        for coord in coords {
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude))
            #expect(try #require(rect?.contains(point)))
        }
        #expect(try #require(rect?.size.width) > 0)
        #expect(try #require(rect?.size.height) > 0)
    }

    /// The headline case: two pins straddling the antimeridian (1° apart across the seam)
    /// must fit to a *tight* wrapped rect, not a near-whole-globe one. We prove "tight" by
    /// showing the wrapped 1° rect is narrower than a plain 30° span — i.e. it did NOT span
    /// the long way around the globe (which the naive union would, at ~358° wide).
    @Test func boundingRect_antimeridianClusterStaysTight() throws {
        let cluster = [
            Coordinate(longitude: 179.5, latitude: 0.0),
            Coordinate(longitude: -179.5, latitude: 0.0),
        ]
        let span30 = [
            Coordinate(longitude: 0.0, latitude: 0.0),
            Coordinate(longitude: 30.0, latitude: 0.0),
        ]
        let clusterRect = try #require(MapRectBuilder.boundingRect(for: cluster))
        let span30Rect = try #require(MapRectBuilder.boundingRect(for: span30))
        #expect(clusterRect.size.width < span30Rect.size.width,
                "A 1° wrapped antimeridian cluster must fit tighter than a 30° span")
    }

    /// A normal (non-wrapping) span must be numerically identical to the naive union — the
    /// wrapping path must never alter the common case. Values pinned from the pre-change
    /// implementation run against the Paris+Rome fixture.
    @Test func boundingRect_normalSpanUnchanged() throws {
        let coords = [
            Coordinate(longitude: 2.35, latitude: 48.86), // Paris
            Coordinate(longitude: 12.5, latitude: 41.9), // Rome
        ]
        let rect = try #require(MapRectBuilder.boundingRect(for: coords))
        // Pinned from the original naive MKMapRect.union implementation.
        #expect(rect.origin.x == 135_970_015.004_444_45)
        #expect(rect.origin.y == 92_345_567.882_861_27)
        #expect(rect.size.width == 7_568_388.551_111_132)
        #expect(rect.size.height == 7_402_505.305_823_192)
    }

    /// Both antimeridian endpoints must be framed by the returned rect. The wrapped rect lives
    /// in shifted longitude space and legally extends past `MKMapRect.world.maxX`, so the
    /// eastern point sits inside it directly while the western point's map x is reached by its
    /// +360° (one-world-width) twin — exactly the cross-seam region `setVisibleMapRect` renders.
    @Test func antimeridianSpanningPoints_rectContainsBothEndpoints() throws {
        let coords = [
            Coordinate(longitude: 179.0, latitude: 0.0),
            Coordinate(longitude: -179.0, latitude: 0.0),
        ]
        let rect = try #require(MapRectBuilder.boundingRect(for: coords))
        let worldWidth = MKMapRect.world.size.width
        // The wrapped rect spans, in shifted longitude space, from the eastern point's x to
        // the western point's +360° twin x. Assert each endpoint's shifted x falls within the
        // rect's [minX, maxX] extent (inclusive of the right edge, which `MKMapRect.contains`
        // treats as exclusive — hence checking bounds directly rather than `contains`).
        for coord in coords {
            let base = MKMapPoint(CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude))
            let shiftedX = coord.longitude < 0 ? base.x + worldWidth : base.x
            #expect(shiftedX >= rect.minX && shiftedX <= rect.maxX,
                    "each endpoint's shifted x must lie within the wrapped rect's horizontal extent")
        }
        // And the rect must be tight: ~2° wide (1° either side of the seam), nowhere near a
        // whole world.
        #expect(rect.size.width < worldWidth * 0.05)
    }
}
