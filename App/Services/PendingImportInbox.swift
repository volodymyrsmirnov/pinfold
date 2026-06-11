import Foundation
import os

/// Drains the App Group inbox directory, importing each KML/KMZ file that has not been
/// seen before, then removes it.
///
/// Inject a custom `inboxURL` in tests — do not rely on the real App Group container.
@MainActor
struct PendingImportInbox {
    /// Diagnostics for per-file import failures. The user-facing `failureLog` carries only
    /// friendly reasons; the underlying errors go here so they stay diagnosable from the
    /// console (follows the `migrationLogger` precedent in `PinfoldApp`).
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Pinfold",
        category: "import"
    )

    // MARK: - Properties

    /// The inbox directory to drain (typically `AppGroup.inboxURL`).
    let inboxURL: URL

    /// The catalogue, used for deduplication and reloaded after importing.
    let catalog: Catalog

    /// On-disk path helpers for creating per-entry folders and writing files.
    let storage: StorageLocations

    /// Cache for writing embedded resources and initiating remote downloads.
    let cache: ResourceCache

    /// Sink for surfacing per-file failures to the user. Optional so existing call sites and
    /// tests that don't care about failures keep compiling; production paths thread it in.
    var failureLog: ImportFailureLog?

    // MARK: - Concurrency guard

    /// In-flight drains keyed by inbox directory path. `PendingImportInbox` is a short-lived
    /// value type reconstructed at each call site (bootstrap, scenePhase, onOpenURL), so a
    /// guard living on an instance wouldn't see sibling drains. This `@MainActor` static
    /// registry makes draining the *same inbox directory* idempotent under concurrency: a
    /// second `drain()` arriving while one is in flight joins the existing task instead of
    /// starting a parallel pass that would double-import the same files (the dedup check reads
    /// pre-drain catalogue state, so two parallel passes both see a file as "new").
    @MainActor private static var inFlight: [String: Task<Int, Never>] = [:]

    // MARK: - Drain

    /// Imports every file in the inbox, skipping content-duplicates — coalescing concurrent
    /// calls on the same inbox directory so each file is imported exactly once.
    ///
    /// If a drain for this inbox path is already running, this awaits that one rather than
    /// starting a second parallel pass (see `inFlight`). The actual import work is in
    /// `performDrain`.
    ///
    /// - Returns: The number of newly imported files (the count from the shared pass when
    ///   coalesced).
    @discardableResult
    func drain() async -> Int {
        let key = inboxURL.path
        if let existing = Self.inFlight[key] {
            return await existing.value
        }
        let task = Task { @MainActor in
            await performDrain()
        }
        Self.inFlight[key] = task
        let result = await task.value
        Self.inFlight[key] = nil
        return result
    }

    /// Imports every file in the inbox, skipping content-duplicates.
    ///
    /// Failure handling distinguishes *permanent* from *transient* errors so a one-off I/O
    /// hiccup is never lost:
    /// - **Parse failure** (`ImportError.parseFailure`): the bytes are not valid KML/KMZ. This
    ///   never succeeds on retry, so the inbox file is removed and the failure recorded.
    /// - **Any other error** (folder creation / write I/O): potentially transient. The inbox
    ///   file is KEPT so a later drain can retry it; the failure is still recorded so the user
    ///   sees it. (The previous behaviour removed the file regardless, losing the import.)
    /// Successfully-imported and deduped-skipped files are always removed. One bad file never
    /// blocks the rest.
    ///
    /// - Returns: The number of newly imported files.
    private func performDrain() async -> Int {
        let fm = FileManager.default

        // If the inbox directory doesn't exist there is nothing to drain.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: inboxURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return 0
        }

        // List inbox contents, skipping hidden files (e.g. .DS_Store).
        let candidates: [URL]
        do {
            candidates = try fm.contentsOfDirectory(
                at: inboxURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return 0
        }

        // Filter out any subdirectories — only process regular files.
        let files = candidates.filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory != true
        }

        var imported = 0
        // Hashes committed within THIS drain. The catalogue is only reloaded at the end, so
        // without this two identical files dropped in one batch would both import.
        var committedHashes: Set<String> = []

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let result = try ImportService.prepare(
                    data: data,
                    sourceFilename: file.lastPathComponent
                )
                let isNew = catalog.entry(withSHA256: result.contentSHA256) == nil
                    && !committedHashes.contains(result.contentSHA256)
                if isNew {
                    _ = try ImportService.commit(
                        result,
                        storage: storage,
                        cache: cache
                    )
                    committedHashes.insert(result.contentSHA256)
                    imported += 1
                }
                // Imported or deduped — either way, done with this inbox file.
                try? fm.removeItem(at: file)
            } catch let ImportError.parseFailure(underlying) {
                // Permanent: the bytes are not valid KML/KMZ. Record and remove so it is not
                // retried forever.
                Self.logger.error(
                    """
                    Parse failure importing '\(file.lastPathComponent, privacy: .public)': \
                    \(underlying.localizedDescription, privacy: .public)
                    """
                )
                failureLog?.record(
                    filename: file.lastPathComponent,
                    reason: String(
                        localized: "Not a valid KML or KMZ file.",
                        comment: "Import failure reason: the file could not be parsed."
                    )
                )
                try? fm.removeItem(at: file)
            } catch {
                // Potentially transient (e.g. an I/O error writing to disk). Record a friendly
                // reason (the raw error is developer-speak) but KEEP the file so a later drain
                // can retry it; the underlying error goes to the console log.
                Self.logger.error(
                    """
                    Transient failure importing '\(file.lastPathComponent, privacy: .public)': \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                failureLog?.record(
                    filename: file.lastPathComponent,
                    reason: String(
                        localized: "Couldn't save the file. It will be retried automatically.",
                        comment: "Import failure reason: a transient I/O error; the import will be retried."
                    )
                )
            }
        }

        // Reload so freshly-imported folders appear in the catalogue.
        if imported > 0 { await catalog.reload() }
        return imported
    }
}
