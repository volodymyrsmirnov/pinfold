import Foundation

/// Drains the App Group inbox directory, importing each KML/KMZ file that has not been
/// seen before, then removes it.
///
/// Inject a custom `inboxURL` in tests — do not rely on the real App Group container.
@MainActor
struct PendingImportInbox {

    // MARK: - Properties

    /// The inbox directory to drain (typically `AppGroup.inboxURL`).
    let inboxURL: URL

    /// The catalogue, used for deduplication and reloaded after importing.
    let catalog: Catalog

    /// On-disk path helpers for creating per-entry folders and writing files.
    let storage: StorageLocations

    /// Cache for writing embedded resources and initiating remote downloads.
    let cache: ResourceCache

    // MARK: - Drain

    /// Imports every file in the inbox, skipping content-duplicates, then removes each
    /// inbox file (whether imported or skipped). Per-file errors are swallowed so one bad
    /// file never blocks the rest.
    ///
    /// - Returns: The number of newly imported files.
    @discardableResult
    func drain() async -> Int {
        let fm = FileManager.default

        // If the inbox directory doesn't exist there is nothing to drain.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: inboxURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
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

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let result = try ImportService.prepare(
                    data: data,
                    sourceFilename: file.lastPathComponent
                )
                if catalog.entry(withSHA256: result.contentSHA256) == nil {
                    _ = try ImportService.commit(
                        result,
                        storage: storage,
                        cache: cache
                    )
                    imported += 1
                }
            } catch {
                // Per-file errors are swallowed; the inbox file is still removed below.
            }
            // Always remove the inbox file, regardless of import outcome.
            try? fm.removeItem(at: file)
        }

        // Reload so freshly-imported folders appear in the catalogue.
        if imported > 0 { await catalog.reload() }
        return imported
    }
}
