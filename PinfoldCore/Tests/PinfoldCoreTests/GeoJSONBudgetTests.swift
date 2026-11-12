import Foundation
@testable import PinfoldCore
import Testing

/// Every feature, geometry node and position is charged to the work budget, and the byte cap is
/// well below the plain-KML one.
struct GeoJSONBudgetTests {
    private func read(_ json: String, maxWork: Int = GeoJSONReader.maxWork) throws -> KMLDocument {
        try GeoJSONReader.read(Data(json.utf8), maxBytes: GeoJSONReader.maxBytes, maxWork: maxWork)
    }

    private func expectTooComplex(_ json: String, maxWork: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: KMLReadError.self, sourceLocation: sourceLocation) { try read(json, maxWork: maxWork) }
        do {
            _ = try read(json, maxWork: maxWork)
        } catch KMLReadError.geoJSONTooComplex {
            return
        } catch {
            Issue.record("expected geoJSONTooComplex, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func pointsAreCharged() {
        // One Feature, a MultiPoint-free point per geometry node of a collection.
        let points = String(repeating: #"{"type":"Point","coordinates":[1,2]},"#, count: 50)
        let json = #"{"type":"GeometryCollection","geometries":["# + points + #"{"type":"Point","coordinates":[1,2]}]}"#
        expectTooComplex(json, maxWork: 40)
        #expect(throws: Never.self) { try read(json, maxWork: 500) }
    }

    @Test func emptyGeometryCollectionNodesAreCharged() {
        let nodes = String(repeating: #"{"type":"GeometryCollection","geometries":[]},"#, count: 60)
        let json = #"{"type":"GeometryCollection","geometries":["# + nodes + #"{"type":"GeometryCollection"}]}"#
        expectTooComplex(json, maxWork: 50)
    }

    @Test func linesPolygonsAndRingsAreCharged() {
        let lines = String(repeating: "[],", count: 60)
        expectTooComplex(#"{"type":"MultiLineString","coordinates":["# + lines + "[]]}", maxWork: 50)
        let polygons = String(repeating: "[],", count: 60)
        expectTooComplex(#"{"type":"MultiPolygon","coordinates":["# + polygons + "[]]}", maxWork: 50)
        let rings = String(repeating: "[],", count: 60)
        expectTooComplex(#"{"type":"Polygon","coordinates":["# + rings + "[]]}", maxWork: 50)
    }

    @Test func manyPointFeaturesStillCountPerFeatureAndPoint() {
        let feature = #"{"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":null},"#
        let json = #"{"type":"FeatureCollection","features":["# + String(repeating: feature, count: 30) + "null]}"
        // 30 features x (feature + point node + point) = 90 units.
        expectTooComplex(json, maxWork: 80)
        #expect(throws: Never.self) { try read(json, maxWork: 100) }
    }

    @Test func byteCapIsSixtyFourMiB() {
        #expect(GeoJSONReader.maxBytes == 64 * 1024 * 1024)
    }

    @Test func oversizedGeoJSONFailsWithReadableError() {
        let data = Data(#"{"type":"Point","coordinates":[1,2]}"#.utf8)
        do {
            _ = try GeoJSONReader.read(data, maxBytes: 10)
            Issue.record("expected fileTooLarge")
        } catch let error as KMLReadError {
            guard case .fileTooLarge = error else {
                Issue.record("expected fileTooLarge, got \(error)")
                return
            }
            #expect(error.errorDescription == "This file is too large to open.")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
