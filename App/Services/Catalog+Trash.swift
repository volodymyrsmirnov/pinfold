import Foundation

extension Catalog {
    /// Permanently removes each given entry that is in Trash (folder + resource cache), removes
    /// its Spotlight items, and reloads once. With nothing to delete it is a no-op (no reload).
    ///
    /// The single path for every permanent delete (a Trash row, select-mode Delete), and it can
    /// never remove a file that isn't in Trash. Each entry's sidecar on disk is checked right
    /// before its folder is removed, with no suspension in between: an entry restored (on this
    /// device or another) while an earlier index read was awaited is skipped, as is one already
    /// deleted by a repeated tap. Deletion also stops if the storage root changed meanwhile (the
    /// iCloud sync toggle), so it never acts on a root the selection didn't come from.
    func deleteForever(_ selection: [CatalogEntry]) async {
        let trashedFolders = Set(trashed.map(\.storageFolderName))
        let doomed = selection.filter { trashedFolders.contains($0.storageFolderName) }
        guard !doomed.isEmpty else { return }
        let root = storage.root
        for entry in doomed {
            // Read the index BEFORE removing the folder so placemark Spotlight ids can be rebuilt.
            let indexEntries = await trashIndexEntries(from: storage.resourcesDirectory(for: entry))
            guard storage.root == root else { break }
            guard isStillTrashedOnDisk(entry) else { continue }
            do {
                try storage.removeFolder(named: entry.storageFolderName)
                SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: indexEntries)
            } catch {
                actionError = .deleteFailed(entryName: entry.displayName, error: error)
            }
        }
        await reload()
    }

    /// Whether `entry`'s sidecar on disk still marks it as trashed. A sidecar that can't be read
    /// counts as "not trashed": when in doubt, keep the file.
    private func isStillTrashedOnDisk(_ entry: CatalogEntry) -> Bool {
        let meta = try? storage.readMetadata(forFolderNamed: entry.storageFolderName)
        return meta?.trashedAt != nil
    }
}

/// Reads a placemark index off the main actor. `nonisolated` free function so the detached
/// closure is not compiled inside a `@MainActor` context (see `DocumentLoad.swift`).
private func trashIndexEntries(from resourcesDir: URL) async -> [PlacemarkIndex.Entry] {
    await Task.detached(priority: .userInitiated) {
        PlacemarkIndex.read(from: resourcesDir) ?? []
    }.value
}
