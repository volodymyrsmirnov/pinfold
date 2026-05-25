import Foundation

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

    /// The sidecar path for a raw folder name (used by the reconciler before a
    /// `KMLFileEntry` exists).
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

    // MARK: - Sidecar I/O

    /// Writes the sidecar `metadata.json` for `entry` (folder must already exist).
    func writeMetadata(_ metadata: EntryMetadata, for entry: CatalogEntry) throws {
        try metadata.encoded().write(to: metadataFile(for: entry))
    }

    /// Writes the sidecar into a raw folder name (used by the reconciler to backfill a
    /// sidecar for a pre-existing entry that predates iCloud sync). Folder must exist.
    func writeMetadata(_ metadata: EntryMetadata, forFolderNamed name: String) throws {
        try metadata.encoded().write(to: metadataFile(forFolderNamed: name))
    }

    /// Reads the sidecar for a raw folder name, or `nil` if the file is absent.
    /// Throws only if the file exists but cannot be decoded.
    func readMetadata(forFolderNamed name: String) throws -> EntryMetadata? {
        let url = metadataFile(forFolderNamed: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try EntryMetadata.decoded(from: Data(contentsOf: url))
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

    /// Moves every per-entry folder from `oldRoot` into `newRoot`, so nothing disappears
    /// from the catalogue when the iCloud sync toggle changes the active root.
    ///
    /// Picks the correct file API for the move:
    /// - **local → iCloud** (`toUbiquitous`): `setUbiquitous(true,…)` to publish the folder
    ///   into the ubiquity container (plain `moveItem` into iCloud is unsupported).
    /// - **iCloud → local** (`fromUbiquitous`): `setUbiquitous(false,…)` to evict it.
    /// - **otherwise** (local → local): `moveItem`.
    ///
    /// Creates `newRoot` if absent. Skips any folder whose name already exists at the
    /// destination (the destination is authoritative — e.g. iCloud already holds that
    /// entry) without throwing. No-op when the roots are equal or `oldRoot` is absent.
    static func migrateEntryFolders(
        from oldRoot: URL,
        to newRoot: URL,
        fromUbiquitous: Bool = false,
        toUbiquitous: Bool = false
    ) throws {
        guard oldRoot.standardizedFileURL != newRoot.standardizedFileURL else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: oldRoot.path) else { return }
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)

        let contents = try fm.contentsOfDirectory(
            at: oldRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for source in contents {
            let isDir = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDir else { continue }
            let dest = newRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: dest.path) { continue }

            if toUbiquitous, !fromUbiquitous {
                try fm.setUbiquitous(true, itemAt: source, destinationURL: dest)
            } else if fromUbiquitous, !toUbiquitous {
                try fm.setUbiquitous(false, itemAt: source, destinationURL: dest)
            } else {
                try fm.moveItem(at: source, to: dest)
            }
        }
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
