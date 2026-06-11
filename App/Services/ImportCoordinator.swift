import Foundation
import Observation

// MARK: - ImportCoordinator

/// Manages the state machine for the file-import flow in `HomeView`.
///
/// Import is a two-phase pipeline: `prepare` runs off-main (hashing + parsing),
/// then `commit` runs on the main actor (writes files to disk). When a
/// duplicate SHA-256 is detected, the coordinator stalls and presents an alert so
/// the user can choose Import Anyway or Skip. After the user responds, the
/// coordinator moves on to the next URL in the queue.
///
/// `ImportCoordinator` is `@Observable` so `HomeView` can react to its state.
@MainActor @Observable
final class ImportCoordinator {
    // MARK: - Alert content

    struct DuplicateAlert {
        let result: ImportResult
        let existingEntry: CatalogEntry
    }

    // MARK: - Published state

    /// Non-nil while the duplicate-import alert is visible.
    var pendingDuplicate: DuplicateAlert?

    /// Non-nil when an import error should be presented to the user.
    var importError: Error?

    // MARK: - Private state

    private var queue: [URL] = []
    private var isProcessing = false

    // MARK: - Entry point

    /// Enqueues a set of security-scoped URLs for sequential import processing.
    func enqueue(_ urls: [URL], catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        queue.append(contentsOf: urls)
        if !isProcessing {
            processNext(catalog: catalog, storage: storage, cache: cache)
        }
    }

    // MARK: - Duplicate resolution

    /// Called when the user taps "Import Anyway" on the duplicate alert.
    func importAnyway(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard let dup = pendingDuplicate else { return }
        pendingDuplicate = nil
        commit(dup.result, catalog: catalog, storage: storage, cache: cache)
        processNext(catalog: catalog, storage: storage, cache: cache)
    }

    /// Called when the user taps "Skip" on the duplicate alert, or when the alert is
    /// dismissed by any other means. Idempotent: if the alert was already resolved (e.g.
    /// via "Import Anyway"), this is a no-op so the queue is never advanced twice.
    func skipDuplicate(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard pendingDuplicate != nil else { return }
        pendingDuplicate = nil
        processNext(catalog: catalog, storage: storage, cache: cache)
    }

    // MARK: - Private queue processing

    private func commit(_ result: ImportResult, catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        do {
            try ImportService.commit(result, storage: storage, cache: cache)
            Task { await catalog.reload() }
        } catch {
            importError = error
        }
    }

    private func processNext(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard !queue.isEmpty else {
            isProcessing = false
            return
        }
        isProcessing = true
        let url = queue.removeFirst()
        Task {
            await self.importURL(url, catalog: catalog, storage: storage, cache: cache)
        }
    }

    private func importURL(
        _ url: URL,
        catalog: Catalog,
        storage: StorageLocations,
        cache: ResourceCache
    ) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            importError = error
            processNext(catalog: catalog, storage: storage, cache: cache)
            return
        }

        let result: ImportResult
        do {
            result = try ImportService.prepare(data: data, sourceFilename: url.lastPathComponent)
        } catch {
            importError = error
            processNext(catalog: catalog, storage: storage, cache: cache)
            return
        }

        if let existing = catalog.entry(withSHA256: result.contentSHA256) {
            // Stall the queue and show the duplicate alert; processNext runs after the
            // user responds.
            pendingDuplicate = DuplicateAlert(result: result, existingEntry: existing)
        } else {
            do {
                try ImportService.commit(result, storage: storage, cache: cache)
                // Await the reload so the next file's duplicate check sees this one.
                await catalog.reload()
            } catch {
                importError = error
            }
            processNext(catalog: catalog, storage: storage, cache: cache)
        }
    }
}
