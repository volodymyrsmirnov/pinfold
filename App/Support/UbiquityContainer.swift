import Foundation

/// Resolves the app's iCloud Drive ubiquity container and stores the user's
/// "sync with iCloud" preference.
///
/// `documentsURL()` performs a **blocking** call (`url(forUbiquityContainerIdentifier:)`)
/// and must be invoked off the main actor. It returns `nil` when iCloud is unavailable
/// (not signed in, restricted, or — as on the unsigned simulator — no container at all),
/// in which case the app falls back to local Application Support storage.
enum UbiquityContainer {

    /// Matches the iCloud container declared in the entitlements and `NSUbiquitousContainers`.
    static let identifier = "iCloud.tech.inkhorn.pinfold"

    /// The container's `Documents` directory (created if needed), or `nil` if iCloud is
    /// unavailable. **Call off the main actor** — this blocks while iCloud initialises.
    static func documentsURL() -> URL? {
        guard let container = FileManager.default
            .url(forUbiquityContainerIdentifier: identifier) else { return nil }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    /// Reads `url`, first materializing it from iCloud if it is a not-yet-downloaded
    /// placeholder (the common case on a second device: the tiny sidecar syncs first, the
    /// original lands as a stub). Safe for non-ubiquitous files — the download request is a
    /// harmless no-op and the wait loop exits immediately because the file already exists.
    ///
    /// **Blocking — call off the main actor.** Polls until the file materialises or
    /// `timeout` elapses, then reads (throwing the usual no-such-file error if it never
    /// arrived).
    static func readDownloadingIfNeeded(_ url: URL, timeout: TimeInterval = 20) throws -> Data {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            let deadline = Date().addingTimeInterval(timeout)
            while !fm.fileExists(atPath: url.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        return try Data(contentsOf: url)
    }
}
