import CryptoKit
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

    @Test func multiPoint_stableKeyUsesLastPointLikeVersion1_7() throws {
        let multi = try parseOne("""
        Multi</name><MultiGeometry><Point><coordinates>1,2</coordinates></Point>
        <Point><coordinates>3,4</coordinates></Point></MultiGeometry>
        """)
        let last = try parseOne("Multi</name><Point><coordinates>3,4</coordinates></Point>")
        #expect(multi.stableKey == last.stableKey)
        // The display coordinate is still the first point.
        #expect(multi.coordinate == Coordinate(longitude: 1, latitude: 2))
    }
}

/// Pinned keys taken verbatim from the 1.7 parser (`main`) for inputs where 2.0 improved the
/// display fields: the key must not follow them. Favourites/visited/notes hang off it.
struct LegacyStableKeyTests {
    private func parse(_ body: String) throws -> [KMLPlacemark] {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><kml xmlns="http://www.opengis.net/kml/2.2" \
        xmlns:atom="http://www.w3.org/2005/Atom" xmlns:gx="http://www.google.com/kml/ext/2.2">\
        <Document><name>Doc</name>\(body)</Document></kml>
        """
        return try KMLParser.parse(data: Data(xml.utf8)).root.allPlacemarks
    }

    /// (a) MultiGeometry with two points: 1.7 keyed on the last one.
    @Test func a_multiPointKeyUsesLastPoint() throws {
        let pm = try #require(parse("""
        <Placemark><name>MP</name><MultiGeometry><Point><coordinates>1,2,0</coordinates></Point>\
        <Point><coordinates>3,4,0</coordinates></Point></MultiGeometry></Placemark>
        """).first)
        #expect(pm.stableKey == "h:086e63d6ae83789b")
        #expect(pm.coordinate == Coordinate(longitude: 1, latitude: 2, altitude: 0))
    }

    /// (b) A nested `<name>` after the real one wins in 1.7.
    @Test func b_nestedNameKeyUsesLastName() throws {
        let pm = try #require(parse("""
        <Placemark><name>Real</name><atom:author><atom:name>Author</atom:name></atom:author>\
        <Point><coordinates>1,2,0</coordinates></Point></Placemark>
        """).first)
        #expect(pm.stableKey == "h:4be9e12ad5a72d18")
        #expect(pm.name == "Real")
    }

    /// (c) "1, 2, 0 3, 4, 0": 1.7's list parser found nothing, so no coordinate in the key.
    @Test func c_spacedLineKeyHasNoCoordinate() throws {
        let pm = try #require(parse("""
        <Placemark><name>Line</name><LineString><coordinates>1, 2, 0 3, 4, 0</coordinates></LineString></Placemark>
        """).first)
        #expect(pm.stableKey == "h:7608f808b5cab929")
        #expect(pm.coordinate != nil)
    }

    /// (d) An unparseable `<Point>` beside a line: 1.7 keyed on a nil coordinate.
    @Test func d_unparseablePointWithLine() throws {
        let pm = try #require(parse("""
        <Placemark><name>PtLine</name><Point><coordinates>bogus</coordinates></Point>\
        <LineString><coordinates>5,6 7,8</coordinates></LineString></Placemark>
        """).first)
        #expect(pm.stableKey == "h:3394b7bff2495ce3")
        #expect(pm.coordinate == Coordinate(longitude: 5, latitude: 6))
    }

    /// (e) A two-vertex polygon: 1.7 kept its first vertex; 2.0 drops the polygon but still
    /// locates the placemark there.
    @Test func e_degeneratePolygonKeepsCoordinate() throws {
        let pm = try #require(parse("""
        <Placemark><name>Poly</name><Polygon><outerBoundaryIs><LinearRing>\
        <coordinates>1,2,0 3,4,0</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
        """).first)
        #expect(pm.stableKey == "h:39bed3365c3d2d8d")
        #expect(pm.geometries.isEmpty)
        #expect(pm.coordinate == Coordinate(longitude: 1, latitude: 2, altitude: 0))
    }

    /// (f) An inline `<Style>` must not consume the shared id counter: the later
    /// placeless placemark stays `p:p3`.
    @Test func f_inlineStyleDoesNotShiftParseOrderIDs() throws {
        let pms = try parse("""
        <Placemark><name>A</name><Style><IconStyle><scale>2</scale></IconStyle></Style>\
        <Point><coordinates>1,2</coordinates></Point></Placemark>\
        <Placemark><description>nameless placeless</description></Placemark>
        """)
        #expect(pms.map(\.stableKey) == ["h:eff883892a1be8e7", "p:p3"])
    }

    /// An inline StyleMap pair style likewise.
    @Test func inlineStyleMapDoesNotShiftIDs() throws {
        let pms = try parse("""
        <Placemark><name>A</name><StyleMap><Pair><key>normal</key><Style><LineStyle><width>2</width></LineStyle>\
        </Style></Pair></StyleMap><Point><coordinates>1,2</coordinates></Point></Placemark>\
        <Placemark><description>x</description></Placemark>
        """)
        #expect(pms.last?.stableKey == "p:p3")
    }
}

/// Pins `stableKey` for every fallback case so storing it at init cannot change a value.
struct StableKeyPinTests {
    private func key(id: String = "p1", name: String?, _ coordinate: Coordinate?, sourceID: String? = nil) -> String {
        KMLPlacemark(id: id, name: name, descriptionHTML: nil, styleUrl: nil, coordinate: coordinate,
                     extendedData: [], photoLinks: [], sourceID: sourceID).stableKey
    }

    /// The pre-CD-1 computed property, verbatim.
    private func legacy(id: String, name: String?, coordinate: Coordinate?, sourceID: String?) -> String {
        if let sourceID, !sourceID.trimmingCharacters(in: .whitespaces).isEmpty {
            return "id:\(sourceID.trimmingCharacters(in: .whitespaces))"
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespaces)
        let hasName = !(trimmedName?.isEmpty ?? true)
        if hasName || coordinate != nil {
            let lat = coordinate.map { String(format: "%.6f", $0.latitude + 0.0) } ?? ""
            let lon = coordinate.map { String(format: "%.6f", $0.longitude + 0.0) } ?? ""
            let basis = "\(trimmedName ?? "")|\(lat)|\(lon)"
            let hex = SHA256.hash(data: Data(basis.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            return "h:\(hex)"
        }
        return "p:\(id)"
    }

    @Test func literalsStayPinned() {
        #expect(key(name: "Cafe", Coordinate(longitude: 10.5, latitude: 20.25)) == "h:07eb97e70a8e05a9")
        #expect(key(id: "p7", name: nil, nil) == "p:p7")
        #expect(key(id: "p3", name: "  ", nil) == "p:p3")
        #expect(key(name: "A", nil, sourceID: " abc ") == "id:abc")
    }

    @Test func everyFallbackCaseMatchesLegacy() {
        let names: [String?] = [nil, "", "   ", "Cafe", " Cafe ", "Café ☕", "a|b"]
        let coords: [Coordinate?] = [nil, Coordinate(longitude: 0, latitude: 0),
                                     Coordinate(longitude: -0.0, latitude: -0.0),
                                     Coordinate(longitude: -0.12, latitude: 51.5),
                                     Coordinate(longitude: 179.9999999, latitude: -89.1234567)]
        let sources: [String?] = [nil, "", "  ", "abc", " x y "]
        for name in names {
            for coordinate in coords {
                for sourceID in sources {
                    let expected = legacy(id: "p9", name: name, coordinate: coordinate, sourceID: sourceID)
                    #expect(key(id: "p9", name: name, coordinate, sourceID: sourceID) == expected)
                }
            }
        }
    }
}
