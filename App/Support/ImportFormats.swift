import Foundation
import UniformTypeIdentifiers

/// What Pinfold accepts as an importable original, and the user-facing wording about it.
enum ImportFormats {
    /// Lower-cased file extensions treated as the original KML/KMZ inside an entry folder.
    static let originalExtensions: Set<String> = ["kml", "kmz"]

    /// File names inside an entry folder that are never the original (synced sidecars).
    static let reservedNames: Set<String> = ["metadata.json"]

    /// The filename an imported original is stored under inside its entry folder.
    ///
    /// The catalogue scanner finds an entry's original by extension, so a shared file that
    /// arrives without a supported extension (or with the reserved sidecar name) would be written
    /// but never found. This keeps a supported extension as is and otherwise appends one chosen
    /// by content: a ZIP signature means `.kmz`, anything else `.kml`. A reserved name (the
    /// `metadata.json` sidecar) is renamed so the original can never overwrite it.
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
        let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let newExtension = data.starts(with: zipMagic) ? "kmz" : "kml"
        let stem = reserved ? (sanitized as NSString).deletingPathExtension : sanitized
        return "\(stem).\(newExtension)"
    }

    /// Content types offered by the file importer. Prefers the extension-derived type for an
    /// exact KML/KMZ match and falls back to `.xml` / `.zip` when it is unavailable.
    static var allowedContentTypes: [UTType] {
        let kml = UTType(filenameExtension: "kml") ?? .xml
        let kmz = UTType(filenameExtension: "kmz") ?? .zip
        return [kml, kmz]
    }

    /// Empty-state hint shown when the catalogue has no files.
    static let emptyCatalogueHint = "Import a KML or KMZ file using the + button."

    /// Failure reason recorded when a file cannot be read or parsed as KML/KMZ.
    static var invalidFileReason: String {
        String(
            localized: "Not a valid KML or KMZ file.",
            comment: "Import failure reason: the file could not be read or parsed."
        )
    }
}
