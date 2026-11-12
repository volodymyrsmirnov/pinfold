import Foundation

enum GeoJSONReader {
    static func read(_: Data) throws -> KMLDocument {
        throw KMLReadError.unsupportedFormat
    }
}
