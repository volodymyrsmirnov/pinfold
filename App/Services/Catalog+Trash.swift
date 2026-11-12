import Foundation

extension Catalog {
    /// Permanently removes every trashed entry (folder + resource cache), removes their
    /// Spotlight items, and reloads once. Active entries are untouched; with nothing in Trash
    /// this is a no-op (no reload).
    func emptyTrash() async {
        let doomed = trashed
        guard !doomed.isEmpty else { return }
        for entry in doomed {
            // Read the index BEFORE removing the folder so placemark Spotlight ids can be rebuilt.
            let indexEntries = await trashIndexEntries(from: storage.resourcesDirectory(for: entry))
            try? storage.removeFolder(named: entry.storageFolderName)
            SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: indexEntries)
        }
        await reload()
    }
}

/// Reads a placemark index off the main actor. `nonisolated` free function so the detached
/// closure is not compiled inside a `@MainActor` context (see `FavoritesView.swift`).
private func trashIndexEntries(from resourcesDir: URL) async -> [PlacemarkIndex.Entry] {
    await Task.detached(priority: .userInitiated) {
        PlacemarkIndex.read(from: resourcesDir) ?? []
    }.value
}
