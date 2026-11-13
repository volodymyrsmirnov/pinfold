import Foundation
@testable import PinfoldCore
import Testing

struct GeoJSONReaderTests {
    private func read(_ json: String) throws -> KMLDocument {
        try KMLReader.readDocument(data: Data(json.utf8))
    }

    private func feature(_ geometry: String, properties: String = "null", extra: String = "") -> String {
        """
        {"type":"Feature",\(extra) "geometry":\(geometry),"properties":\(properties)}
        """
    }

    @Test func featureCollectionOfPoints() throws {
        let parsed = try KMLReader.read(data: Fixture.data("sample.geojson"))
        #expect(parsed.format == .geoJSON)
        #expect(parsed.embeddedResources.isEmpty)
        #expect(parsed.document.name == "Sample GeoJSON")
        #expect(parsed.document.root.children.isEmpty)
        let cafe = try #require(parsed.document.root.placemarks.first)
        #expect(cafe.name == "Old Town Cafe")
        #expect(cafe.hasPoint)
        #expect(cafe.coordinate == Coordinate(longitude: 14.4208, latitude: 50.0875, altitude: 202.5))
        #expect(parsed.document.root.placemarks.count == 3)
        #expect(parsed.document.pointCount == 1)
    }

    @Test func multiPointKeepsEveryPoint() throws {
        let doc = try KMLReader.readDocument(data: Fixture.data("multipoint.geojson"))
        let mark = try #require(doc.root.placemarks.first)
        #expect(mark.coordinate == Coordinate(longitude: 1, latitude: 2))
        #expect(mark.hasPoint)
        #expect(mark.geometries == [.point(Coordinate(longitude: 3, latitude: 4)),
                                    .point(Coordinate(longitude: 5, latitude: 6))])
    }

    @Test func lineAndPolygonWithHoles() throws {
        let doc = try KMLReader.readDocument(data: Fixture.data("sample.geojson"))
        let line = doc.root.placemarks[1]
        #expect(line.name == "River walk")
        #expect(!line.hasPoint)
        #expect(line.coordinate == Coordinate(longitude: 14.40, latitude: 50.08))
        #expect(line.geometries.count == 1)
        guard case let .lineString(points) = line.geometries[0] else {
            Issue.record("not a line")
            return
        }
        #expect(points.count == 3)
        guard case let .polygon(outer, inners) = doc.root.placemarks[2].geometries[0] else {
            Issue.record("not a polygon")
            return
        }
        #expect(outer.count == 5)
        #expect(inners.count == 1)
        #expect(inners[0].count == 5)
    }

    @Test func multiPolygonBecomesSeveralPolygons() throws {
        let ring = "[[0,0],[1,0],[1,1],[0,0]]"
        let ring2 = "[[5,5],[6,5],[6,6],[5,5]]"
        let doc = try read(feature("""
        {"type":"MultiPolygon","coordinates":[[\(ring)],[\(ring2)]]}
        """))
        let mark = try #require(doc.root.placemarks.first)
        #expect(mark.geometries.count == 2)
        #expect(mark.geometries.allSatisfy {
            if case .polygon = $0 {
                true
            } else {
                false
            }
        })
        let lines = try read(feature("""
        {"type":"MultiLineString","coordinates":[[[0,0],[1,1]],[[2,2],[3,3]]]}
        """))
        #expect(lines.root.placemarks[0].geometries.count == 2)
    }

    @Test func geometryCollection() throws {
        let doc = try read(feature("""
        {"type":"GeometryCollection","geometries":[
          {"type":"LineString","coordinates":[[0,0],[1,1]]},
          {"type":"Point","coordinates":[7,8]},
          {"type":"Point","coordinates":[9,10]}]}
        """))
        let mark = try #require(doc.root.placemarks.first)
        #expect(mark.hasPoint)
        #expect(mark.coordinate == Coordinate(longitude: 7, latitude: 8))
        #expect(mark.geometries == [.lineString([Coordinate(longitude: 0, latitude: 0),
                                                 Coordinate(longitude: 1, latitude: 1)]),
                                    .point(Coordinate(longitude: 9, latitude: 10))])
    }

    @Test func propertiesBecomeNameDescriptionAndData() throws {
        let doc = try KMLReader.readDocument(data: Fixture.data("sample.geojson"))
        let cafe = doc.root.placemarks[0]
        #expect(cafe.descriptionHTML == "Best coffee &amp; cake")
        let data = Dictionary(uniqueKeysWithValues: cafe.extendedData.map { ($0.name, $0.value) })
        #expect(data["rating"] == "4.5")
        #expect(data["open"] == "true")
        #expect(data["tags"] == #"["coffee","cake"]"#)
        #expect(data["name"] == nil)
        #expect(data["description"] == nil)
        #expect(data["marker-color"] == nil)
        #expect(cafe.extendedData.map(\.name) == ["open", "rating", "tags"])
        // `title` is the fallback name and is then not repeated as data.
        #expect(doc.root.placemarks[1].name == "River walk")
        #expect(doc.root.placemarks[1].extendedData.isEmpty)
    }

    @Test func htmlDescriptionIsKept() throws {
        let doc = try read(feature(#"{"type":"Point","coordinates":[1,2]}"#,
                                   properties: #"{"description":"<b>bold</b>"}"#))
        #expect(doc.root.placemarks[0].descriptionHTML == "<b>bold</b>")
    }

    private func description(_ text: String) throws -> String? {
        let encoded = try JSONSerialization.data(withJSONObject: ["description": text])
        let properties = try #require(String(bytes: encoded, encoding: .utf8))
        return try read(feature(#"{"type":"Point","coordinates":[1,2]}"#, properties: properties))
            .root.placemarks[0].descriptionHTML
    }

    @Test func angleBracketWordsInPlainTextAreEscaped() throws {
        #expect(try description("Walk <checked> & done") == "Walk &lt;checked&gt; &amp; done")
        #expect(try description("x<y and a>b") == "x&lt;y and a&gt;b")
        #expect(try description("Bring <your-own> cup") == "Bring &lt;your-own&gt; cup")
    }

    @Test func realHTMLTagsAreKeptInAnyCase() throws {
        #expect(try description("<P>Hi</P>") == "<P>Hi</P>")
        #expect(try description(#"<img src="https://a.example/x.png">"#) == #"<img src="https://a.example/x.png">"#)
        #expect(try description("Line<br/>break") == "Line<br/>break")
        #expect(try description("<!-- note -->Text") == "<!-- note -->Text")
        #expect(try description("<a href=\"https://a.example\">link</a>") == "<a href=\"https://a.example\">link</a>")
    }

    @Test func simplestyleBecomesStyles() throws {
        let doc = try KMLReader.readDocument(data: Fixture.data("sample.geojson"))
        let marker = try #require(doc.resolvedStyle(forStyleUrl: doc.root.placemarks[0].styleUrl))
        #expect(marker.iconColor == "ff0000ff")
        let stroke = try #require(doc.resolvedStyle(forStyleUrl: doc.root.placemarks[1].styleUrl))
        #expect(stroke.lineColor == "ff00ff00")
        #expect(stroke.lineWidth == 3)
        let fill = try #require(doc.resolvedStyle(forStyleUrl: doc.root.placemarks[2].styleUrl))
        #expect(fill.polyColor == "40ff0000")
        #expect(fill.polyFill == true)
    }

    @Test func identicalStylesAreShared() throws {
        let props = ##"{"marker-color":"#112233"}"##
        let point = #"{"type":"Point","coordinates":[1,2]}"#
        let json = """
        {"type":"FeatureCollection","features":[\(feature(point, properties: props)),\(feature(point, properties: props))]}
        """
        let doc = try read(json)
        #expect(doc.styles.count == 1)
        #expect(doc.root.placemarks[0].styleUrl == doc.root.placemarks[1].styleUrl)
        #expect(try read(feature(point, properties: #"{"marker-color":"nope"}"#)).styles.isEmpty)
    }

    @Test func featureIdBecomesStableKey() throws {
        let point = #"{"type":"Point","coordinates":[1,2]}"#
        let doc = try read(feature(point, extra: #""id":42,"#))
        #expect(doc.root.placemarks[0].sourceID == "42")
        #expect(doc.root.placemarks[0].stableKey == "id:42")
        let cafe = try KMLReader.readDocument(data: Fixture.data("sample.geojson"))
        #expect(cafe.root.placemarks[0].stableKey == "id:cafe-1")
    }

    @Test func bareGeometry() throws {
        let doc = try read(#"{"type":"Point","coordinates":[3,4]}"#)
        #expect(doc.root.placemarks.count == 1)
        #expect(doc.root.placemarks[0].coordinate == Coordinate(longitude: 3, latitude: 4))
        #expect(doc.name == nil)
    }

    @Test func shortAndNonNumericPositionsAreDropped() throws {
        let doc = try read(feature(#"{"type":"LineString","coordinates":[[0,0],["x",1],[2,2],[3],true]}"#))
        guard case let .lineString(points) = doc.root.placemarks[0].geometries[0] else {
            Issue.record("not a line")
            return
        }
        #expect(points == [Coordinate(longitude: 0, latitude: 0), Coordinate(longitude: 2, latitude: 2)])
    }

    @Test func overflowingNumbersAreRejectedAsMalformed() {
        // JSONSerialization refuses numbers that overflow to infinity, so no non-finite value
        // can reach the position filter; the whole file is reported as malformed instead.
        do {
            _ = try read(feature(#"{"type":"Point","coordinates":[1,2,1e999]}"#))
            Issue.record("expected a throw")
        } catch KMLReadError.malformedGeoJSON {
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func nullGeometryKeepsAPlacelessPlacemark() throws {
        let doc = try read(feature("null", properties: #"{"name":"Nowhere"}"#))
        #expect(doc.root.placemarks[0].name == "Nowhere")
        #expect(doc.root.placemarks[0].coordinate == nil)
    }

    @Test func invalidJSONThrowsReadableError() {
        do {
            _ = try read(#"{"type": "FeatureCollection", "features": [ "#)
            Issue.record("expected a throw")
        } catch let error as KMLReadError {
            #expect(error.errorDescription?.contains("GeoJSON") == true)
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func nonGeoJSONObjectIsUnsupported() {
        expectReadError(.unsupportedFormat) { try read(#"{"hello":"world"}"#) }
        expectReadError(.unsupportedFormat) { try read(#"{"type":"Topology","objects":{}}"#) }
        expectReadError(.unsupportedFormat) { try read("[1,2,3]") }
        expectReadError(.unsupportedFormat) { try read("[]") }
    }

    @Test func excessiveGeometryNestingIsRejected() {
        var json = #"{"type":"Point","coordinates":[1,2]}"#
        for _ in 0 ..< 40 {
            json = #"{"type":"GeometryCollection","geometries":["# + json + "]}"
        }
        expectReadError(.geoJSONTooComplex) { try read(json) }
    }

    @Test func oversizedGeoJSONIsRefused() {
        let data = Data(#"{"type":"Point","coordinates":[1,2]}"#.utf8)
        expectReadError(.fileTooLarge) {
            try KMLReader.read(data: data, maxPlainBytes: 10, maxArchiveBytes: 10)
        }
    }

    @Test func cancellationStopsTheRead() async {
        let positions = (0 ..< 20000).map { "[\($0 % 100),\($0 % 50)]" }.joined(separator: ",")
        let data = Data(feature(#"{"type":"LineString","coordinates":[\#(positions)]}"#).utf8)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try KMLReader.readDocument(data: data)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
