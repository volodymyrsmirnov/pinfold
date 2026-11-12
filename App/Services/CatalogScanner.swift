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
    /// - `.unreadable` → derive the entry in memory from the original but write NOTHING (trash
    ///   state, id and name are recovered from the damaged JSON where possible); the entry is
    ///   read-only. If there is no readable original either, skip the folder entirely.
    /// - `.notDownloaded` → (iCloud) the sidecar has probably not synced down yet: request its
    ///   download and derive a read-only entry in memory, writing nothing (B2).
    private func entry(forFolderNamed name: String) -> CatalogEntry? {
        switch storage.readSidecar(forFolderNamed: name) {
        case let .ok(meta):
            // Readable sidecar but a not-yet-downloaded original (iCloud placeholder, or a
            // crash mid-commit between the sidecar and the original): skip silently and leave
            // the folder. The watcher rescans once the original lands, surfacing the entry
            // with its intended identity — no self-heal under a fresh UUID.
            storage.removeStaleSnapshotTemps(inFolderNamed: name)
            guard storage.originalFileURL(inFolderNamed: name) != nil else { return nil }
            return CatalogEntry(metadata: meta, storageFolderName: name)
        case .missing:
            return rebuildFromBareOriginal(folderNamed: name)
        case .unreadable:
            return readOnlyEntry(forFolderNamed: name, state: .unreadable)
        case .notDownloaded:
            storage.probe.startDownloading(storage.metadataFile(forFolderNamed: name))
            return readOnlyEntry(forFolderNamed: name, state: .notDownloaded)
        }
    }

    /// Derives an entry in memory only — the on-disk sidecar is untouchable (newer schema,
    /// conflict artifact, or not downloaded yet). For an unreadable sidecar the identity, name
    /// and trash state are recovered from whatever JSON is still intact, so a trashed entry does
    /// not pop back into the active list. `nil` if there is nothing to derive from.
    private func readOnlyEntry(forFolderNamed name: String, state: CatalogEntry.SidecarState) -> CatalogEntry? {
        guard var entry = deriveFromOriginal(folderNamed: name)?.entry else { return nil }
        if state == .unreadable, let tolerant = storage.tolerantSidecar(forFolderNamed: name) {
            entry.id = tolerant.id ?? entry.id
            entry.displayName = tolerant.displayName ?? entry.displayName
            entry.trashedAt = tolerant.trashedAt
        }
        entry.sidecarState = state
        return entry
    }

    /// Parses the original file in `name`, writes a sidecar + caches resources, and
    /// returns the rebuilt entry. `nil` if there is no original or it fails to parse.
    private func rebuildFromBareOriginal(folderNamed name: String) -> CatalogEntry? {
        guard let derived = deriveFromOriginal(folderNamed: name) else { return nil }
        let meta = derived.metadata

        try? storage.writeMetadata(meta, forFolderNamed: name)
        let resourcesDir = storage.resourcesDirectory(forFolderNamed: name)
        // We parsed the original anyway: extract the resources and write the index in one pass.
        writeLocalCache(for: derived.parsed, to: resourcesDir)
        let hrefs = derived.parsed.remoteResourceHrefs
        let cache = cache
        Task.detached { await cache.downloadRemote(hrefs, to: resourcesDir) }

        // A bare original we just rebuilt is searchable too (e.g. an entry that synced in as a
        // sidecar-less original). Don't index a trashed entry (the sidecar's the source of trash
        // state; a freshly-rebuilt one is always active here).
        SpotlightIndexer.index(entry: derived.entry, indexEntries: derived.parsed.indexEntries)

        return derived.entry
    }

    /// In-memory derivation of an entry from a folder's bare original — parses the file and
    /// builds `EntryMetadata`/`CatalogEntry` **without writing anything to disk**. Used both
    /// by `rebuildFromBareOriginal` (which then persists) and by the `.unreadable`-sidecar
    /// path (which must not). `nil` if there is no original or it fails to parse.
    private func deriveFromOriginal(folderNamed name: String) -> DerivedEntry? {
        guard let fileURL = storage.originalFileURL(inFolderNamed: name),
              let data = try? readOriginal(fileURL),
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
            parsed: result
        )
    }

    /// Reads an original. A local file is memory-mapped when safe; an iCloud file goes through
    /// the coordinated, download-waiting read.
    private func readOriginal(_ url: URL) throws -> Data {
        if storage.isUbiquitous || !FileManager.default.fileExists(atPath: url.path) {
            return try UbiquityContainer.readDownloadingIfNeeded(url)
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Creates `resourcesDir` (its existence is the "materialized" marker, so it is made even
    /// when there is nothing to put in it), streams a KMZ's resources out of the original and
    /// writes the search index. Both writes are derivable, so failures are not fatal.
    private func writeLocalCache(for result: ImportResult, to resourcesDir: URL) {
        try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        if result.format == .kmz {
            try? cache.extractEmbedded(fromKMZ: result.originalData, to: resourcesDir)
        }
        if (try? PlacemarkIndex.write(result.indexEntries, to: resourcesDir)) != nil {
            PlacemarkIndex.writeSourceStamp(result.contentSHA256, to: resourcesDir)
            PlacemarkIndex.writeDerivedDataVersion(to: resourcesDir)
        }
        PlacemarkIndex.clearParseFailureMarker(in: resourcesDir)
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
                // (e.g. the device was offline at import); no re-parse is needed, the expected
                // href list was recorded to disk at download time.
                await cache.retryPending(in: resourcesDir)
                // A folder without the current index predates it (a pre-2.0 import), or its
                // index was built from an older original (a network-link snapshot replaced it,
                // here or on another device): refresh everything derived from the original in
                // this one re-parse. Otherwise the original is never read here again.
                if needsRefresh(forFolderNamed: name, resourcesDir: resourcesDir) {
                    _ = await refreshDerivedData(forFolderNamed: name, resourcesDir: resourcesDir)
                }
                continue
            }
            if await refreshDerivedData(forFolderNamed: name, resourcesDir: resourcesDir) {
                didWork = true
            }
        }
        return didWork
    }

    /// Whether the derived data in `resourcesDir` must be rebuilt: the index is missing, it was
    /// built by an older derived-data generation, or it was stamped with a different source SHA
    /// than the sidecar's `contentSHA256`.
    ///
    /// An index with no stamp counts as current (existing installs are not re-parsed twice);
    /// `writeLocalCache` stamps every index it writes, and an unstamped one is stamped here with
    /// the sidecar's SHA on first sight, which is what protects it from then on. The residual
    /// window (an update landing before that first stamping pass) is small and accepted.
    private func needsRefresh(forFolderNamed name: String, resourcesDir: URL) -> Bool {
        guard PlacemarkIndex.exists(in: resourcesDir) else { return true }
        // Built by an older build (before description images were gathered): refresh once; the
        // refresh writes the current version, so this never repeats.
        guard PlacemarkIndex.derivedDataIsCurrent(in: resourcesDir) else { return true }
        guard case let .ok(meta) = storage.readSidecar(forFolderNamed: name), !meta.contentSHA256.isEmpty
        else { return false }
        let sidecarSHA = meta.contentSHA256
        guard let stamp = PlacemarkIndex.sourceStamp(in: resourcesDir) else {
            PlacemarkIndex.writeSourceStamp(sidecarSHA, to: resourcesDir)
            return false
        }
        return stamp != sidecarSHA
    }

    /// Whether the original's content (by the sidecar's SHA) is recorded as having failed to parse.
    private func isKnownUnparseable(folderNamed name: String, resourcesDir: URL) -> Bool {
        guard let failed = PlacemarkIndex.parseFailureMarker(in: resourcesDir),
              case let .ok(meta) = storage.readSidecar(forFolderNamed: name)
        else { return false }
        return meta.contentSHA256 == failed
    }

    /// Re-parses the original in `name` once and rebuilds everything derived from it: the
    /// resources directory (embedded KMZ media streamed out, manifest recorded), the search
    /// index, the recorded remote hrefs and their downloads (through `ResourceCache`, so the
    /// download policy and retry backoff still apply), and the Spotlight items. `false`,
    /// writing nothing, when the original cannot be read or parsed yet (retried on a later scan).
    private func refreshDerivedData(forFolderNamed name: String, resourcesDir: URL) async -> Bool {
        // A marker for the sidecar's SHA means this content already failed to parse: skip
        // without even reading it, until the content (and so the SHA) changes.
        if isKnownUnparseable(folderNamed: name, resourcesDir: resourcesDir) {
            return false
        }
        guard let fileURL = storage.originalFileURL(inFolderNamed: name),
              let data = try? readOriginal(fileURL)
        else { return false } // not downloaded yet: retried on a later pass
        guard let result = try? ImportService.prepare(data: data, sourceFilename: fileURL.lastPathComponent) else {
            // Read fine but can never parse: remember the content so it is not retried.
            PlacemarkIndex.writeParseFailureMarker(ImportService.sha256Hex(data), to: resourcesDir)
            return false
        }
        writeLocalCache(for: result, to: resourcesDir)
        await cache.downloadRemote(result.remoteResourceHrefs, to: resourcesDir)
        // Index from the sidecar (so the display name and trash state are right); a trashed
        // entry is skipped.
        indexMaterializedEntry(forFolderNamed: name, indexEntries: result.indexEntries)
        return true
    }

    /// Adds the entry in `name` (plus its placemarks) to Core Spotlight, sourcing the entry's
    /// display name and trash state from its sidecar. Skips a folder without a readable sidecar
    /// or one that is trashed (a trashed entry shouldn't surface in system search). Fire-and-
    /// forget via `SpotlightIndexer`.
    private func indexMaterializedEntry(forFolderNamed name: String, indexEntries: [PlacemarkIndex.Entry]) {
        guard case let .ok(meta) = storage.readSidecar(forFolderNamed: name), meta.trashedAt == nil else { return }
        let entry = CatalogEntry(metadata: meta, storageFolderName: name)
        SpotlightIndexer.index(entry: entry, indexEntries: indexEntries)
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
    let parsed: ImportResult
}
