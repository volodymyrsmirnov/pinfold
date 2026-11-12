import Foundation

/// A user-facing failure of a catalogue mutation, surfaced through `Catalog.actionError`
/// and shown by `CatalogErrorAlert`.
struct CatalogActionError: Identifiable, Equatable {
    let id = UUID()
    /// Plain-language explanation shown in the alert.
    let message: String

    /// The entry's saved data is unreadable or still downloading, so it can't be changed.
    static func readOnly(entryName: String, state: CatalogEntry.SidecarState) -> CatalogActionError {
        switch state {
        case .notDownloaded:
            CatalogActionError(
                message: "\u{201C}\(entryName)\u{201D} is still downloading from iCloud. Try again in a moment."
            )
        case .unreadable, .ok:
            CatalogActionError(
                message: """
                \u{201C}\(entryName)\u{201D} has saved data that can't be read, possibly because it was \
                written by a newer version of Pinfold. It can't be changed until it can be read.
                """
            )
        }
    }

    /// Writing the entry's saved data failed.
    static func saveFailed(entryName: String, error: Error) -> CatalogActionError {
        CatalogActionError(
            message: "Couldn't save changes to \u{201C}\(entryName)\u{201D}: \(error.localizedDescription)"
        )
    }

    /// Removing the entry's files failed.
    static func deleteFailed(entryName: String, error: Error) -> CatalogActionError {
        CatalogActionError(
            message: "Couldn't delete \u{201C}\(entryName)\u{201D}: \(error.localizedDescription)"
        )
    }
}
