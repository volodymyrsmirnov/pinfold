import Foundation

extension Catalog {
    /// Permanently removes each given entry that is in Trash (folder + resource cache), removes
    /// its Spotlight items, and reloads once. With nothing to delete it is a no-op (no reload).
    ///
    /// The single path for every permanent delete (a Trash row, select-mode Delete), and it can
    /// never remove a file that isn't in Trash: the check that the sidecar still says "trashed"
    /// and the removal happen inside one coordinated file lock (`removeFolderIfTrashed`), so a
    /// restore from this or another device can't slip in between. An entry restored meanwhile,
    /// or already deleted by a repeated tap, is skipped quietly; one whose sidecar can't be read
    /// is kept and reported. Deletion also stops if the storage root changed during an index
    /// read (the iCloud sync toggle), so it never acts on a root the selection didn't come from.
    func deleteForever(_ selection: [CatalogEntry]) async {
        let trashedFolders = Set(trashed.map(\.storageFolderName))
        let doomed = selection.filter { trashedFolders.contains($0.storageFolderName) }
        guard !doomed.isEmpty else { return }
        let root = storage.root
        var unreadable: [CatalogEntry] = []
        for entry in doomed {
            // Read the index BEFORE removing the folder so placemark Spotlight ids can be rebuilt.
            let indexEntries = await trashIndexEntries(from: storage.resourcesDirectory(for: entry))
            guard storage.root == root else { break }
            do {
                switch try storage.removeFolderIfTrashed(named: entry.storageFolderName) {
                case .removed:
                    SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: indexEntries)
                case .notTrashed:
                    break
                case .unreadable:
                    unreadable.append(entry)
                }
            } catch {
                actionError = .deleteFailed(entryName: entry.displayName, error: error)
            }
        }
        if !unreadable.isEmpty, actionError == nil {
            actionError = Self.keptInTrashError(unreadable)
        }
        await reload()
    }

    /// Why some files stayed in Trash: their saved data can't be read, so it can't be confirmed
    /// they are still trashed (they may be mid-download or restored on another device).
    private static func keptInTrashError(_ kept: [CatalogEntry]) -> CatalogActionError {
        if kept.count == 1, let only = kept.first {
            return CatalogActionError(
                message: "\u{201C}\(only.displayName)\u{201D} was kept: its saved data can't be read yet "
                    + "(it may still be downloading from iCloud). Try again in a moment."
            )
        }
        return CatalogActionError(
            message: "\(kept.count) files were kept: their saved data can't be read yet "
                + "(they may still be downloading from iCloud). Try again in a moment."
        )
    }
}

/// Reads a placemark index off the main actor. `nonisolated` free function so the detached
/// closure is not compiled inside a `@MainActor` context (see `DocumentLoad.swift`).
private func trashIndexEntries(from resourcesDir: URL) async -> [PlacemarkIndex.Entry] {
    await Task.detached(priority: .userInitiated) {
        PlacemarkIndex.read(from: resourcesDir) ?? []
    }.value
}
