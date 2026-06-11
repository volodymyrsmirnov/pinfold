import Foundation

public struct Coordinate: Equatable, Sendable {
    public let longitude: Double
    public let latitude: Double
    public let altitude: Double?

    public init(longitude: Double, latitude: Double, altitude: Double? = nil) {
        self.longitude = longitude
        self.latitude = latitude
        self.altitude = altitude
    }

    /// Parses the first `lon,lat[,alt]` tuple from a KML `<coordinates>` string.
    /// Returns nil if no valid tuple is present.
    public init?(parsingFirstTuple raw: String) {
        let firstTuple = raw
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .first
        guard let firstTuple else { return nil }
        self.init(parsingTuple: String(firstTuple), wholeStringFallback: raw)
    }

    /// Parses every whitespace-separated `lon,lat[,alt]` tuple from a KML `<coordinates>`
    /// string, in order. Unparseable tuples are skipped.
    public static func parseList(_ raw: String) -> [Coordinate] {
        raw
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .compactMap { Coordinate(parsingTuple: String($0), wholeStringFallback: nil) }
    }

    /// Parses a single comma-separated `lon,lat[,alt]` tuple. `wholeStringFallback`, when
    /// provided, is the original `<coordinates>` text used to recover tuples written with
    /// whitespace after the commas ("lon, lat, alt") — only meaningful for a single-tuple
    /// string, so `parseList` passes nil.
    private init?(parsingTuple tuple: String, wholeStringFallback raw: String?) {
        var parts = tuple.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0) }
        if parts.prefix(2).compactMap(Double.init).count < 2, let raw {
            // Fallback for tuples with whitespace after the commas ("lon, lat, alt"):
            // the whitespace split above truncated the tuple, so re-split the whole
            // string on commas, trim each component, and take the first two/three.
            parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",", omittingEmptySubsequences: false)
                .prefix(3)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard parts.count >= 2,
              let lon = Double(parts[0]),
              let lat = Double(parts[1]),
              // Reject non-finite values (NaN / ±Infinity, e.g. from "nan" or "1e999"):
              // they would propagate into MapKit as invalid map points. Out-of-range but
              // finite values are intentionally NOT rejected — clamping/dropping a slightly
              // off coordinate is a worse outcome than letting MapKit place it.
              lon.isFinite, lat.isFinite else { return nil }
        longitude = lon
        latitude = lat
        let altitude = parts.count >= 3 ? Double(parts[2]) : nil
        self.altitude = (altitude?.isFinite ?? false) ? altitude : nil
    }
}
