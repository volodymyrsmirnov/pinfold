import Foundation

/// The outcome of reading an entry's `metadata.json` sidecar, distinguishing an *absent*
/// sidecar from one that *exists but cannot be decoded*.
///
/// This distinction is load-bearing for the scanner: a `.missing` sidecar may be safely
/// backfilled, but an `.unreadable` one (a conflict artifact or a newer schema) must never
/// be overwritten — doing so would destroy trash/favorite/visited state.
enum SidecarReadResult: Equatable {
    /// No `metadata.json` exists in the folder.
    case missing
    /// A `metadata.json` exists but could not be read or decoded.
    case unreadable
    /// A `metadata.json` was read and decoded successfully.
    case ok(EntryMetadata)
}

/// Computes on-disk paths for imported KML/KMZ files.
///
/// Storage is split across two roots so iCloud sync only carries what it must:
/// - `root` (the *synced* root): the original file and its `metadata.json` sidecar.
///   In iCloud mode this is the ubiquity container's `Documents` folder.
/// - `cacheRoot` (the *local* root): the `resources/` cache (downloaded icons,
///   extracted KMZ media). This is fully derivable, so it never syncs.
///
/// In non-iCloud mode both roots live under Application Support and behave exactly
/// as before. Inject custom roots in tests so path operations never touch real
/// Application Support or iCloud.
///
/// Layout per entry:
/// ```
/// <root>/<storageFolderName>/
///     <sourceFilename>      ← original KML/KMZ as received
///     metadata.json         ← synced catalogue sidecar
/// <cacheRoot>/<storageFolderName>/
///     resources/            ← local-only icon/photo cache
/// ```
struct StorageLocations {
    // MARK: - Properties

    /// Synced root: holds per-entry folders with the original file + sidecar.
    let root: URL
    /// Local root: holds per-entry `resources/` caches. Never synced.
    let cacheRoot: URL

    // MARK: - Init

    /// Creates a `StorageLocations` with explicit synced and cache roots.
    ///
    /// No directories are created at initialisation; call `createFolders(for:)`
    /// before writing any files.
    init(root: URL, cacheRoot: URL) {
        self.root = root
        self.cacheRoot = cacheRoot
    }

    /// Convenience for the non-split case (tests, and the legacy single-root layout):
    /// resources live under the same root as originals.
    init(root: URL) {
        self.init(root: root, cacheRoot: root)
    }

    // MARK: - Static factory

    /// A `StorageLocations` rooted entirely under `<Application Support>/Pinfold`
    /// (no iCloud). Both originals and resources live there.
    ///
    /// The directory is created on first access; failure crashes, which is correct —
    /// Application Support is always writable on iOS.
    static var applicationSupport: StorageLocations {
        StorageLocations(root: applicationSupportRoot)
    }

