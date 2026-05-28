import CryptoKit
import Foundation
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
    /// KMZ-embedded resources keyed by archive-relative path (empty for plain KML).
    let embeddedResources: [String: Data]
    /// Remote http(s) resource URLs gathered from icon styles and placemark photo links.
    let remoteResourceHrefs: [String]
}

// MARK: - ImportError

/// Errors thrown by `ImportService`.
enum ImportError: Error {
    /// The file bytes could not be parsed as valid KML or KMZ.
    case parseFailure(underlying: Error)
}

// MARK: - ImportService

/// Static methods that implement the two-phase import flow:
/// 1. `prepare` — off-main, pure computation; returns `ImportResult`.
/// 2. `commit`  — main-actor, performs storage (writes files to disk); returns `CatalogEntry`.
enum ImportService {
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
    static func prepare(data: Data, sourceFilename: String) throws -> ImportResult {
        let sha256 = sha256Hex(data)

        let parsed: ParsedKML
        do {
            parsed = try KMLReader.read(data: data)
        } catch {
            throw ImportError.parseFailure(underlying: error)
        }

        let document = parsed.document

        // Display name: document name → filename without extension.
        let stem = (sourceFilename as NSString).deletingPathExtension
        let displayName = document.name.flatMap { $0.isEmpty ? nil : $0 } ?? stem

        let pointCount = document.pointCount

        // Gather remote resource hrefs from icon styles and placemark photo links.
        // Deduplicate and keep only http/https URLs (KMZ paths are handled separately).
        var hrefSet: Set<String> = []
        for style in document.styles.values {
            guard let href = style.iconHref else { continue }
            if href.hasPrefix("http://") || href.hasPrefix("https://") {
                hrefSet.insert(href)
            }
        }
        for placemark in document.root.allPlacemarks {
            for link in placemark.photoLinks {
                if link.hasPrefix("http://") || link.hasPrefix("https://") {
                    hrefSet.insert(link)
                }
            }
        }
        let remoteResourceHrefs = Array(hrefSet)

        return ImportResult(
            displayName: displayName,
            sourceFilename: sourceFilename,
            pointCount: pointCount,
            contentSHA256: sha256,
            storageFolderName: UUID().uuidString,
            originalData: data,
            embeddedResources: parsed.embeddedResources,
            remoteResourceHrefs: remoteResourceHrefs
        )
    }

    // MARK: - Commit (main actor)

    /// Persists a prepared import result to disk: creates the per-entry folder, writes the
    /// original file and its `metadata.json` sidecar, caches embedded resources, and fires a
    /// detached background task to download any remote resources.
    ///
    /// The catalogue is sourced from the folders on disk, so this writes files only — it
    /// does not touch any in-memory list. The caller reloads the `Catalog` afterwards so the
    /// new folder shows up.
    ///
    /// - Returns: The `CatalogEntry` that now exists on disk.
    /// - Throws: A file-system error if folder creation or file writing fails.
    @MainActor
    @discardableResult
    static func commit(
        _ result: ImportResult,
        storage: StorageLocations,
        cache: ResourceCache
    ) throws -> CatalogEntry {
        let entry = CatalogEntry(
            id: UUID(),
            displayName: result.displayName,
            sourceFilename: result.sourceFilename,
            importDate: .now,
            pointCount: result.pointCount,
            contentSHA256: result.contentSHA256,
            storageFolderName: result.storageFolderName,
            trashedAt: nil
        )

        // Create on-disk folders before writing any files.
        try storage.createFolders(for: entry)

        // Write the original file bytes.
        try result.originalData.write(to: storage.originalFile(for: entry), options: .atomic)

        // Write the synced metadata sidecar next to the original.
        try storage.writeMetadata(entry.metadata, for: entry)

        // Write KMZ-embedded resources synchronously (no network needed).
        let resourcesDir = storage.resourcesDirectory(for: entry)
        try cache.writeEmbedded(result.embeddedResources, to: resourcesDir)

        // Kick off remote downloads in the background — non-blocking, offline-first.
        let hrefs = result.remoteResourceHrefs
        Task.detached {
            await cache.downloadRemote(hrefs, to: resourcesDir)
        }

        return entry
    }
}
