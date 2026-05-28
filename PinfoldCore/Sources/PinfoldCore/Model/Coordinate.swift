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
        let parts = firstTuple.split(separator: ",", omittingEmptySubsequences: false)
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
