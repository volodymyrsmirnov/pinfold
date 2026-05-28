import CryptoKit
import Foundation

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
        let remote = hrefs.filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        // Record the full expected set up front so a later retry pass can fill in any that
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
                let filename = cachedFilename(for: href)
                let dest = resourcesDir.appendingPathComponent(filename)
                try data.write(to: dest, options: .atomic)
                var manifest = loadManifest(from: resourcesDir)
                manifest[href] = filename
                try saveManifest(manifest, to: resourcesDir)
            } catch {
                // Offline-first: skip this href. The recorded-hrefs file lets `retryPending`
                // re-attempt it on a later materialization pass / app foreground.
            }
        }
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
        guard let filename = manifest[href] else { return nil }
        let url = resourcesDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
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
