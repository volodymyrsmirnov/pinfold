import Foundation

/// One catalogue item, sourced directly from a per-entry folder in the active storage
/// root. This is a plain value type: the catalogue is rebuilt from the folders on disk
/// (see `CatalogScanner`), never persisted in a parallel database.
///
/// The on-disk representation is `EntryMetadata` (`metadata.json`); this adds the folder
/// name so the app can locate the entry's files, and exposes the same field names the
/// views previously read from the SwiftData model.
struct CatalogEntry: Identifiable, Equatable {
    var id: UUID
    var displayName: String
    var sourceFilename: String
    var importDate: Date
    var pointCount: Int
    var contentSHA256: String
    var storageFolderName: String
    var trashedAt: Date?
    /// User-assigned labels (per-ENTRY), copied from the sidecar so the catalogue list can
    /// render filter chips and per-row tag text without re-reading metadata. Kept sorted.
    var tags: [String] = []

    /// `true` when the entry has been moved to Trash.
    var isTrashed: Bool {
        trashedAt != nil
    }
}

extension CatalogEntry {
    /// Builds an entry from its on-disk sidecar plus the folder it lives in.
    init(metadata: EntryMetadata, storageFolderName: String) {
        self.init(
            id: metadata.id,
            displayName: metadata.displayName,
            sourceFilename: metadata.sourceFilename,
            importDate: metadata.importDate,
            pointCount: metadata.pointCount,
            contentSHA256: metadata.contentSHA256,
            storageFolderName: storageFolderName,
            trashedAt: metadata.trashedAt,
            tags: metadata.tags
        )
    }

    /// The sidecar representation of this entry, for writing back to disk.
    var metadata: EntryMetadata {
        EntryMetadata(
            id: id,
            displayName: displayName,
            sourceFilename: sourceFilename,
            importDate: importDate,
            pointCount: pointCount,
            contentSHA256: contentSHA256,
            trashedAt: trashedAt,
            tags: tags
        )
    }
}
