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
    /// The format the data was read from (KML, KMZ, GPX or GeoJSON).
    public let format: SourceFormat

    public init(document: KMLDocument, embeddedResources: [String: Data], rootKMLPath: String?,
                format: SourceFormat = .kml)
    // swiftlint:disable:next opening_brace
    {
        self.format = format
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
    /// A plain (non-zip) input exceeds the size cap.
    case fileTooLarge
    /// The bytes are not KML, KMZ, GPX or GeoJSON (empty input, an unknown XML root, plain text).
    case unsupportedFormat
}

extension KMLReadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .kmzEntryParseFailed(entry, underlying):
            "\(entry): \(underlying.localizedDescription)"
        case .fileTooLarge:
            "This file is too large to open."
        case .unsupportedFormat:
            "This is not a KML, KMZ, GPX or GeoJSON file."
        }
    }
}

public enum KMLReader {
    /// Cap on a plain (non-zip) KML input.
    public static let defaultMaxPlainBytes = 256 * 1024 * 1024 // 256 MiB

    /// Reads KML or KMZ bytes and returns the parsed document plus any embedded resources.
    /// Every resource is inflated into memory; for large archives prefer `readDocument(data:)`
    /// plus `extractResources(fromKMZ:into:filenameFor:)`.
    public static func read(data: Data) throws -> ParsedKML {
        try read(data: data, maxPlainBytes: defaultMaxPlainBytes,
                 maxArchiveBytes: KMZArchive.defaultMaxUncompressedBytes)
    }

    /// Parses only the document: for a KMZ, inflates just the root KML (resources are never
    /// touched, so a large photo set costs nothing). Same document `read(data:)` returns.
    public static func readDocument(data: Data) throws -> KMLDocument {
        try readDocument(data: data, maxPlainBytes: defaultMaxPlainBytes,
                         maxRootBytes: KMZArchive.defaultMaxUncompressedBytes)
    }

    /// The format of `data`, decided from its content (never a file extension). Throws
    /// `KMLReadError.unsupportedFormat` for anything that is not KML, KMZ, GPX or GeoJSON.
    public static func detectFormat(of data: Data) throws -> SourceFormat {
        KMZArchive.isKMZ(data) ? .kmz : try FormatSniffer.sniff(data)
    }

    /// Streams each non-root KMZ entry to `directory`; returns root-relative key (matching
    /// hrefs as written in the KML) -> written filename. `filenameFor` maps a key to a flat
    /// filename. Unsafe entry paths are skipped. Capped at 1 GiB in total. On any throw, the
    /// files this call already wrote are deleted again (the directory itself is kept).
    @discardableResult
    public static func extractResources(
        fromKMZ data: Data, into directory: URL, filenameFor: (String) -> String
    ) throws -> [String: String] {
        try KMZArchive.extractResources(data, into: directory, filenameFor: filenameFor)
    }

    static func readDocument(data: Data, maxPlainBytes: Int, maxRootBytes: Int) throws -> KMLDocument {
        guard KMZArchive.isKMZ(data) else { return try parsePlain(data, maxBytes: maxPlainBytes).document }
        let root = try KMZArchive.extractRoot(data, maxRootBytes: maxRootBytes)
        return try parseRoot(root.rootKML, path: root.rootKMLPath)
    }

    static func read(data: Data, maxPlainBytes: Int, maxArchiveBytes: Int) throws -> ParsedKML {
        guard KMZArchive.isKMZ(data) else {
            let plain = try parsePlain(data, maxBytes: maxPlainBytes)
            return ParsedKML(document: plain.document, embeddedResources: [:], rootKMLPath: nil,
                             format: plain.format)
        }
        let contents = try KMZArchive.extract(data, maxUncompressedBytes: maxArchiveBytes)
        let document = try parseRoot(contents.rootKML, path: contents.rootKMLPath)
        let resources = contents.resources.reduce(into: [String: Data]()) { result, pair in
            result[KMZArchive.rootRelativeKey(pair.key, rootKMLPath: contents.rootKMLPath)] = pair.value
        }
        return ParsedKML(document: document, embeddedResources: resources,
                         rootKMLPath: contents.rootKMLPath, format: .kmz)
    }

    /// Size-capped, content-dispatched parse of non-zip input.
    private static func parsePlain(_ data: Data, maxBytes: Int) throws -> (document: KMLDocument, format: SourceFormat) {
        guard data.count <= maxBytes else { throw KMLReadError.fileTooLarge }
        let format = try FormatSniffer.sniff(data)
        switch format {
        case .geoJSON: return try (GeoJSONReader.read(data), format)
        case .gpx: return try (GPXReader.read(data), format)
        case .kml, .kmz: return try (KMLParser.parse(data: data), .kml)
        }
    }

    private static func parseRoot(_ bytes: Data, path: String) throws -> KMLDocument {
        do {
            return try KMLParser.parse(data: bytes)
        } catch {
            throw KMLReadError.kmzEntryParseFailed(entry: path, underlying: error)
        }
    }
}
