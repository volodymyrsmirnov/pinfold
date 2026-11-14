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

    /// Bumps after every published scan; part of the search task identity so cross-file
    /// results refresh after a note save or any other on-disk change.
    private(set) var searchDataRevision = 0

    /// The active storage root. Changes (live) when the iCloud sync toggle flips.
    private(set) var storage: StorageLocations

    /// The last user-initiated mutation that could not be carried out (a read-only entry, a
    /// failed write or delete). Observable; shown by `CatalogErrorAlert`, which clears it.
    var actionError: CatalogActionError?

    @ObservationIgnored private let cache: ResourceCache
    /// At most one resource-materialization pass runs at a time (see `reload`).
    @ObservationIgnored private var materializeTask: Task<Void, Never>?
    /// Set when a `reload` arrives while a materialization pass is already running, so the pass
    /// re-runs once on completion to pick up folders that synced in mid-pass.
    @ObservationIgnored private var materializePending = false
    /// Monotonically increasing token identifying the latest `reload`. A detached scan captures
    /// the token it was started for and only publishes its result if it is still the latest, so
    /// a slower earlier scan can never clobber a newer one (concurrent reloads settle to the
    /// final state). Internal so tests can overtake a reload in flight.
    @ObservationIgnored var scanGeneration = 0
    /// While `true` no materialization pass starts (a root migration is about to run).
    @ObservationIgnored var backgroundWorkSuspended = false

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
        searchDataRevision &+= 1
        pruneIndexStore()
        scheduleResourceMaterialization()
    }

    /// Drops cached search indexes and note snapshots of entries that are no longer in the
    /// catalogue (cheap: only touches the store's in-memory dictionaries).
    private func pruneIndexStore() {
        let resourceDirs = Set(entries.map { storage.resourcesDirectory(for: $0) })
        let sidecars = Set(entries.map { storage.metadataFile(for: $0) })
        PlacemarkIndexStore.shared.prune(keeping: resourceDirs, sidecars: sidecars)
    }

    /// Starts a single background materialization pass. If one is already running, marks the
    /// pass dirty (`materializePending`) so it re-runs once on completion — a folder that syncs
    /// in while a pass is mid-flight would otherwise be missed until the next unrelated reload.
    private func scheduleResourceMaterialization() {
        guard materializeTask == nil else {
            materializePending = true
            return
        }
        guard !backgroundWorkSuspended else {
            materializePending = true
            return
        }
        let storage = storage
        let cache = cache
        materializeTask = Task { [weak self] in
            await runMaterialization(storage: storage, cache: cache)
            guard let self else { return }
            materializeTask = nil
            // If a reload arrived during the pass, run one more pass to pick up what it added.
            if materializePending {
                materializePending = false
                scheduleResourceMaterialization()
            }
        }
    }

    /// Stops the background materialization/refresh pass and waits until it has fully ended, so
    /// nothing re-creates `resources/` folders in the root a migration is about to read. New
    /// passes are deferred (not dropped) until `resumeBackgroundWork()`.
    func suspendBackgroundWork() async {
        backgroundWorkSuspended = true
        let running = materializeTask
        if running != nil {
            materializePending = true
        } // restart once resumed
        running?.cancel()
        await running?.value
    }

    /// Lets deferred materialization run again, starting a pass if one was requested meanwhile.
    func resumeBackgroundWork() {
        backgroundWorkSuspended = false
        if materializePending, materializeTask == nil {
            materializePending = false
            scheduleResourceMaterialization()
        }
    }

    /// Moves an entry to Trash by setting `trashedAt` in its sidecar, then reloading.
    ///
    /// A trashed entry should disappear from system (Core Spotlight) search, so its items are
    /// removed here. Restore re-indexes them.
    func moveToTrash(_ entry: CatalogEntry) async {
        guard writeTrashedAt(.now, to: entry) else { return }
        let toRemove = await indexEntries(for: entry)
        SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: toRemove)
        await reload()
    }

    /// Restores a trashed entry by clearing `trashedAt` in its sidecar, then reloading.
    ///
    /// - Returns: `false` when nothing was restored (read-only entry or failed write; the
    ///   reason is in `actionError`).
    @discardableResult
    func restore(_ entry: CatalogEntry) async -> Bool {
        guard writeTrashedAt(nil, to: entry) else { return false }
        let toIndex = await indexEntries(for: entry)
        SpotlightIndexer.index(entry: entry, indexEntries: toIndex)
        await reload()
        return true
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
        guard updateSidecar(of: entry, { $0.displayName = trimmed }) else { return }
        // Re-index the whole entry so Spotlight reflects the new name everywhere: the entry
        // item's title AND every placemark item's contentDescription embed the display name, so
        // a name-only reindex would leave stale "<old name>" subtitles on the placemark hits.
        // The index file is one cheap read and we're already reloading from disk — correctness
        // over the marginal cost of re-pushing the items.
        var renamed = entry
        renamed.displayName = trimmed
        let toIndex = await indexEntries(for: entry)
        SpotlightIndexer.index(entry: renamed, indexEntries: toIndex)
        await reload()
    }

    /// Permanently removes an entry's folder (and its resource cache), then reloads.
    func deleteForever(_ entry: CatalogEntry) async {
        // Read the index BEFORE removing the folder so the placemark item ids can be
        // reconstructed; otherwise the cache is gone and only the entry item would be removable.
        // The read is `await`ed (now off-main) and completes fully before `removeFolder`, so the
        // ordering is preserved.
        let toRemove = await indexEntries(for: entry)
        do {
            try storage.removeFolder(named: entry.storageFolderName)
            SpotlightIndexer.deindex(folderName: entry.storageFolderName, indexEntries: toRemove)
        } catch {
            actionError = .deleteFailed(entryName: entry.displayName, error: error)
        }
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
    /// used to reconstruct Spotlight placemark item ids for (de)indexing. The file read runs
    /// off the main actor so a large index doesn't block UI; the directory URL is resolved on
    /// the main actor first and passed into the detached read.
    private func indexEntries(for entry: CatalogEntry) async -> [PlacemarkIndex.Entry] {
        await readIndexEntries(from: storage.resourcesDirectory(for: entry))
    }

    private func writeTrashedAt(_ date: Date?, to entry: CatalogEntry) -> Bool {
        updateSidecar(of: entry) { $0.trashedAt = date }
    }

    /// Applies `mutate` to the entry's sidecar, refusing read-only entries (whose sidecar must
    /// not be touched) and reporting a failed write through `actionError`. Returns whether the
    /// change was written. The live catalogue state wins over a stale copy held by a view.
    private func updateSidecar(of entry: CatalogEntry, _ mutate: (inout EntryMetadata) -> Void) -> Bool {
        let live = entries.first { $0.storageFolderName == entry.storageFolderName } ?? entry
        if live.isReadOnly {
            actionError = .readOnly(entryName: live.displayName, state: live.sidecarState)
            return false
        }
        do {
            try storage.updateMetadata(forFolderNamed: entry.storageFolderName, mutate)
            return true
        } catch {
            actionError = .saveFailed(entryName: live.displayName, error: error)
            return false
        }
    }
}

/// Runs the materialization pass off-main, forwarding cancellation to the detached work so a
/// migration can stop and await it. A `nonisolated` free function (see the note below).
private nonisolated func runMaterialization(storage: StorageLocations, cache: ResourceCache) async {
    let work = Task.detached {
        await CatalogScanner(storage: storage, cache: cache).materializeMissingResources()
    }
    await withTaskCancellationHandler {
        _ = await work.value
    } onCancel: {
        work.cancel()
    }
}

/// Reads an entry's placemark index off the main actor (the synchronous `PlacemarkIndex.read`
/// does a `Data(contentsOf:)` + JSON decode that can be costly for large indexes). A
/// `nonisolated` free function so the `Task.detached` closure is compiled here, not inside the
/// `@MainActor` `Catalog` — see the `ClosureLifetimeFixup` note in DocumentLoad.swift.
private func readIndexEntries(from resourcesDir: URL) async -> [PlacemarkIndex.Entry] {
    await Task.detached(priority: .userInitiated) {
        PlacemarkIndex.read(from: resourcesDir) ?? []
    }.value
}
