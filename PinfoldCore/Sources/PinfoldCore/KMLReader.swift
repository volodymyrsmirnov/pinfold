import Foundation

public struct ParsedKML: Sendable {
    public let document: KMLDocument
    /// Resources bundled inside a KMZ, keyed **relative to the root KML's directory** — i.e.
    /// matching hrefs exactly as the KML references them. When the root KML lives in a
    /// subdirectory (e.g. `folder/doc.kml`), an archive entry `folder/icons/pin.png` is keyed
    /// as `icons/pin.png` so a `<href>icons/pin.png</href>` lookup resolves. Entries outside
    /// the root KML's directory keep their raw archive path (so `../`-style hrefs from nested
    /// roots remain unsupported — rare). Keys remain traversal-safe: stripping a known prefix
    /// cannot introduce `..`. Empty for plain KML.
    public let embeddedResources: [String: Data]
    /// Archive-relative path of the root KML file for a KMZ (e.g. "doc.kml"), or nil for plain KML.
    /// Used to key `embeddedResources` relative to the root KML's directory.
    public let rootKMLPath: String?

    public init(document: KMLDocument, embeddedResources: [String: Data], rootKMLPath: String?) {
        self.document = document
        self.embeddedResources = embeddedResources
        self.rootKMLPath = rootKMLPath
    }
}

/// Errors surfaced by `KMLReader` above the bare-bytes `KMLParser` layer.
public enum KMLReadError: Error {
    /// A KMZ archive extracted fine, but its root KML entry failed to parse. Carries the
    /// archive-relative entry name so the failure can be attributed to the right file.
    case kmzEntryParseFailed(entry: String, underlying: Error)
}

public enum KMLReader {
    /// Reads KML or KMZ bytes and returns the parsed document plus any embedded resources.
    public static func read(data: Data) throws -> ParsedKML {
        if KMZArchive.isKMZ(data) {
            let contents = try KMZArchive.extract(data)
            let document: KMLDocument
            do {
                document = try KMLParser.parse(data: contents.rootKML)
            } catch {
                throw KMLReadError.kmzEntryParseFailed(entry: contents.rootKMLPath, underlying: error)
            }
            return ParsedKML(document: document,
                             embeddedResources: rootRelativeResources(contents.resources,
                                                                      rootKMLPath: contents.rootKMLPath),
                             rootKMLPath: contents.rootKMLPath)
        } else {
            return try ParsedKML(document: KMLParser.parse(data: data),
                                 embeddedResources: [:],
                                 rootKMLPath: nil)
        }
    }

    /// Re-keys KMZ resources so their keys match hrefs as written in the root KML — i.e.
    /// relative to the root KML's directory. When the root KML is nested (`folder/doc.kml`),
    /// every resource under that directory has the `folder/` prefix stripped
    /// (`folder/icons/pin.png` → `icons/pin.png`). Entries outside the root KML's directory
    /// keep their raw archive path. A top-level root KML (the common case) has no directory
    /// prefix, so this is a no-op. Prefix stripping cannot introduce `..`, so keys stay
    /// traversal-safe.
    private static func rootRelativeResources(
        _ resources: [String: Data], rootKMLPath: String
    ) -> [String: Data] {
        guard let slash = rootKMLPath.lastIndex(of: "/") else { return resources }
        let prefix = String(rootKMLPath[..<rootKMLPath.index(after: slash)]) // includes trailing "/"
        var remapped: [String: Data] = [:]
        remapped.reserveCapacity(resources.count)
        for (key, data) in resources {
            if key.hasPrefix(prefix) {
                remapped[String(key.dropFirst(prefix.count))] = data
            } else {
                remapped[key] = data
            }
        }
        return remapped
    }
}
