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

    /// Non-trashed entries.
    var active: [CatalogEntry] { entries.filter { !$0.isTrashed } }

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
        let scanner = CatalogScanner(storage: storage, cache: cache)
        entries = await Task.detached { scanner.scan() }.value
        scheduleResourceMaterialization()
    }

    /// Starts a single background materialization pass. If one is already running, this is a
    /// no-op — that pass scans every folder, and any folders that sync in afterwards are
    /// picked up by the next `reload` (the watcher fires again).
    private func scheduleResourceMaterialization() {
        guard materializeTask == nil else { return }
        let storage = storage
        let cache = cache
        materializeTask = Task { [weak self] in
            _ = await Task.detached {
                await CatalogScanner(storage: storage, cache: cache).materializeMissingResources()
            }.value
            self?.materializeTask = nil
        }
    }

    /// Moves an entry to Trash by setting `trashedAt` in its sidecar, then reloading.
    func moveToTrash(_ entry: CatalogEntry) async {
        writeTrashedAt(.now, to: entry)
        await reload()
    }

    /// Restores a trashed entry by clearing `trashedAt` in its sidecar, then reloading.
    func restore(_ entry: CatalogEntry) async {
        writeTrashedAt(nil, to: entry)
        await reload()
    }

    /// Permanently removes an entry's folder (and its resource cache), then reloads.
    func deleteForever(_ entry: CatalogEntry) async {
        try? storage.removeFolder(named: entry.storageFolderName)
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

    private func writeTrashedAt(_ date: Date?, to entry: CatalogEntry) {
        var meta = entry.metadata
        meta.trashedAt = date
        try? storage.writeMetadata(meta, forFolderNamed: entry.storageFolderName)
    }
}
