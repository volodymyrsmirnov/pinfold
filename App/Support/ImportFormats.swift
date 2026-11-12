import Foundation
import PinfoldCore
import UniformTypeIdentifiers

/// What Pinfold accepts as an importable original, and the user-facing wording about it.
enum ImportFormats {
    /// Lower-cased file extensions treated as the original inside an entry folder.
    static let originalExtensions: Set<String> = ["kml", "kmz", "gpx", "geojson", "json"]

    /// File names inside an entry folder that are never the original (synced sidecars).
    static let reservedNames: Set<String> = ["metadata.json"]

    /// The filename an imported original is stored under inside its entry folder.
    ///
    /// The catalogue scanner finds an entry's original by extension, so a shared file that
    /// arrives without a supported extension (or with the reserved sidecar name) would be written
    /// but never found. A supported extension is kept as is; otherwise one is appended by the
    /// detected content: `.kmz`, `.gpx`, `.geojson`, and `.kml` for anything else. A reserved
    /// name (the `metadata.json` sidecar) is renamed so the original can never overwrite it;
    /// since only GeoJSON can arrive under that name, it becomes `metadata.geojson`.
    ///
    /// - Parameters:
    ///   - sanitized: The already-sanitized source filename (see `SafeFilename.sanitize`).
    ///   - data: The file's bytes, used to pick the extension.
    static func storedFilename(for sanitized: String, data: Data) -> String {
        let ext = (sanitized as NSString).pathExtension.lowercased()
        let reserved = reservedNames.contains(sanitized.lowercased())
        if !reserved, originalExtensions.contains(ext) {
            return sanitized
        }
        let newExtension = switch try? KMLReader.detectFormat(of: data) {
        case .kmz: "kmz"
        case .gpx: "gpx"
        case .geoJSON: "geojson"
        case .kml, .none: "kml"
        }
        let stem = reserved ? (sanitized as NSString).deletingPathExtension : sanitized
        return "\(stem).\(newExtension)"
    }

    /// Content types offered by the in-app file importer: KML, KMZ, GPX, GeoJSON, and plain
    /// JSON (content-sniffed on import; not claimed as a document type or in the share sheet).
    static var allowedContentTypes: [UTType] {
        [
            UTType(filenameExtension: "kml") ?? .xml,
            UTType(filenameExtension: "kmz") ?? .zip,
            gpxType,
            geoJSONType,
            .json,
        ]
    }

    /// GPX has no system constant; it is declared as an imported type in `App/Info.plist`.
    private static var gpxType: UTType {
        UTType("com.topografix.gpx") ?? UTType(filenameExtension: "gpx") ?? .xml
    }

    /// `public.geojson` is system-declared (`UTType.geoJSON`).
    private static var geoJSONType: UTType {
        UTType("public.geojson") ?? UTType(filenameExtension: "geojson") ?? .json
    }

    /// Empty-state hint shown when the catalogue has no files.
    static let emptyCatalogueHint = "Import a KML, KMZ, GPX or GeoJSON file using the + button."

    /// Failure reason recorded when a file cannot be read or parsed as KML, KMZ, GPX or GeoJSON.
    static var invalidFileReason: String {
        String(
            localized: "Not a valid KML, KMZ, GPX or GeoJSON file.",
            comment: "Import failure reason: the file could not be read or parsed."
        )
    }
}
