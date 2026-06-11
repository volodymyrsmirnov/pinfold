import Foundation
import PinfoldCore

/// Scans the synced storage root and produces the catalogue, treating the folders on
/// disk as the single source of truth: one `CatalogEntry` per folder that has a readable
/// `metadata.json`, or a parseable bare original file.
///
/// Invariant: an existing sidecar, even one that fails to decode, is **never overwritten** —
/// it may be a newer schema or an iCloud conflict artifact, and clobbering it would destroy
/// trash/favorite/visited state. Only a genuinely *absent* sidecar is backfilled.
///
/// `Sendable` so it can run off the main actor: `Catalog.reload()` hands the scan to a
/// detached task and assigns the result back on the main actor.
struct CatalogScanner {
    let storage: StorageLocations
    var cache: ResourceCache = .init()

    /// Returns one entry per folder, sorted by `importDate` descending. Self-heals a
    /// folder that has a bare original but no sidecar by parsing it and writing one.
    /// Folders that are empty / not-yet-downloaded / unparseable are skipped, never
    /// de-duplicated — what's on disk is what the catalogue shows.
    func scan() -> [CatalogEntry] {
        let folderNames = (try? storage.entryFolderNames()) ?? []
        let entries = folderNames.compactMap { entry(forFolderNamed: $0) }
        return entries.sorted { $0.importDate > $1.importDate }
    }

    /// Builds an entry for one folder, honouring the never-overwrite-a-sidecar invariant:
    /// - `.ok`         → build the entry from the sidecar as today.
    /// - `.missing`    → backfill from the bare original (writes a fresh sidecar + cache).
    /// - `.unreadable` → derive the entry in memory from the original but write NOTHING; if
    ///   there is no readable original either, skip the folder entirely (no writes/deletes).
    private func entry(forFolderNamed name: String) -> CatalogEntry? {
        switch storage.readSidecar(forFolderNamed: name) {
        case let .ok(meta):
            // Readable sidecar but a not-yet-downloaded original (iCloud placeholder, or a
            // crash mid-commit between the sidecar and the original): skip silently and leave
            // the folder. The watcher rescans once the original lands, surfacing the entry
            // with its intended identity — no self-heal under a fresh UUID.
            guard storage.originalFileURL(inFolderNamed: name) != nil else { return nil }
            return CatalogEntry(metadata: meta, storageFolderName: name)
        case .missing:
            return rebuildFromBareOriginal(folderNamed: name)
        case .unreadable:
            // Derive in memory only — the on-disk sidecar is untouchable (newer schema or
            // conflict artifact). No entry if there is nothing to derive from.
            return deriveFromOriginal(folderNamed: name)?.entry
        }
    }

    /// Parses the original file in `name`, writes a sidecar + caches resources, and
    /// returns the rebuilt entry. `nil` if there is no original or it fails to parse.
    private func rebuildFromBareOriginal(folderNamed name: String) -> CatalogEntry? {
        guard let derived = deriveFromOriginal(folderNamed: name) else { return nil }
        let meta = derived.metadata

        try? storage.writeMetadata(meta, forFolderNamed: name)
        let resourcesDir = storage.resourcesDirectory(forFolderNamed: name)
        try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try? cache.writeEmbedded(derived.embeddedResources, to: resourcesDir)
        // We parsed the original anyway — write the local search index in the same pass.
        try? PlacemarkIndex.write(derived.indexEntries, to: resourcesDir)
        let hrefs = derived.remoteResourceHrefs
        let cache = cache
        Task.detached { await cache.downloadRemote(hrefs, to: resourcesDir) }

        return derived.entry
    }

    /// In-memory derivation of an entry from a folder's bare original — parses the file and
    /// builds `EntryMetadata`/`CatalogEntry` **without writing anything to disk**. Used both
    /// by `rebuildFromBareOriginal` (which then persists) and by the `.unreadable`-sidecar
    /// path (which must not). `nil` if there is no original or it fails to parse.
    private func deriveFromOriginal(folderNamed name: String) -> DerivedEntry? {
        guard let fileURL = storage.originalFileURL(inFolderNamed: name),
              let data = try? Data(contentsOf: fileURL),
              let result = try? ImportService.prepare(
                  data: data,
                  sourceFilename: fileURL.lastPathComponent
              )
        else { return nil }

        let meta = EntryMetadata(
            // Reuse the folder-name UUID as the entry identity so a rebuilt entry keeps a
            // stable identity across devices and rescans (see EntryMetadata.id). Falls back
            // to a fresh UUID only for legacy folders whose name is not a UUID string.
            id: UUID(uuidString: name) ?? UUID(),
            displayName: result.displayName,
            sourceFilename: result.sourceFilename,
            // Use the file's creation date so the catalogue order is stable across devices.
            importDate: fileCreationDate(fileURL),
            pointCount: result.pointCount,
            contentSHA256: result.contentSHA256,
            trashedAt: nil
        )

        return DerivedEntry(
            metadata: meta,
            entry: CatalogEntry(metadata: meta, storageFolderName: name),
            embeddedResources: result.embeddedResources,
            remoteResourceHrefs: result.remoteResourceHrefs,
            indexEntries: result.indexEntries
        )
    }

