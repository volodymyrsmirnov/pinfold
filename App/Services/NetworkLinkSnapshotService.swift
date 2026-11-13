import Foundation
import PinfoldCore

/// Helpers shared by the subscribe flow: which `<NetworkLink>` hrefs can be followed, and the
/// file work that replaces an entry's original with fetched content.
enum NetworkLinkSnapshotService {
    // MARK: - Links

    /// The URL to fetch for `link`: `http(s)` only, with `http` upgraded to `https`.
    static func fetchURL(for link: KMLNetworkLink) -> URL? {
        SubscriptionURL.normalise(link.href)
    }

    /// The filename to store a download under: the URL's own `.kml`/`.kmz` name, else the link
    /// name (or host) with a `.kml` extension (`ImportService.prepare` corrects it by content).
    static func filename(for link: KMLNetworkLink, url: URL) -> String {
        let last = url.lastPathComponent
        if ImportFormats.originalExtensions.contains((last as NSString).pathExtension.lowercased()) {
            return last
        }
        let base = link.name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ?? url.host ?? "network-link"
        return "\(base).kml"
    }
}

/// The synchronous file work that replaces an original with fetched content. Ordered so a failure at any step leaves
/// the old original and old sidecar intact:
/// 1. require a readable sidecar (a missing or not-yet-downloaded one aborts before any write);
/// 2. write the new bytes under a temporary, non-original name in the entry folder;
/// 3. update the sidecar (throws if absent);
/// 4. move the temporary file into place, rolling the sidecar back if that fails;
/// 5. only then remove a differently named old original (never when both names are the same
///    file, as with a case-only rename on a case-insensitive volume);
/// 6. reset `resources/` as `resetResources` says.
nonisolated func writeSnapshot(
    _ result: ImportResult,
    to entry: CatalogEntry,
    storage: StorageLocations,
    resetResources: ResourceReset = .all
) throws -> CatalogEntry {
    guard case .ok = storage.readSidecar(forFolderNamed: entry.storageFolderName) else {
        throw CocoaError(.fileNoSuchFile)
    }
    var updated = entry
    updated.sourceFilename = result.sourceFilename
    updated.pointCount = result.pointCount
    updated.contentSHA256 = result.contentSHA256

    let fm = FileManager.default
    let oldURL = storage.originalFile(for: entry)
    let newURL = storage.originalFile(for: updated)
    let tempURL = storage.folder(for: entry).appendingPathComponent(".snapshot-\(UUID().uuidString).tmp")

    try storage.coordinatedWrite(result.originalData, to: tempURL)
    if isSameFile(oldURL, newURL) {
        // Same file slot: the sidecar can never name a missing file, so sidecar first, then
        // the in-place replace (rolled back on failure).
        try updateOwnedFields(of: entry, to: updated, storage: storage, discarding: tempURL)
        do {
            try placeSnapshot(tempURL, over: oldURL, as: newURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            try? updateOwnedFields(of: entry, to: entry, storage: storage, discarding: nil)
            throw error
        }
    } else {
        // New name: publish the new file first (the old one stays until the sidecar names the
        // new one), so a crash in between never leaves a sidecar naming a missing file.
        try placeSnapshotFile(tempURL, as: newURL)
        do {
            try updateOwnedFields(of: entry, to: updated, storage: storage, discarding: nil)
        } catch {
            try? fm.removeItem(at: newURL)
            throw error
        }
        try? fm.removeItem(at: oldURL)
    }
    let resourcesDir = storage.resourcesDirectory(for: entry)
    switch resetResources {
    case .all:
        // Everything under `resources/` derives from the original; it rebuilds on the next reload.
        try? fm.removeItem(at: resourcesDir)
    case .derivedOnly:
        pruneDerivedResources(in: resourcesDir, keepingRemote: Set(result.remoteResourceHrefs))
    }
    return updated
}

/// How much of an entry's `resources/` a snapshot write resets.
enum ResourceReset {
    /// Remove the whole folder; the next reload rebuilds it (the one-time snapshot).
    case all
    /// Remove only what derives from the original's bytes (KMZ media, the search index and its
    /// stamps, the parse marker, `remote-hrefs.json`), keeping the files that hold the person's
    /// choices and the refresh state (`ResourceReset.keptFilenames`), the manifest, and the
    /// downloaded images of remote hrefs the new original still lists. Nothing is rebuilt here:
    /// the caller rebuilds (see `SubscriptionContentWriter`).
    case derivedOnly

    /// The files `.derivedOnly` always keeps: the refresh state, the download state (which holds
    /// the person's remote-image consent) and the manifest (trimmed by `pruneForRefresh`).
    static let keptFilenames: Set<String> = [
        SubscriptionStateStore.filename, ResourceManifestStore.stateFilename, ResourceManifestStore.manifestFilename,
    ]
}

/// Trims the remote image cache to `hrefs` (`ResourceManifestStore.pruneForRefresh`), then removes
/// everything else in `resourcesDir` except `ResourceReset.keptFilenames` and the images still in
/// use. Best effort, like the `.all` removal: what goes is derivable and rebuilds.
private nonisolated func pruneDerivedResources(in resourcesDir: URL, keepingRemote hrefs: Set<String>) {
    let inUse = ResourceManifestStore.shared.pruneForRefresh(keepingRemote: hrefs, in: resourcesDir)
    let keep = ResourceReset.keptFilenames.union(inUse)
    let fm = FileManager.default
    let names = (try? fm.contentsOfDirectory(atPath: resourcesDir.path)) ?? []
    for name in names where !keep.contains(name) {
        try? fm.removeItem(at: resourcesDir.appendingPathComponent(name))
    }
}

/// Updates only the content fields a snapshot owns (`sourceFilename`, `pointCount`,
/// `contentSHA256`) in one coordinated read-modify-write, leaving tags, favourites, trash state
/// and everything else exactly as a concurrent edit left them. Removes `discarding` on failure.
private nonisolated func updateOwnedFields(
    of entry: CatalogEntry, to target: CatalogEntry, storage: StorageLocations, discarding: URL?
) throws {
    do {
        try storage.updateExistingMetadata(forFolderNamed: entry.storageFolderName) { metadata in
            metadata.sourceFilename = target.sourceFilename
            metadata.pointCount = target.pointCount
            metadata.contentSHA256 = target.contentSHA256
        }
    } catch {
        if let discarding {
            try? FileManager.default.removeItem(at: discarding)
        }
        throw error
    }
}

/// Moves the downloaded `temp` file to the not-yet-existing `new` name (never replaces a folder).
private nonisolated func placeSnapshotFile(_ temp: URL, as new: URL) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: new.path, isDirectory: &isDirectory) {
        try? FileManager.default.removeItem(at: temp)
        throw CocoaError(.fileWriteFileExists)
    }
    do {
        try rename(temp, to: new)
    } catch {
        try? FileManager.default.removeItem(at: temp)
        throw error
    }
}

