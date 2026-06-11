import Foundation
import Observation

/// The catalogue, held in memory and sourced entirely from the per-entry folders in the
/// active storage root — the folders on disk are the single source of truth.
///
/// Replaces the old `CatalogStore` (SwiftData) + `CatalogReconciler` pair. There is no
/// parallel index to diverge: every mutation writes through to the folder's `metadata.json`
/// (or removes the folder) and then re-scans, so the list always reflects exactly what is
/// on disk. The scan runs off the main actor; the result is assigned back here.
@MainActor @Observable final class Catalog {
    /// All entries (active and trashed), newest first.
    private(set) var entries: [CatalogEntry] = []

    /// The active storage root. Changes (live) when the iCloud sync toggle flips.
    private(set) var storage: StorageLocations

    @ObservationIgnored private let cache: ResourceCache
    /// At most one resource-materialization pass runs at a time (see `reload`).
    @ObservationIgnored private var materializeTask: Task<Void, Never>?
    /// Set when a `reload` arrives while a materialization pass is already running, so the pass
    /// re-runs once on completion to pick up folders that synced in mid-pass.
    @ObservationIgnored private var materializePending = false
    /// Monotonically increasing token identifying the latest `reload`. A detached scan captures
    /// the token it was started for and only publishes its result if it is still the latest, so
    /// a slower earlier scan can never clobber a newer one (concurrent reloads settle to the
    /// final state).
    @ObservationIgnored private var scanGeneration = 0

    /// Non-trashed entries.
    var active: [CatalogEntry] {
        entries.filter { !$0.isTrashed }
    }

    /// Trashed entries, most recently trashed first.
    var trashed: [CatalogEntry] {
        entries.filter(\.isTrashed).sorted { lhs, rhs in
            (lhs.trashedAt ?? .distantPast) > (rhs.trashedAt ?? .distantPast)
        }
    }

    init(storage: StorageLocations, cache: ResourceCache = .init()) {
        self.storage = storage
        self.cache = cache
    }

    /// Rescans the active root off-main and republishes `entries`, then kicks a background
    /// pass to build any per-device resource caches that are missing (e.g. icons for a file
    /// that synced in from another device — its derivable `resources/` cache is local-only,
    /// so each device builds its own from the synced original).
    func reload() async {
        let generation = scanGeneration + 1
        scanGeneration = generation
        let scanner = CatalogScanner(storage: storage, cache: cache)
        let scanned = await Task.detached { scanner.scan() }.value
        // Only publish if this scan is still the most recent one. A concurrent later reload
        // bumps `scanGeneration`, so a slower earlier scan that finishes afterwards is dropped
        // and the newest result wins — the catalogue settles to the final state.
        guard generation == scanGeneration else { return }
        entries = scanned
        scheduleResourceMaterialization()
    }

    /// Starts a single background materialization pass. If one is already running, marks the
    /// pass dirty (`materializePending`) so it re-runs once on completion — a folder that syncs
    /// in while a pass is mid-flight would otherwise be missed until the next unrelated reload.
    private func scheduleResourceMaterialization() {
        guard materializeTask == nil else {
            materializePending = true
            return
        }
        let storage = storage
        let cache = cache
        materializeTask = Task { [weak self] in
            _ = await Task.detached {
                await CatalogScanner(storage: storage, cache: cache).materializeMissingResources()
            }.value
            guard let self else { return }
            materializeTask = nil
            // If a reload arrived during the pass, run one more pass to pick up what it added.
            if materializePending {
                materializePending = false
                scheduleResourceMaterialization()
            }
        }
    }

