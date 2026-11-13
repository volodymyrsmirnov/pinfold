import Foundation
import os

/// Writes a refreshed online list's new content over its original while keeping everything the
/// person made: the sidecar's annotations (only the content fields change, see `writeSnapshot`),
/// the remote-image consent and the refresh state in `resources/`. Data derived from the
/// original is rebuilt the way an import builds it.
enum SubscriptionContentWriter {
    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "subscription"
    )

    /// What `applyAndReindex` did.
    struct Reindexed {
        /// The updated entry.
        let entry: CatalogEntry
        /// The Spotlight items removed: placemarks the new content no longer has.
        let deindexedIdentifiers: [String]
        /// Whether the folder's whole Spotlight domain was replaced instead, because there was
        /// no previous index to tell which placemarks left.
        var replacedSpotlightDomain = false
    }

    /// Replaces `entry`'s original with `result`, off the main actor: resolves any iCloud
    /// conflict on the original first, writes the snapshot keeping the person's choices, then
    /// rebuilds the derived data. Returns the updated entry.
    static func apply(
        _ result: ImportResult,
        to entry: CatalogEntry,
        storage: StorageLocations,
        cache: ResourceCache
    ) async throws -> CatalogEntry {
        try await applyOffMain(result, to: entry, storage: storage, cache: cache).entry
    }

    /// `apply`, then refreshes what search and Spotlight hold for `entry`: drops its cached
    /// placemark index, removes the Spotlight items of placemarks the new content no longer has
    /// and re-indexes the rest (a trashed list is out of Spotlight; restoring it re-indexes).
    /// Without a previous index to diff against, the folder's Spotlight domain is deleted and
    /// then re-indexed, in that order.
    /// Shared by a refresh and the in-place subscribe. Safe inside a `StorageApplyQueue`
    /// operation: it never waits on the queue.
    @discardableResult
    static func applyAndReindex(
        _ result: ImportResult,
        to entry: CatalogEntry,
        storage: StorageLocations,
        cache: ResourceCache
    ) async throws -> Reindexed {
        let applied = try await applyOffMain(result, to: entry, storage: storage, cache: cache)
        PlacemarkIndexStore.shared.invalidate(
            resourcesDir: storage.resourcesDirectory(for: entry), sidecar: storage.metadataFile(for: entry)
        )
        guard !entry.isTrashed else { return Reindexed(entry: applied.entry, deindexedIdentifiers: []) }
        guard let previous = applied.previousIndex else {
            SpotlightIndexer.reindexReplacingDomain(entry: applied.entry, indexEntries: result.indexEntries)
            return Reindexed(entry: applied.entry, deindexedIdentifiers: [], replacedSpotlightDomain: true)
        }
        // Removed and added identifiers are disjoint, so the two fire-and-forget calls can
        // land in any order.
        let removed = SpotlightIndexer.removedPlacemarkIdentifiers(
            folderName: entry.storageFolderName, previous: previous, current: result.indexEntries
        )
        SpotlightIndexer.deindex(identifiers: removed)
        SpotlightIndexer.index(entry: applied.entry, indexEntries: result.indexEntries)
        return Reindexed(entry: applied.entry, deindexedIdentifiers: removed)
    }
}

/// The written entry and the search index of the content it replaced (`nil` when none could be read).
private struct Applied {
    let entry: CatalogEntry
    let previousIndex: [PlacemarkIndex.Entry]?
}

/// Runs the refresh write in a detached task. A `nonisolated` free function so the detached
/// closure is compiled outside any actor-isolated caller (see FavoritesView.swift).
private nonisolated func applyOffMain(
    _ result: ImportResult, to entry: CatalogEntry, storage: StorageLocations, cache: ResourceCache
) async throws -> Applied {
    try await Task.detached(priority: .userInitiated) {
        try writeRefresh(result, to: entry, storage: storage, cache: cache)
    }.value
}

/// The synchronous file work behind `SubscriptionContentWriter.apply`.
private nonisolated func writeRefresh(
    _ result: ImportResult, to entry: CatalogEntry, storage: StorageLocations, cache: ResourceCache
) throws -> Applied {
    // Read before the write prunes it: Spotlight items of placemarks that leave are removed.
    let previousIndex = PlacemarkIndex.read(from: storage.resourcesDirectory(for: entry))
    try resolveOriginalConflicts(at: storage.originalFile(for: entry))
    let updated = try writeSnapshot(result, to: entry, storage: storage, resetResources: .derivedOnly)
    // The new original is in place, so a failure here never fails the refresh: the index is
    // missing (or stamped with the old SHA), and the materialisation pass rebuilds it.
    do {
        try ImportService.writeDerivedData(for: result, to: storage.resourcesDirectory(for: entry), cache: cache)
    } catch {
        SubscriptionContentWriter.logger.error(
            """
            Derived data rebuild failed for \(entry.storageFolderName, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """
        )
    }
    return Applied(entry: updated, previousIndex: previousIndex)
}

/// Resolves unresolved iCloud conflicts on an original before a refresh writes over it: the
/// newest version (by modification date) wins and replaces the current one if it is newer; the
/// others are marked resolved and removed. Does nothing when there are no conflicts (always the
/// case for a local root).
nonisolated func resolveOriginalConflicts(at url: URL) throws {
    guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else {
        return
    }
    let currentDate = NSFileVersion.currentVersionOfItem(at: url)?.modificationDate ?? .distantPast
    let newest = conflicts.max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
    if let newest, (newest.modificationDate ?? .distantPast) > currentDate {
        try StorageLocations.coordinate(writingAt: url, options: .forReplacing) { target in
            _ = try newest.replaceItem(at: target, options: [])
        }
    }
    for version in conflicts {
        version.isResolved = true
    }
    try StorageLocations.coordinate(writingAt: url, options: []) { target in
        try NSFileVersion.removeOtherVersionsOfItem(at: target)
    }
}