/// Moves the downloaded `temp` file into place as `new` with an atomic `rename(2)`, then removes
/// the superseded `old` original, unless `old` and `new` are the same file (as with a case-only
/// rename on a case-insensitive volume), which must never be deleted.
private nonisolated func placeSnapshot(_ temp: URL, over old: URL, as new: URL) throws {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    if fm.fileExists(atPath: new.path, isDirectory: &isDirectory), isDirectory.boolValue {
        // Never replace a folder squatting on the name.
        throw CocoaError(.fileWriteFileExists)
    }
    if isSameFile(old, new) {
        // Same name, or a case-only rename: replace in place, then adopt the new casing
        // (best effort). `old` is never deleted: it is the file just written.
        try rename(temp, to: old)
        if old.lastPathComponent != new.lastPathComponent {
            try? rename(old, to: new)
        }
        return
    }
    try rename(temp, to: new)
    try? fm.removeItem(at: old)
}

/// Atomic `rename(2)` (replaces an existing destination file).
private nonisolated func rename(_ source: URL, to destination: URL) throws {
    guard Darwin.rename(source.path, destination.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Whether `lhs` and `rhs` are the same file slot: the same path, or names that differ only in
/// letter case. On a case-insensitive volume those are one file (`stat` can even disagree about
/// whether the other casing exists, so the directory listing is the arbiter); on a
/// case-sensitive one a file already existing under *both* exact names means two real files.
private nonisolated func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
    if lhs.path == rhs.path {
        return true
    }
    guard
        lhs.deletingLastPathComponent().path == rhs.deletingLastPathComponent().path,
        lhs.lastPathComponent.caseInsensitiveCompare(rhs.lastPathComponent) == .orderedSame
    else { return false }
    let listing = (try? FileManager.default.contentsOfDirectory(atPath: lhs.deletingLastPathComponent().path)) ?? []
    return !(listing.contains(lhs.lastPathComponent) && listing.contains(rhs.lastPathComponent))
}
