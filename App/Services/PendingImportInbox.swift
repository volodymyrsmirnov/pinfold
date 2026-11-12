import Foundation

/// Scans an inbox directory (the share extension's App Group inbox, or the app's
/// `Documents/Inbox` for "Open in Pinfold" copies) and hands every file in it to the shared
/// `ImportCoordinator` queue.
///
/// The inbox no longer imports anything itself: the coordinator reads, hashes, parses and
/// commits off the main actor, deletes each copy on success or a permanent (parse) failure,
/// keeps it on a transient failure so a later scan retries it, and ignores a file that is
/// already queued or in flight (so a scan racing an "Open in" of the same file cannot import
/// it twice, B16).
///
/// Inject a custom `inboxURL` in tests — do not rely on the real App Group container.
@MainActor
struct PendingImportInbox {
    // MARK: - Properties

    /// The inbox directory to scan (typically `AppGroup.inboxURL`).
    let inboxURL: URL

    /// The queue that performs the imports.
    let coordinator: ImportCoordinator

    /// The catalogue, used by the coordinator for deduplication and reloaded after importing.
    let catalog: Catalog

    /// Cache for writing embedded resources and initiating remote downloads.
    let cache: ResourceCache

    // MARK: - Drain

    /// Enqueues every regular file in the inbox on the coordinator. Returns immediately; the
    /// coordinator imports in the background.
    ///
    /// The share extension prefixes `<UUID>-` to file names for collision safety; the prefix is
    /// stripped here (also for files already sitting in the inbox) so it never becomes a title.
    ///
    /// - Returns: The number of files newly enqueued (files already queued or in flight are
    ///   not counted).
    @discardableResult
    func drain() -> Int {
        let fm = FileManager.default

        // If the inbox directory doesn't exist there is nothing to drain.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: inboxURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return 0
        }

        // List inbox contents, skipping hidden files (e.g. .DS_Store).
        guard let candidates = try? fm.contentsOfDirectory(
            at: inboxURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        // Only regular files; sorted so the import order is deterministic.
        let files = candidates
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
            // The share extension copies to `.<UUID>.partial` and renames when complete.
            .filter { !$0.lastPathComponent.hasSuffix(".partial") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map {
                ImportCoordinator.OwnedFile(
                    url: $0,
                    filename: SafeFilename.strippingInboxPrefix($0.lastPathComponent)
                )
            }

        return coordinator.enqueueOwned(files, catalog: catalog, cache: cache)
    }
}
