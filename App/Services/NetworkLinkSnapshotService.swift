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
        { url in try await BoundedDownloader.fetch(url, maxBytes: maxBytes, timeout: timeout) }
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

/// The synchronous file work behind `applySnapshot`. The new original is written first, then
/// the sidecar; if the sidecar update fails a differently named new file is removed again.
nonisolated func writeSnapshot(
    _ result: ImportResult, to entry: CatalogEntry, storage: StorageLocations
) throws -> CatalogEntry {
    var updated = entry
    updated.sourceFilename = result.sourceFilename
    updated.pointCount = result.pointCount
    updated.contentSHA256 = result.contentSHA256
    let renamed = updated.sourceFilename != entry.sourceFilename

    try storage.writeOriginal(result.originalData, for: updated)
    do {
        try storage.updateMetadata(forFolderNamed: entry.storageFolderName) { metadata in
            metadata.sourceFilename = updated.sourceFilename
            metadata.pointCount = updated.pointCount
            metadata.contentSHA256 = updated.contentSHA256
        }
    } catch {
        if renamed {
            try? FileManager.default.removeItem(at: storage.originalFile(for: updated))
        }
        throw error
    }
    if renamed {
        try? FileManager.default.removeItem(at: storage.originalFile(for: entry))
    }
    // Everything under `resources/` derives from the original; it rebuilds on the next reload.
    try? FileManager.default.removeItem(at: storage.resourcesDirectory(for: entry))
    return updated
}
