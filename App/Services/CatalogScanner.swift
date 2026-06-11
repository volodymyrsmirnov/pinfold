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
            CatalogEntry(metadata: meta, storageFolderName: name)
        case .missing:
            rebuildFromBareOriginal(folderNamed: name)
        case .unreadable:
            // Derive in memory only — the on-disk sidecar is untouchable (newer schema or
            // conflict artifact). No entry if there is nothing to derive from.
            deriveFromOriginal(folderNamed: name)?.entry
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
            id: UUID(),
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
            remoteResourceHrefs: result.remoteResourceHrefs
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
            await cache.downloadRemote(result.remoteResourceHrefs, to: resourcesDir)
            didWork = true
        }
        return didWork
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
}
