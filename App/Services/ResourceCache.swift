import CryptoKit
import Foundation
import os

// MARK: - DoS bounds for untrusted input

/// Maximum byte size accepted for a single downloaded remote resource. Remote hrefs come
/// from untrusted KML/KMZ; without a cap a malicious file could point at an arbitrarily
/// large URL and fill the device's disk. Responses over this size are rejected and the
/// href is permanently skipped (never retried).
private let maxResourceBytes = 20 * 1024 * 1024

/// Maximum number of remote resources downloaded per imported entry. Caps the fan-out of a
/// crafted file that lists thousands of hrefs (disk + arbitrary outbound requests). Enforced
/// at the download stage so every caller is covered; the first N in input order are kept.
private let maxRemoteResourcesPerEntry = 500

/// Manages the `resources/` cache directory for an imported KML/KMZ file.
///
/// Responsibilities:
/// - Writes KMZ-embedded resources directly to disk (no network required).
/// - Downloads remote http(s) icon/photo hrefs via an injected downloader.
/// - Maintains a `manifest.json` mapping original href/path to cached filename so the
///   UI can resolve an href to a local `URL` without knowledge of the naming scheme.
/// - Records the full set of expected remote hrefs (`remote-hrefs.json`) so a later
///   `retryPending(in:)` pass can fill in downloads that failed while offline — without
///   re-parsing the original file.
/// - Skips individual download failures (offline-first) and retries them later.
///
/// The downloader closure is injectable so tests never hit the network.
///
/// `ResourceCache` is `Sendable` because all its state is a single immutable `let`
/// constant. It is not `@Observable` — the resource cache writes to disk and the UI
/// resolves resources by calling `localURL(forHref:in:)` directly (no SwiftUI binding).
final class ResourceCache: Sendable {
    // MARK: - Types

    /// A function that fetches bytes for a given URL.
    typealias Downloader = @Sendable (URL) async throws -> Data

    /// The default downloader backed by `URLSession.shared`.
    static let urlSessionDownloader: Downloader = { url in
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    // MARK: - Properties

    private let downloader: Downloader

    /// Diagnostics for download bounds (dropped over-cap hrefs, rejected payloads).
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "resources"
    )

    // MARK: - Init

    /// Creates a `ResourceCache` with the given downloader.
    ///
    /// - Parameter downloader: Closure used to fetch remote resources. Defaults to
    ///   `URLSession.shared`. Pass a stub in tests to avoid network I/O.
    init(downloader: @escaping Downloader = ResourceCache.urlSessionDownloader) {
        self.downloader = downloader
    }

    // MARK: - Filename derivation

