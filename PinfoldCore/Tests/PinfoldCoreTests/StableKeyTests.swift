import Foundation
@testable import PinfoldCore
import Testing

struct StableKeyTests {
    private func placemark(
        id: String = "p1",
        name: String? = nil,
        coordinate: Coordinate? = nil,
        sourceID: String? = nil
    ) -> KMLPlacemark {
        KMLPlacemark(
            id: id, name: name, descriptionHTML: nil, styleUrl: nil,
            coordinate: coordinate, extendedData: [], photoLinks: [], sourceID: sourceID
        )
    }

    @Test func usesSourceIDWhenPresent() {
        let key = placemark(name: "A", coordinate: Coordinate(longitude: 2, latitude: 1), sourceID: "abc").stableKey
        #expect(key == "id:abc")
    }

    @Test func emptySourceIDFallsThrough() {
        let key = placemark(name: "A", coordinate: Coordinate(longitude: 2, latitude: 1), sourceID: "").stableKey
        #expect(key.hasPrefix("h:"))
    }

    @Test func hashIsStableForSameContent() {
        let a = placemark(name: "Cafe", coordinate: Coordinate(longitude: -0.12, latitude: 51.5)).stableKey
        let b = placemark(id: "p99", name: "Cafe", coordinate: Coordinate(longitude: -0.12, latitude: 51.5)).stableKey
        #expect(a == b) // independent of parse-order id
        #expect(a.hasPrefix("h:"))
    }

    @Test func hashDiffersByCoordinate() {
        let a = placemark(name: "Cafe", coordinate: Coordinate(longitude: -0.12, latitude: 51.5)).stableKey
        let b = placemark(name: "Cafe", coordinate: Coordinate(longitude: -0.12, latitude: 52.0)).stableKey
        #expect(a != b)
    }

    @Test func hashDiffersByName() {
        let coord = Coordinate(longitude: 2, latitude: 1)
        #expect(placemark(name: "A", coordinate: coord).stableKey != placemark(name: "B", coordinate: coord).stableKey)
    }

    @Test func placelessNamelessFallsBackToParseOrderID() {
        #expect(placemark(id: "p7").stableKey == "p:p7")
    }

    @Test func whitespaceOnlySourceIDFallsThrough() {
        let key = placemark(name: "A", coordinate: Coordinate(longitude: 2, latitude: 1), sourceID: "   ").stableKey
        #expect(key.hasPrefix("h:"))
    }

    @Test func emptyNameNoCoordinateFallsBackToParseOrderID() {
        #expect(placemark(id: "p3", name: "").stableKey == "p:p3")
    }

    private func parseOne(_ body: String) throws -> KMLPlacemark {
        let xml = "<kml><Document><Placemark><name>\(body)</Placemark></Document></kml>"
        return try #require(KMLParser.parse(data: Data(xml.utf8)).root.allPlacemarks.first)
    }

    @Test func singlePointPlacemark_hasNoPointGeometry_andSameStableKeyAsBefore() throws {
        let pm = try parseOne("Cafe</name><Point><coordinates>10.5,20.25,0</coordinates></Point>")
        #expect(pm.geometries.isEmpty)
        // Literal captured from the pre-A2 code.
        #expect(pm.stableKey == "h:07eb97e70a8e05a9")
    }

    @Test func multiPoint_stableKeyUsesFirstPoint() throws {
        let multi = try parseOne("""
        Multi</name><MultiGeometry><Point><coordinates>1,2</coordinates></Point>
        <Point><coordinates>3,4</coordinates></Point></MultiGeometry>
        """)
        let single = try parseOne("Multi</name><Point><coordinates>1,2</coordinates></Point>")
        #expect(multi.stableKey == single.stableKey)
    }
}
