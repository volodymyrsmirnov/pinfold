import CryptoKit
import Foundation
import os

// MARK: - DoS bounds for untrusted input

/// Maximum byte size accepted for a single downloaded remote resource. Remote hrefs come
/// from untrusted KML/KMZ; without a cap a malicious file could point at an arbitrarily
/// large URL and fill the device's disk. Responses over this size are rejected and the
/// href is permanently skipped (never retried).
private let maxResourceBytes = 20 * 1024 * 1024

/// Per-request timeout for a remote resource download, in seconds.
private let downloadTimeout: TimeInterval = 20

/// Concurrent downloads per entry. Matches `URLSession`'s default connections per host, so a
/// file whose images all live on one host keeps every connection busy.
private let maxConcurrentDownloads = 6

/// A 2xx response that is not an image counts as a failed attempt; after this many the href
/// is permanently skipped (a captive portal answering 200 with HTML recovers in between).
private let maxNonImageAttempts = 5

/// Upper bound of the retry backoff.
private let maxBackoff: TimeInterval = 24 * 60 * 60

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
    ///
    /// Throw `DownloadError.tooLarge` for an over-cap body (permanent skip); any other error
    /// is a retryable failure.
    typealias Downloader = @Sendable (URL) async throws -> Data

    /// Supplies the current remote-image policy; read at the start of every download pass.
    typealias PolicyProvider = @Sendable () -> RemoteImagePolicy

    /// The default downloader: `BoundedDownloader` (shared session, transient failures retried)
    /// with the size cap and a 20 s timeout.
    static let urlSessionDownloader: Downloader = { url in
        try await BoundedDownloader.fetch(url, maxBytes: maxResourceBytes, timeout: downloadTimeout)
    }

    /// The default policy provider, reading `UserDefaults.standard`.
    static let storedPolicy: PolicyProvider = {
        RemoteImagePolicy.stored(in: .standard)
    }

    /// What the consent banner needs: how many images are waiting and which hosts they live on.
    struct PendingConsent: Equatable {
        /// Number of recorded remote hrefs not yet downloaded.
        var count: Int
        /// Distinct lowercase hosts of those hrefs, sorted.
        var hosts: [String]

        static let none = PendingConsent(count: 0, hosts: [])
    }

    // MARK: - Properties

    private let downloader: Downloader
    private let policy: PolicyProvider
    private let now: @Sendable () -> Date
    private let store = ResourceManifestStore.shared

    /// Diagnostics for download bounds (dropped over-cap hrefs, rejected payloads).
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "resources"
    )

    // MARK: - Init

    /// Creates a `ResourceCache`.
    ///
    /// - Parameters:
    ///   - downloader: Closure used to fetch remote resources. Defaults to
    ///     `BoundedDownloader`. Pass a stub in tests to avoid network I/O.
    ///   - policy: Supplies the remote-image policy. Defaults to the value stored in
    ///     `UserDefaults.standard` (`.always` when unset).
    ///   - now: Clock used for retry backoff; injectable for tests.
    init(
        downloader: @escaping Downloader = ResourceCache.urlSessionDownloader,
        policy: @escaping PolicyProvider = ResourceCache.storedPolicy,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.downloader = downloader
        self.policy = policy
        self.now = now
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
        var filenames: [String: String] = [:]
        for (key, data) in resources {
            let filename = cachedFilename(for: key)
            try data.write(to: resourcesDir.appendingPathComponent(filename), options: .atomic)
            filenames[key] = filename
        }
        try store.updateManifest(in: resourcesDir) { $0.merge(filenames) { _, new in new } }
    }

    // MARK: - Remote downloads

    /// Downloads each http(s) href via the injected downloader and writes the result to
    /// `resourcesDir`. Individual failures are skipped (offline-first) and retried later
    /// with backoff. The full (capped) href set is always recorded first so
    /// `retryPending(in:)` can resume it, whatever the policy says.
    ///
    /// Honours `RemoteImagePolicy`: `.never` fetches nothing, `.ask` fetches only once the
    /// entry has consent (`grantConsent(in:)`). Hrefs already in the manifest (cached or
    /// permanently skipped) and hrefs still inside their backoff window are not fetched.
    ///
    /// - Parameters:
    ///   - hrefs: Remote resource URLs to download.
    ///   - resourcesDir: Destination `resources/` directory.
    func downloadRemote(_ hrefs: [String], to resourcesDir: URL) async {
        var remote = hrefs.filter(Self.isRemoteHref)
        // Count cap (DoS bound): keep the first N in input order (deterministic), drop the rest.
        if remote.count > maxRemoteResourcesPerEntry {
            let dropped = remote.count - maxRemoteResourcesPerEntry
            let cap = maxRemoteResourcesPerEntry
            Self.logger.warning(
                "Dropping \(dropped, privacy: .public) href(s) over per-entry cap \(cap, privacy: .public)"
            )
            remote = Array(remote.prefix(maxRemoteResourcesPerEntry))
        }
        store.recordHrefs(remote, in: resourcesDir)
        await fetchDue(remote, to: resourcesDir)
    }

    /// Fetches the hrefs that are unresolved and out of backoff, at most
    /// `maxConcurrentDownloads` at a time. They are marked queued in `ResourceActivity` (the
    /// placeholders show progress) until each one ends. Once a download finds the device offline
    /// the pass starts no more: they would all fail the same way, each after its retries.
    private func fetchDue(_ hrefs: [String], to resourcesDir: URL) async {
        let state = store.state(in: resourcesDir)
        // Cleared by the user: wait until the entry is opened (`resumeDeferred(in:)`).
        guard !state.deferredUntilOpened else { return }
        switch policy() {
        case .never: return
        case .ask where !state.consent: return
        default: break
        }
        let manifest = store.manifest(in: resourcesDir)
        let current = now()
        let due = hrefs.filter { href in
            guard manifest[href] == nil else { return false }
            guard let next = state.hrefs[href]?.nextAttemptAt else { return true }
            return next <= current
        }
        guard !due.isEmpty else { return }
        ResourceActivity.begin(due, in: resourcesDir)
        var started = Set<String>()
        await withTaskGroup(of: FetchOutcome.self) { group in
            var iterator = due.makeIterator()
            var offline = false
            for _ in 0 ..< maxConcurrentDownloads {
                guard mayFetch(in: resourcesDir), let href = iterator.next() else { break }
                started.insert(href)
                group.addTask { await self.fetchTracked(href, to: resourcesDir) }
            }
            while let outcome = await group.next() {
                if outcome == .offline {
                    offline = true
                }
                guard !offline, mayFetch(in: resourcesDir), let href = iterator.next() else { continue }
                started.insert(href)
                group.addTask { await self.fetchTracked(href, to: resourcesDir) }
            }
        }
        ResourceActivity.cancel(due.filter { !started.contains($0) }, in: resourcesDir)
    }

    /// How one download ended.
    private enum FetchOutcome { case cached, failed, offline, notStarted }

    /// `fetchOne`, keeping `ResourceActivity` up to date.
    private func fetchTracked(_ href: String, to resourcesDir: URL) async -> FetchOutcome {
        let outcome = await fetchOne(href, to: resourcesDir)
        switch outcome {
        case .notStarted: ResourceActivity.cancel([href], in: resourcesDir)
        case .cached: ResourceActivity.end(href, failed: false, in: resourcesDir)
        case .failed, .offline: ResourceActivity.end(href, failed: true, in: resourcesDir)
        }
        return outcome
    }

    /// Whether a request may start now (re-read before every request): not cancelled, not
    /// deferred, and the current policy and consent allow it.
    private func mayFetch(in resourcesDir: URL) -> Bool {
        guard !Task.isCancelled else { return false }
        let state = store.state(in: resourcesDir)
        guard !state.deferredUntilOpened else { return false }
        switch policy() {
        case .never: return false
        case .ask: return state.consent
        case .always: return true
        }
    }

    private func fetchOne(_ href: String, to resourcesDir: URL) async -> FetchOutcome {
        guard let url = URL(string: href), mayFetch(in: resourcesDir) else { return .notStarted }
        // App Transport Security blocks plain http loads, so fetch over https. Many KML
        // files reference icons via http URLs (e.g. http://maps.google.com/...) whose
        // hosts also serve https. The manifest is still keyed by the original `href`
        // so UI lookups via `localURL(forHref:)` resolve unchanged. A host that serves
        // *only* http (no https) is unsupported by design.
        do {
            let data = try await downloader(Self.httpsUpgraded(url))
            guard data.count <= maxResourceBytes else {
                Self.logger.warning("Rejecting resource over size cap; skipping permanently")
                markSkipped(href, to: resourcesDir)
                return .failed
            }
            guard Self.looksLikeImage(data) else {
                // A 2xx non-image may be a captive portal: retry with backoff, give up
                // only after `maxNonImageAttempts`.
                Self.logger.warning("Rejecting non-image remote resource")
                recordFailure(href, in: resourcesDir, isNonImage: true)
                return .failed
            }
            let filename = cachedFilename(for: href)
            try data.write(to: resourcesDir.appendingPathComponent(filename), options: .atomic)
            try store.updateManifest(in: resourcesDir) { $0[href] = filename }
            store.updateState(in: resourcesDir) { $0.hrefs[href] = nil }
            return .cached
        } catch DownloadError.tooLarge {
            Self.logger.warning("Rejecting resource over size cap; skipping permanently")
            markSkipped(href, to: resourcesDir)
            return .failed
        } catch is CancellationError {
            return .notStarted
        } catch {
            if Self.isConnectivityFailure(error) {
                // The device is offline (not the host's fault): don't burn an attempt or grow the
                // backoff, so the image is fetched as soon as the connection is back.
                Self.logger.debug("Offline; leaving resource pending without penalty")
                return .offline
            }
            // HTTP errors, timeouts, dead hosts (already retried briefly by the downloader):
            // retry later with backoff.
            recordFailure(href, in: resourcesDir, isNonImage: false)
            return .failed
        }
    }

    /// Delay before the next attempt after `attempts` failures: 60 s, doubling, capped at 24 h.
    static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        return min(60 * pow(2, Double(min(attempts - 1, 20))), maxBackoff)
    }

    private func recordFailure(_ href: String, in resourcesDir: URL, isNonImage: Bool) {
        let current = now()
        var giveUp = false
        store.updateState(in: resourcesDir) { state in
            var entry = state.hrefs[href] ?? DownloadState.HrefState(attempts: 0, nextAttemptAt: nil)
            entry.attempts += 1
            // Only 2xx non-image responses count toward giving up (not HTTP/transport failures).
            if isNonImage {
                entry.nonImageResponses += 1
            }
            if isNonImage, entry.nonImageResponses >= maxNonImageAttempts {
                giveUp = true
                state.hrefs[href] = nil
            } else {
                entry.nextAttemptAt = current.addingTimeInterval(Self.backoff(afterAttempts: entry.attempts))
                state.hrefs[href] = entry
            }
        }
        if giveUp {
            Self.logger.warning("Non-image content after repeated attempts; skipping permanently")
            markSkipped(href, to: resourcesDir)
        }
    }

    // MARK: - Consent (RemoteImagePolicy.ask)

    /// What the consent banner should show for this entry: recorded remote hrefs that are not
    /// downloaded yet, but only while the policy is `.ask` and the entry has no consent.
    func pendingConsent(in resourcesDir: URL) -> PendingConsent {
        guard policy() == .ask, !store.state(in: resourcesDir).consent else { return .none }
        let manifest = store.manifest(in: resourcesDir)
        let pending = store.recordedHrefs(in: resourcesDir).filter { manifest[$0] == nil }
        let hosts = Set(pending.compactMap { URL(string: $0)?.host?.lowercased() })
        return PendingConsent(count: pending.count, hosts: hosts.sorted())
    }

    /// Records the user's consent to download this entry's remote images, then downloads
    /// everything pending.
    func grantConsent(in resourcesDir: URL) async {
        store.updateState(in: resourcesDir) { $0.consent = true }
        await retryPending(in: resourcesDir)
    }

    // MARK: - Retry

    /// Re-attempts any hrefs in `hrefs` that are not yet recorded in the manifest and are
    /// outside their backoff window.
    ///
    /// - Parameters:
    ///   - hrefs: The full set of remote hrefs for the entry (same list used at import).
    ///   - resourcesDir: The entry's `resources/` directory.
    func retryPending(_ hrefs: [String], to resourcesDir: URL) async {
        await downloadRemote(hrefs, to: resourcesDir)
    }

    /// Re-attempts downloads for the remote hrefs recorded for this entry (by a prior
    /// `downloadRemote`) that are not yet in the manifest. Reads the persisted href list, so
    /// no re-parse of the original file is needed; a cheap no-op when everything is cached
    /// (or when the entry has no remote resources). Call when connectivity may have been
    /// restored — e.g. from the background materialization pass on app foreground.
    func retryPending(in resourcesDir: URL) async {
        let recorded = store.recordedHrefs(in: resourcesDir)
        guard !recorded.isEmpty else { return }
        await retryPending(recorded, to: resourcesDir)
    }

    // MARK: - Clearing (C9)

    /// Removes this entry's downloaded http(s) images and manifest entries, and defers
    /// downloads until it is opened (`resumeDeferred(in:)`). KMZ-extracted resources, the
    /// search index and permanent-skip markers (empty filename) stay.
    func clearDownloaded(in resourcesDir: URL) {
        let manifest = store.manifest(in: resourcesDir)
        // Skip markers (empty filename) go too: Clear is the user's reset.
        let remoteKeys = manifest.keys.filter { Self.isRemoteHref($0) }
        for key in remoteKeys {
            guard let file = manifest[key], !file.isEmpty else { continue }
            try? FileManager.default.removeItem(at: resourcesDir.appendingPathComponent(file))
        }
        try? store.updateManifest(in: resourcesDir) { current in remoteKeys.forEach { current[$0] = nil } }
        if !store.recordedHrefs(in: resourcesDir).isEmpty {
            store.updateState(in: resourcesDir) { $0.deferredUntilOpened = true }
        }
        ResourceActivity.reset(in: resourcesDir)
    }

    /// Clears the deferral and fetches the recorded hrefs again (policy, consent and backoff
    /// still apply). Call when the entry is opened.
    func resumeDeferred(in resourcesDir: URL) async {
        store.updateState(in: resourcesDir) { $0.deferredUntilOpened = false }
        await retryPending(in: resourcesDir)
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
        let manifest = store.manifest(in: resourcesDir)
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
        try? store.updateManifest(in: resourcesDir) { $0[href] = "" }
        store.updateState(in: resourcesDir) { $0.hrefs[href] = nil }
    }
}
