import Foundation
@testable import PinfoldCore
import Testing

struct GPXReaderTests {
    private func wrap(_ body: String, prolog: String = "") -> Data {
        Data("""
        \(prolog)<gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1">\(body)</gpx>
        """.utf8)
    }

    private func read(_ body: String) throws -> KMLDocument {
        try KMLReader.readDocument(data: wrap(body))
    }

    private func folder(_ doc: KMLDocument, _ name: String) throws -> KMLContainer {
        try #require(doc.root.children.first { $0.name == name })
    }

    @Test func waypointsBecomePointPlacemarks() throws {
        let parsed = try KMLReader.read(data: Fixture.data("sample.gpx"))
        #expect(parsed.format == .gpx)
        #expect(parsed.embeddedResources.isEmpty)
        let waypoints = try folder(parsed.document, "Waypoints").placemarks
        #expect(waypoints.count == 2)
        let head = waypoints[0]
        #expect(head.name == "Trailhead")
        #expect(head.hasPoint)
        #expect(head.coordinate == Coordinate(longitude: 14.4208, latitude: 50.0875, altitude: 202.5))
        #expect(head.geometries.isEmpty)
        #expect(head.descriptionHTML == #"Start &amp; finish<br><a href="https://example.com/trailhead">Trail page</a>"#)
        let data = Dictionary(uniqueKeysWithValues: head.extendedData.map { ($0.name, $0.value) })
        #expect(data["sym"] == "Flag, Blue")
        #expect(data["type"] == "Parking")
        #expect(data["time"] == "2025-05-01T09:30:00Z")
        #expect(data["cmt"] == "Park by the gate")
        // `cmt` stands in for a missing `desc` and is then not repeated as data.
        #expect(waypoints[1].descriptionHTML == "Great view")
        #expect(waypoints[1].extendedData.isEmpty)
    }

    @Test func trackSegmentsBecomeTrackGeometries() throws {
        let doc = try KMLReader.readDocument(data: Fixture.data("sample.gpx"))
        let track = try #require(folder(doc, "Tracks").placemarks.first)
        #expect(track.name == "Morning track")
        #expect(!track.hasPoint)
        #expect(track.coordinate == Coordinate(longitude: 14.4208, latitude: 50.0875, altitude: 202.5))
        #expect(track.geometries == [
            .track([Coordinate(longitude: 14.4208, latitude: 50.0875, altitude: 202.5),
                    Coordinate(longitude: 14.43, latitude: 50.09, altitude: 250)]),
            .track([Coordinate(longitude: 14.44, latitude: 50.095), Coordinate(longitude: 14.45, latitude: 50.1)]),
        ])
        #expect(track.extendedData.map(\.name) == ["type"])
    }

    @Test func routeBecomesLineString() throws {
        let doc = try KMLReader.readDocument(data: Fixture.data("sample.gpx"))
        let route = try #require(folder(doc, "Routes").placemarks.first)
        #expect(route.name == "Return route")
        guard case let .lineString(points) = route.geometries.first else {
            Issue.record("not a line")
            return
        }
        #expect(points.count == 3)
        #expect(points[0].altitude == 310)
        #expect(route.geometries.count == 1)
    }

    @Test func metadataNameBecomesDocumentName() throws {
        let doc = try KMLReader.readDocument(data: Fixture.data("sample.gpx"))
        #expect(doc.name == "Sample Hike")
        #expect(doc.descriptionHTML == "A short loop")
        #expect(try read(#"<wpt lat="1" lon="2"/>"#).name == nil)
    }

    @Test func mixedFileGetsThreeFolders() throws {
        let doc = try KMLReader.readDocument(data: Fixture.data("sample.gpx"))
        #expect(doc.root.placemarks.isEmpty)
        #expect(doc.root.children.map(\.name) == ["Waypoints", "Tracks", "Routes"])
        #expect(doc.placemarkCount == 4)
        #expect(Set(doc.root.allPlacemarks.map(\.id)).count == 4)
    }

    @Test func singleKindStaysFlat() throws {
        let doc = try read(#"<wpt lat="1" lon="2"><name>A</name></wpt><wpt lat="3" lon="4"/>"#)
        #expect(doc.root.children.isEmpty)
        #expect(doc.root.placemarks.count == 2)
    }

    @Test func invalidWaypointsAndUnsafeLinksAreDropped() throws {
        let doc = try read("""
        <wpt lat="95x" lon="2"><name>bad</name></wpt>
        <wpt lat="1" lon="2"><name>ok</name><link href="javascript:alert(1)"><text>x</text></link></wpt>
        """)
        #expect(doc.root.placemarks.count == 1)
        #expect(doc.root.placemarks[0].descriptionHTML == nil)
    }

    @Test func extensionTextIsNotMistakenForFields() throws {
        let doc = try read("""
        <wpt lat="1" lon="2"><name>Real</name><extensions><x:name xmlns:x="u">Fake</x:name>\
        <name>Nested</name></extensions></wpt>
        """)
        #expect(doc.root.placemarks[0].name == "Real")
    }

    @Test func gpxWithDoctypeSubsetIsRejected() {
        let prolog = #"<?xml version="1.0"?><!DOCTYPE gpx [<!ENTITY a "b">]>"#
        #expect(throws: KMLParseError.dtdProhibited) {
            try KMLReader.readDocument(data: wrap(#"<wpt lat="1" lon="2"/>"#, prolog: prolog))
        }
    }

    @Test(arguments: [
        #"<!DOCTYPE gpx [<!ENTITY a "b">]>"#,
        "<!DOCTYPE gpx [<!ELEMENT gpx ANY>]>",
        "<!DOCTYPE gpx [<!ATTLIST gpx a CDATA #IMPLIED>]>",
        #"<!DOCTYPE gpx [<!NOTATION gif SYSTEM "x">]>"#,
    ])
    func delegateAbortsOnAnyDeclaration(_ doctype: String) {
        // `parseUnguarded` skips the byte scan, so only the delegate callbacks can stop this.
        #expect(throws: KMLParseError.dtdProhibited) {
            try GPXReader.parseUnguarded(wrap(#"<wpt lat="1" lon="2"/>"#, prolog: doctype + "\n"))
        }
    }

    @Test func unsupportedEncodingIsRejected() {
        let data = Data(#"<?xml version="1.0" encoding="UTF-7"?><gpx/>"#.utf8)
        #expect(throws: KMLParseError.unsupportedEncoding) { try GPXReader.read(data) }
    }

    @Test func malformedGPXReportsLine() {
        let xml = "<gpx>\n<wpt lat=\"1\" lon=\"2\">\n<name>A</wpt>\n</gpx>"
        do {
            _ = try GPXReader.read(Data(xml.utf8))
            Issue.record("expected a throw")
        } catch let KMLParseError.malformedXML(line, _, _, _) {
            #expect((3 ... 4).contains(line)) // libxml2 reports at/after the mismatched end tag
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func nonGPXRootThrows() {
        #expect(throws: KMLParseError.unsupportedRootElement("html")) {
            try GPXReader.read(Data("<html/>".utf8))
        }
    }

    @Test func cancellationStopsTheRead() async {
        let points = (0 ..< 5000).map { #"<trkpt lat="\#($0 % 80)" lon="\#($0 % 170)"/>"# }.joined()
        let data = wrap("<trk><trkseg>\(points)</trkseg></trk>")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try KMLReader.readDocument(data: data)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