    /// For each entry folder whose local resources cache is absent, parses the original and
    /// populates the cache (extracts KMZ-embedded media, downloads remote icon/photo hrefs).
    ///
    /// The `resources/` directory's existence is the per-device "already materialized"
    /// marker: the importing device creates it at import; a second device (which only
    /// received the synced original + sidecar) has no such directory and builds it here.
    /// This is why icons appear on every device, not just the one that imported the file.
    ///
    /// Skips folders whose original cannot be read yet (e.g. an iCloud placeholder still
    /// downloading) so they are retried on a later scan. Returns `true` if it materialized
    /// at least one folder. Safe to run repeatedly; cheap once caches exist.
    func materializeMissingResources() async -> Bool {
        let folderNames = (try? storage.entryFolderNames()) ?? []
        var didWork = false
        for name in folderNames {
            let resourcesDir = storage.resourcesDirectory(forFolderNamed: name)
            if FileManager.default.fileExists(atPath: resourcesDir.path) {
                // Already materialized once. Retry any remote downloads that failed earlier
                // (e.g. the device was offline at import). Cheap no-op when the manifest
                // already covers them, and no re-parse is needed — the expected href list
                // was recorded to disk at download time.
                await cache.retryPending(in: resourcesDir)
                // Self-heal: a folder materialized before the search feature shipped has a
                // resource cache but no `placemarks-index.json`. Backfill it once by parsing
                // the original (the only re-parse here, gated on the index being absent).
                if PlacemarkIndex.read(from: resourcesDir) == nil {
                    backfillIndex(forFolderNamed: name, to: resourcesDir)
                }
                continue
            }

            guard let fileURL = storage.originalFileURL(inFolderNamed: name),
                  let data = try? UbiquityContainer.readDownloadingIfNeeded(fileURL),
                  let result = try? ImportService.prepare(
                      data: data,
                      sourceFilename: fileURL.lastPathComponent
                  )
            else { continue }

            // Create the directory first so it acts as the done-marker even when the file
            // has no resources (a plain KML with no icons/photos won't be re-parsed next scan).
            try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
            try? cache.writeEmbedded(result.embeddedResources, to: resourcesDir)
            // Build the local search index in the same pass (we parsed the original anyway).
            try? PlacemarkIndex.write(result.indexEntries, to: resourcesDir)
            await cache.downloadRemote(result.remoteResourceHrefs, to: resourcesDir)
            didWork = true
        }
        return didWork
    }

    /// Parses the original in `name` and writes its `placemarks-index.json` into an
    /// already-materialized `resourcesDir`. Used to backfill the index for entries imported
    /// before catalogue-wide search existed. Silent no-op if the original can't be read or
    /// parsed (retried on a later pass).
    private func backfillIndex(forFolderNamed name: String, to resourcesDir: URL) {
        guard let fileURL = storage.originalFileURL(inFolderNamed: name),
              let data = try? UbiquityContainer.readDownloadingIfNeeded(fileURL),
              let result = try? ImportService.prepare(
                  data: data,
                  sourceFilename: fileURL.lastPathComponent
              )
        else { return }
        try? PlacemarkIndex.write(result.indexEntries, to: resourcesDir)
    }

    private func fileCreationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .now
    }
}

/// The result of deriving an entry from a bare original in memory: the entry itself plus the
/// resources that `rebuildFromBareOriginal` would persist (the `.unreadable` path discards
/// these, keeping the derivation read-only).
private struct DerivedEntry {
    let metadata: EntryMetadata
    let entry: CatalogEntry
    let embeddedResources: [String: Data]
    let remoteResourceHrefs: [String]
    let indexEntries: [PlacemarkIndex.Entry]
}
