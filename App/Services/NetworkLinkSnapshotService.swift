import Foundation
import PinfoldCore

/// Downloads a one-time snapshot of the files a `<NetworkLink>` document points at.
///
/// Nothing here runs on its own: the file screen offers the snapshot, names the hosts, and calls
/// in only after the person confirms. Downloads use `BoundedDownloader` (50 MB cap, no
/// cookies), upgrade `http` to `https`, never follow links found inside the downloaded content,
/// and are validated with `ImportService.prepare` before anything on disk is touched.
struct NetworkLinkSnapshotService {
    // MARK: - Types

    /// Fetches the bytes for a URL. Tests inject a stub so nothing touches the network.
    typealias Downloader = @Sendable (URL) async throws -> Data

    /// Why a snapshot could not be taken. Messages are written for the person using the app.
    enum SnapshotError: Error, LocalizedError, Equatable {
        case unsupportedLink(String)
        case http(Int)
        case tooLarge
        case notKML
        case noPlacemarks
        case readOnly
        case network(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedLink(href):
                "Pinfold can only download http and https links (\(href))."
            case let .http(status):
                "The server answered with an error (HTTP \(status))."
            case .tooLarge:
                "The linked file is larger than 50 MB."
            case .notKML:
                "The linked file is not a KML or KMZ file."
            case .noPlacemarks:
                "The linked file has no placemarks."
            case .readOnly:
                "This file cannot be changed right now. Try again once it has finished syncing."
            case let .network(message):
                "The download failed: \(message)"
            case let .writeFailed(message):
                "The downloaded file could not be saved: \(message)"
            }
        }
    }

    /// A downloaded and validated file, ready to import or to replace an original.
    struct Downloaded {
        let result: ImportResult
    }

    /// The outcome of enqueueing several links.
    struct EnqueueOutcome {
        var enqueued = 0
        var failures: [SnapshotError] = []
    }

    // MARK: - Configuration

    /// Largest accepted download.
    static let defaultMaxBytes = 50 * 1024 * 1024
    private static let timeout: TimeInterval = 30

    let downloader: Downloader
    let maxBytes: Int

    /// The live downloader: `BoundedDownloader` with the cap.
    static func liveDownloader(maxBytes: Int = defaultMaxBytes) -> Downloader {
        { url in
            try await BoundedDownloader.fetch(
                url, maxBytes: maxBytes, timeout: timeout, followCrossHostRedirects: false
            )
        }
    }

    init(maxBytes: Int = defaultMaxBytes, downloader: Downloader? = nil) {
        self.maxBytes = maxBytes
        self.downloader = downloader ?? Self.liveDownloader(maxBytes: maxBytes)
    }

    // MARK: - Links

    /// The URL to fetch for `link`: `http(s)` only, with `http` upgraded to `https`.
    static func fetchURL(for link: KMLNetworkLink) -> URL? {
        let trimmed = link.href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.host?.isEmpty == false
        else { return nil }
        return ResourceCache.httpsUpgraded(url)
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

    // MARK: - Download

    /// Downloads `link` and validates the bytes as KML or KMZ.
    func download(_ link: KMLNetworkLink) async throws(SnapshotError) -> Downloaded {
        guard let url = Self.fetchURL(for: link) else { throw .unsupportedLink(link.href) }
        let data: Data
        do {
            data = try await downloader(url)
        } catch let error as DownloadError {
            throw Self.mapped(error)
        } catch is CancellationError {
            throw .network("cancelled")
        } catch {
            throw .network(error.localizedDescription)
        }
        guard data.count <= maxBytes else { throw .tooLarge }
        return try await validated(data, filename: Self.filename(for: link, url: url))
    }

    private static func mapped(_ error: DownloadError) -> SnapshotError {
        switch error {
        case let .httpStatus(status): .http(status)
        case .tooLarge: .tooLarge
        case .redirectedToOtherHost: .network("the server redirected to a different host")
        case let .transport(underlying): .network(underlying.localizedDescription)
        }
    }

    private func validated(_ data: Data, filename: String) async throws(SnapshotError) -> Downloaded {
        let result = await prepareOffMain(data, filename: filename)
        switch result {
        case let .success(prepared):
            guard prepared.pointCount > 0 || !prepared.indexEntries.isEmpty else { throw .noPlacemarks }
            return Downloaded(result: prepared)
        case .failure:
            throw .notKML
        }
    }

    // MARK: - Several links: each becomes a new entry

    /// Downloads every link and hands each file to the import queue as a new entry. The link
    /// file itself is left as it is (there is no KML writer to merge them).
    @MainActor
    func enqueueSnapshots(
        for links: [KMLNetworkLink],
        coordinator: ImportCoordinator,
        catalog: Catalog,
        cache: ResourceCache
    ) async -> EnqueueOutcome {
        var outcome = EnqueueOutcome()
        for link in links {
            do {
                let downloaded = try await download(link)
                coordinator.enqueueDownloaded(
                    downloaded.result.originalData,
                    filename: downloaded.result.sourceFilename,
                    catalog: catalog,
                    cache: cache
                )
                outcome.enqueued += 1
            } catch {
                outcome.failures.append(error)
            }
        }
        return outcome
    }

    // MARK: - One link: replace the original

    /// Downloads the single `link` and, when it is valid, replaces `entry`'s original with it:
    /// new bytes, sidecar `sourceFilename`/`pointCount`/`contentSHA256`, derived `resources/`
    /// removed (it rebuilds), catalogue reloaded. Nothing changes if any step before the write
    /// fails. Returns the updated entry.
    @MainActor
    func replaceOriginal(
        of entry: CatalogEntry,
        with link: KMLNetworkLink,
        storage: StorageLocations,
        catalog: Catalog
    ) async throws(SnapshotError) -> CatalogEntry {
        let live = catalog.entries.first { $0.storageFolderName == entry.storageFolderName } ?? entry
        guard !live.isReadOnly else { throw .readOnly }
        let downloaded = try await download(link)
        let updated: CatalogEntry
        do {
            updated = try await applySnapshot(downloaded.result, to: live, storage: storage)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        SpotlightIndexer.index(entry: updated, indexEntries: downloaded.result.indexEntries)
        await catalog.reload()
        return updated
    }
}

// MARK: - Off-main work

/// Validates downloaded bytes off the main actor. A `nonisolated` free function so the detached
/// closure is compiled outside any actor-isolated caller (see FavoritesView.swift).
private nonisolated func prepareOffMain(_ data: Data, filename: String) async -> Result<ImportResult, ImportError> {
    await Task.detached(priority: .userInitiated) {
        do {
            return try .success(ImportService.prepare(data: data, sourceFilename: filename))
        } catch let error as ImportError {
            return .failure(error)
        } catch {
            return .failure(.parseFailure(underlying: error))
        }
    }.value
}

/// Writes the snapshot over `entry`'s original and updates its sidecar, off the main actor.
private nonisolated func applySnapshot(
    _ result: ImportResult, to entry: CatalogEntry, storage: StorageLocations
) async throws -> CatalogEntry {
    try await Task.detached(priority: .userInitiated) {
        try writeSnapshot(result, to: entry, storage: storage)
    }.value
}

/// The synchronous file work behind `applySnapshot`. Ordered so a failure at any step leaves
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
        pruneDerivedResources(in: resourcesDir)
    }
    return updated
}

/// How much of an entry's `resources/` a snapshot write resets.
enum ResourceReset {
    /// Remove the whole folder; the next reload rebuilds it (the one-time snapshot).
    case all
    /// Remove only what derives from the original, keeping the files that hold the person's
    /// choices and the refresh state (`ResourceReset.keptFilenames`). Nothing is rebuilt here:
    /// the caller rebuilds (see `SubscriptionContentWriter`).
    case derivedOnly

    /// The files `.derivedOnly` keeps: the refresh state and the download state, which holds the
    /// person's remote-image consent.
    static let keptFilenames: Set<String> = [SubscriptionStateStore.filename, ResourceManifestStore.stateFilename]
}

/// Removes everything in `resourcesDir` except `ResourceReset.keptFilenames`. Best effort, like
/// the `.all` removal: what survives is derivable and rebuilds from the source stamp.
private nonisolated func pruneDerivedResources(in resourcesDir: URL) {
    let fm = FileManager.default
    let names = (try? fm.contentsOfDirectory(atPath: resourcesDir.path)) ?? []
    for name in names where !ResourceReset.keptFilenames.contains(name) {
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
