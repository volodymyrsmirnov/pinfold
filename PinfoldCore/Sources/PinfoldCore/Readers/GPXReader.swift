import Foundation

enum GPXReader {
    static func read(_: Data) throws -> KMLDocument {
        throw KMLReadError.unsupportedFormat
    }
}
