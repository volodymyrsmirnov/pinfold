import Foundation

/// Reads RFC 7946 GeoJSON into the same `KMLDocument` model the KML parser produces.
///
/// A `FeatureCollection`, a single `Feature` or a bare geometry becomes one flat root container
/// (`id` "root") holding one placemark per feature. Placemark ids are `p1`, `p2`, ... in file
/// order, and synthesized style ids are `geojson-style-1`, ... in order of first use.
enum GeoJSONReader {
    /// Geometry nesting (`GeometryCollection` inside `GeometryCollection`) deeper than this is
    /// refused as `geoJSONTooComplex`.
    static let maxGeometryDepth = 32
    /// Features plus positions a single file may contain before it is refused.
    static let maxWork = 5_000_000

    static func read(_ data: Data) throws -> KMLDocument {
        try Task.checkCancellation()
        let object = try parseJSON(data)
        guard let top = object as? [String: Any], let type = top["type"] as? String else {
            throw KMLReadError.unsupportedFormat
        }
        var builder = GeoJSONBuilder()
        var name: String?
        switch type {
        case "FeatureCollection":
            name = (top["name"] as? String).flatMap(GeoJSONProperties.nonEmpty)
            for case let feature as [String: Any] in top["features"] as? [Any] ?? [] {
                try builder.addFeature(feature)
            }
        case "Feature":
            try builder.addFeature(top)
        case _ where GeoJSONGeometry.types.contains(type):
            try builder.addPlacemark(geometry: top, properties: nil, id: nil)
        default:
            throw KMLReadError.unsupportedFormat
        }
        return builder.makeDocument(name: name)
    }

    private static func parseJSON(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch let error as NSError {
            let detail = error.userInfo[NSDebugDescriptionErrorKey] as? String ?? "code \(error.code)"
            throw KMLReadError.malformedGeoJSON(detail)
        }
    }
}

/// Accumulates placemarks and the deduplicated styles while walking the JSON tree.
struct GeoJSONBuilder {
    private var placemarks: [KMLPlacemark] = []
    private var styles: [String: KMLStyle] = [:]
    private var styleIDs: [GeoJSONStyleKey: String] = [:]
    private var work = 0

    mutating func addFeature(_ feature: [String: Any]) throws {
        try Task.checkCancellation()
        try spend(1)
        let geometry = feature["geometry"] as? [String: Any]
        let properties = feature["properties"] as? [String: Any]
        try addPlacemark(geometry: geometry, properties: properties,
                         id: GeoJSONProperties.identifier(feature["id"]))
    }

    mutating func addPlacemark(geometry: [String: Any]?, properties: [String: Any]?, id: String?) throws {
        var geometries: [KMLGeometry] = []
        if let geometry {
            var spent = 0
            try GeoJSONGeometry.collect(geometry, depth: 0, into: &geometries, spent: &spent)
            try spend(spent)
        }
        let fields = GeoJSONProperties(properties ?? [:])
        let styleUrl = fields.style.map { styleURL(for: $0) }
        let shape = GeoJSONGeometry.representative(of: geometries)
        placemarks.append(KMLPlacemark(
            id: "p\(placemarks.count + 1)", name: fields.name, descriptionHTML: fields.descriptionHTML,
            styleUrl: styleUrl, coordinate: shape.coordinate, hasPoint: shape.hasPoint,
            geometries: shape.geometries, extendedData: fields.data, photoLinks: [], sourceID: id
        ))
    }

    func makeDocument(name: String?) -> KMLDocument {
        let root = KMLContainer(id: "root", name: nil, children: [], placemarks: placemarks)
        return KMLDocument(name: name, descriptionHTML: nil, root: root, styles: styles, styleMaps: [:])
    }

    private mutating func spend(_ amount: Int) throws {
        work += amount
        if work > GeoJSONReader.maxWork {
            throw KMLReadError.geoJSONTooComplex
        }
    }

    private mutating func styleURL(for key: GeoJSONStyleKey) -> String {
        if let existing = styleIDs[key] {
            return "#\(existing)"
        }
        let id = "geojson-style-\(styleIDs.count + 1)"
        styleIDs[key] = id
        styles[id] = KMLStyle(id: id, iconHref: nil, iconColor: key.iconColor, iconScale: nil,
                              lineColor: key.lineColor, lineWidth: key.lineWidth,
                              polyColor: key.polyColor, polyFill: key.polyColor == nil ? nil : true)
        return "#\(id)"
    }
}
