import UniformTypeIdentifiers

/// What Pinfold accepts as an importable original, and the user-facing wording about it.
enum ImportFormats {
    /// Lower-cased file extensions treated as the original KML/KMZ inside an entry folder.
    static let originalExtensions: Set<String> = ["kml", "kmz"]

    /// File names inside an entry folder that are never the original (synced sidecars).
    static let reservedNames: Set<String> = ["metadata.json"]

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
