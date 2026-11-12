import CryptoKit
import Foundation
import os
import PinfoldCore

// MARK: - ImportResult

/// A value-type snapshot of a successfully-prepared import, ready to be committed.
///
/// `prepare(data:sourceFilename:)` computes all expensive work off the main actor
/// (hashing, parsing). `commit` then takes this struct on the main actor to create
/// the `CatalogEntry`, write files, and kick off caching.
struct ImportResult {
    /// Human-readable name shown in the catalogue (document name or filename stem).
    let displayName: String
    /// Original filename as received (e.g. `"Rome.kml"`).
    let sourceFilename: String
    /// Number of `<Placemark>` elements with `<Point>` geometry.
    let pointCount: Int
    /// Lowercase hex SHA-256 of the raw file bytes (before extraction).
    let contentSHA256: String
    /// UUID string used as the on-disk folder name for this entry.
    let storageFolderName: String
    /// The original file bytes to be written to disk.
    let originalData: Data
    /// The detected source format; a KMZ has its embedded resources streamed out of
    /// `originalData` at commit time.
    let format: SourceFormat
    /// Remote http(s) resource URLs gathered from icon styles and placemark photo links.
    let remoteResourceHrefs: [String]
    /// Flattened placemark search-index entries (stableKey + name + coordinate), built from
    /// the parsed document so `commit` can write the local `placemarks-index.json` without a
    /// re-parse. Backs catalogue-wide search.
    let indexEntries: [PlacemarkIndex.Entry]
}

// MARK: - ImportError

/// Errors thrown by `ImportService`.
enum ImportError: Error {
    /// The file bytes could not be parsed as a supported file.
    case parseFailure(underlying: Error)
}

extension ImportError: LocalizedError {
    /// The underlying description when it is readable, else the generic invalid-file reason
    /// (never a raw `NSXMLParserErrorDomain` string).
    var errorDescription: String? {
        switch self {
        case let .parseFailure(underlying):
            if let described = (underlying as? any LocalizedError)?.errorDescription, !described.isEmpty {
                return described
            }
            return ImportFormats.invalidFileReason
        }
    }
}

// MARK: - ImportService

