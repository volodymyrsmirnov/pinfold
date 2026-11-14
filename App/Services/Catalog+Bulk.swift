import Foundation

/// Bulk mutations for multi-select (C8). Each one writes every eligible entry's sidecar and
/// then reloads ONCE, instead of looping the single-entry API (one rescan per entry).
///
/// Read-only entries (unreadable or not-yet-downloaded sidecar, B12) are skipped untouched and
/// reported through `actionError`; the rest still go through.
extension Catalog {
    /// Moves every given entry to Trash (and out of Spotlight), then reloads once.
    func moveToTrash(_ selection: [CatalogEntry]) async {
        let now = Date.now
        let changed = applyBulk(to: selection) { $0.trashedAt = now }
        for entry in changed {
            let indexRows = await readBulkIndexEntries(from: storage.resourcesDirectory(for: entry))
            SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: indexRows)
        }
        if !changed.isEmpty {
            await reload()
        }
    }

    /// Applies `mutate` to each eligible entry's sidecar and returns the entries written.
    /// Skipped read-only entries and failed writes are summarised in a single `actionError`.
    private func applyBulk(
        to selection: [CatalogEntry],
        _ mutate: (inout EntryMetadata) -> Void
    ) -> [CatalogEntry] {
        var changed: [CatalogEntry] = []
        var skipped: [CatalogEntry] = []
        var failure: CatalogActionError?
        for entry in selection {
            let live = entries.first { $0.storageFolderName == entry.storageFolderName } ?? entry
            if live.isReadOnly {
                skipped.append(live)
                continue
            }
            do {
                try storage.updateMetadata(forFolderNamed: live.storageFolderName, mutate)
                changed.append(live)
            } catch {
                failure = failure ?? .saveFailed(entryName: live.displayName, error: error)
            }
        }
        if let failure {
            actionError = failure
        } else if !skipped.isEmpty {
            actionError = Self.skippedError(skipped)
        }
        return changed
    }

    private static func skippedError(_ skipped: [CatalogEntry]) -> CatalogActionError {
        if skipped.count == 1, let only = skipped.first {
            return .readOnly(entryName: only.displayName, state: only.sidecarState)
        }
        return CatalogActionError(
            message: "\(skipped.count) files were left unchanged because their saved data can't be "
                + "read yet (still downloading from iCloud, or written by a newer version of Pinfold)."
        )
    }
}

/// Reads an entry's placemark index off the main actor. A `nonisolated` free function so the
/// `Task.detached` closure is compiled outside the `@MainActor` catalogue (see CLAUDE.md).
private func readBulkIndexEntries(from resourcesDir: URL) async -> [PlacemarkIndex.Entry] {
    await Task.detached(priority: .userInitiated) {
        PlacemarkIndex.read(from: resourcesDir) ?? []
    }.value
}
