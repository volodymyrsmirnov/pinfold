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
        guard let first = Self.tokenize(raw, limit: 1).first else { return nil }
        self.init(parts: first)
    }

    /// Parses every `lon,lat[,alt]` tuple from a KML `<coordinates>` string, in order.
    /// Unparseable tuples are skipped.
    public static func parseList(_ raw: String) -> [Coordinate] {
        tokenize(raw, limit: Int.max).compactMap { Coordinate(parts: $0) }
    }

    /// Splits `raw` into tuples of number strings. A comma (with optional whitespace on
    /// either side) continues the current tuple; whitespace with no comma starts the next
    /// one, so "1, 2, 0 3, 4, 0" yields two tuples. Stops once `limit` tuples are complete.
    private static func tokenize(_ raw: String, limit: Int) -> [[String]] {
        var tuples: [[String]] = []
        var current: [String] = []
        var continues = false // the last significant token was a comma
        var tokenStart: Int?
        let comma = UInt8(ascii: ",")

        func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
        }

        var text = raw
        text.makeContiguousUTF8()
        return text.utf8.withContiguousStorageIfAvailable { bytes -> [[String]] in
            func flushNumber(upTo end: Int) {
                guard let start = tokenStart else { return }
                tokenStart = nil
                let token = String(decoding: UnsafeBufferPointer(rebasing: bytes[start ..< end]), as: UTF8.self)
                if continues, !current.isEmpty {
                    current.append(token)
                } else {
                    if !current.isEmpty {
                        tuples.append(current)
                    }
                    current = [token]
                }
                continues = false
            }
            for index in 0 ..< bytes.count {
                if tuples.count >= limit {
                    return tuples
                }
                let byte = bytes[index]
                if byte == comma {
                    flushNumber(upTo: index)
                    if continues {
                        current.append("")
                    } // ",," leaves an empty component
                    if current.isEmpty {
                        current = [""]
                    }
                    continues = true
                } else if isSpace(byte) {
                    flushNumber(upTo: index)
                } else if tokenStart == nil {
                    tokenStart = index
                }
            }
            flushNumber(upTo: bytes.count)
            if !current.isEmpty {
                tuples.append(current)
            }
            return Array(tuples.prefix(limit))
        } ?? []
    }

    private init?(parts: [String]) {
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