    /// The `<Application Support>/Pinfold` directory, created if absent.
    static var applicationSupportRoot: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let pinfoldRoot = appSupport.appendingPathComponent("Pinfold", isDirectory: true)
        // Application Support is guaranteed writable on iOS.
        // swiftlint:disable:next force_try
        try! FileManager.default.createDirectory(at: pinfoldRoot, withIntermediateDirectories: true)
        return pinfoldRoot
    }

    /// A `StorageLocations` whose originals live in the given synced (iCloud) root and
    /// whose resources live under `<Application Support>/Pinfold/resources`.
    static func synced(root: URL) -> StorageLocations {
        let cacheRoot = applicationSupportRoot.appendingPathComponent("resources", isDirectory: true)
        return StorageLocations(root: root, cacheRoot: cacheRoot)
    }

    // MARK: - Path helpers

    /// The per-entry synced folder: `root/<storageFolderName>/`.
    func folder(for entry: CatalogEntry) -> URL {
        root.appendingPathComponent(entry.storageFolderName, isDirectory: true)
    }

    /// The original KML/KMZ file: `folder/<sourceFilename>`.
    func originalFile(for entry: CatalogEntry) -> URL {
        folder(for: entry).appendingPathComponent(entry.sourceFilename)
    }

    /// The sidecar metadata file: `folder/metadata.json`.
    func metadataFile(for entry: CatalogEntry) -> URL {
        folder(for: entry).appendingPathComponent("metadata.json")
    }

    /// The sidecar path for a raw folder name (used by the scanner before a
    /// `CatalogEntry` exists).
    func metadataFile(forFolderNamed name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true).appendingPathComponent("metadata.json")
    }

    /// The local resources cache directory: `cacheRoot/<storageFolderName>/resources/`.
    func resourcesDirectory(for entry: CatalogEntry) -> URL {
        resourcesDirectory(forFolderNamed: entry.storageFolderName)
    }

    /// The local resources cache directory for a raw folder name.
    func resourcesDirectory(forFolderNamed name: String) -> URL {
        cacheRoot
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("resources", isDirectory: true)
    }

    /// Locates the original KML/KMZ file inside a synced folder, by extension.
    /// Deterministic (alphabetical) when several match; `nil` if none. Used by the
    /// reconciler to rebuild an entry from a folder that has files but no sidecar.
    func originalFileURL(inFolderNamed name: String) -> URL? {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents
            .filter { ["kml", "kmz"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    // MARK: - Coordinated file I/O

    /// Reads `url` under an `NSFileCoordinator` read lock, so a concurrent iCloud daemon
    /// write can't tear the file out from under us. Applied unconditionally: for local
    /// (non-ubiquitous) files coordination is cheap and a transparent pass-through, and the
    /// synced root may be the iCloud container, where racing the daemon is the actual bug.
    private func coordinatedRead(at url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        // NSFileCoordinator surfaces accessor failures through the `byAccessor` closure, not
        // its own `error` out-param, so capture into an outer var and rethrow afterwards.
        var accessorError: Error?
        var result: Data?
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do { result = try Data(contentsOf: readURL) } catch { accessorError = error }
        }
        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
        // `result` is non-nil whenever neither error fired.
        return result ?? Data()
    }

    /// Writes `data` to `url` under an `NSFileCoordinator` write lock (`.forReplacing`),
    /// atomically. Applied unconditionally for the same reason as `coordinatedRead`.
    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var accessorError: Error?
        var coordinationError: NSError?
        coordinator.coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { writeURL in
            do { try data.write(to: writeURL, options: .atomic) } catch { accessorError = error }
        }
        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
    }

    // MARK: - Sidecar I/O

    /// Writes the sidecar `metadata.json` for `entry` (folder must already exist).
    func writeMetadata(_ metadata: EntryMetadata, for entry: CatalogEntry) throws {
        try coordinatedWrite(metadata.encoded(), to: metadataFile(for: entry))
    }

    /// Writes the sidecar into a raw folder name (used by the reconciler to backfill a
    /// sidecar for a pre-existing entry that predates iCloud sync). Folder must exist.
    func writeMetadata(_ metadata: EntryMetadata, forFolderNamed name: String) throws {
        try coordinatedWrite(metadata.encoded(), to: metadataFile(forFolderNamed: name))
    }

    /// Reads the sidecar for a raw folder name, or `nil` if the file is absent.
    /// Throws only if the file exists but cannot be decoded.
    func readMetadata(forFolderNamed name: String) throws -> EntryMetadata? {
        let url = metadataFile(forFolderNamed: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let meta = try EntryMetadata.decoded(from: coordinatedRead(at: url))
        return resolvingConflicts(of: meta, at: url)
    }

    /// Reads the sidecar for a raw folder name, distinguishing *absent* from *undecodable*.
    ///
    /// The scanner relies on this distinction: a sidecar that exists but won't decode (an
    /// iCloud conflict placeholder, a half-synced file, or a future schema version) must be
    /// left alone, whereas an absent sidecar can be safely backfilled. The throwing
    /// `readMetadata(forFolderNamed:)` collapses both into a thrown error / `nil` and is kept
    /// for callers that only need the happy path (e.g. `updateMetadata`).
    func readSidecar(forFolderNamed name: String) -> SidecarReadResult {
        let url = metadataFile(forFolderNamed: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? coordinatedRead(at: url),
              let meta = try? EntryMetadata.decoded(from: data)
        else { return .unreadable }
        return .ok(resolvingConflicts(of: meta, at: url))
    }

    /// Best-effort resolution of iCloud edit conflicts for a sidecar we've **already decoded
    /// successfully** (`current`). When two devices edited the same `metadata.json`, iCloud
    /// keeps the losing versions as conflict siblings; left alone they're never reconciled and
    /// one device's favorites/visited/trash silently disappears.
    ///
    /// We union-merge every decodable conflict version into `current` (see
    /// `EntryMetadata.merging(conflicts:)`), write the merged result back, and mark the
    /// **decoded** conflicts resolved. The entire block is best-effort (`try?`-style): a
    /// failure here must never block reading, and on local roots / in tests there are never
    /// any conflict versions, so it is fully inert (returns `current` unchanged). Gating on a
    /// successful decode of `current` preserves the never-overwrite-an-unreadable-sidecar
    /// invariant.
    ///
    /// **Undecodable versions are preserved, never destroyed.** A conflict version that won't
    /// decode is most likely a *newer* schema written by another device's future build;
    /// `removeOtherVersionsOfItem` is irreversible, so deleting it would permanently destroy
    /// that device's favorites/visited/trash state. We therefore call
    /// `removeOtherVersionsOfItem` only when **every** conflict version decoded into the
    /// merge; otherwise only the decoded versions are marked `.isResolved`, and the
    /// undecodable ones stay unresolved for a future build that understands them. Leaving
    /// conflicts pending is safe: the union merge is idempotent, so re-merging on a later
    /// read — including two devices alternating writes — converges on the same merged set.
    private func resolvingConflicts(of current: EntryMetadata, at url: URL) -> EntryMetadata {
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return current }

        let decodedPairs = conflicts.compactMap { version -> (NSFileVersion, EntryMetadata)? in
            guard let data = try? Data(contentsOf: version.url),
                  let meta = try? EntryMetadata.decoded(from: data)
            else { return nil }
            return (version, meta)
        }
        let merged = current.merging(conflicts: decodedPairs.map(\.1))

        do {
            try coordinatedWrite(merged.encoded(), to: url)
            for (version, _) in decodedPairs {
                version.isResolved = true
            }
            if decodedPairs.count == conflicts.count {
                // Every version was folded into the merge — safe to discard the copies.
                try? NSFileVersion.removeOtherVersionsOfItem(at: url)
            }
            return merged
        } catch {
            // Couldn't persist the merge; return the in-memory union so the caller at least
            // sees the combined state for this read, leaving conflicts to retry next time.
            return merged
        }
    }

    /// Reads the sidecar, applies `mutate`, and writes it back, preserving every field
    /// the caller does not touch. No-op if the sidecar is absent. Use this instead of
    /// reconstructing `EntryMetadata` from an in-memory `CatalogEntry` (which does not
    /// carry the favorite/visited sets and would clobber them).
    func updateMetadata(forFolderNamed name: String, _ mutate: (inout EntryMetadata) -> Void) throws {
        guard var meta = try readMetadata(forFolderNamed: name) else { return }
        mutate(&meta)
        try writeMetadata(meta, forFolderNamed: name)
    }

    // MARK: - Enumeration

    /// Names of all per-entry folders directly under the synced root. Returns `[]`
    /// if the root does not yet exist.
    func entryFolderNames() throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let contents = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return isDir ? url.lastPathComponent : nil
        }
    }

    // MARK: - Root migration

    /// The outcome of a root migration: which per-entry folders moved and which couldn't.
    ///
    /// Migration is best-effort *per folder* — a single failing folder must not strand the
    /// rest in the old root — so the result is a report rather than a thrown error. The caller
    /// repoints storage to `newRoot` regardless (the moved majority lives there) and surfaces
    /// `failed` to the user, whose files remain readable in the previous location.
    struct MigrationReport {
        var moved: [String] = []
        var failed: [MigrationFailure] = []
    }

    /// A single per-folder migration failure: the folder that could not be moved and why.
    struct MigrationFailure {
        let folderName: String
        let error: Error
    }

    /// Moves every per-entry folder from `oldRoot` into `newRoot`, so nothing disappears
    /// from the catalogue when the iCloud sync toggle changes the active root.
    ///
    /// Picks the correct file API for the move:
    /// - **local → iCloud** (`toUbiquitous`): `setUbiquitous(true,…)` to publish the folder
    ///   into the ubiquity container (plain `moveItem` into iCloud is unsupported).
    /// - **iCloud → local** (`fromUbiquitous`): `setUbiquitous(false,…)` to evict it.
    /// - **otherwise** (local → local): `moveItem`.
    ///
    /// Each move (`setUbiquitous`/`moveItem`) removes the source folder on success, so after a
    /// fully successful migration no per-entry folders remain in `oldRoot`.
    ///
    /// Creates `newRoot` if absent. Skips any folder whose name already exists at the
    /// destination (the destination is authoritative — e.g. iCloud already holds that
    /// entry) without recording a failure. **Per-folder failures are collected and the loop
    /// continues**, so one bad folder never strands the others; the returned `MigrationReport`
    /// lists what moved and what failed. Returns an empty report when the roots are equal or
    /// `oldRoot` is absent. Only throws for failures *before* the per-folder loop (creating
    /// `newRoot`, enumerating `oldRoot`).
    @discardableResult
    static func migrateEntryFolders(
        from oldRoot: URL,
        to newRoot: URL,
        fromUbiquitous: Bool = false,
        toUbiquitous: Bool = false
    ) throws -> MigrationReport {
        var report = MigrationReport()
        guard oldRoot.standardizedFileURL != newRoot.standardizedFileURL else { return report }
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldRoot.path) else { return report }
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)

        let contents = try fm.contentsOfDirectory(
            at: oldRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for source in contents {
            let isDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDir else { continue }
            let name = source.lastPathComponent
            let dest = newRoot.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: dest.path) { continue }

            do {
                if toUbiquitous, !fromUbiquitous {
                    try fm.setUbiquitous(true, itemAt: source, destinationURL: dest)
                } else if fromUbiquitous, !toUbiquitous {
                    try fm.setUbiquitous(false, itemAt: source, destinationURL: dest)
                } else {
                    try fm.moveItem(at: source, to: dest)
                }
                report.moved.append(name)
            } catch {
                // Collect and keep going — a single un-movable folder (e.g. a non-empty
                // destination already present, or a transient iCloud error) must not strand
                // the remaining entries in the old root.
                report.failed.append(MigrationFailure(folderName: name, error: error))
            }
        }
        return report
    }

    // MARK: - Directory management

    /// Creates the synced per-entry folder and the local `resources/` subdirectory.
    /// Idempotent.
    func createFolders(for entry: CatalogEntry) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder(for: entry), withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesDirectory(for: entry), withIntermediateDirectories: true)
    }

    /// Removes the entry's synced folder and its local resources folder.
    /// Safe to call when either is absent.
    func removeFolder(for entry: CatalogEntry) throws {
        try removeFolder(named: entry.storageFolderName)
    }

    /// Removes the synced folder and local resources folder for a raw folder name.
    func removeFolder(named name: String) throws {
        let fm = FileManager.default
        let synced = root.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: synced.path) { try fm.removeItem(at: synced) }
        let cache = cacheRoot.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: cache.path) { try fm.removeItem(at: cache) }
    }
}