    /// Returns a deterministic cached filename for `href`.
    ///
    /// The filename is the lowercase hex SHA-256 of the href bytes, with the path
    /// extension from the href appended (or `"img"` if there is none). This ensures:
    /// - unique filenames per resource (collision-resistant),
    /// - consistent lookup regardless of how the href was encountered,
    /// - no filesystem-unsafe characters.
    ///
    /// - Parameter href: The original resource reference (URL or archive-relative path).
    /// - Returns: A flat filename like `"a3f2...d1.png"` or `"b4c9...img"`.
    func cachedFilename(for href: String) -> String {
        let digest = SHA256.hash(data: Data(href.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        // Use URL(string:) to parse extension so query strings don't pollute it.
        // Fall back to (href as NSString).pathExtension for non-URL paths like "images/icon-1.png".
        let ext: String
        if let parsed = URL(string: href), !parsed.pathExtension.isEmpty {
            ext = parsed.pathExtension
        } else {
            let nsExt = (href as NSString).pathExtension
            ext = nsExt.isEmpty ? "img" : nsExt
        }
        return "\(hex).\(ext)"
    }

    // MARK: - Embedded resources (KMZ)

    /// Writes every entry in `resources` to `resourcesDir` using a flattened cached
    /// filename, then updates the manifest.
    ///
    /// - Parameters:
    ///   - resources: KMZ embedded resources keyed by archive-relative path
    ///                (e.g. `"images/icon-1.png"`).
    ///   - resourcesDir: The `resources/` directory for the entry (must already exist).
    /// - Throws: A file-system error if a write fails.
    func writeEmbedded(_ resources: [String: Data], to resourcesDir: URL) throws {
        guard !resources.isEmpty else { return }
        var manifest = loadManifest(from: resourcesDir)
        for (key, data) in resources {
            let filename = cachedFilename(for: key)
            let dest = resourcesDir.appendingPathComponent(filename)
            try data.write(to: dest, options: .atomic)
            manifest[key] = filename
        }
        try saveManifest(manifest, to: resourcesDir)
    }

    // MARK: - Remote downloads

    /// Downloads each http(s) href via the injected downloader and writes the result to
    /// `resourcesDir`. Individual failures are silently skipped (offline-first). The
    /// manifest is updated after each successful write, and the full expected href set is
    /// recorded so `retryPending(in:)` can re-attempt failures later.
    ///
    /// - Parameters:
    ///   - hrefs: Remote resource URLs to download.
    ///   - resourcesDir: Destination `resources/` directory.
    func downloadRemote(_ hrefs: [String], to resourcesDir: URL) async {
        var remote = hrefs.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        // Count cap (DoS bound): a crafted file can list thousands of hrefs. Keep the first N
        // in input order so the cap is deterministic, and drop the rest before recording or
        // downloading anything.
        if remote.count > maxRemoteResourcesPerEntry {
            let dropped = remote.count - maxRemoteResourcesPerEntry
            let cap = maxRemoteResourcesPerEntry
            Self.logger.warning(
                "Dropping \(dropped, privacy: .public) href(s) over per-entry cap \(cap, privacy: .public)"
            )
            remote = Array(remote.prefix(maxRemoteResourcesPerEntry))
        }
        // Record the (capped) expected set up front so a later retry pass can fill in any that
        // fail now, without re-parsing the original file.
        recordExpectedRemoteHrefs(remote, to: resourcesDir)
        for href in remote {
            guard let url = URL(string: href) else { continue }
            // App Transport Security blocks plain http loads, so fetch over https. Many KML
            // files reference icons via http URLs (e.g. http://maps.google.com/...) whose
            // hosts also serve https. The manifest is still keyed by the original `href`
            // so UI lookups via `localURL(forHref:)` resolve unchanged. A host that serves
            // *only* http (no https) is unsupported by design — the download fails and the
            // UI falls back to a generic pin.
            let downloadURL = Self.httpsUpgraded(url)
            do {
                let data = try await downloader(downloadURL)
                // Reject payloads that are too large or aren't an image we can render. These
                // are *content* failures, not network failures: mark the href permanently
                // skipped (see `markSkipped`) so `retryPending` never re-fetches it.
                guard data.count <= maxResourceBytes else {
                    let size = data.count
                    Self.logger.warning(
                        "Rejecting resource over size cap (\(size, privacy: .public) bytes); skipping"
                    )
                    markSkipped(href, to: resourcesDir)
                    continue
                }
                guard Self.looksLikeImage(data) else {
                    Self.logger.warning("Rejecting non-image remote resource; skipping permanently")
                    markSkipped(href, to: resourcesDir)
                    continue
                }
                let filename = cachedFilename(for: href)
                let dest = resourcesDir.appendingPathComponent(filename)
                try data.write(to: dest, options: .atomic)
                var manifest = loadManifest(from: resourcesDir)
                manifest[href] = filename
                try saveManifest(manifest, to: resourcesDir)
            } catch {
                // Offline-first: skip this href *transiently*. The recorded-hrefs file lets
                // `retryPending` re-attempt it on a later materialization pass / app foreground.
            }
        }
    }

    // MARK: - Image sniffing

    /// Returns `true` if `data` begins with the magic bytes of an image format we render.
    ///
    /// Content-type response headers are unreliable (and absent for archive resources), and we
    /// hand these bytes straight to the image pipeline, so we sniff the actual bytes. Covers
    /// PNG, JPEG, GIF, WebP, BMP, TIFF, and the ISO-BMFF `ftyp` family (HEIC/HEIF/AVIF).
    static func looksLikeImage(_ data: Data) -> Bool {
        // Need at least the largest signature window we inspect (12 bytes for RIFF/WEBP & ftyp).
        guard data.count >= 12 else {
            // BMP ("BM") and the shortest TIFF/JPEG headers still fit in fewer bytes.
            return shortSignatureMatch(data)
        }
        let b = [UInt8](data.prefix(12))

        // PNG: 89 50 4E 47
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }
        // JPEG: FF D8 FF
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
        // GIF: 47 49 46 38 ("GIF8")
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true }
        // BMP: 42 4D ("BM")
        if b[0] == 0x42, b[1] == 0x4D { return true }
        // TIFF little-endian "II*\0" / big-endian "MM\0*"
        if b[0] == 0x49, b[1] == 0x49, b[2] == 0x2A, b[3] == 0x00 { return true }
        if b[0] == 0x4D, b[1] == 0x4D, b[2] == 0x00, b[3] == 0x2A { return true }
        // WebP: "RIFF"...."WEBP"
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }
        // ISO-BMFF ftyp box (bytes 4-7 == "ftyp"), brand at bytes 8-11. Compare the brand as
        // raw ASCII bytes to avoid a Data→String conversion.
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = Array(b[8 ..< 12])
            let imageBrands: Set<[UInt8]> = [
                Array("heic".utf8), Array("heix".utf8), Array("hevc".utf8),
                Array("mif1".utf8), Array("msf1".utf8), Array("avif".utf8),
            ]
            if imageBrands.contains(brand) { return true }
        }
        return false
    }

    /// Signature check for payloads shorter than the 12-byte window (BMP, short TIFF/JPEG).
    private static func shortSignatureMatch(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(4))
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return true } // BMP
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true } // JPEG
        if b.count >= 4 {
            if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true } // PNG
            if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true } // GIF
            if b[0] == 0x49, b[1] == 0x49, b[2] == 0x2A, b[3] == 0x00 { return true } // TIFF LE
            if b[0] == 0x4D, b[1] == 0x4D, b[2] == 0x00, b[3] == 0x2A { return true } // TIFF BE
        }
        return false
    }

    /// Returns `url` with its scheme upgraded from `http` to `https`; other URLs unchanged.
    static func httpsUpgraded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    // MARK: - Retry

    /// Re-attempts any hrefs in `hrefs` that are not yet recorded in the manifest.
    ///
    /// - Parameters:
    ///   - hrefs: The full set of remote hrefs for the entry (same list used at import).
    ///   - resourcesDir: The entry's `resources/` directory.
    func retryPending(_ hrefs: [String], to resourcesDir: URL) async {
        let manifest = loadManifest(from: resourcesDir)
        let pending = hrefs.filter { manifest[$0] == nil }
        await downloadRemote(pending, to: resourcesDir)
    }

    /// Re-attempts downloads for the remote hrefs recorded for this entry (by a prior
    /// `downloadRemote`) that are not yet in the manifest. Reads the persisted href list, so
    /// no re-parse of the original file is needed; a cheap no-op when everything is cached
    /// (or when the entry has no remote resources). Call when connectivity may have been
    /// restored — e.g. from the background materialization pass on app foreground.
    func retryPending(in resourcesDir: URL) async {
        let recorded = loadRecordedHrefs(from: resourcesDir)
        guard !recorded.isEmpty else { return }
        await retryPending(recorded, to: resourcesDir)
    }

    // MARK: - Lookup

    /// Returns the cached file `URL` for `href` if a record exists in the manifest AND
    /// the file is present on disk; otherwise `nil`.
    ///
    /// - Parameters:
    ///   - href: The original resource reference.
    ///   - resourcesDir: The entry's `resources/` directory.
    /// - Returns: A file `URL` that exists on disk, or `nil`.
    func localURL(forHref href: String, in resourcesDir: URL) -> URL? {
        let manifest = loadManifest(from: resourcesDir)
        // A non-nil but empty filename is the permanent-skip sentinel (see `markSkipped`):
        // the href is "resolved" but maps to no on-disk file.
        guard let filename = manifest[href], !filename.isEmpty else { return nil }
        let url = resourcesDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Permanent skip

    /// Records `href` as permanently rejected (over-size or non-image content).
    ///
    /// Skip-tracking representation: a manifest entry mapping the href to an **empty filename**.
    /// This reuses the existing "is this href done?" mechanism — `retryPending` filters on
    /// `manifest[href] == nil`, so a skipped href (non-nil, empty) is treated as resolved and
    /// never re-fetched. `localURL` appends the empty filename and then fails its
    /// `fileExists` check, so a skipped href resolves to no image (UI falls back to a generic
    /// pin). No separate sidecar is needed.
    private func markSkipped(_ href: String, to resourcesDir: URL) {
        var manifest = loadManifest(from: resourcesDir)
        manifest[href] = ""
        try? saveManifest(manifest, to: resourcesDir)
    }

    // MARK: - Manifest helpers

    private func manifestURL(in resourcesDir: URL) -> URL {
        resourcesDir.appendingPathComponent("manifest.json")
    }

    /// Loads the manifest from disk. Returns an empty dictionary if the file doesn't
    /// exist or cannot be decoded.
    private func loadManifest(from resourcesDir: URL) -> [String: String] {
        let url = manifestURL(in: resourcesDir)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    /// Encodes `manifest` to JSON and writes it atomically to `resourcesDir/manifest.json`.
    private func saveManifest(_ manifest: [String: String], to resourcesDir: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(in: resourcesDir), options: .atomic)
    }

    // MARK: - Recorded remote hrefs (for retry)

    private func recordedHrefsURL(in resourcesDir: URL) -> URL {
        resourcesDir.appendingPathComponent("remote-hrefs.json")
    }

    /// The full set of remote http(s) hrefs expected for this entry, recorded at download
    /// time so failed downloads can be retried later without re-parsing the original.
    private func loadRecordedHrefs(from resourcesDir: URL) -> [String] {
        guard let data = try? Data(contentsOf: recordedHrefsURL(in: resourcesDir)),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return decoded
    }

    /// Merges `hrefs` into the recorded set and writes it back (sorted, atomic). No-op when
    /// `hrefs` adds nothing new, so repeated `downloadRemote` calls don't rewrite the file.
    private func recordExpectedRemoteHrefs(_ hrefs: [String], to resourcesDir: URL) {
        guard !hrefs.isEmpty else { return }
        var set = Set(loadRecordedHrefs(from: resourcesDir))
        let original = set
        set.formUnion(hrefs)
        guard set != original else { return }
        if let data = try? JSONEncoder().encode(set.sorted()) {
            try? data.write(to: recordedHrefsURL(in: resourcesDir), options: .atomic)
        }
    }
}
