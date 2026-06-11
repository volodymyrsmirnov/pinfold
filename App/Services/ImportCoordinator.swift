import Foundation
import Observation

// MARK: - ImportCoordinator

/// Manages the state machine for the file-import flow in `HomeView`.
///
/// Import is a two-phase pipeline: `prepare` runs off-main (hashing + parsing),
/// then `commit` runs on the main actor (writes files to disk). When a
/// duplicate SHA-256 is detected, the coordinator stalls and presents an alert so
/// the user can choose Import Anyway or Skip. After the user responds, the
/// coordinator moves on to the next item in the queue.
///
/// The queue is drained by a single driving `Task` (`processingTask`): each pass prepares one
/// item off-main, then commits and **awaits** `catalog.reload()` on the main actor before
/// pulling the next item, so a later item's duplicate check always sees every earlier commit.
/// Duplicate resolution (`importAnyway` / `skipDuplicate`) follows the same await-before-next
/// discipline — see `importAnyway`.
///
/// `ImportCoordinator` is `@Observable` so `HomeView` can react to its state.
@MainActor @Observable
final class ImportCoordinator {
    // MARK: - Alert content

    struct DuplicateAlert {
        let result: ImportResult
        let existingEntry: CatalogEntry
    }

    // MARK: - Queue items

    /// A queued import. Production enqueues `.url`s from the file importer / inbox; tests
    /// enqueue `.prepared` byte buffers via `enqueuePrepared` so they need no security-scoped
    /// file URLs. Both converge on the same `importData` core.
    private enum PendingImport {
        case url(URL)
        case prepared(data: Data, filename: String)
    }

    // MARK: - Published state

    /// Non-nil while the duplicate-import alert is visible.
    var pendingDuplicate: DuplicateAlert?

    /// Non-nil when an import error should be presented to the user.
    var importError: Error?

    /// `true` while the queue is actively being processed (between enqueue and the queue
    /// draining / stalling on a duplicate). Drives the progress indicator in `HomeView`.
    private(set) var isImporting = false

    /// The display filename of the item currently being imported, for the progress label.
    private(set) var currentFilename: String?

    // MARK: - Private state

    private var queue: [PendingImport] = []
    /// The single in-flight drain Task, if any. `drainForTesting` awaits it.
    private var processingTask: Task<Void, Never>?

    // MARK: - Entry point

    /// Enqueues a set of security-scoped URLs for sequential import processing.
    func enqueue(_ urls: [URL], catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        queue.append(contentsOf: urls.map(PendingImport.url))
        startProcessingIfNeeded(catalog: catalog, storage: storage, cache: cache)
    }

    /// Test-only entry point: enqueues already-prepared `(data, filename)` pairs, bypassing the
    /// security-scoped URL read so unit tests need no file URLs. The production path stays
    /// URL-based (`enqueue`); both share the `importData` core, so this exercises the real
    /// dedup / commit / reload / stall logic.
    func enqueuePrepared(
        _ items: [(Data, String)],
        catalog: Catalog,
        storage: StorageLocations,
        cache: ResourceCache
    ) {
        queue.append(contentsOf: items.map { PendingImport.prepared(data: $0.0, filename: $0.1) })
        startProcessingIfNeeded(catalog: catalog, storage: storage, cache: cache)
    }

    // MARK: - Duplicate resolution

    /// Called when the user taps "Import Anyway" on the duplicate alert.
    ///
    /// Commits the duplicate copy and **awaits** `catalog.reload()` before resuming the queue,
    /// mirroring the normal-path discipline in `importData`: the next queued item's duplicate
    /// check must run against the post-commit catalogue, never a stale snapshot.
    func importAnyway(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard let dup = pendingDuplicate else { return }
        pendingDuplicate = nil
        // Resume processing with a leading commit+reload of the duplicate copy, then continue
        // the queue. Awaiting the reload here (rather than the old fire-and-forget Task) is the
        // race fix: the next item sees the just-committed copy.
        startProcessing(catalog: catalog, storage: storage, cache: cache) { [weak self] in
            await self?.commitAndReload(dup.result, catalog: catalog, storage: storage, cache: cache)
        }
    }

