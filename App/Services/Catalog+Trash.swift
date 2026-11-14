import Foundation

extension Catalog {
    /// Permanently removes each given entry that is in Trash (folder + resource cache), removes
    /// its Spotlight items, and reloads once. Entries not in Trash are skipped, so this can never
    /// delete an active file; with nothing to delete it is a no-op (no reload).
    func deleteForever(_ selection: [CatalogEntry]) async {
        let trashedFolders = Set(trashed.map(\.storageFolderName))
        let doomed = selection.filter { trashedFolders.contains($0.storageFolderName) }
        guard !doomed.isEmpty else { return }
        for entry in doomed {
            // Read the index BEFORE removing the folder so placemark Spotlight ids can be rebuilt.
            let indexEntries = await trashIndexEntries(from: storage.resourcesDirectory(for: entry))
            do {
                try storage.removeFolder(named: entry.storageFolderName)
                SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: indexEntries)
            } catch {
                actionError = .deleteFailed(entryName: entry.displayName, error: error)
            }
        }
        await reload()
    }
}

/// Reads a placemark index off the main actor. `nonisolated` free function so the detached
/// closure is not compiled inside a `@MainActor` context (see `DocumentLoad.swift`).
private func trashIndexEntries(from resourcesDir: URL) async -> [PlacemarkIndex.Entry] {
    await Task.detached(priority: .userInitiated) {
        PlacemarkIndex.read(from: resourcesDir) ?? []
    }.value
}
