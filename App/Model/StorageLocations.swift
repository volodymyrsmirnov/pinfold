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
    /// No sidecar is on disk *yet*, but in an iCloud root it very likely exists remotely and has
    /// just not downloaded. Treated like `.unreadable`: never backfilled over (B2).
    case notDownloaded
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
    /// `true` when `root` is the iCloud container (set by `synced(root:)`). Gates the
    /// "never backfill over a sidecar that has not downloaded" rule.
    var isUbiquitous = false
    /// Answers "has this iCloud item downloaded?" Injectable so tests need no iCloud.
    var probe: any UbiquityProbe = SystemUbiquityProbe()
    /// Unresolved iCloud conflict versions of a file. Injectable; defaults to `NSFileVersion`.
    var conflictVersions: @Sendable (URL) -> [ConflictVersion] = ConflictVersion.systemVersions(of:)
    /// Discards every other version of a file once all conflicts were folded in. Injectable.
    var removeOtherVersions: @Sendable (URL) throws -> Void = ConflictVersion.removeSystemOtherVersions(of:)

    /// Top-level folder name reserved for the local cache root; never an entry folder.
    static let reservedCacheFolderName = "resources"

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
        let cacheRoot = applicationSupportRoot
            .appendingPathComponent(reservedCacheFolderName, isDirectory: true)
        var locations = StorageLocations(root: root, cacheRoot: cacheRoot)
        locations.isUbiquitous = true
        return locations
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

    /// Writes the original KML/KMZ bytes to `originalFile(for:)` atomically, under an
    /// `NSFileCoordinator` `.forReplacing` lock (pass-through for local roots).
    func writeOriginal(_ data: Data, for entry: CatalogEntry) throws {
        try coordinatedWrite(data, to: originalFile(for: entry))
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

    // `originalFileURL(inFolderNamed:)` lives in StorageLocations+Original.swift.

    // MARK: - Coordinated file I/O

    /// Reads `url` under an `NSFileCoordinator` read lock, so a concurrent iCloud daemon
    /// write can't tear the file out from under us. Applied unconditionally: for local
    /// (non-ubiquitous) files coordination is cheap and a transparent pass-through, and the
    /// synced root may be the iCloud container, where racing the daemon is the actual bug.
    func coordinatedRead(at url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        // NSFileCoordinator surfaces accessor failures through the `byAccessor` closure, not
        // its own `error` out-param, so capture into an outer var and rethrow afterwards.
        var accessorError: Error?
        var result: Data?
        var coordinationError: NSError?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do { result = try Data(contentsOf: readURL) } catch { accessorError = error }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let accessorError {
            throw accessorError
        }
        // `result` is non-nil whenever neither error fired.
        return result ?? Data()
    }

    /// Writes `data` to `url` under an `NSFileCoordinator` write lock (`.forReplacing`),
    /// atomically. Applied unconditionally for the same reason as `coordinatedRead`.
    func coordinatedWrite(_ data: Data, to url: URL) throws {
        try Self.coordinate(writingAt: url, options: .forReplacing) { writeURL in
            try data.write(to: writeURL, options: .atomic)
        }
    }

    /// Removes `url` under an `NSFileCoordinator` `.forDeleting` lock.
    static func coordinatedRemove(at url: URL) throws {
        try coordinate(writingAt: url, options: .forDeleting) { target in
            try FileManager.default.removeItem(at: target)
        }
    }

    /// Runs `body` inside a coordinated write on `url`, rethrowing both coordination and
    /// accessor failures (the latter surface through the accessor closure, not `error:`).
    static func coordinate(
        writingAt url: URL,
        options: NSFileCoordinator.WritingOptions,
        _ body: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var accessorError: Error?
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { target in
            do { try body(target) } catch { accessorError = error }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let accessorError {
            throw accessorError
        }
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
        guard FileManager.default.fileExists(atPath: url.path) else {
            return isUbiquitous && sidecarProbablyExistsRemotely(at: url, folderNamed: name)
                ? .notDownloaded : .missing
        }
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
    func resolvingConflicts(of current: EntryMetadata, at url: URL) -> EntryMetadata {
        let conflicts = conflictVersions(url)
        guard !conflicts.isEmpty else { return current }

        let decodedPairs = conflicts.compactMap { version -> (ConflictVersion, EntryMetadata)? in
            guard let data = version.read(),
                  let meta = try? EntryMetadata.decoded(from: data)
            else { return nil }
            return (version, meta)
        }
        let merged = current.merging(conflicts: decodedPairs.map(\.1))

        do {
            try coordinatedWrite(merged.encoded(), to: url)
            for (version, _) in decodedPairs {
                version.markResolved()
            }
            if decodedPairs.count == conflicts.count {
                // Every version was folded into the merge — safe to discard the copies.
                try? removeOtherVersions(url)
            }
            return merged
        } catch {
            // Couldn't persist the merge; return the in-memory union so the caller at least
            // sees the combined state for this read, leaving conflicts to retry next time.
            return merged
        }
    }

    // `updateMetadata` / `updateExistingMetadata` live in StorageLocations+Update.swift.

    // MARK: - Enumeration

    /// Names of all per-entry folders directly under the synced root. Returns `[]`
    /// if the root does not yet exist.
    func entryFolderNames() throws -> [String] {
        try Self.entryFolderNames(in: root)
    }

    /// Names of the per-entry folders directly under `root`: every directory except the
    /// reserved `resources` cache root. (Not "UUID folders only": the scanner deliberately
    /// supports legacy and user-dropped folders with other names.)
    static func entryFolderNames(in root: URL) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let contents = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let name = url.lastPathComponent
            return isDir && name != reservedCacheFolderName ? name : nil
        }
    }

    // MARK: - Directory management

    /// Creates the synced per-entry folder (coordinated) and the local `resources/` subdirectory.
    /// Idempotent.
    func createFolders(for entry: CatalogEntry) throws {
        let fm = FileManager.default
        try Self.coordinate(writingAt: folder(for: entry), options: []) { target in
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: resourcesDirectory(for: entry), withIntermediateDirectories: true)
    }

    /// Removes the entry's synced folder and its local resources folder.
    /// Safe to call when either is absent.
    func removeFolder(for entry: CatalogEntry) throws {
        try removeFolder(named: entry.storageFolderName)
    }

    /// What `removeFolderIfTrashed` did.
    enum TrashedRemoval: Equatable {
        /// The folder (and its local cache) was removed.
        case removed
        /// Kept: the folder is gone already, or its sidecar no longer marks it trashed
        /// (restored on this or another device).
        case notTrashed
        /// Kept: the sidecar can't be read (still downloading, corrupt), so whether it is
        /// trashed can't be confirmed.
        case unreadable
    }

    /// Removes the folder only if its sidecar still marks it as trashed, checking and removing
    /// inside ONE coordinated `.forDeleting` lock on the folder, so a restore arriving from
    /// another device or process (the iCloud daemon writes the sidecar under coordination)
    /// can't land between the check and the removal. The local resources folder goes too, but
    /// only when the synced folder was removed. When in doubt, the file is kept.
    func removeFolderIfTrashed(named name: String) throws -> TrashedRemoval {
        let fm = FileManager.default
        let synced = root.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: synced.path) else { return .notTrashed }
        var outcome = TrashedRemoval.notTrashed
        try Self.coordinate(writingAt: synced, options: .forDeleting) { target in
            // Plain read: the coordinated write on the folder already excludes other writers.
            let sidecar = target.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: sidecar),
                  let meta = try? EntryMetadata.decoded(from: data)
            else {
                outcome = .unreadable
                return
            }
            guard meta.trashedAt != nil else { return }
            try fm.removeItem(at: target)
            outcome = .removed
        }
        if outcome == .removed {
            // Best effort: the file is already deleted. This is derived per-device data, and a
            // background cache build may be writing into it at this moment; anything left over
            // is an orphan nothing reads.
            let cache = cacheRoot.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(atPath: cache.path) {
                try? fm.removeItem(at: cache)
            }
        }
        return outcome
    }

    /// Removes the synced folder (coordinated, `.forDeleting`) and the local resources folder
    /// (plain: it never syncs) for a raw folder name.
    func removeFolder(named name: String) throws {
        let fm = FileManager.default
        let synced = root.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: synced.path) {
            try Self.coordinatedRemove(at: synced)
        }
        let cache = cacheRoot.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: cache.path) {
            try fm.removeItem(at: cache)
        }
    }
}
