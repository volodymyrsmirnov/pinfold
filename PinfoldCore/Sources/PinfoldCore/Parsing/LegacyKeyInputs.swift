import Foundation

/// The inputs `KMLPlacemark.stableKey` was derived from in Pinfold 1.7, tracked next to the
/// improved display fields while parsing.
///
/// Favourites, visited marks and notes are persisted against `stableKey`, so a key must stay
/// byte-identical for every placemark 1.7 accepted even though the display name, coordinate
/// and geometry have since improved. Everything here deliberately mirrors the 1.7 parser:
/// the last `<name>` seen anywhere in the placemark (nested ones included), the last
/// `<Point>`'s coordinate (even an unparseable one), 1.7's whitespace-split coordinate lists
/// for the first-geometry fallback, and 1.7's keep rule.
struct LegacyKeyInputs {
    /// Last `<name>` closed anywhere inside the placemark, trimmed of whitespace/newlines.
    var name: String?
    /// True once any `<Point>` opened, valid or not.
    var hasPoint = false
    /// Coordinate of the last `<Point>`'s `<coordinates>` (nil when it did not parse).
    var pointCoordinate: Coordinate?
    /// True once a line, polygon or track closed (1.7 kept every one, however short).
    var hasGeometry = false
    /// First coordinate of the first closed geometry that had one (1.7 semantics).
    var firstGeometryCoordinate: Coordinate?
    /// True for a `<Model>` or `<gx:MultiTrack>`, which 1.7 did not capture.
    var hasUncapturedGeometry = false
    /// First coordinate of the open `<LineString>`'s last `<coordinates>`.
    var lineFirst: Coordinate?
    /// First coordinate of the open polygon's last outer-boundary `<coordinates>`.
    var outerFirst: Coordinate?

    /// The coordinate 1.7 used as the placemark's representative one.
    var coordinate: Coordinate? {
        hasPoint ? pointCoordinate : firstGeometryCoordinate
    }

    /// 1.7's keep rule: a point, any geometry, or no uncaptured geometry at all.
    var isKept: Bool {
        hasPoint || hasGeometry || !hasUncapturedGeometry
    }

    /// The 1.7-compatible key: legacy name and coordinate, never the improved display ones.
    func stableKey(id: String, sourceID: String?) -> String {
        KMLPlacemark.makeStableKey(id: id, name: name, coordinate: coordinate, sourceID: sourceID)
    }

    mutating func closeGeometry(first: Coordinate?) {
        hasGeometry = true
        if firstGeometryCoordinate == nil {
            firstGeometryCoordinate = first
        }
    }
}

/// 1.7's coordinate parsing, kept verbatim so legacy key inputs do not follow later
/// tokenizer improvements ("1, 2, 0 3, 4, 0" is a list of nothing here, a pair of points in
/// the display parser).
enum LegacyCoordinate {
    private static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\n" || character == "\t" || character == "\r"
    }

    static func firstTuple(_ raw: String) -> Coordinate? {
        guard let first = raw.split(whereSeparator: isSpace).first else { return nil }
        return tuple(String(first), wholeStringFallback: raw)
    }

    static func list(_ raw: String) -> [Coordinate] {
        raw.split(whereSeparator: isSpace)
            .compactMap { tuple(String($0), wholeStringFallback: nil) }
    }

    private static func tuple(_ tuple: String, wholeStringFallback raw: String?) -> Coordinate? {
        var parts = tuple.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0) }
        if parts.prefix(2).compactMap(Double.init).count < 2, let raw {
            parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",", omittingEmptySubsequences: false)
                .prefix(3)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard parts.count >= 2,
              let lon = Double(parts[0]),
              let lat = Double(parts[1]),
              lon.isFinite, lat.isFinite else { return nil }
        let altitude = parts.count >= 3 ? Double(parts[2]) : nil
        return Coordinate(longitude: lon, latitude: lat,
                          altitude: (altitude?.isFinite ?? false) ? altitude : nil)
    }
}
