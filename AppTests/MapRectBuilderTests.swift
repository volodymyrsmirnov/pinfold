import MapKit
@testable import Pinfold
import PinfoldCore
import Testing

/// Tests for `MapRectBuilder.boundingRect(for:)`. Pure geometry — no shared state,
/// no MapKit view, so no `.serialized` requirement.
struct MapRectBuilderTests {
    @Test func emptyInput_returnsNil() {
        #expect(MapRectBuilder.boundingRect(for: []) == nil)
    }

    @Test func singlePoint_returnsZeroSizeRectAtThatPoint() throws {
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

    @Test func antimeridianSpanningPoints_rectContainsBothEndpoints() throws {
        let coords = [
            Coordinate(longitude: 179.0, latitude: 0.0),
            Coordinate(longitude: -179.0, latitude: 0.0),
        ]
        let rect = MapRectBuilder.boundingRect(for: coords)
        #expect(rect != nil)
        for coord in coords {
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: coord.latitude, longitude: coord.longitude))
            #expect(try #require(rect?.contains(point)))
        }
    }
}
