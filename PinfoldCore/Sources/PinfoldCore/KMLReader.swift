import Foundation

public struct ParsedKML: Sendable {
    public let document: KMLDocument
    /// Resources bundled inside a KMZ, keyed by archive-relative path. Empty for plain KML.
    public let embeddedResources: [String: Data]
    /// Archive-relative path of the root KML file for a KMZ (e.g. "doc.kml"), or nil for plain KML.
    /// Phase 2 uses this to resolve resource hrefs that are relative to the root KML's location.
    public let rootKMLPath: String?

    public init(document: KMLDocument, embeddedResources: [String: Data], rootKMLPath: String?) {
        self.document = document
        self.embeddedResources = embeddedResources
        self.rootKMLPath = rootKMLPath
    }
}

public enum KMLReader {
    /// Reads KML or KMZ bytes and returns the parsed document plus any embedded resources.
    public static func read(data: Data) throws -> ParsedKML {
        if KMZArchive.isKMZ(data) {
            let contents = try KMZArchive.extract(data)
            return ParsedKML(document: try KMLParser.parse(data: contents.rootKML),
                             embeddedResources: contents.resources,
                             rootKMLPath: contents.rootKMLPath)
        } else {
            return ParsedKML(document: try KMLParser.parse(data: data),
                             embeddedResources: [:],
                             rootKMLPath: nil)
        }
    }
}