    /// Called when the user taps "Skip" on the duplicate alert, or when the alert is
    /// dismissed by any other means. Idempotent: if the alert was already resolved (e.g.
    /// via "Import Anyway"), this is a no-op so the queue is never advanced twice.
    func skipDuplicate(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard pendingDuplicate != nil else { return }
        pendingDuplicate = nil
        startProcessing(catalog: catalog, storage: storage, cache: cache, leading: nil)
    }

    // MARK: - Testing

    /// Awaits the in-flight drain Task (if any) so tests can deterministically wait for the
    /// queue to settle or stall on a duplicate. No-op in production.
    func drainForTesting() async {
        await processingTask?.value
    }

    // MARK: - Driving loop

    private func startProcessingIfNeeded(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) {
        guard processingTask == nil, pendingDuplicate == nil else { return }
        startProcessing(catalog: catalog, storage: storage, cache: cache, leading: nil)
    }

    /// Starts a single drain Task that optionally runs `leading` first (used by `importAnyway`
    /// to commit the just-approved duplicate), then processes the queue until it empties or
    /// stalls on a duplicate. `isImporting` is held `true` for the lifetime of the drain.
    private func startProcessing(
        catalog: Catalog,
        storage: StorageLocations,
        cache: ResourceCache,
        leading: (@MainActor () async -> Void)?
    ) {
        guard processingTask == nil else { return }
        isImporting = true
        processingTask = Task { [weak self] in
            await leading?()
            await self?.drainQueue(catalog: catalog, storage: storage, cache: cache)
            guard let self else { return }
            isImporting = false
            currentFilename = nil
            processingTask = nil
        }
    }

    /// Processes queued items one at a time until the queue empties or a duplicate stalls it.
    private func drainQueue(catalog: Catalog, storage: StorageLocations, cache: ResourceCache) async {
        while pendingDuplicate == nil, !queue.isEmpty {
            let item = queue.removeFirst()
            await importItem(item, catalog: catalog, storage: storage, cache: cache)
        }
    }

    // MARK: - Single-item import

    private func importItem(
        _ item: PendingImport,
        catalog: Catalog,
        storage: StorageLocations,
        cache: ResourceCache
    ) async {
        switch item {
        case let .url(url):
            await importURL(url, catalog: catalog, storage: storage, cache: cache)
        case let .prepared(data, filename):
            await importData(data, filename: filename, catalog: catalog, storage: storage, cache: cache)
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
            return
        }
        await importData(data, filename: url.lastPathComponent, catalog: catalog, storage: storage, cache: cache)
    }

    /// The shared import core: prepares `data` off the published path, then either commits (and
    /// awaits the reload) or stalls on a duplicate. Sets `currentFilename` for the progress UI.
    private func importData(
        _ data: Data,
        filename: String,
        catalog: Catalog,
        storage: StorageLocations,
        cache: ResourceCache
    ) async {
        currentFilename = filename

        let result: ImportResult
        do {
            // `prepare` is a plain static function (no actor isolation); run it off-main so the
            // hashing + parsing of a large KMZ doesn't block the main actor.
            result = try await Task.detached { try ImportService.prepare(data: data, sourceFilename: filename) }.value
        } catch {
            importError = error
            return
        }

        if let existing = catalog.entry(withSHA256: result.contentSHA256) {
            // Stall the queue and show the duplicate alert; the drain loop exits and a fresh
            // drain starts once the user resolves the alert.
            pendingDuplicate = DuplicateAlert(result: result, existingEntry: existing)
        } else {
            await commitAndReload(result, catalog: catalog, storage: storage, cache: cache)
        }
    }

    /// Commits `result` to disk and **awaits** the catalog reload so the next item's duplicate
    /// check sees this commit. Any failure surfaces via `importError`.
    private func commitAndReload(
        _ result: ImportResult,
        catalog: Catalog,
        storage: StorageLocations,
        cache: ResourceCache
    ) async {
        do {
            try ImportService.commit(result, storage: storage, cache: cache)
            await catalog.reload()
        } catch {
            importError = error
        }
    }
}
