import Foundation

/// Geometry mapping for `GeoJSONReader`. Positions are `[lon, lat, alt?]`.
enum GeoJSONGeometry {
    static let types: Set<String> = [
        "Point", "MultiPoint", "LineString", "MultiLineString", "Polygon", "MultiPolygon",
        "GeometryCollection",
    ]

    /// Appends the primitive geometries of `geometry` in file order. `spent` counts positions
    /// (for the complexity budget).
    static func collect(_ geometry: [String: Any], depth: Int, into out: inout [KMLGeometry],
                        spent: inout Int) throws
    // swiftlint:disable:next opening_brace
    {
        guard depth <= GeoJSONReader.maxGeometryDepth else { throw KMLReadError.geoJSONTooComplex }
        try Task.checkCancellation()
        let coordinates = geometry["coordinates"]
        switch geometry["type"] as? String {
        case "Point":
            if let point = position(coordinates) {
                out.append(.point(point))
            }
        case "MultiPoint":
            for point in try positions(coordinates, spent: &spent) {
                out.append(.point(point))
            }
        case "LineString":
            try out.append(.lineString(positions(coordinates, spent: &spent)))
        case "MultiLineString":
            for line in coordinates as? [Any] ?? [] {
                try out.append(.lineString(positions(line, spent: &spent)))
            }
        case "Polygon":
            try appendPolygon(coordinates, into: &out, spent: &spent)
        case "MultiPolygon":
            for polygon in coordinates as? [Any] ?? [] {
                try appendPolygon(polygon, into: &out, spent: &spent)
            }
        case "GeometryCollection":
            for case let child as [String: Any] in geometry["geometries"] as? [Any] ?? [] {
                try collect(child, depth: depth + 1, into: &out, spent: &spent)
            }
        default:
            break // unknown geometry types are ignored; the feature keeps its properties
        }
    }

    /// The first point is the placemark's representative point (and is not repeated in
    /// `geometries`); without any point, the first coordinate of the first shape stands in.
    static func representative(of geometries: [KMLGeometry]) -> Representative {
        guard let index = geometries.firstIndex(where: isPoint),
              case let .point(coordinate) = geometries[index]
        else {
            return Representative(coordinate: geometries.lazy.compactMap(firstCoordinate).first,
                                  hasPoint: false, geometries: geometries)
        }
        var rest = geometries
        rest.remove(at: index)
        return Representative(coordinate: coordinate, hasPoint: true, geometries: rest)
    }

    struct Representative {
        let coordinate: Coordinate?
        let hasPoint: Bool
        let geometries: [KMLGeometry]
    }

    private static func isPoint(_ geometry: KMLGeometry) -> Bool {
        if case .point = geometry {
            true
        } else {
            false
        }
    }

    private static func firstCoordinate(_ geometry: KMLGeometry) -> Coordinate? {
        switch geometry {
        case let .point(coordinate): coordinate
        case let .lineString(points), let .track(points): points.first
        case let .polygon(outer, _): outer.first
        }
    }

    private static func appendPolygon(_ rings: Any?, into out: inout [KMLGeometry], spent: inout Int) throws {
        var parsed: [[Coordinate]] = []
        for ring in rings as? [Any] ?? [] {
            try parsed.append(positions(ring, spent: &spent))
        }
        guard let outer = parsed.first, !outer.isEmpty else { return }
        out.append(.polygon(outer: outer, inners: Array(parsed.dropFirst().filter { !$0.isEmpty })))
    }

    private static func positions(_ raw: Any?, spent: inout Int) throws -> [Coordinate] {
        guard let list = raw as? [Any] else { return [] }
        spent += list.count
        guard spent <= GeoJSONReader.maxWork else { throw KMLReadError.geoJSONTooComplex }
        var result: [Coordinate] = []
        result.reserveCapacity(list.count)
        for (index, item) in list.enumerated() {
            if index.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            if let point = position(item) {
                result.append(point)
            }
        }
        return result
    }

    /// A position with at least two finite numbers; a non-finite altitude is dropped.
    private static func position(_ raw: Any?) -> Coordinate? {
        guard let parts = raw as? [Any], parts.count >= 2,
              let lon = number(parts[0]), let lat = number(parts[1]),
              lon.isFinite, lat.isFinite else { return nil }
        let altitude = parts.count >= 3 ? number(parts[2]).flatMap { $0.isFinite ? $0 : nil } : nil
        return Coordinate(longitude: lon, latitude: lat, altitude: altitude)
    }

    private static func number(_ raw: Any) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }
}