/// Static methods that implement the two-phase import flow:
/// 1. `prepare` — off-main, pure computation; returns `ImportResult`.
/// 2. `commit`  — plain synchronous file I/O, `nonisolated`; the coordinator runs it through
///    `commitOffMain` so the main actor stays free. Returns the `CatalogEntry` on disk.
enum ImportService {
    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "import"
    )

    // MARK: - SHA-256

    /// Returns the lowercase hex SHA-256 digest of `data`.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Prepare (off-main)

    /// Parses `data`, hashes it, and gathers all resource references.
    ///
    /// This is a plain `static` function with no actor annotation — call it inside a
    /// `Task` or `async` context to keep the main actor free.
    ///
    /// - Parameters:
    ///   - data: Raw bytes of the KML or KMZ file.
    ///   - sourceFilename: The original filename (used as the display-name fallback and
    ///     as the stored filename on disk).
    /// - Returns: A fully-populated `ImportResult`.
    /// - Throws: `ImportError.parseFailure` if `KMLReader.read(data:)` fails.
    static func prepare(data: Data, sourceFilename rawSourceFilename: String) throws -> ImportResult {
        // Sanitize the attacker-controlled filename once, here — the single choke point all
        // three import paths flow through. A crafted name like "images/evil.kml" would
        // otherwise create nested paths under the per-entry folder and break the top-level
        // original-file lookup. The sanitized name is what we store and surface.
        let sourceFilename = ImportFormats.storedFilename(for: SafeFilename.sanitize(rawSourceFilename), data: data)

        let sha256 = sha256Hex(data)

        let document: KMLDocument
        let format: SourceFormat
        do {
            format = try KMLReader.detectFormat(of: data)
            document = try KMLReader.readDocument(data: data)
        } catch is CancellationError {
            // A cancelled parse is not a bad file: let the caller see the cancellation.
            throw CancellationError()
        } catch {
            throw ImportError.parseFailure(underlying: error)
        }

        // Display name: document name → filename without extension.
        let stem = (sourceFilename as NSString).deletingPathExtension
        let displayName = document.name.flatMap { $0.isEmpty ? nil : $0 } ?? stem

        let pointCount = document.pointCount

        // Gather remote resource hrefs from icon styles and placemark photo links.
        // Deduplicate and keep only http/https URLs (KMZ paths are handled separately).
        var iconHrefs: Set<String> = []
        var photoHrefs: Set<String> = []
        var imageHrefs: Set<String> = []
        for style in document.styles.values {
            guard let href = style.iconHref else { continue }
            if ResourceCache.isRemoteHref(href) {
                iconHrefs.insert(href)
            }
        }
        /// Description images are only ever rendered from the cache, so they must be fetched
        /// here. `imageSources` trims, matching the key `DescriptionView` looks up. This covers
        /// placemark, folder and document descriptions (all shown through `DescriptionView`).
        func gatherImages(from html: String?) {
            guard let html, html.contains("<") else { return }
            for src in DescriptionBlocks.imageSources(in: html) where ResourceCache.isRemoteHref(src) {
                imageHrefs.insert(src)
            }
        }
        gatherImages(from: document.descriptionHTML)
        var containers = [document.root]
        while let container = containers.popLast() {
            gatherImages(from: container.descriptionHTML)
            containers.append(contentsOf: container.children)
        }
        for placemark in document.root.allPlacemarks {
            for link in placemark.photoLinks where ResourceCache.isRemoteHref(link) {
                photoHrefs.insert(link)
            }
            gatherImages(from: placemark.descriptionHTML)
        }
        let remoteResourceHrefs = Self.cappedHrefs(icons: iconHrefs, photos: photoHrefs, images: imageHrefs)

        return ImportResult(
            displayName: displayName,
            sourceFilename: sourceFilename,
            pointCount: pointCount,
            contentSHA256: sha256,
            storageFolderName: UUID().uuidString,
            originalData: data,
            format: format,
            remoteResourceHrefs: remoteResourceHrefs,
            indexEntries: PlacemarkIndex.entries(for: document)
        )
    }

    /// Caps the carried hrefs at 500 (DoS bound; `ResourceCache.downloadRemote` enforces the
    /// authoritative per-entry cap for all callers). Icons come first, then photo links, then
    /// description images, each group sorted, so a flood of description images can never push
    /// the pin icons out.
    static func cappedHrefs(icons: Set<String>, photos: Set<String>, images: Set<String>) -> [String] {
        var seen: Set<String> = []
        let ordered = (icons.sorted() + photos.sorted() + images.sorted()).filter { seen.insert($0).inserted }
        return Array(ordered.prefix(500))
    }

    // MARK: - Commit

    /// Runs `commit` on a background task so the file writes never block the main actor (B11).
    /// The caller reloads the `Catalog` afterwards, on the main actor.
    ///
    /// - Parameter onStart: Called on the background task just before the writes begin. A test
    ///   seam: it lets a test observe which thread the commit runs on.
    static func commitOffMain(
        _ result: ImportResult,
        storage: StorageLocations,
        cache: ResourceCache,
        onStart: (@Sendable () -> Void)? = nil
    ) async throws -> CatalogEntry {
        try await detachedCommit(result, storage: storage, cache: cache, onStart: onStart)
    }

    /// Persists a prepared import result to disk: creates the per-entry folder, writes the
    /// `metadata.json` sidecar and the original file, caches embedded resources, and fires a
    /// detached background task to download any remote resources.
    ///
    /// The catalogue is sourced from the folders on disk, so this writes files only — it
    /// does not touch any in-memory list. The caller reloads the `Catalog` afterwards so the
    /// new folder shows up.
    ///
    /// Ordering invariant: the **sidecar is written before the original**. The scanner skips
    /// a folder that has a sidecar but no original yet (harmless — it rescans once the file
    /// lands), so a crash between the two writes leaves the entry dormant until the original
    /// arrives, then surfaces with its *intended* identity. The reverse order (original-first)
    /// would leave a bare original that the scanner self-heals under a fresh random UUID —
    /// identity drift. Both files share the folder-name UUID, so the recovered entry is the
    /// same entry either way.
    ///
    /// - Returns: The `CatalogEntry` that now exists on disk.
    /// - Throws: A file-system error if folder creation or file writing fails.
    @discardableResult
    static func commit(
        _ result: ImportResult,
        storage: StorageLocations,
        cache: ResourceCache
    ) throws -> CatalogEntry {
        // The folder name is always a UUID string generated by `prepare`; reuse it as the
        // entry identity so `entry.id` equals the folder UUID (see EntryMetadata.id).
        guard let id = UUID(uuidString: result.storageFolderName) else {
            preconditionFailure("storageFolderName must be a UUID string: \(result.storageFolderName)")
        }
        let entry = CatalogEntry(
            id: id,
            displayName: result.displayName,
            sourceFilename: result.sourceFilename,
            importDate: .now,
            pointCount: result.pointCount,
            contentSHA256: result.contentSHA256,
            storageFolderName: result.storageFolderName,
            trashedAt: nil
        )

        // Create on-disk folders before writing any files. From here on a failure must leave
        // nothing behind: an orphan folder is skipped by the scanner forever and a retry would
        // create a second one (B8, E3).
        do {
            try storage.createFolders(for: entry)

            // Write the synced metadata sidecar FIRST (see ordering invariant above).
            try storage.writeMetadata(entry.metadata, for: entry)

            // Write the original file bytes.
            try storage.writeOriginal(result.originalData, for: entry)
        } catch {
            removeFailedImport(entry, storage: storage)
            throw error
        }

        // The resource cache and search index are derivable, so a failure here never fails the
        // import: drop the `resources/` directory (its existence is the scanner's
        // "materialized" marker) and let the materialisation pass rebuild it.
        let resourcesDir = storage.resourcesDirectory(for: entry)
        var cacheIsReady = true
        do {
            if result.format == .kmz {
                try cache.extractEmbedded(fromKMZ: result.originalData, to: resourcesDir)
            }
            try PlacemarkIndex.write(result.indexEntries, to: resourcesDir)
            // Stamp at import so the scanner neither re-parses nor re-stamps a fresh entry.
            PlacemarkIndex.writeSourceStamp(result.contentSHA256, to: resourcesDir)
            PlacemarkIndex.writeDerivedDataVersion(to: resourcesDir)
        } catch {
            ImportService.logger.error(
                """
                Cache write failed for \(entry.storageFolderName, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
            try? FileManager.default.removeItem(at: resourcesDir)
            cacheIsReady = false
        }

        // Kick off remote downloads in the background — non-blocking, offline-first.
        // Skipped when the cache write failed: the materialisation pass rebuilds it all.
        if cacheIsReady {
            downloadRemoteResources(result.remoteResourceHrefs, cache: cache, to: resourcesDir)
        }

        // Make the new entry and its placemarks reachable from system (Core Spotlight) search.
        // Fire-and-forget — a missing index is non-fatal and self-heals on the next pass.
        SpotlightIndexer.index(entry: entry, indexEntries: result.indexEntries)

        return entry
    }
}

/// Removes the synced folder and cache folder of an import that failed part-way. Best effort:
/// the original error is what the caller reports.
private func removeFailedImport(_ entry: CatalogEntry, storage: StorageLocations) {
    do {
        try storage.removeFolder(for: entry)
    } catch {
        ImportService.logger.error(
            """
            Could not clean up failed import \(entry.storageFolderName, privacy: .public): \
            \(error.localizedDescription, privacy: .public)
            """
        )
    }
}

/// Starts the background download of `hrefs`. A free function so the `Task.detached` closure
/// is compiled outside `ImportService.commit` (see the `ClosureLifetimeFixup` note in
/// FavoritesView.swift).
private func downloadRemoteResources(_ hrefs: [String], cache: ResourceCache, to resourcesDir: URL) {
    Task.detached {
        await cache.downloadRemote(hrefs, to: resourcesDir)
    }
}

/// Runs `ImportService.commit` in a detached task. A `nonisolated` free function so the
/// `Task.detached` closure is compiled outside any `@MainActor` caller's SIL (see the
/// `ClosureLifetimeFixup` note in FavoritesView.swift).
private func detachedCommit(
    _ result: ImportResult,
    storage: StorageLocations,
    cache: ResourceCache,
    onStart: (@Sendable () -> Void)?
) async throws -> CatalogEntry {
    try await Task.detached(priority: .userInitiated) {
        onStart?()
        return try ImportService.commit(result, storage: storage, cache: cache)
    }.value
}