    /// Moves an entry to Trash by setting `trashedAt` in its sidecar, then reloading.
    ///
    /// A trashed entry should disappear from system (Core Spotlight) search, so its items are
    /// removed here. Restore re-indexes them.
    func moveToTrash(_ entry: CatalogEntry) async {
        writeTrashedAt(.now, to: entry)
        SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: indexEntries(for: entry))
        await reload()
    }

    /// Restores a trashed entry by clearing `trashedAt` in its sidecar, then reloading.
    func restore(_ entry: CatalogEntry) async {
        writeTrashedAt(nil, to: entry)
        SpotlightIndexer.index(entry: entry, indexEntries: indexEntries(for: entry))
        await reload()
    }

    /// Renames an entry by writing a new `displayName` into its sidecar, then reloading.
    ///
    /// Trims surrounding whitespace; a name that is empty after trimming is rejected as a
    /// no-op (nothing is written, no reload). Writes through `updateMetadata`, which preserves
    /// every other sidecar field (favorites/visited/trash), unlike reconstructing the metadata
    /// from the in-memory `CatalogEntry`.
    func rename(_ entry: CatalogEntry, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? storage.updateMetadata(forFolderNamed: entry.storageFolderName) { $0.displayName = trimmed }
        // Re-index the whole entry so Spotlight reflects the new name everywhere: the entry
        // item's title AND every placemark item's contentDescription embed the display name, so
        // a name-only reindex would leave stale "<old name>" subtitles on the placemark hits.
        // The index file is one cheap read and we're already reloading from disk — correctness
        // over the marginal cost of re-pushing the items.
        var renamed = entry
        renamed.displayName = trimmed
        SpotlightIndexer.index(entry: renamed, indexEntries: indexEntries(for: entry))
        await reload()
    }

    /// Sets an entry's tags by writing a normalized list into its sidecar, then reloading.
    ///
    /// Normalization (so the on-disk JSON is stable and the UI is clean): each tag is trimmed
    /// of surrounding whitespace, empties are dropped, duplicates are removed
    /// case-INSENSITIVELY but the first-seen casing is **preserved**, and the result is sorted
    /// case-insensitively. Writes through `updateMetadata`, preserving every other sidecar
    /// field (favorites/visited/trash/name) — mirrors `rename`.
    func setTags(_ tags: [String], for entry: CatalogEntry) async {
        let normalized = Self.normalizeTags(tags)
        try? storage.updateMetadata(forFolderNamed: entry.storageFolderName) { $0.tags = normalized }
        await reload()
    }

    /// Trims, drops empties, de-duplicates case-insensitively (keeping the first casing seen),
    /// and sorts case-insensitively. Pure and `static` so it is testable in isolation.
    static func normalizeTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in tags {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            guard seen.insert(lowered).inserted else { continue }
            result.append(trimmed)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Permanently removes an entry's folder (and its resource cache), then reloads.
    func deleteForever(_ entry: CatalogEntry) async {
        // Read the index BEFORE removing the folder so the placemark item ids can be
        // reconstructed; otherwise the cache is gone and only the entry item would be removable.
        let toRemove = indexEntries(for: entry)
        try? storage.removeFolder(named: entry.storageFolderName)
        SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: toRemove)
        await reload()
    }

    /// The first entry with the given content hash, for import-time duplicate detection.
    func entry(withSHA256 sha256: String) -> CatalogEntry? {
        entries.first { $0.contentSHA256 == sha256 }
    }

    /// Repoints the catalogue at a new root and reloads. Any file migration between roots
    /// (e.g. when the iCloud sync toggle flips) is the caller's responsibility — `Catalog`
    /// is deliberately unaware of iCloud vs local storage.
    func setStorage(_ newStorage: StorageLocations) async {
        storage = newStorage
        await reload()
    }

    /// Reads an entry's `placemarks-index.json` rows (or `[]` when the index isn't present),
    /// used to reconstruct Spotlight placemark item ids for (de)indexing.
    private func indexEntries(for entry: CatalogEntry) -> [PlacemarkIndex.Entry] {
        PlacemarkIndex.read(from: storage.resourcesDirectory(for: entry)) ?? []
    }

    private func writeTrashedAt(_ date: Date?, to entry: CatalogEntry) {
        try? storage.updateMetadata(forFolderNamed: entry.storageFolderName) { $0.trashedAt = date }
    }
}
